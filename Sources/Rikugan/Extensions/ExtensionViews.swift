import SwiftUI
import WebKit

/// `rikugan://extensions` / `chrome://extensions` (spec §18).
struct ExtensionManagerView: View {
    @EnvironmentObject private var runtime: ExtensionRuntime
    @EnvironmentObject private var installer: ExtensionInstaller
    @EnvironmentObject private var manager: TabManager
    @Binding var importKind: BrowserView.ImportKind?
    @State private var askStoreLink = false
    @State private var storeLink = ""

    var body: some View {
        List {
            if runtime.records.isEmpty {
                Section {
                    Text("还没有安装扩展。可以导入 ZIP / CRX / 解压后的扩展文件夹，或打开 Chrome 应用商店 / Edge 加载项的扩展详情页，用页面顶部的“安装到 Rikugan”安装。").foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(runtime.records) { record in
                    NavigationLink { ExtensionDetailView(extID: record.id) } label: { ExtensionRow(record: record) }
                        .accessibilityIdentifier("extension-\(record.name)")
                }
            }
            Section {
                Button { importKind = .extensionPackage } label: { Text("导入 ZIP / CRX") }
                Button { importKind = .extensionFolder } label: { Text("导入解压后的文件夹") }
                Button { openStore("https://chromewebstore.google.com/") } label: { Text("打开 Chrome 应用商店") }
                Button { openStore("https://microsoftedge.microsoft.com/addons/") } label: { Text("打开 Edge 加载项") }
                Button { storeLink = ""; askStoreLink = true } label: { Text("通过商店链接或扩展 ID 安装") }
            } header: {
                Text("安装")
            } footer: {
                Text("商店会在新标签页打开。商店自己的“添加 / 获取”按钮在 iPhone 上不可用（Chrome 提示仅限桌面，Edge 按钮为灰色）：打开扩展详情页后，使用页面顶部 Rikugan 的“安装到 Rikugan”栏。")
            }
            Section {
                NavigationLink { CompatibilityView() } label: { Text("Chrome API 兼容性矩阵") }
            } footer: {
                Text("Rikugan 在自己的 WKWebView 环境中实现 Chrome Manifest V3 兼容运行时（不是 Safari Web Extension）。未实现的 API 会返回明确的 “Unsupported API” 错误。扩展默认不在无痕标签页运行。")
            }
        }
        .navigationTitle("扩展")
        .alert("通过商店链接安装", isPresented: $askStoreLink) {
            TextField("商店链接或 32 位扩展 ID", text: $storeLink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("安装") { installFromLink() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("粘贴 Chrome 应用商店或 Edge 加载项的扩展详情页链接；只填 ID 时按 Chrome 应用商店处理。")
        }
    }

    /// Opens the store in a new foreground tab and closes the settings / extensions sheet so the
    /// store is actually visible.
    private func openStore(_ address: String) {
        guard let url = URL(string: address) else { return }
        manager.newTab(url: url)
        NotificationCenter.default.post(name: .rikuganCloseSheet, object: manager)
    }

    private func installFromLink() {
        guard let item = WebStoreItem.parse(storeLink) else {
            ToastCenter.shared.show("无法识别：请粘贴扩展详情页链接或 32 位扩展 ID", symbol: "exclamationmark.triangle", duration: 4)
            return
        }
        // The permission confirmation is presented by the browser window, which cannot show it
        // while this sheet is up: close it first, the download then prompts over the browser.
        NotificationCenter.default.post(name: .rikuganCloseSheet, object: manager)
        installer.stage(store: item)
    }
}

struct ExtensionRow: View {
    let record: InstalledExtension
    @EnvironmentObject private var runtime: ExtensionRuntime

    var body: some View {
        HStack(spacing: 12) {
            if let icon = runtime.loaded[record.id]?.icon {
                Image(uiImage: icon).resizable().scaledToFit().frame(width: 32, height: 32)
            } else {
                Image(icon: "puzzlepiece.extension.fill").resizable().scaledToFit().frame(width: 30, height: 30).foregroundStyle(.gray)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name).font(.body.weight(.medium)).lineLimit(1)
                Text(record.lastErrors.isEmpty ? "版本 \(record.version)" : record.lastErrors[0])
                    .font(.subheadline).foregroundStyle(record.lastErrors.isEmpty ? Color.secondary : Color.red).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { record.enabled }, set: { runtime.setEnabled(record.id, $0) })).labelsHidden()
        }
    }
}

struct ExtensionDetailView: View {
    let extID: String
    @EnvironmentObject private var runtime: ExtensionRuntime
    @EnvironmentObject private var installer: ExtensionInstaller
    @EnvironmentObject private var manager: TabManager
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var showManifest = false
    @State private var confirmRemove = false

