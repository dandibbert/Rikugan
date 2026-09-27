import SwiftUI

// MARK: - Manual test checklist

/// Human-run manual test checklist (Settings → Developer). This is NOT automation: every status is
/// set by a person on a real install (PlayCover or iPhone) and exported with Diagnostics labelled
/// as manual results — never as CI results.
enum ManualTestStatus: String, Codable, CaseIterable {
    case untested, pass, fail, notApplicable
    var label: String {
        switch self {
        case .untested: return "未测试"
        case .pass: return "通过"
        case .fail: return "失败"
        case .notApplicable: return "不适用"
        }
    }
    var symbol: String {
        switch self {
        case .untested: return "circle"
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.octagon.fill"
        case .notApplicable: return "minus.circle"
        }
    }
    var color: Color {
        switch self {
        case .untested: return .secondary
        case .pass: return .green
        case .fail: return .red
        case .notApplicable: return .gray
        }
    }
}

struct ManualTestItem: Identifiable, Hashable {
    let id: String
    let title: String
    let steps: String
    /// Only meaningful on a real iPhone / iPad (PlayCover and the simulator cannot exercise it).
    var realDeviceOnly = false
}

struct ManualTestSection: Identifiable {
    let id: String
    let title: String
    let items: [ManualTestItem]
}

enum ManualTestChecklist {
    static let version = 1

