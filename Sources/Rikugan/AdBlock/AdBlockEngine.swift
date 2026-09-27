import Foundation
import WebKit
import CryptoKit

/// AdBlock engine (spec §21): built-in rules, user custom rules and AdGuard / ABP subscriptions.
/// Network rules compile to WKContentRuleList; cosmetic rules are injected per host as CSS.
@MainActor final class AdBlockEngine: ObservableObject {
    struct Stats: Equatable { var network = 0; var cosmetic = 0; var unsupported = 0 }

    @Published private(set) var subscriptions: [FilterSubscription] = []
    @Published private(set) var customRules = ""
    @Published private(set) var allowlist: [String] = []
    @Published private(set) var isCompiling = false
    @Published private(set) var lastError: String?
    @Published private(set) var stats = Stats()
    @Published private(set) var lastCompiled: Date?
    private(set) var activeLists: [WKContentRuleList] = []
    private var cosmetic = CosmeticIndex()
    private var enabled = true
    private var compileTask: Task<Void, Never>?
    private let stateFile = JSONFile<State>(AppPaths.filters.appendingPathComponent("state.json"))

    struct State: Codable {
        var subscriptions: [FilterSubscription]
        var customRules: String
        var allowlist: [String]
    }

    func start(prefs: Preferences) {
        enabled = prefs.adBlockEnabled
        if let state = stateFile.load() {
            subscriptions = state.subscriptions
            for builtIn in FilterSubscription.defaults where !subscriptions.contains(where: { $0.id == builtIn.id }) { subscriptions.append(builtIn) }
            customRules = state.customRules
            allowlist = state.allowlist
        } else {
            subscriptions = FilterSubscription.defaults
        }
        recompile()
        Task {
            // Fetch enabled subscriptions that were never downloaded or are older than 4 days.
            let stale = subscriptions.filter { $0.enabled && ($0.lastUpdated.map { Date().timeIntervalSince($0) > 4 * 86400 } ?? true) }
            if !stale.isEmpty { await updateSubscriptions(only: Set(stale.map(\.id))) }
        }
    }

    private func saveState() {
        stateFile.save(State(subscriptions: subscriptions, customRules: customRules, allowlist: allowlist))
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        recompile()
    }

    // MARK: Queries

    func isAllowlisted(_ host: String) -> Bool { allowlist.contains { DomainTools.host(host, isWithin: $0) } }

    func cosmeticRules(forHost host: String) -> (selectors: [String], css: [String]) {
        guard enabled, !host.isEmpty else { return ([], []) }
        return cosmetic.rules(forHost: host)
    }

    // MARK: Mutations

    func addCustomRule(_ rule: String) {
        let line = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !customRules.components(separatedBy: .newlines).contains(line) else { return }
        customRules = customRules.isEmpty ? line : customRules + "\n" + line
        saveState()
        recompile()
    }

    func removeCustomRule(_ rule: String) {
        customRules = customRules.components(separatedBy: .newlines).filter { $0.trimmingCharacters(in: .whitespaces) != rule }.joined(separator: "\n")
        saveState()
        recompile()
    }

    func setCustomRules(_ text: String) {
        customRules = text
        saveState()
        recompile()
    }