    var body: some View {
        if let record = runtime.records.first(where: { $0.id == extID }) {
            let loaded = runtime.loaded[extID]
            Form {
                Section {
                    ItemHeader(title: record.name, subtitle: record.description) {
                        if let icon = loaded?.icon { Image(uiImage: icon).resizable().scaledToFit() }
                        else { Image(icon: "puzzlepiece.extension.fill").resizable().scaledToFit().foregroundStyle(.gray) }
                    }
                    Toggle("启用", isOn: Binding(get: { record.enabled }, set: { runtime.setEnabled(record.id, $0) }))
                }
                if let loaded, record.enabled {
                    Section {
                        Button("打开扩展") { runtime.performAction(loaded, tab: manager.activeTab) }
                        if loaded.manifest.optionsPage != nil {
                            Button("扩展选项") { runtime.openOptions(loaded, from: manager.activeTab) }
                        }
                    }
                }
                Section {
                    LabeledContent("版本", value: record.version)
                    LabeledContent("来源", value: sourceName(record.source))
                    if let manifest = loaded?.manifest { LabeledContent("后台类型", value: manifest.backgroundKind) }
                    if let bg = loaded?.background { LabeledContent("后台运行时", value: bg.isReady ? "运行中" : "未运行") }
                    LinkRow(title: "扩展 ID", value: record.id)
                    if let store = record.storeURL, !store.isEmpty { LinkRow(title: "商店页面", value: store) { openInNewTab($0) } }
                }
                Section {
                    Picker("网站访问", selection: Binding(get: { record.hostAccess }, set: { runtime.setHostAccess(record.id, $0) })) {
                        Text("自动运行").tag(InstalledExtension.HostAccess.granted)
                        Text("点击时运行").tag(InstalledExtension.HostAccess.onClick)
                    }
                    ForEach(record.grantedHosts, id: \.self) { host in
                        Text(host).font(.callout.monospaced())
                            .swipeActions { Button("撤销", role: .destructive) { runtime.revokeHost(record.id, pattern: host) } }
                    }
                } header: { Text("网站访问") } footer: {
                    Text(record.hostAccess == .granted ? "在下列已授权的网站上自动运行。左滑可撤销。" : "只有在网页上点击扩展按钮后，才在该网站运行。")
                }
                Section("权限") {
                    ForEach(PermissionDescriber.describe(apiPermissions: record.grantedPermissions, hostPatterns: [])) { line in
                        Text(line.text).foregroundStyle(line.level == .unsupported ? .secondary : .primary)
                    }
                    if record.grantedPermissions.isEmpty { Text("无 API 权限").foregroundStyle(.secondary) }
                }
                if !record.lastErrors.isEmpty {
                    Section("最近错误") { ForEach(record.lastErrors, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) } }
                }
                Section {
                    Button("检查更新") { Task { status = await installer.checkUpdate(record) } }
                    Button("重新加载") { runtime.reload(record.id); status = "已重新加载" }
                    Button("查看 manifest.json") { showManifest = true }
                } footer: {
                    if let status { Text(status) }
                }
                Section {
                    Button("移除扩展", role: .destructive) { confirmRemove = true }
                }
            }
            .navigationTitle(record.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showManifest) {
                NavigationStack {
                    ScrollView {
                        Text(manifestText(loaded)).font(.footnote.monospaced()).textSelection(.enabled).padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle("manifest.json").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showManifest = false } } }
                }
            }
            .confirmationDialog("移除「\(record.name)」及其数据？", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("移除", role: .destructive) { runtime.remove(record.id); dismiss() }
            }
        } else {
            Text("扩展已移除").foregroundStyle(.secondary)
        }
    }

    private func sourceName(_ source: InstalledExtension.Source) -> String {
        switch source {
        case .file: return "本地文件"
        case .chromeWebStore: return "Chrome 应用商店"
        case .edgeAddons: return "Edge 加载项"
        case .bundled: return "内置"
        }
    }

    private func manifestText(_ ext: LoadedExtension?) -> String {
        guard let raw = ext?.manifest.raw, let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) else { return "（扩展未加载）" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Permission confirmation at install / update time (spec §19).
struct ExtensionInstallSheet: View {
    let pending: PendingExtensionInstall
    @EnvironmentObject private var installer: ExtensionInstaller

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ItemHeader(title: pending.displayName,
                               subtitle: "版本 \(pending.manifest.version)" + (pending.existing.map { " · 当前已安装 \($0.version)" } ?? "")) {
                        if let icon = pending.icon { Image(uiImage: icon).resizable().scaledToFit() }
                        else { Image(icon: "puzzlepiece.extension.fill").resizable().scaledToFit().foregroundStyle(.gray) }
                    }
                }
                Section(pending.existing == nil ? "该扩展希望：" : "新版本需要新的权限：") {
                    let lines = pending.descriptionLines
                    if lines.isEmpty { Text("不需要特殊权限").foregroundStyle(.secondary) }
                    ForEach(lines) { line in
                        Text(line.text).foregroundStyle(line.level == .unsupported ? .secondary : .primary)
                    }
                }
                Section {
                    LinkRow(title: "扩展 ID", value: pending.extensionID)
                    LabeledContent("后台", value: pending.manifest.backgroundKind)
                    LabeledContent("内容脚本", value: "\(pending.manifest.contentScripts.count) 组")
                    if pending.manifest.actionPopup != nil { LabeledContent("弹出页面", value: pending.manifest.actionPopup ?? "") }
                } footer: {
                    Text("只安装你信任的扩展。拥有“读取和修改所有网站的数据”权限的扩展可以看到你在网页上输入的内容。")
                }
            }
            .navigationTitle(pending.existing == nil ? "添加扩展" : "更新扩展")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { installer.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pending.existing == nil ? "安装" : "更新") { installer.confirm(pending) }.accessibilityIdentifier("installExtension")
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// Runtime permission request (chrome.permissions.request).
struct PermissionPromptSheet: View {
    let prompt: ExtensionRuntime.PermissionPrompt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("「\(prompt.extName)」请求额外权限：") {
                    ForEach(prompt.lines) { Text($0.text) }
                }
            }
            .navigationTitle("扩展权限")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("拒绝") { prompt.completion(false); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("允许") { prompt.completion(true); dismiss() } }
            }
        }
        .presentationDetents([.medium])
        .onDisappear { prompt.completion(false) }
    }
}