    static let sections: [ManualTestSection] = [
        ManualTestSection(id: "browser", title: "浏览器", items: [
            ManualTestItem(id: "browser.navigate", title: "打开网址、搜索、前进 / 后退 / 刷新", steps: "地址栏输入网址与关键词；使用工具栏导航按钮。"),
            ManualTestItem(id: "browser.tabs", title: "新建 / 关闭 / 切换标签页，标签组", steps: "新建 5+ 个标签页，建一个标签组，切换并关闭。"),
            ManualTestItem(id: "browser.suspend", title: "后台标签页挂起后恢复（网址、滚动位置）", steps: "打开超过“后台存活上限”的标签页后逐个切回，确认恢复且不丢失位置。"),
            ManualTestItem(id: "browser.restore", title: "重启 App 后恢复会话", steps: "强制退出 App 后重新打开。"),
            ManualTestItem(id: "browser.private", title: "无痕标签页不写历史", steps: "无痕浏览后检查历史记录。"),
        ]),
        ManualTestSection(id: "userscripts", title: "用户脚本", items: [
            ManualTestItem(id: "us.install", title: "从网址 / 文件安装脚本", steps: "打开 .user.js 链接并安装；从“文件”导入一个脚本。"),
            ManualTestItem(id: "us.grantnone", title: "@grant none 脚本在页面环境运行", steps: "安装一个 @grant none 脚本，确认其页面修改生效。"),
            ManualTestItem(id: "us.gm", title: "GM_setValue / GM_xmlhttpRequest / 菜单命令", steps: "安装使用 GM 存储、跨域请求和菜单命令的脚本（例如常用的增强脚本）。"),
            ManualTestItem(id: "us.pageworld", title: "@inject-into page + 特权 API 显示警告且被拒绝", steps: "查看脚本详情中的橙色警告；确认脚本仍可加载。"),
            ManualTestItem(id: "us.update", title: "脚本更新检查", steps: "对带 @updateURL 的脚本执行“检查更新”。"),
        ]),
        ManualTestSection(id: "extensions", title: "扩展", items: [
            ManualTestItem(id: "ext.darkreader", title: "Dark Reader：安装、开关、按站点设置", steps: "从 Chrome 应用店或 CRX 安装，打开 popup 切换站点。"),
            ManualTestItem(id: "ext.ubol", title: "uBlock Origin Lite：拦截广告（DNR）", steps: "安装后访问广告较多的网站，检查“诊断”中 DNR 跳过规则摘要。"),
            ManualTestItem(id: "ext.popup", title: "扩展 popup 打开与交互", steps: "从页面菜单打开每个已安装扩展的 popup。"),
            ManualTestItem(id: "ext.wake", title: "后台挂起后被消息唤醒", steps: "开发者 → 后台运行时：挂起一个扩展，再使用该扩展的功能，确认自动唤醒（唤醒次数 +1）。"),
            ManualTestItem(id: "ext.storage", title: "扩展存储在重启后保留", steps: "修改扩展设置 → 重启 App → 设置仍在。"),
            ManualTestItem(id: "ext.ports", title: "长连接端口（popup ↔ 后台）", steps: "打开使用端口的扩展 popup，确认后台计数显示活动端口，关闭后归零。"),
            ManualTestItem(id: "ext.restart", title: "扩展停用 / 启用 / 重建后台", steps: "在扩展管理停用再启用；在开发者页“停止并重建”。"),
        ]),
        ManualTestSection(id: "content", title: "内容工具", items: [
            ManualTestItem(id: "content.reader", title: "阅读模式", steps: "在文章页打开阅读模式并调整字号。"),
            ManualTestItem(id: "content.translate", title: "网页翻译", steps: "翻译一个外文页面并还原。"),
            ManualTestItem(id: "content.darkmode", title: "网页深色模式", steps: "开关深色模式并调整亮度。"),
            ManualTestItem(id: "content.adblock", title: "内容拦截与元素隐藏", steps: "开启拦截后访问广告页；使用元素选择器隐藏一个元素。"),
            ManualTestItem(id: "content.fonts", title: "网页字体（内置 / 导入字体）", steps: "设置全局网页字体并在几个网站上确认。"),
        ]),
        ManualTestSection(id: "files", title: "文件与媒体", items: [
            ManualTestItem(id: "files.download", title: "普通文件下载并在“文件”中打开", steps: "下载一个 PDF / ZIP，在下载管理中打开。"),
            ManualTestItem(id: "files.hls", title: "媒体嗅探（MP4 / HLS）", steps: "在视频页打开媒体面板，确认检测到媒体并可下载 / 播放。"),
            ManualTestItem(id: "files.upload", title: "网页文件上传", steps: "在上传表单中选择文件。"),
        ]),
        ManualTestSection(id: "importexport", title: "导入与导出", items: [
            ManualTestItem(id: "ie.export", title: "导出全部数据归档", steps: "导入与导出 → 导出，保存到“文件”。"),
            ManualTestItem(id: "ie.import", title: "在全新安装上导入归档", steps: "删除 App 重装（或使用另一身份）后导入，检查书签 / 脚本 / 扩展 / 设置。"),
            ManualTestItem(id: "ie.bookmarks", title: "导入 HTML 书签", steps: "导入浏览器导出的书签 HTML。"),
        ]),
        ManualTestSection(id: "system", title: "系统集成（仅真机）", items: [
            ManualTestItem(id: "sys.share", title: "分享扩展：从其他 App 分享网址到 Rikugan", steps: "在 Safari / 其他 App 中分享链接到 Rikugan。", realDeviceOnly: true),
            ManualTestItem(id: "sys.appgroup", title: "App Group 可用（诊断 → 环境）", steps: "签名安装后查看诊断中 App Group 状态。", realDeviceOnly: true),
            ManualTestItem(id: "sys.files", title: "“文件”选择器边界情况（iCloud、外部存储、取消）", steps: "从 iCloud Drive / U 盘选择文件，中途取消。", realDeviceOnly: true),
            ManualTestItem(id: "sys.photos", title: "照片：网页上传选择照片 / 保存图片", steps: "上传照片并长按网页图片保存到相册。", realDeviceOnly: true),
            ManualTestItem(id: "sys.camera", title: "相机：网页拍照上传 / getUserMedia", steps: "在需要相机的网页授权并拍摄。", realDeviceOnly: true),
            ManualTestItem(id: "sys.pip", title: "画中画", steps: "播放视频并进入画中画，切到其他 App。", realDeviceOnly: true),
            ManualTestItem(id: "sys.airplay", title: "AirPlay", steps: "将网页视频投送到 AirPlay 设备。", realDeviceOnly: true),
            ManualTestItem(id: "sys.urlscheme", title: "外部 URL scheme（打开 / 被打开）", steps: "从其他 App 以 URL scheme 打开 Rikugan；网页跳转到其他 App 时的确认。", realDeviceOnly: true),
            ManualTestItem(id: "sys.fonts", title: "系统字体 / 描述文件安装的字体", steps: "安装字体描述文件后在网页字体中选择。", realDeviceOnly: true),
            ManualTestItem(id: "sys.memory", title: "WebContent 进程终止 / 内存压力后的恢复", steps: "打开大量重型页面后切回旧标签页，确认自动重新加载且扩展后台可唤醒。", realDeviceOnly: true),
        ]),
    ]

