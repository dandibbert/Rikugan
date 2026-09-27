import SwiftUI
import WebKit
import CryptoKit

/// Snapshot of the app's runtime state for the Diagnostics page and its single-file bug-report
/// export. Contains no passwords, cookies, Keychain items, page or form contents, userscript
/// source or stored values, extension storage, or archive contents; URLs are reduced to their host.
struct DiagnosticsReport: Codable {
    struct Build: Codable { var appVersion: String; var gitCommit: String; var buildDate: String; var device: String; var os: String; var isSimulator: Bool }
    struct Tabs: Codable { var windows: Int; var tabs: Int; var active: Int; var liveBackground: Int; var suspended: Int; var restoring: Int; var terminated: Int
        var liveWebViews: Int; var registeredWebViews: Int; var groups: Int }
    struct ExtensionInfo: Codable { var id: String; var name: String; var version: String; var enabled: Bool; var manifestVersion: Int
        var background: String?; var backgroundState: String?; var backgroundDetail: String?; var unsupportedCalls: [String: Int]
        var recentErrors: [String] = [] }
    struct ScriptInfo: Codable { var name: String; var version: String; var enabled: Bool; var world: String; var grants: [String] }
    struct DNR: Codable { var probed: Bool; var redirect: Bool; var modifyHeaders: Bool; var redirectCompiles: Bool; var modifyHeadersCompiles: Bool; var convertedRules: Int; var lists: Int; var skipped: [String: [String]] }
    struct Environment: Codable { var appGroup: Bool; var shareExtensionEmbedded: Bool; var webInspector: Bool; var profile: String; var profileCount: Int }
    struct APISummary: Codable { var namespaces: Int; var supported: Int; var partial: Int; var unsupported: Int; var methodsImplemented: Int; var methodsMissing: Int }

    struct Security: Codable { var rejectedPrivilegedCalls: Int; var recent: [SecurityLog.Entry] }

    static let privacyStatement = "Contains: build, OS/device model, tab and background-runtime counters, extension and userscript names/versions/grants, feature flags, compatibility-matrix version, DNR skipped-rule summary, recent runtime/security log lines (URLs reduced to domains), manual test statuses. Does NOT contain: passwords, cookies, Keychain secrets, page or form contents, browsing URLs beyond domains, userscript source or GM stored values, extension storage, or archive contents."

    var reportFormat = "rikugan-diagnostics/2"
    var generatedAt = Date()
    var privacy = DiagnosticsReport.privacyStatement
    var build: Build
    var environment: Environment
    var tabs: Tabs
    var extensions: [ExtensionInfo]
    var userscripts: [ScriptInfo]
    var chromeAPI: APISummary
    var dnr: DNR
    var errors: [ErrorLog.Entry]
    var backgroundRuntime: BackgroundRuntimeSummary
    var security: Security
    var featureFlags: [String: String]
    var compatibilityMatrixVersion: String
    /// Entered by a person on the Manual Test Checklist page — not CI results.
    var manualTests: ManualTestStore.Export

