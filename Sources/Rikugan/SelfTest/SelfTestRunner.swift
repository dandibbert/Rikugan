import Foundation
import Network
import SwiftUI
import WebKit

/// Tiny loopback HTTP server serving the bundled self-test fixtures.
final class LocalHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let root: URL
    private let queue = DispatchQueue(label: "rikugan.selftest.http")
    private(set) var port: UInt16 = 0

    init(root: URL) { self.root = root }

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
            let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = line.split(separator: " ")
            var path = parts.count > 1 ? String(parts[1]) : "/"
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            if path == "/" { path = "/index.html" }
            let file = self.root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
            var status = "200 OK"
            var body = Data()
            if file.path.hasPrefix(self.root.standardizedFileURL.path), let contents = try? Data(contentsOf: file) {
                body = contents
            } else {
                status = "404 Not Found"
                body = Data("not found".utf8)
            }
            let head = "HTTP/1.1 \(status)\r\nContent-Type: \(MIME.type(forExtension: file.pathExtension))\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// In-app compatibility self-test (spec §50 / §51). Installs a fixture extension and userscript,
/// opens a local test page and verifies that they actually work — not only that they installed.
@MainActor final class SelfTestRunner: ObservableObject {
    static let shared = SelfTestRunner()
    struct Result: Identifiable { let id = UUID(); let name: String; let passed: Bool; let detail: String }

    @Published private(set) var results: [Result] = []
    @Published private(set) var running = false
    @Published private(set) var summary: String?
    static var autoRun = false
    private var server: LocalHTTPServer?

    static func configureFromLaunchArguments() {
        autoRun = ProcessInfo.processInfo.arguments.contains("-RikuganSelfTest")
        if autoRun {
            // Deterministic environment for UI tests.
            AppServices.shared.prefs.restoreTabs = false
            AppServices.shared.prefs.consoleCaptureEnabled = true
        }
    }

