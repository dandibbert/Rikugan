import Foundation
import Network
import SwiftUI
import WebKit

/// In-app self-test (spec §50 / §51). Each suite installs its own fixtures, drives the real app
/// code against a local test server and verifies observable behaviour — not only that things
/// installed. Suites: core, pageworld, fonts, dnr, lifecycle, stress, archive, compat.
/// Launch with `-RikuganSelfTest` (core) or `-RikuganSuite <name>` (implies autorun).
@MainActor final class SelfTestRunner: ObservableObject {
    static let shared = SelfTestRunner()
    struct Result: Identifiable { let id = UUID(); let name: String; let passed: Bool; let detail: String }
    static let suites = ["core", "pageworld", "fonts", "dnr", "lifecycle", "stress", "archive", "compat"]

    @Published private(set) var results: [Result] = []
    @Published private(set) var running = false
    @Published private(set) var summary: String?
    @Published var suite = "core"
    static var autoRun = false
    static var launchSuite = "core"

    static func configureFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-RikuganSuite"), index + 1 < args.count {
            launchSuite = args[index + 1]
            autoRun = true
        }
        if args.contains("-RikuganSelfTest") { autoRun = true }
        if autoRun {
            // Deterministic environment for UI tests.
            AppServices.shared.prefs.restoreTabs = false
            AppServices.shared.prefs.consoleCaptureEnabled = true
            shared.suite = launchSuite
        }
    }

    func run(in manager: TabManager) async {
        guard !running else { return }
        running = true
        results.removeAll()
        summary = nil
        defer { running = false }
        let name = suite
        guard let root = Bundle.main.url(forResource: "SelfTest", withExtension: nil) else {
            results = [Result(name: "fixtures", passed: false, detail: "SelfTest resources missing")]
            finish(nil); return
        }
        let server = LocalHTTPServer(root: root)
        do { _ = try await server.start() } catch {
            results = [Result(name: "本地测试服务器", passed: false, detail: error.localizedDescription)]
            finish(nil); return
        }
        let ctx = SelfTestContext(suite: name, manager: manager, root: root, server: server)
        ctx.record("本地测试服务器", server.port > 0, ctx.base)
        switch name {
        case "core": await CoreSuite.run(ctx)
        case "pageworld": await PageWorldSuite.run(ctx)
        case "fonts": await FontSuite.run(ctx)
        case "dnr": await DNRSuite.run(ctx)
        case "lifecycle": await LifecycleSuite.run(ctx)
        case "stress": await BackgroundStressSuite.run(ctx)
        case "archive": await ArchiveSuite.run(ctx)
        case "compat": await CompatSuite.run(ctx)
        default: ctx.record("未知测试套件", false, name)
        }
        results = ctx.results
        finish(ctx)
        server.stop()
    }

    private func finish(_ ctx: SelfTestContext?) {
        let passed = results.filter(\.passed).count
        let failures = results.filter { !$0.passed }.map { "\($0.name)（\($0.detail)）" }.joined(separator: "；")
        summary = "SELFTEST \(suite) \(passed == results.count && !results.isEmpty ? "PASS" : "FAIL") \(passed)/\(results.count)" + (failures.isEmpty ? "" : " — " + failures)
        for result in results where !result.passed { print("SELFTEST FAILED: \(result.name) – \(result.detail)") }
        print(summary ?? "")
        ctx?.writeReport(summary: summary ?? "")
    }
}