    @MainActor static func collect() -> DiagnosticsReport {
        let services = AppServices.shared
        let info = Bundle.main.infoDictionary ?? [:]
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let build = Build(appVersion: services.appVersion, gitCommit: info["RikuganGitCommit"] as? String ?? "unknown",
                          buildDate: info["RikuganBuildDate"] as? String ?? "unknown",
                          device: "\(UIDevice.current.model) (\(machine))", os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                          isSimulator: simulator)

        let all = TabRegistry.shared.allTabs
        func count(_ state: TabLifecycleState) -> Int { all.filter { $0.lifecycle == state }.count }
        let windows = TabRegistry.shared.allWindows
        let tabs = Tabs(windows: windows.count, tabs: all.count, active: count(.active), liveBackground: count(.liveBackground),
                        suspended: count(.suspended), restoring: count(.restoring), terminated: count(.terminated),
                        liveWebViews: RikuganWebView.liveCount, registeredWebViews: TabRegistry.shared.liveWebViewCount,
                        groups: windows.reduce(0) { $0 + $1.groups.count })

        let runtime = services.profile.extensions!
        let extensions = runtime.records.map { record -> ExtensionInfo in
            let loaded = runtime.loaded[record.id]
            return ExtensionInfo(id: record.id, name: record.name, version: record.version, enabled: record.enabled,
                                 manifestVersion: loaded?.manifest.manifestVersion ?? 0,
                                 background: loaded?.manifest.backgroundKind,
                                 backgroundState: loaded?.background?.state.rawValue,
                                 backgroundDetail: loaded?.background?.diagnostics,
                                 unsupportedCalls: runtime.unsupportedCalls[record.id] ?? [:],
                                 recentErrors: record.lastErrors.suffix(5).map(ErrorLog.scrub))
        }
        let scripts = services.profile.userscripts.scripts.map {
            ScriptInfo(name: $0.metadata.name, version: $0.metadata.version, enabled: $0.enabled,
                       world: $0.usesPageWorld ? "page" : "isolated", grants: $0.metadata.grants)
        }
        let entries = ChromeAPIMatrix.entries
        let api = APISummary(namespaces: entries.count,
                             supported: entries.filter { $0.level == .supported }.count,
                             partial: entries.filter { $0.level == .partial }.count,
                             unsupported: entries.filter { $0.level == .unsupported }.count,
                             methodsImplemented: entries.reduce(0) { $0 + $1.implemented.count },
                             methodsMissing: entries.reduce(0) { $0 + $1.missing.count })
        let d = runtime.dnrStatus
        let dnr = DNR(probed: d.probed, redirect: d.capabilities.redirect, modifyHeaders: d.capabilities.modifyHeaders,
                      redirectCompiles: d.compiles.redirect, modifyHeadersCompiles: d.compiles.modifyHeaders,
                      convertedRules: d.convertedRules, lists: d.lists, skipped: d.skipped)
        let plugins = Bundle.main.builtInPlugInsURL.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        let environment = Environment(
            appGroup: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.dandibbert.Rikugan") != nil,
            shareExtensionEmbedded: plugins.contains { $0.hasSuffix(".appex") },
            webInspector: services.prefs.webInspectorEnabled,
            profile: services.profile.info.name, profileCount: services.profiles.profiles.count)
        let security = Security(rejectedPrivilegedCalls: SecurityLog.shared.totalRejected, recent: Array(SecurityLog.shared.entries.suffix(30)))
        return DiagnosticsReport(build: build, environment: environment, tabs: tabs, extensions: extensions, userscripts: scripts,
                                 chromeAPI: api, dnr: dnr, errors: ErrorLog.shared.entries,
                                 backgroundRuntime: BackgroundRuntimeSummary.collect(), security: security,
                                 featureFlags: featureFlags(services.prefs), compatibilityMatrixVersion: matrixVersion(),
                                 manualTests: ManualTestStore.shared.export())
    }

    /// Non-sensitive switches only (no API keys, server URLs, homepage or search templates).
    static func featureFlags(_ p: Preferences) -> [String: String] {
        ["adBlockEnabled": "\(p.adBlockEnabled)", "pageDarkMode": p.pageDarkMode.rawValue, "webFontEnabled": "\(p.webFontEnabled)",
         "mediaSnifferEnabled": "\(p.mediaSnifferEnabled)", "consoleCaptureEnabled": "\(p.consoleCaptureEnabled)",
         "webInspectorEnabled": "\(p.webInspectorEnabled)", "geolocationShim": "\(p.geolocationShim)", "blockPopups": "\(p.blockPopups)",
         "preventAppStoreRedirect": "\(p.preventAppStoreRedirect)", "preventExternalAppRedirect": "\(p.preventExternalAppRedirect)",
         "restoreTabs": "\(p.restoreTabs)", "autofillEnabled": "\(p.autofillEnabled)", "defaultDesktopMode": "\(p.defaultDesktopMode)",
         "translationProvider": p.translationProvider, "maxLiveBackgroundTabs": "\(p.maxLiveBackgroundTabs)",
         "backgroundIdleSeconds": "\(p.backgroundIdleSeconds)", "showDiagnostics": "\(p.showDiagnostics)"]
    }