    private func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        results.append(Result(name: name, passed: passed, detail: detail))
    }

    func run(in manager: TabManager) async {
        guard !running else { return }
        running = true
        results.removeAll()
        summary = nil
        defer { running = false }
        let services = AppServices.shared
        let profile = services.profile
        guard let root = Bundle.main.url(forResource: "SelfTest", withExtension: nil) else {
            record("fixtures", false, "SelfTest resources missing"); finish(); return
        }
        // 1. Local server.
        let server = LocalHTTPServer(root: root)
        self.server = server
        let port: UInt16
        do { port = try await server.start() } catch { record("本地测试服务器", false, error.localizedDescription); finish(); return }
        record("本地测试服务器", port > 0, "127.0.0.1:\(port)")
        let base = "http://127.0.0.1:\(port)"

        // 2. Install the fixture extension (no prompt) and userscript.
        do {
            let pending = try ExtensionInstaller.shared.prepareDirectory(root.appendingPathComponent("ext"), source: .bundled, storeURL: nil, seed: "selftest")
            try profile.extensions.install(pending)
            record("扩展安装（manifest 解析）", true, pending.extensionID)
        } catch { record("扩展安装（manifest 解析）", false, error.localizedDescription) }
        do {
            let script = try profile.userscripts.installBundled(named: "selftest")
            profile.userscripts.replaceValues([:], for: script.id)
            record("用户脚本安装（metadata 解析）", true, script.name)
        } catch { record("用户脚本安装（metadata 解析）", false, error.localizedDescription) }
        services.adBlock.addCustomRule("127.0.0.1##.rikugan-ad-test")
        guard let ext = profile.extensions.enabledExtensions.first(where: { $0.manifest.name == "Rikugan Self-Test Extension" }) else {
            record("扩展运行时", false, "extension not loaded"); finish(); return
        }
        // Wait for the background worker and rule lists.
        let bgReady = await waitUntil(15) { ext.background?.isReady == true }
        record("后台 Service Worker 启动", bgReady)
        _ = await waitUntil(20) { !services.adBlock.isCompiling }
        _ = await waitUntil(10) { !profile.extensions.dnrLists.isEmpty }

        // 3. Open the test page.
        let tab = manager.newTab(url: URL(string: base + "/index.html")!, isPrivate: false)
        let loaded = await waitUntil(20) { tab.webView?.isLoading == false && tab.webView?.url?.path == "/index.html" }
        record("测试页面加载", loaded)
        _ = await waitUntil(8) { (self.attr(tab, "data-scripting-result")) != nil && self.attr(tab, "data-gmxhr") != nil }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let snapshot = await pageState(tab)
        check(snapshot, "data-cs-start", "Test 1 内容脚本 document_start")
        check(snapshot, "data-cs-end", "Test 1 内容脚本 document_end / DOM")
        record("Test 1 内容脚本 CSS", snapshot["cssColor"] == "rgb(1, 2, 3)", snapshot["cssColor"] ?? "")
        check(snapshot, "data-messaging", "Test 2 runtime.sendMessage")
        check(snapshot, "data-port", "Test 2 runtime.connect Port")
        check(snapshot, "data-storage", "Test 3 chrome.storage.local")
        check(snapshot, "data-scripting", "Test 5 scripting.executeScript")
        check(snapshot, "data-scripting-result", "Test 5 executeScript 返回值")
        check(snapshot, "data-permissions", "Test 6 host permissions")
        check(snapshot, "data-bg-storage", "Test 7 后台唤醒 + 消息处理")
        check(snapshot, "data-to-content", "Test 7 tabs.sendMessage → content")
        record("Test 8 DNR 屏蔽测试资源", snapshot["blocked"] != "loaded" && snapshot["pageScript"] == "true", "blocked.js=\(snapshot["blocked"] ?? "nil")")
        check(snapshot, "data-unsupported", "未实现 API 返回 Unsupported API")
        // Userscript suite.
        check(snapshot, "data-us", "用户脚本 @match 注入", expected: "ran")
        check(snapshot, "data-gm-storage", "GM storage")
        check(snapshot, "data-gmxhr", "GM_xmlhttpRequest")
        record("GM_addStyle", snapshot["gmColor"] == "rgb(4, 5, 6)", snapshot["gmColor"] ?? "")
        check(snapshot, "data-unsafe-window", "unsafeWindow")
        record("AdBlock 元素隐藏规则", snapshot["adHidden"] == "true", snapshot["adHidden"] ?? "")
        // Menu command.
        if let command = tab.menuCommands.first {
            tab.runMenuCommand(command)
            _ = await waitUntil(5) { self.attr(tab, "data-menu") == "ok" }
        }
        record("GM_registerMenuCommand", attr(tab, "data-menu") == "ok", "\(tab.menuCommands.count) command(s)")
        // Test 4: popup.
        let holder = PopupHolder()
        if let popup = URL(string: ext.baseURL + "popup.html") {
            holder.load(ExtensionRuntime.PopupRequest(extID: ext.id, url: popup, tabID: tab.numericID, title: "popup"), runtime: profile.extensions)
            if let webView = holder.webView { BackgroundHostContainer.shared.attach(webView) }
            let popupOK = await waitUntil(10) { profile.extensions.storage(ext, area: "local")["popupSawTab"] == String(tab.numericID) }
            record("Test 4 Popup → 当前标签页", popupOK, profile.extensions.storage(ext, area: "local")["popupSawTab"] ?? "nil")
            holder.webView?.removeFromSuperview()
            holder.close(runtime: profile.extensions)
        }
        // Exclude + reload + persistence.
        tab.reload()
        _ = await waitUntil(10) { tab.webView?.isLoading == false }
        _ = await waitUntil(5) { self.attr(tab, "data-gm-runs") == "2" }
        record("刷新后脚本再次运行 + GM 值持久化", attr(tab, "data-gm-runs") == "2", attr(tab, "data-gm-runs") ?? "nil")
        tab.load(URL(string: base + "/index.html?skip=1")!)
        _ = await waitUntil(10) { tab.webView?.isLoading == false && tab.webView?.url?.query == "skip=1" }
        try? await Task.sleep(nanoseconds: 800_000_000)
        record("@exclude 生效", attr(tab, "data-us") == nil, attr(tab, "data-us") ?? "not injected")
        // New tab + private tab.
        let privateTab = manager.newTab(url: URL(string: base + "/index.html")!, isPrivate: true)
        _ = await waitUntil(10) { privateTab.webView?.isLoading == false && privateTab.webView?.url != nil }
        _ = await waitUntil(5) { self.attr(privateTab, "data-us") == "ran" }
        record("无痕标签页中运行用户脚本", attr(privateTab, "data-us") == "ran")
        manager.close(privateTab)
        finish()
    }

    private func finish() {
        let passed = results.filter(\.passed).count
        summary = "SELFTEST \(passed == results.count ? "PASS" : "FAIL") \(passed)/\(results.count)"
        for result in results where !result.passed { print("SELFTEST FAILED: \(result.name) – \(result.detail)") }
        print(summary ?? "")
        server?.stop()
    }

    private func check(_ snapshot: [String: String], _ attribute: String, _ name: String, expected: String = "ok") {
        let value = snapshot[attribute]
        record(name, value == expected, value ?? "nil")
    }

    private var attrCache: [Int: [String: String]] = [:]

    private func attr(_ tab: BrowserTab, _ name: String) -> String? { attrCache[tab.numericID]?[name] }

    private func pageState(_ tab: BrowserTab) async -> [String: String] {
        guard let webView = tab.webView else { return [:] }
        let script = """
        const r = {};
        for (const a of document.documentElement.attributes) r[a.name] = a.value;
        r.cssColor = getComputedStyle(document.getElementById('css-test')).color;
        r.gmColor = getComputedStyle(document.getElementById('gm-style')).color;
        r.adHidden = String(getComputedStyle(document.getElementById('ad')).display === 'none');
        r.blocked = document.documentElement.getAttribute('data-blocked') || 'not-loaded';
        r.pageScript = String(window.__pageScriptRan === true);
        return r;
        """
        let result = (try? await webView.rkCall(script, world: .page)) as? [String: Any] ?? [:]
        let mapped = result.compactMapValues { $0 as? String }
        attrCache[tab.numericID] = mapped
        return mapped
    }

    /// Polls a condition, refreshing the page attribute cache for every live tab.
    private func waitUntil(_ seconds: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            for tab in TabRegistry.shared.allTabs where tab.webView?.url?.host == "127.0.0.1" { _ = await pageState(tab) }
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return condition()
    }
}