    var customRuleLines: [String] {
        customRules.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("!") }
    }

    func setAllowlisted(_ host: String, _ allowed: Bool) {
        let host = host.lowercased()
        allowlist.removeAll { $0 == host }
        if allowed { allowlist.append(host) }
        saveState()
        recompile()
    }

    func setSubscription(_ id: String, enabled: Bool) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[index].enabled = enabled
        saveState()
        if enabled && subscriptions[index].lastUpdated == nil {
            Task { await updateSubscriptions(only: [id]) }
        } else {
            recompile()
        }
    }

    func addSubscription(name: String, url: String) {
        guard URL(string: url)?.scheme?.hasPrefix("http") == true else { lastError = "订阅地址无效"; return }
        let item = FilterSubscription(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: name.isEmpty ? url : name, url: url, enabled: true)
        subscriptions.append(item)
        saveState()
        Task { await updateSubscriptions(only: [item.id]) }
    }

    func removeSubscription(_ id: String) {
        subscriptions.removeAll { $0.id == id && !$0.isBuiltIn }
        try? FileManager.default.removeItem(at: cacheURL(id))
        saveState()
        recompile()
    }

    func replaceState(customRules: String, subscriptions: [FilterSubscription], allowlist: [String]) {
        self.customRules = customRules
        if !subscriptions.isEmpty { self.subscriptions = subscriptions }
        self.allowlist = allowlist
        saveState()
        recompile()
    }

    private func cacheURL(_ id: String) -> URL { AppPaths.filters.appendingPathComponent("\(id).txt") }

    func updateSubscriptions(only ids: Set<String>? = nil) async {
        var errors: [String] = []
        for index in subscriptions.indices where subscriptions[index].enabled && (ids?.contains(subscriptions[index].id) ?? true) {
            let item = subscriptions[index]
            guard let url = URL(string: item.url) else { continue }
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                request.setValue("Rikugan/1.0", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw RikuganError("HTTP \(http.statusCode)") }
                try data.write(to: cacheURL(item.id), options: .atomic)
                subscriptions[index].lastUpdated = Date()
            } catch {
                errors.append("\(item.name)：\(error.localizedDescription)")
            }
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        saveState()
        recompile()
    }

    // MARK: Compilation

    func recompile() {
        compileTask?.cancel()
        isCompiling = true
        let enabled = self.enabled
        var sources: [String] = []
        if enabled {
            if let url = Bundle.main.url(forResource: "builtin", withExtension: "txt"), let text = try? String(contentsOf: url, encoding: .utf8) {
                sources.append(text)
            }
            for item in subscriptions where item.enabled {
                if let text = try? String(contentsOf: cacheURL(item.id), encoding: .utf8) { sources.append(text) }
            }
            sources.append(customRules)
        }
        let allowlist = self.allowlist
        compileTask = Task { [weak self] in
            let (documents, index, stats, counts) = await Task.detached(priority: .utility) { () -> ([String], CosmeticIndex, Stats, [Int]) in
                var network: [NetworkRule] = []
                var cosmetic = CosmeticIndex()
                var stats = Stats()
                var counts: [Int] = []
                for source in sources {
                    let result = FilterListParser.parse(source)
                    network += result.network
                    cosmetic.merge(result.cosmetic)
                    stats.unsupported += result.unsupported
                    counts.append(result.network.count + result.cosmetic.selectorCount)
                }
                stats.network = network.count
                stats.cosmetic = cosmetic.selectorCount
                let docs = network.isEmpty && allowlist.isEmpty ? [] : ContentBlockerCompiler.compile(network, allowlistedHosts: allowlist)
                return (docs, cosmetic, stats, counts)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.cosmetic = index
            self.stats = stats
            for (i, item) in self.subscriptions.enumerated() where item.enabled {
                let position = self.subscriptions.filter(\.enabled).firstIndex(of: item).map { $0 + 1 } ?? 0
                if position < counts.count { self.subscriptions[i].ruleCount = counts[position] }
            }
            var lists: [WKContentRuleList] = []
            for (i, json) in documents.enumerated() {
                let identifier = "rikugan-adblock-\(i)"
                let hash = SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
                let hashKey = "rikugan.adblock.hash.\(i)"
                if UserDefaults.standard.string(forKey: hashKey) == hash,
                   let cached = await WKContentRuleListStore.default().rkLookUp(identifier) {
                    lists.append(cached)
                    continue
                }
                if let list = await WKContentRuleListStore.default().rkCompile(identifier, json) {
                    lists.append(list)
                    UserDefaults.standard.set(hash, forKey: hashKey)
                } else if let list = await ContentBlockerCompilerRuntime.compileBisecting(json: json, identifier: identifier) {
                    lists.append(list)
                    UserDefaults.standard.removeObject(forKey: hashKey)
                }
                if Task.isCancelled { return }
            }
            self.activeLists = lists
            self.isCompiling = false
            self.lastCompiled = Date()
            WebViewFactory.refreshAllContentRuleLists()
            WebViewFactory.invalidateAllTabs()
        }
    }
}

/// Compiles a rule list, isolating rules WebKit rejects by bisection so one bad rule cannot
/// disable the whole list.
enum ContentBlockerCompilerRuntime {
    @MainActor static func compileBisecting(json: String, identifier: String) async -> WKContentRuleList? {
        guard let rules = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return nil }
        var good: [[String: Any]] = []
        var stack: [[[String: Any]]] = [rules]
        var attempts = 0
        while let chunk = stack.popLast(), attempts < 400 {
            attempts += 1
            let text = JSONText.encode(chunk)
            if await WKContentRuleListStore.default().rkCompile(identifier + "-probe", text) != nil {
                good += chunk
            } else if chunk.count > 1 {
                let mid = chunk.count / 2
                stack.append(Array(chunk[mid...]))
                stack.append(Array(chunk[..<mid]))
            }
        }
        await WKContentRuleListStore.default().rkRemove(identifier + "-probe")
        guard !good.isEmpty else { return nil }
        return await WKContentRuleListStore.default().rkCompile(identifier, JSONText.encode(good))
    }
}

extension WKContentRuleListStore {
    @MainActor func rkCompile(_ identifier: String, _ json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in continuation.resume(returning: list) }
        }
    }

    @MainActor func rkLookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            lookUpContentRuleList(forIdentifier: identifier) { list, _ in continuation.resume(returning: list) }
        }
    }

    @MainActor func rkRemove(_ identifier: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
        }
    }
}
