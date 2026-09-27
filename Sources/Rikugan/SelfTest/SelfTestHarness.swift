import Foundation
import Network
import WebKit

/// Tiny loopback HTTP server serving the bundled self-test fixtures. Every request is logged
/// (path, query, headers) so tests can prove what did — and did not — reach the network, which
/// is the only reliable way to observe content-blocker decisions from outside WebKit.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request { let path: String; let query: String?; let headers: [String: String]; let date: Date }

    private var listener: NWListener?
    private let root: URL
    private let queue = DispatchQueue(label: "rikugan.selftest.http")
    private let lock = NSLock()
    private var log: [Request] = []
    private(set) var port: UInt16 = 0

    init(root: URL) { self.root = root }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }
    func requested(_ path: String) -> Bool { requests.contains { $0.path == path } }
    func count(_ path: String) -> Int { requests.filter { $0.path == path }.count }
    func clearLog() { lock.lock(); log.removeAll(); lock.unlock() }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    self.port = port
                    if once.fire() { continuation.resume(returning: port) }
                case .failed(let error):
                    if once.fire() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let lines = request.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            var path = target
            var query: String?
            if let q = target.firstIndex(of: "?") { path = String(target[..<q]); query = String(target[target.index(after: q)...]) }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if line.isEmpty { break }
                if let colon = line.firstIndex(of: ":") {
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            self.lock.lock()
            self.log.append(Request(path: path, query: query, headers: headers, date: Date()))
            self.lock.unlock()

            var status = "200 OK"
            var body = Data()
            var type = "text/plain"
            if path == "/echo-headers" {
                body = (try? JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys])) ?? Data()
                type = "application/json"
            } else {
                if path == "/" { path = "/index.html" }
                let file = self.root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
                if file.path.hasPrefix(self.root.standardizedFileURL.path), let contents = try? Data(contentsOf: file) {
                    body = contents
                    type = MIME.type(forExtension: file.pathExtension)
                } else {
                    status = "404 Not Found"
                    body = Data("not found".utf8)
                }
            }
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// Shared state and helpers for one self-test suite run.
///
/// Waiting is always "poll a concrete condition until a fixed deadline, then fail with what was
/// observed" — never a fixed sleep that hopes the app has caught up, and never a retry of the
/// action under test.
@MainActor final class SelfTestContext {
    let suite: String
    let manager: TabManager
    let root: URL
    let server: LocalHTTPServer
    let base: String
    private(set) var results: [SelfTestRunner.Result] = []
    /// Extra structured data written to the suite's JSON report (e.g. the compatibility matrix).
    var extras: [String: Any] = [:]
    var services: AppServices { AppServices.shared }
    var profile: ProfileContext { services.profile }

    init(suite: String, manager: TabManager, root: URL, server: LocalHTTPServer) {
        self.suite = suite
        self.manager = manager
        self.root = root
        self.server = server
        base = "http://127.0.0.1:\(server.port)"
    }

    func url(_ path: String) -> URL { URL(string: base + path)! }

    func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        results.append(SelfTestRunner.Result(name: name, passed: passed, detail: detail))
        print("SELFTEST [\(suite)] \(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — " + detail)")
    }

    /// Polls `condition` every 100 ms until it holds or `seconds` elapse.
    func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }

    func eval(_ tab: BrowserTab, _ js: String, world: WKContentWorld = .page, arguments: [String: Any] = [:]) async -> Any? {
        guard let webView = tab.webView else { return nil }
        return try? await webView.rkCall(js, arguments: arguments, world: world)
    }

    /// Evaluates and returns the error text instead of swallowing it.
    func evalResult(_ tab: BrowserTab, _ js: String, world: WKContentWorld = .page, arguments: [String: Any] = [:]) async -> (Any?, String?) {
        guard let webView = tab.webView else { return (nil, "no web view") }
        do { return (try await webView.rkCall(js, arguments: arguments, world: world), nil) } catch { return (nil, error.localizedDescription) }
    }

    func attr(_ tab: BrowserTab, _ name: String) async -> String? {
        await eval(tab, "return document.documentElement.getAttribute(n);", arguments: ["n": name]) as? String
    }

    func attrs(_ tab: BrowserTab) async -> [String: String] {
        let value = await eval(tab, "const r = {}; for (const a of document.documentElement.attributes) r[a.name] = a.value; return r;")
        return (value as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    /// Waits until the tab's main frame finished loading `path` (optionally with query).
    func waitLoaded(_ tab: BrowserTab, path: String? = nil, query: String? = nil, seconds: Double = 20) async -> Bool {
        await waitUntil(seconds) {
            guard let webView = tab.webView, !webView.isLoading, let url = webView.url else { return false }
            if let path, url.path != path { return false }
            if let query, url.query != query { return false }
            return (await self.eval(tab, "return document.readyState;") as? String) == "complete"
        }
    }

    @discardableResult
    func open(_ path: String, background: Bool = false) async -> BrowserTab {
        let target = url(path)
        let tab = manager.newTab(url: target, background: background, isPrivate: false)
        _ = await waitLoaded(tab, path: target.path, query: target.query)
        return tab
    }

    /// Installs a bundled fixture extension without a prompt (the self-test is explicit consent).
    func installExtension(_ directory: String, seed: String) throws -> LoadedExtension {
        let pending = try ExtensionInstaller.shared.prepareDirectory(root.appendingPathComponent(directory), source: .bundled, storeURL: nil, seed: seed)
        try profile.extensions.install(pending)
        guard let ext = profile.extensions.loaded[pending.extensionID] else { throw RikuganError("extension \(directory) did not load") }
        return ext
    }

    func installScript(_ path: String) throws -> InstalledUserScript {
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return try profile.userscripts.install(source: source, sourceURL: nil, requires: [:], resources: [:])
    }

    func waitForDNRCompile(after date: Date, seconds: Double = 20) async -> Bool {
        await waitUntil(seconds) {
            let status = self.profile.extensions.dnrStatus
            return !status.compiling && (status.lastCompiled ?? .distantPast) >= date
        }
    }

    /// Writes `Documents/SelfTestReports/<suite>.json` (collected by CI with `simctl get_app_container`).
    func writeReport(summary: String) {
        let report: [String: Any] = [
            "suite": suite,
            "summary": summary,
            "date": ISO8601DateFormatter().string(from: Date()),
            "build": Bundle.main.infoDictionary?["RikuganGitCommit"] as? String ?? "unknown",
            "environment": {
                #if targetEnvironment(simulator)
                return "simulator"
                #else
                return "device"
                #endif
            }(),
            "os": UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
            "results": results.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] },
            "extras": extras,
        ]
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SelfTestReports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if JSONSerialization.isValidJSONObject(report), let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("\(suite).json"))
        } else {
            print("SELFTEST [\(suite)] report not JSON-serialisable")
        }
    }
}
