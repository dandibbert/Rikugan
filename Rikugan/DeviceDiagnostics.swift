import SwiftUI
import WebKit

struct DiagnosticCheck: Codable, Identifiable, Equatable {
    enum Level: String, Codable { case pass, warning, fail, info }
    var id: String
    var title: String
    var level: Level
    var detail: String
}

struct DiagnosticReport: Codable, Equatable {
    var format = "com.dandibbert.rikugan.diagnostics.v1"
    var generatedAt = Date()
    var appVersion: String
    var build: String
    var osVersion: String
    var environment: String
    var checks: [DiagnosticCheck]
}

@MainActor enum DeviceDiagnostics {
    static func report(model: AppModel, session: BrowserSession) -> DiagnosticReport {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let simulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
        var checks: [DiagnosticCheck] = []
        func add(_ id: String, _ title: String, _ level: DiagnosticCheck.Level, _ detail: String) {
            checks.append(DiagnosticCheck(id: id, title: title, level: level, detail: detail))
        }

        add("environment", "运行环境", simulator ? .warning : .pass,
            simulator ? "模拟器：可验证逻辑，但不能替代证书、App Group 和系统分享面板真机验收。" : "真实 iOS 设备。")
        add("bundle", "主 App 标识", bundle.bundleIdentifier == "com.dandibbert.Rikugan" ? .pass : .warning,
            bundle.bundleIdentifier ?? "没有 Bundle ID")

        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupID.suite)
        if let group {
            let probe = group.appendingPathComponent("rikugan-diagnostic-probe-" + UUID().uuidString)
            do {
                let expected = Data("rikugan-app-group-probe".utf8)
                try expected.write(to: probe, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                let actual = try Data(contentsOf: probe)
                try FileManager.default.removeItem(at: probe)
                add("app-group", "App Group 主 App 读写", actual == expected ? .pass : .fail,
                    actual == expected ? AppGroupID.suite + " 可读写。" : "写入后读取内容不一致。")
            } catch {
                try? FileManager.default.removeItem(at: probe)
                add("app-group", "App Group 主 App 读写", .fail, "容器存在，但实际读写失败：" + safe(error.localizedDescription))
            }
        } else {
            add("app-group", "App Group 主 App 读写", .fail,
                "无法打开 " + AppGroupID.suite + "。重签时主 App 和 Share Extension 都必须包含同一 App Group。")
        }

        let plugIns = bundle.builtInPlugInsURL
        let shareEmbedded = plugIns.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            ?.contains(where: { $0.pathExtension == "appex" && $0.lastPathComponent.contains("RikuganShare") }) == true
        add("share-extension", "Share Extension 嵌入", shareEmbedded ? .pass : .fail,
            shareEmbedded ? "RikuganShare.appex 已嵌入；仍需从其他 App 的系统分享面板做一次真实往返测试。" : "安装包内没有发现 RikuganShare.appex。")

        add("website-store", "身份网站数据容器", session.dataStore.isPersistent ? .pass : .fail,
            session.dataStore.isPersistent ? "当前普通身份使用持久 WKWebsiteDataStore。" : "普通身份意外使用非持久容器。")
        add("private-store", "无痕网站数据容器", session.privateStore.isPersistent ? .fail : .pass,
            session.privateStore.isPersistent ? "无痕容器意外为持久存储。" : "无痕使用 nonPersistent WKWebsiteDataStore。")

        let enabledExtensions = session.profile.extensions.filter(\.enabled).count
        let loadedExtensions = session.contexts.count
        let extensionFailures = session.extensionErrors.count
        add("extensions", "扩展宿主", extensionFailures > 0 || loadedExtensions < enabledExtensions ? .warning : .pass,
            "启用 \(enabledExtensions)，已载入 \(loadedExtensions)，记录到加载错误 \(extensionFailures)。")
        add("static-dnr", "静态 DNR 宿主规则", session.extensionDNRLists.count <= loadedExtensions ? .pass : .warning,
            "当前已挂载 \(session.extensionDNRLists.count) 个扩展静态规则列表；仅代表已编译列表，不代表第三方规则语法全兼容。")
        if let error = session.contentRuleError {
            add("content-blocker", "浏览器内容拦截", .warning, safe(error))
        } else {
            add("content-blocker", "浏览器内容拦截", .pass, session.contentRuleList == nil ? "当前没有需要挂载的浏览器规则。" : "WKContentRuleList 已编译。")
        }

        let downloads = session.profile.downloads
        let active = downloads.filter { ["running", "pausing"].contains($0.state) }.count
        let resumable = downloads.filter(\.resumable).count
        add("downloads", "下载状态", .info, "记录 \(downloads.count)，在途 \(active)，可续传 \(resumable)。报告不包含下载 URL 或文件名。")
        add("tabs", "标签页生命周期", .info,
            "总标签 \(session.tabs.count)，当前分配 WKWebView \(session.tabs.filter { $0.existingWebView != nil }.count)。报告不包含页面 URL 或标题。")
        add("default-browser", "默认浏览器资格", .info,
            "应用内无法可靠断言重签后的系统 Default Browser entitlement。请以系统默认浏览器列表是否出现 Rikugan 为准。")

        return DiagnosticReport(appVersion: version, build: build,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            environment: simulator ? "simulator" : "device", checks: checks)
    }

    static func export(_ report: DiagnosticReport) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rikugan-Diagnostics-\(Int(Date().timeIntervalSince1970)).json")
        try encoder.encode(report).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    private static func safe(_ text: String) -> String {
        String(text.replacingOccurrences(of: #"/[^\s]+"#, with: "<local-path>", options: .regularExpression).prefix(800))
    }
}

struct DeviceDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: BrowserSession
    @State private var report: DiagnosticReport?
    var body: some View {
        List {
            Section {
                Text("不读取或导出 Cookie、历史、书签、脚本源码、网页 URL、下载地址或密码。报告用于判断重签/App Group/Share Extension/WebKit 宿主是否处于可验收状态。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let report {
                Section("环境") {
                    LabeledContent("Rikugan", value: report.appVersion + " (" + report.build + ")")
                    LabeledContent("系统", value: report.osVersion)
                }
                Section("检查") {
                    ForEach(report.checks) { check in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(check.level)).foregroundStyle(color(check.level)).frame(width: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.title).font(.headline)
                                Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                Section {
                    Button("导出诊断 JSON") {
                        do { BrowserPresentation.share([try DeviceDiagnostics.export(report)]) }
                        catch { model.message = error.localizedDescription }
                    }
                    Button("重新检查") { self.report = DeviceDiagnostics.report(model: model, session: session) }
                }
            } else { ProgressView("正在检查") }
        }.navigationTitle("真机验收诊断")
            .task { report = DeviceDiagnostics.report(model: model, session: session) }
    }
    private func symbol(_ level: DiagnosticCheck.Level) -> String {
        switch level { case .pass: return "checkmark.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .fail: return "xmark.octagon.fill"; case .info: return "info.circle.fill" }
    }
    private func color(_ level: DiagnosticCheck.Level) -> Color {
        switch level { case .pass: return .green; case .warning: return .orange; case .fail: return .red; case .info: return .secondary }
    }
}