    static var allItems: [ManualTestItem] { sections.flatMap(\.items) }
}

@MainActor final class ManualTestStore: ObservableObject {
    struct Record: Codable, Equatable {
        var status: ManualTestStatus
        var note: String
        var updatedAt: Date
    }

    static let shared = ManualTestStore()
    private static let key = "rikugan.manualTests.v1"
    @Published private(set) var records: [String: Record] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        }
    }

    func status(_ id: String) -> ManualTestStatus { records[id]?.status ?? .untested }
    func note(_ id: String) -> String { records[id]?.note ?? "" }

    func set(_ id: String, status: ManualTestStatus? = nil, note: String? = nil) {
        var record = records[id] ?? Record(status: .untested, note: "", updatedAt: Date())
        if let status { record.status = status }
        if let note { record.note = String(note.prefix(500)) }
        record.updatedAt = Date()
        records[id] = record
        save()
    }

    func resetAll() { records = [:]; save() }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Export form: every checklist item with its status (untested included), labelled as manual.
    struct ExportItem: Codable { var id: String; var section: String; var title: String; var realDeviceOnly: Bool; var status: String; var note: String; var updatedAt: Date? }
    struct Export: Codable {
        var source = "manual — entered by a person in Settings → Developer → Manual Test Checklist; not CI results"
        var checklistVersion = ManualTestChecklist.version
        var counts: [String: Int]
        var items: [ExportItem]
    }

    func export() -> Export {
        var items: [ExportItem] = []
        for section in ManualTestChecklist.sections {
            for item in section.items {
                let record = records[item.id]
                items.append(ExportItem(id: item.id, section: section.title, title: item.title, realDeviceOnly: item.realDeviceOnly,
                                        status: (record?.status ?? .untested).rawValue, note: ErrorLog.scrub(record?.note ?? ""), updatedAt: record?.updatedAt))
            }
        }
        var counts: [String: Int] = [:]
        for item in items { counts[item.status, default: 0] += 1 }
        return Export(counts: counts, items: items)
    }
}

