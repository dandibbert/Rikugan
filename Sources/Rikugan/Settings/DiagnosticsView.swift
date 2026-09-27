import SwiftUI
import WebKit

/// Snapshot of the app's runtime state for the Diagnostics page and its export.
/// Contains no page content, cookies, passwords, userscript source or storage values; URLs are
/// reduced to their host.
struct DiagnosticsReport: Codable {
    struct Build: Codable { var appVersion: String; var gitCommit: String; var buildDate: String; var device: String; var os: String; var isSimulator: Bool }
    struct Tabs: Codable { var windows: Int; var tabs: Int; var active: Int; var liveBackground: Int; var suspended: Int; var restoring: Int; var terminated: Int
        var liveWebViews: Int; var registeredWebViews: Int; var groups: Int }
    struct ExtensionInfo: Codable { var id: String; var name: String; var version: String; var enabled: Bool; var manifestVersion: Int
        var background: String?; var backgroundState: String?; var backgroundDetail: String?; var unsupportedCalls: [String: Int] }
    struct ScriptInfo: Codable { var name: String; var version: String; var enabled: Bool; var world: String; var grants: [String] }
    struct DNR: Codable { var probed: Bool; var redirect: Bool; var modifyHeaders: Bool; var convertedRules: Int; var lists: Int; var skipped: [String: [String]] }
    struct Environment: Codable { var appGroup: Bool; var shareExtensionEmbedded: Bool; var webInspector: Bool; var profile: String; var profileCount: Int }
    struct APISummary: Codable { var namespaces: Int; var supported: Int; var partial: Int; var unsupported: Int; var methodsImplemented: Int; var methodsMissing: Int }

    var generatedAt = Date()
    var build: Build
    var environment: Environment
    var tabs: Tabs
    var extensions: [ExtensionInfo]
    var userscripts: [ScriptInfo]
    var chromeAPI: APISummary
    var dnr: DNR
    var errors: [ErrorLog.Entry]

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
                                 unsupportedCalls: runtime.unsupportedCalls[record.id] ?? [:])
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
                      convertedRules: d.convertedRules, lists: d.lists, skipped: d.skipped)
        let plugins = Bundle.main.builtInPlugInsURL.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        let environment = Environment(
            appGroup: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.dandibbert.Rikugan") != nil,
            shareExtensionEmbedded: plugins.contains { $0.hasSuffix(".appex") },
            webInspector: services.prefs.webInspectorEnabled,
            profile: services.profile.info.name, profileCount: services.profiles.profiles.count)
        return DiagnosticsReport(build: build, environment: environment, tabs: tabs, extensions: extensions, userscripts: scripts,
                                 chromeAPI: api, dnr: dnr, errors: ErrorLog.shared.entries)
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
                row("DNR redirect", report.dnr.probed ? (report.dnr.redirect ? "WebKit 支持" : "WebKit 不支持") : "未探测")
                row("DNR modifyHeaders", report.dnr.probed ? (report.dnr.modifyHeaders ? "WebKit 支持" : "WebKit 不支持") : "未探测")
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
                Button { export() } label: { Label("导出诊断信息（JSON）", systemImage: "square.and.arrow.up") }
            } footer: {
                Text("导出内容不含网页内容、Cookie、密码、脚本源码与存储值；错误中的网址只保留域名。")
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