/// Original end-to-end suite: fixture extension + userscript + AdBlock on a local page.
@MainActor enum CoreSuite {
    static func run(_ ctx: SelfTestContext) async {
        let services = ctx.services
        let profile = ctx.profile
        let installStarted = Date()
        let ext: LoadedExtension
        do {
            ext = try ctx.installExtension("ext", seed: "selftest")
            ctx.record("扩展安装（manifest 解析）", true, ext.id)
        } catch { ctx.record("扩展安装（manifest 解析）", false, error.localizedDescription); return }
        do {
            let script = try profile.userscripts.installBundled(named: "selftest")
            profile.userscripts.replaceValues([:], for: script.id)
            ctx.record("用户脚本安装（metadata 解析）", true, script.name + (script.usesPageWorld ? "（页面世界）" : "（隔离世界）"))
        } catch { ctx.record("用户脚本安装（metadata 解析）", false, error.localizedDescription) }
        services.adBlock.addCustomRule("127.0.0.1##.rikugan-ad-test")
        let bgReady = await ctx.waitUntil(15) { ext.background?.isReady == true }
        ctx.record("后台 Service Worker 启动", bgReady, ext.background?.diagnostics ?? "no background host")
        _ = await ctx.waitUntil(20) { !services.adBlock.isCompiling }
        let dnrReady = await ctx.waitForDNRCompile(after: installStarted)
        ctx.record("DNR 规则编译", dnrReady && !profile.extensions.dnrLists.isEmpty, "\(profile.extensions.dnrStatus.convertedRules) rules")

        let tab = await ctx.open("/index.html")
        ctx.record("测试页面加载", tab.webView?.url?.path == "/index.html")
        // Wait for every asynchronous result to be reported by the page (no fixed delay).
        let expected = ["data-cs-start", "data-cs-end", "data-messaging", "data-port", "data-storage", "data-scripting", "data-scripting-result",
                        "data-permissions", "data-bg-storage", "data-to-content", "data-unsupported", "data-us", "data-gm-storage", "data-gmxhr", "data-unsafe-window"]
        _ = await ctx.waitUntil(15) { let a = await ctx.attrs(tab); return expected.allSatisfy { a[$0] != nil } }
        var snapshot = await ctx.attrs(tab)
        let styles = await ctx.eval(tab, """
            return { css: getComputedStyle(document.getElementById('css-test')).color,
                     gm: getComputedStyle(document.getElementById('gm-style')).color,
                     ad: String(getComputedStyle(document.getElementById('ad')).display === 'none'),
                     blocked: document.documentElement.getAttribute('data-blocked') || 'not-loaded',
                     pageScript: String(window.__pageScriptRan === true) };
            """) as? [String: String] ?? [:]
        snapshot.merge(styles) { a, _ in a }
        func check(_ attribute: String, _ name: String, expected: String = "ok") {
            ctx.record(name, snapshot[attribute] == expected, snapshot[attribute] ?? "nil")
        }
        check("data-cs-start", "Test 1 内容脚本 document_start")
        check("data-cs-end", "Test 1 内容脚本 document_end / DOM")
        ctx.record("Test 1 内容脚本 CSS", snapshot["css"] == "rgb(1, 2, 3)", snapshot["css"] ?? "")
        check("data-messaging", "Test 2 runtime.sendMessage")
        check("data-port", "Test 2 runtime.connect Port")
        check("data-storage", "Test 3 chrome.storage.local")
        check("data-scripting", "Test 5 scripting.executeScript")
        check("data-scripting-result", "Test 5 executeScript 返回值")
        check("data-permissions", "Test 6 host permissions")
        check("data-bg-storage", "Test 7 后台唤醒 + 消息处理")
        check("data-to-content", "Test 7 tabs.sendMessage → content")
        ctx.record("Test 8 DNR 屏蔽测试资源", !ctx.server.requested("/blocked.js") && snapshot["pageScript"] == "true",
                   "blocked.js requested=\(ctx.server.requested("/blocked.js"))")
        check("data-unsupported", "未实现 API 返回 Unsupported API")
        check("data-us", "用户脚本 @match 注入", expected: "ran")
        check("data-gm-storage", "GM storage")
        check("data-gmxhr", "GM_xmlhttpRequest")
        ctx.record("GM_addStyle", snapshot["gm"] == "rgb(4, 5, 6)", snapshot["gm"] ?? "")
        check("data-unsafe-window", "unsafeWindow")
        ctx.record("AdBlock 元素隐藏规则", snapshot["ad"] == "true", snapshot["ad"] ?? "")
        // Menu command.
        if let command = tab.menuCommands.first {
            tab.runMenuCommand(command)
            _ = await ctx.waitUntil(5) { await ctx.attr(tab, "data-menu") == "ok" }
        }
        ctx.record("GM_registerMenuCommand", await ctx.attr(tab, "data-menu") == "ok", "\(tab.menuCommands.count) command(s)")
        // Test 4: popup.
        let holder = PopupHolder()
        if let popup = URL(string: ext.baseURL + "popup.html") {
            holder.load(ExtensionRuntime.PopupRequest(extID: ext.id, url: popup, tabID: tab.numericID, title: "popup"), runtime: profile.extensions)
            if let webView = holder.webView { BackgroundHostContainer.shared.attach(webView) }
            let popupOK = await ctx.waitUntil(10) { profile.extensions.storage(ext, area: "local")["popupSawTab"] == String(tab.numericID) }
            ctx.record("Test 4 Popup → 当前标签页", popupOK, profile.extensions.storage(ext, area: "local")["popupSawTab"] ?? "nil")
            holder.webView?.removeFromSuperview()
            holder.close(runtime: profile.extensions)
        }
        // Reload + persistence.
        tab.reload()
        _ = await ctx.waitUntil(10) { await ctx.attr(tab, "data-gm-runs") == "2" }
        let runs = await ctx.attr(tab, "data-gm-runs")
        ctx.record("刷新后脚本再次运行 + GM 值持久化", runs == "2", runs ?? "nil")
        // @exclude: the extension's document_end script is injected after userscripts, so once it
        // has run, an included userscript would have run too.
        tab.load(ctx.url("/index.html?skip=1"))
        _ = await ctx.waitLoaded(tab, path: "/index.html", query: "skip=1")
        let csRan = await ctx.waitUntil(10) { await ctx.attr(tab, "data-cs-end") == "ok" }
        let excluded = await ctx.attr(tab, "data-us")
        ctx.record("@exclude 生效", csRan && excluded == nil, csRan ? (excluded ?? "not injected") : "content script marker missing")
        // Private tab.
        let privateTab = ctx.manager.newTab(url: ctx.url("/index.html"), isPrivate: true)
        _ = await ctx.waitLoaded(privateTab, path: "/index.html")
        _ = await ctx.waitUntil(5) { await ctx.attr(privateTab, "data-us") == "ran" }
        ctx.record("无痕标签页中运行用户脚本", await ctx.attr(privateTab, "data-us") == "ran")
        ctx.manager.close(privateTab)
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
                    Picker("套件", selection: $runner.suite) {
                        ForEach(SelfTestRunner.suites, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(runner.running)
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
                    Text("在本机 127.0.0.1 启动测试服务器并运行所选套件：core（扩展 / 脚本 / 拦截）、pageworld（unsafeWindow 与页面世界）、fonts（字体与图标保护）、dnr（按资源类型拦截 / 重定向 / 改请求头）、lifecycle（标签页挂起恢复与泄漏）、stress（扩展后台冷启动 / 空闲 / 唤醒循环）、archive（导出-重置-导入）、compat（真实扩展，需要 CI 放入扩展包）。会在当前身份中留下测试扩展、脚本和设置；lifecycle / archive 会关闭或替换当前标签页。")
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