struct ManualTestChecklistView: View {
    @ObservedObject private var store = ManualTestStore.shared
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                let export = store.export()
                Text("通过 \(export.counts["pass"] ?? 0) · 失败 \(export.counts["fail"] ?? 0) · 不适用 \(export.counts["notApplicable"] ?? 0) · 未测试 \(export.counts["untested"] ?? 0)")
                    .font(.callout)
            } footer: {
                Text("这是人工测试清单，不是自动化测试：状态由你在真实安装（PlayCover / iPhone）上手动设置，随诊断信息一起导出，并标注为人工结果，绝不代表 CI 结果。标记“仅真机”的项目在 PlayCover / 模拟器上请设为“不适用”。")
            }
            ForEach(ManualTestChecklist.sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        NavigationLink { ManualTestItemView(item: item) } label: {
                            HStack(alignment: .top) {
                                Image(systemName: store.status(item.id).symbol).foregroundStyle(store.status(item.id).color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.callout)
                                    HStack(spacing: 6) {
                                        Text(store.status(item.id).label)
                                        if item.realDeviceOnly { Text("仅真机").foregroundStyle(.orange) }
                                        if !store.note(item.id).isEmpty { Text("有备注") }
                                    }.font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink { DiagnosticsView() } label: { Label("导出诊断信息与清单", systemImage: "square.and.arrow.up") }
                Button("全部重置为未测试", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("人工测试清单")
        .confirmationDialog("将所有项目重置为“未测试”并清除备注？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重置", role: .destructive) { store.resetAll() }
        }
    }
}

private struct ManualTestItemView: View {
    let item: ManualTestItem
    @ObservedObject private var store = ManualTestStore.shared
    @State private var note = ""

    var body: some View {
        Form {
            Section("步骤") {
                Text(item.steps)
                if item.realDeviceOnly { Label("仅能在真机上验证；PlayCover / 模拟器上请设为“不适用”。", systemImage: "iphone").font(.caption).foregroundStyle(.orange) }
            }
            Section("状态") {
                Picker("状态", selection: Binding(get: { store.status(item.id) }, set: { store.set(item.id, status: $0) })) {
                    ForEach(ManualTestStatus.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                TextField("备注（设备、版本、现象；勿填写密码或私人网址）", text: $note, axis: .vertical)
                    .lineLimit(3...8)
                    .onSubmit { store.set(item.id, note: note) }
                Button("保存备注") { store.set(item.id, note: note) }
            } header: { Text("备注") } footer: { Text("备注随诊断导出；其中的网址只保留域名。") }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { note = store.note(item.id) }
        .onDisappear { if note != store.note(item.id) { store.set(item.id, note: note) } }
    }
}

// MARK: - Background runtimes (developer controls)

struct BackgroundRuntimesView: View {
    @EnvironmentObject private var services: AppServices
    @State private var tick = 0
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var runtime: ExtensionRuntime { services.profile.extensions }

    var body: some View {
        let _ = tick
        let summary = BackgroundRuntimeSummary.collect()
        List {
            Section {
                LabeledContent("已安装扩展", value: "\(summary.installedExtensions)")
                LabeledContent("运行中后台", value: "\(summary.runningBackgrounds)")
                LabeledContent("已挂起（web view 驻留）", value: "\(summary.parkedBackgrounds)")
                LabeledContent("存活的浏览器标签页 WebView", value: "\(summary.liveBrowserWebViews)")
                LabeledContent("Rikugan 拥有的 WKWebView 总数", value: "\(summary.totalWKWebViews)")
                Text(summary.webViewsByPurpose.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " · ")).font(.caption2.monospaced()).foregroundStyle(.secondary)
            } header: { Text("汇总") } footer: { Text(BackgroundRuntimeSummary.memoryNote) }
            Section {
                Button("挂起所有可挂起的后台") { suspendAllEligible() }
                Button("唤醒全部后台") { for ext in runtime.loaded.values { ext.background?.developerWake() } }
                Button("清除运行时错误计数") { runtime.clearRuntimeErrorCounters(); ErrorLog.shared.clear() }
            } footer: { Text("“可挂起”= 当前就绪且没有打开的端口（与自动空闲挂起的条件相同）。") }
            ForEach(summary.extensions, id: \.id) { ext in
                Section(ext.name) {
                    LabeledContent("状态", value: ext.state + (ext.parked ? "（web view 驻留）" : ""))
                    LabeledContent("唤醒 / 冷启动", value: "\(ext.wakeCount) / \(ext.coldStartCount)")
                    LabeledContent("卡住启动恢复 / 失败重启", value: "\(ext.stuckStartRecoveries) / \(ext.restartsAfterFailure)")
                    LabeledContent("活动端口", value: "\(ext.activePorts)")
                    LabeledContent("上次唤醒", value: ext.lastWakeAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
                    if let failure = ext.failureReason { Text(failure).font(.caption).foregroundStyle(.red) }
                    if let host = runtime.loaded[ext.id]?.background {
                        HStack {
                            Button("挂起") { host.suspend(reason: "developer") }.disabled(!host.isReady)
                            Spacer()
                            Button("唤醒") { host.developerWake() }.disabled(host.isReady)
                            Spacer()
                            Button("停止并重建") { host.developerRecreate() }
                        }
                        .buttonStyle(.borderless)
                        NavigationLink("状态时间线") { BackgroundTimelineView(extID: ext.id) }
                    } else {
                        Text("此扩展没有后台（或未启用）").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("扩展后台运行时")
        .onReceive(refresh) { _ in tick += 1 }
    }

    private func suspendAllEligible() {
        for ext in runtime.loaded.values {
            guard let host = ext.background, host.isReady, !runtime.bridge.hasOpenPorts(extID: ext.id) else { continue }
            host.suspend(reason: "developer suspend-all")
        }
    }
}

private struct BackgroundTimelineView: View {
    let extID: String
    @EnvironmentObject private var services: AppServices

    var body: some View {
        let host = services.profile.extensions.loaded[extID]?.background
        List {
            Section("状态迁移（最近 50 次）") {
                ForEach(Array((host?.transitions ?? []).reversed().enumerated()), id: \.offset) { _, entry in
                    LabeledContent(entry.1.rawValue, value: entry.0.formatted(date: .omitted, time: .standard))
                }
            }
            Section("当前启动尝试的时间线") {
                ForEach(Array((host?.timeline ?? []).enumerated()), id: \.offset) { _, line in Text(line).font(.caption2.monospaced()) }
            }
            if let failed = host?.lastFailureTimeline, !failed.isEmpty {
                Section("上次失败启动的时间线") {
                    ForEach(Array(failed.enumerated()), id: \.offset) { _, line in Text(line).font(.caption2.monospaced()) }
                }
            }
        }
        .navigationTitle("时间线")
    }
}

/// Background-runtime observability, shared by the Developer page and the diagnostics export.
/// Only counts that public APIs actually provide — no per-process memory figure is reported.
struct BackgroundRuntimeSummary: Codable {
    struct Extension: Codable {
        var id: String; var name: String; var version: String; var hasBackground: Bool; var state: String; var parked: Bool
        var lastWakeAt: Date?; var lastSuspendAt: Date?; var wakeCount: Int; var coldStartCount: Int; var startCount: Int
        var stuckStartRecoveries: Int; var restartsAfterFailure: Int; var activePorts: Int; var failureReason: String?
        var recentTransitions: [String]
    }
    var installedExtensions: Int
    var runningBackgrounds: Int
    var parkedBackgrounds: Int
    var liveBrowserWebViews: Int
    var totalWKWebViews: Int
    var webViewsByPurpose: [String: Int]
    var processMemory = BackgroundRuntimeSummary.memoryNote
    var extensions: [Extension]

    static let memoryNote = "Per-WebContent-process memory is not available through public iOS APIs, so no memory figure is reported (only web view counts)."

    @MainActor static func collect() -> BackgroundRuntimeSummary {
        let runtime = AppServices.shared.profile.extensions!
        var running = 0, parked = 0
        let extensions = runtime.records.map { record -> Extension in
            let host = runtime.loaded[record.id]?.background
            if let host, [.starting, .waking, .ready, .idle].contains(host.state) { running += 1 }
            if host?.isParked == true { parked += 1 }
            return Extension(id: record.id, name: record.name, version: record.version, hasBackground: host != nil,
                             state: host?.state.rawValue ?? (record.enabled ? "none" : "disabled"), parked: host?.isParked ?? false,
                             lastWakeAt: host?.lastWakeAt, lastSuspendAt: host?.lastSuspendAt,
                             wakeCount: host?.wakeCount ?? 0, coldStartCount: host?.coldStartCount ?? 0, startCount: host?.startCount ?? 0,
                             stuckStartRecoveries: host?.stuckStartRecoveries ?? 0, restartsAfterFailure: host?.restartsAfterFailure ?? 0,
                             activePorts: runtime.bridge.portCount(extID: record.id),
                             failureReason: host?.failureReason.map(ErrorLog.scrub),
                             recentTransitions: (host?.transitions ?? []).suffix(12).map { "\(ISO8601DateFormatter().string(from: $0.0)) \($0.1.rawValue)" })
        }
        return BackgroundRuntimeSummary(installedExtensions: runtime.records.count, runningBackgrounds: running, parkedBackgrounds: parked,
                                        liveBrowserWebViews: TabRegistry.shared.liveWebViewCount, totalWKWebViews: RikuganWebView.liveCount,
                                        webViewsByPurpose: RikuganWebView.liveByPurpose, extensions: extensions)
    }
}

// MARK: - Build identity and security log

/// Installed build identity, shown at the bottom of Settings so a tester can confirm which commit
/// is installed without opening Diagnostics.
enum BuildInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    static var commit: String { Bundle.main.infoDictionary?["RikuganGitCommit"] as? String ?? "unknown" }
    static var line: String { "Rikugan \(version) (\(build)) · commit \(commit)" }
}

struct SecurityLogView: View {
    @ObservedObject private var log = SecurityLog.shared

    var body: some View {
        List {
            Section {
                LabeledContent("被拒绝的特权调用（本次运行）", value: "\(log.totalRejected)")
            } footer: {
                Text("网页或其他扩展试图调用未授权的 GM / chrome.* / 原生操作时被拒绝的记录（错误的内容环境、缺少 @grant、伪造的扩展身份、不属于调用方的端口等）。不含网页内容；网址只保留域名。")
            }
            Section("最近记录") {
                if log.entries.isEmpty { Text("无").foregroundStyle(.secondary) }
                ForEach(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        Text(entry.message).font(.caption.monospaced())
                    }
                }
            }
            Section { Button("清除", role: .destructive) { log.clear() } }
        }
        .navigationTitle("安全拒绝记录")
    }
}