struct SelfTestView: View {
    @EnvironmentObject private var manager: TabManager
    @StateObject private var runner = SelfTestRunner.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await runner.run(in: manager) }
                    } label: { HStack { Label("运行自检", systemImage: "play.circle"); if runner.running { Spacer(); ProgressView() } } }
                    .disabled(runner.running)
                    .accessibilityIdentifier("runSelfTest")
                    if let summary = runner.summary {
                        Text(summary).font(.headline).foregroundStyle(summary.contains("PASS") ? .green : .red)
                            .accessibilityIdentifier("selftest-summary")
                    }
                } footer: {
                    Text("在本机 127.0.0.1 启动测试页面，安装测试扩展与测试脚本，并验证内容脚本、消息、存储、Popup、scripting、权限、后台、DNR、GM API、元素隐藏是否真正工作。会在当前身份中留下测试扩展和脚本，可在管理页删除。")
                }
                ForEach(runner.results) { result in
                    HStack(alignment: .top) {
                        Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(result.passed ? .green : .red)
                        VStack(alignment: .leading) {
                            Text(result.name)
                            if !result.detail.isEmpty { Text(result.detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("自检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear {
            if SelfTestRunner.autoRun && runner.results.isEmpty && !runner.running {
                Task { await runner.run(in: manager) }
            }
        }
    }
}