    /// Content hash of the bundled chrome.* matrix plus the GM matrix size — identifies exactly
    /// which compatibility claims this build ships.
    static func matrixVersion() -> String {
        let data = Bundle.main.url(forResource: "chrome-api-matrix", withExtension: "json").flatMap { try? Data(contentsOf: $0) } ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12)
        return "chrome-api-matrix sha256:\(digest) (\(ChromeAPIMatrix.entries.count) namespaces); GM matrix \(GMCompatibility.table.count) rows"
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var services: AppServices
    @ObservedObject private var errors = ErrorLog.shared
    @State private var report = DiagnosticsReport.collect()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section("构建") {
                row("版本", report.build.appVersion)
                row("Git commit", report.build.gitCommit)
                row("构建时间", report.build.buildDate)
                row("设备", report.build.device + (report.build.isSimulator ? "（模拟器）" : ""))
                row("系统", report.build.os)
            }
            Section("环境") {
                row("当前身份", "\(report.environment.profile)（共 \(report.environment.profileCount) 个）")
                row("App Group", report.environment.appGroup ? "可用" : "不可用（未签名或 entitlement 缺失）")
                row("分享扩展", report.environment.shareExtensionEmbedded ? "已嵌入" : "未找到")
                row("网页检查器", report.environment.webInspector ? "开启" : "关闭")
            }
            Section("标签页") {
                row("窗口 / 标签页 / 组", "\(report.tabs.windows) / \(report.tabs.tabs) / \(report.tabs.groups)")
                row("活动 / 后台存活", "\(report.tabs.active) / \(report.tabs.liveBackground)")
                row("已挂起 / 恢复中 / 进程终止", "\(report.tabs.suspended) / \(report.tabs.restoring) / \(report.tabs.terminated)")
                row("存活 WKWebView（全部用途）", "\(report.tabs.liveWebViews)")
                row("已注册的标签页 WebView", "\(report.tabs.registeredWebViews)")
            }
            Section {
                row("已安装 / 运行中 / 已挂起（驻留）", "\(report.backgroundRuntime.installedExtensions) / \(report.backgroundRuntime.runningBackgrounds) / \(report.backgroundRuntime.parkedBackgrounds)")
                row("浏览器标签页 WebView / WKWebView 总数", "\(report.backgroundRuntime.liveBrowserWebViews) / \(report.backgroundRuntime.totalWKWebViews)")
                ForEach(report.backgroundRuntime.extensions.filter(\.hasBackground), id: \.id) { ext in
                    Text("\(ext.name)：\(ext.state)\(ext.parked ? "（驻留）" : "") · 唤醒 \(ext.wakeCount) · 冷启动 \(ext.coldStartCount) · 卡住恢复 \(ext.stuckStartRecoveries) · 端口 \(ext.activePorts)")
                        .font(.caption2.monospaced())
                }
                NavigationLink { BackgroundRuntimesView() } label: { Label("后台运行时控制", systemImage: "gearshape.2") }
            } header: { Text("扩展后台运行时") } footer: { Text(BackgroundRuntimeSummary.memoryNote) }
            Section("安全") {
                row("被拒绝的特权调用", "\(report.security.rejectedPrivilegedCalls)")
                ForEach(report.security.recent.suffix(5).reversed()) { entry in Text(entry.message).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            }
            Section {
                row("通过 / 失败 / 不适用 / 未测试", "\(report.manualTests.counts["pass"] ?? 0) / \(report.manualTests.counts["fail"] ?? 0) / \(report.manualTests.counts["notApplicable"] ?? 0) / \(report.manualTests.counts["untested"] ?? 0)")
                NavigationLink { ManualTestChecklistView() } label: { Label("人工测试清单", systemImage: "checklist") }
            } header: { Text("人工测试（非 CI 结果）") }
            Section("扩展") {
                if report.extensions.isEmpty { Text("未安装扩展").foregroundStyle(.secondary) }
                ForEach(report.extensions, id: \.id) { ext in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(ext.name) \(ext.version)").font(.callout.weight(.medium))
                        Text("MV\(ext.manifestVersion) · \(ext.enabled ? "已启用" : "已停用") · 后台：\(ext.backgroundState ?? "无")").font(.caption)
                        if let detail = ext.backgroundDetail { Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                        if !ext.unsupportedCalls.isEmpty {
                            Text("调用了不支持的 API：" + ext.unsupportedCalls.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section("用户脚本") {
                if report.userscripts.isEmpty { Text("未安装脚本").foregroundStyle(.secondary) }
                ForEach(Array(report.userscripts.enumerated()), id: \.offset) { _, script in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(script.name) \(script.version)").font(.callout)
                        Text("\(script.enabled ? "已启用" : "已停用") · \(script.world == "page" ? "页面世界" : "隔离世界") · @grant \(script.grants.isEmpty ? "none" : script.grants.joined(separator: " "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Chrome API / DNR") {
                row("命名空间 ✅/🟡/⛔", "\(report.chromeAPI.supported) / \(report.chromeAPI.partial) / \(report.chromeAPI.unsupported)")
                row("方法 已实现 / 缺失", "\(report.chromeAPI.methodsImplemented) / \(report.chromeAPI.methodsMissing)")
                row("DNR redirect", report.dnr.probed ? (report.dnr.redirect ? "已启用" : (report.dnr.redirectCompiles ? "WebKit 可编译但不执行 → 跳过" : "WebKit 不支持 → 跳过")) : "未探测")
                row("DNR modifyHeaders", report.dnr.probed ? (report.dnr.modifyHeaders ? "已启用" : (report.dnr.modifyHeadersCompiles ? "WebKit 可编译但不执行 → 跳过" : "WebKit 不支持 → 跳过")) : "未探测")
                row("DNR 已转换规则 / 列表", "\(report.dnr.convertedRules) / \(report.dnr.lists)")
                ForEach(report.dnr.skipped.sorted { $0.key < $1.key }, id: \.key) { ext, reasons in
                    Text("\(ext)：跳过 \(reasons.count) 条 — " + Array(Set(reasons)).sorted().prefix(3).joined(separator: "；")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section {
                if errors.entries.isEmpty { Text("无").foregroundStyle(.secondary) }
                ForEach(errors.entries.suffix(50).reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.source)").font(.caption2).foregroundStyle(.secondary)
                        Text(entry.message).font(.caption.monospaced())
                    }
                }
            } header: {
                HStack { Text("最近错误"); Spacer(); Button("清除") { errors.clear() }.font(.caption) }
            }
            Section {
                row("兼容性矩阵版本", report.compatibilityMatrixVersion)
                Button { export() } label: { Label("导出诊断报告（单个 JSON 文件）", systemImage: "square.and.arrow.up") }
            } header: { Text("导出") } footer: {
                Text("""
                包含：构建与 commit、系统与设备型号、标签页与后台运行时计数、扩展和用户脚本的名称 / 版本 / 权限、功能开关、兼容性矩阵版本、DNR 跳过规则摘要、最近的运行时与安全日志（网址只保留域名）、人工测试状态（标注为人工结果，非 CI）。
                不包含：密码、Cookie、钥匙串内容、网页与表单内容、完整浏览网址、脚本源码与 GM 存储值、扩展存储、归档内容。导出前你可以在分享面板中查看文件。
                """)
            }
        }
        .navigationTitle("诊断")
        .onReceive(refresh) { _ in report = DiagnosticsReport.collect() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).font(.callout).multilineTextAlignment(.trailing).textSelection(.enabled) }
    }

    private func export() {
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Rikugan-diagnostics-\(Int(Date().timeIntervalSince1970)).json")
            try DiagnosticsReport.collect().json().write(to: file)
            Presenter.share([file])
        } catch {
            ToastCenter.shared.show("导出失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }
}