/// Extension popup / options page in a WKWebView with the extension origin (spec §17).
struct ExtensionPopupSheet: View {
    let request: ExtensionRuntime.PopupRequest
    @EnvironmentObject private var runtime: ExtensionRuntime
    @StateObject private var holder = PopupHolder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let webView = holder.webView {
                    PlainWebView(webView: webView)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .onAppear { holder.load(request, runtime: runtime) }
        .onDisappear { holder.close(runtime: runtime) }
    }
}

@MainActor final class PopupHolder: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    @Published var webView: WKWebView?

    func load(_ request: ExtensionRuntime.PopupRequest, runtime: ExtensionRuntime) {
        guard webView == nil, let ext = runtime.loaded[request.extID] else { return }
        let configuration = runtime.extensionPageConfiguration(for: ext, kind: "popup")
        let view = RikuganWebView(frame: .zero, configuration: configuration, purpose: "popup")
        view.uiDelegate = self
        view.navigationDelegate = self
        view.isInspectable = true
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        runtime.registerPage(view, extID: ext.id, kind: "popup")
        view.load(URLRequest(url: request.url))
        webView = view
    }

    func close(runtime: ExtensionRuntime) {
        if let webView {
            runtime.unregisterPage(webView)
            // Ports opened by the popup disconnect now (the background gets onDisconnect and can
            // go idle again).
            runtime.bridge.endpointsGone(webView: webView)
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
        }
        webView = nil
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { TabRegistry.shared.focusedWindow?.newTab(url: url, isPrivate: false) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = AppServices.shared.profile.extensions.scheme
        if url.scheme == scheme || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" || navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
        } else {
            // Links in popups open in a new tab, like Chrome.
            TabRegistry.shared.focusedWindow?.newTab(url: url, isPrivate: false)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        Presenter.present(alert, from: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
        Presenter.present(alert, from: webView)
    }
}


extension ExtensionDetailView {
    /// Opens a link in a new tab of the focused window and closes the settings sheet.
    @MainActor func openInNewTab(_ url: URL) {
        guard let manager = TabRegistry.shared.focusedWindow else { return }
        manager.newTab(url: url)
        NotificationCenter.default.post(name: .rikuganCloseSheet, object: manager)
    }
}
