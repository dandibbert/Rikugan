import UIKit
import WebKit

@MainActor struct PreparedExtension: Identifiable {
    let id: UUID
    let profileID: UUID
    let relativePath: String
    let webExtension: WKWebExtension
    var name: String { webExtension.displayName ?? "未命名扩展" }
    var permissions: [String] { webExtension.requestedPermissions.map(\.rawValue).sorted() }
    var patterns: [String] { webExtension.allRequestedMatchPatterns.map(\.string).sorted() }
    var warnings: String { webExtension.errors.map(\.localizedDescription).joined(separator: "\n") }
}

extension BrowserSession {
    func prepareExtension(_ input: URL) async throws -> PreparedExtension {
        guard let model else { throw RikuganError.message("身份已关闭。") }
        let id = UUID()
        let values = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw RikuganError.message("扩展来源不能是符号链接。") }
        let directory = values.isDirectory == true
        let relative = "Extensions/" + id.uuidString + (directory ? "" : ".zip")
        let destination = model.directory(profileID).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if directory {
            guard FileManager.default.fileExists(atPath: input.appendingPathComponent("manifest.json").path) else { throw RikuganError.message("所选文件夹的根目录缺少 manifest.json。") }
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(at: input, includingPropertiesForKeys: keys) else { throw RikuganError.message("不能读取扩展文件夹。") }
            var count = 0, size = 0
            while let file = enumerator.nextObject() as? URL {
                let info = try file.resourceValues(forKeys: Set(keys)); count += 1; size += info.fileSize ?? 0
                guard info.isSymbolicLink != true, count <= 10000, size <= 128 * 1024 * 1024 else { throw RikuganError.message("文件夹含符号链接或超过扩展大小限制。") }
            }
        } else {
            guard (values.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw RikuganError.message("扩展 ZIP 不能超过 32 MB。") }
            try ArchiveValidator.validate(Data(contentsOf: input))
        }
        try FileManager.default.copyItem(at: input, to: destination)
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: destination)
            guard isActive else { throw RikuganError.message("导入期间切换了身份，请在目标身份重新导入。") }
            return PreparedExtension(id: id, profileID: profileID, relativePath: relative, webExtension: webExtension)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    func discardExtension(_ prepared: PreparedExtension) {
        guard let model else { return }
        try? FileManager.default.removeItem(at: model.directory(prepared.profileID).appendingPathComponent(prepared.relativePath))
    }
    func installExtension(_ prepared: PreparedExtension) async throws {
        guard prepared.profileID == profileID, isActive else { throw RikuganError.message("身份已切换，请重新导入扩展。") }
        let record = ExtensionRecord(id: prepared.id, name: prepared.name, version: prepared.webExtension.version ?? "1.0",
                                     detail: prepared.webExtension.displayDescription ?? "", relativePath: prepared.relativePath,
                                     allowedPermissions: prepared.permissions, allowedPatterns: prepared.patterns, requestedPatterns: prepared.patterns)
        try await activateExtension(prepared.webExtension, record: record)
        model?.updateProfile(profileID) { $0.extensions.append(record) }
    }
    func loadExtension(_ record: ExtensionRecord) async {
        guard let model else { return }
        do {
            let extensionObject = try await WKWebExtension(resourceBaseURL: model.directory(profileID).appendingPathComponent(record.relativePath))
            guard isActive else { return }
            try await activateExtension(extensionObject, record: record)
        } catch { extensionErrors[record.id] = error.localizedDescription }
    }
    private func activateExtension(_ webExtension: WKWebExtension, record: ExtensionRecord) async throws {
        if let previous = contexts.removeValue(forKey: record.id) { try? extensionController.unload(previous) }
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.id.uuidString
        context.baseURL = URL(string: "webkit-extension://" + record.id.uuidString.lowercased() + "/")!
        context.isInspectable = true
        context.hasAccessToPrivateData = false
        context.unsupportedAPIs = ["runtime.sendNativeMessage", "runtime.connectNative"]
        for permission in record.allowedPermissions { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission)) }
        for pattern in record.allowedPatterns {
            if let match = try? WKWebExtension.MatchPattern(string: pattern) { context.setPermissionStatus(.grantedExplicitly, for: match) }
        }
        for pattern in record.requestedPatterns where !record.allowedPatterns.contains(pattern) {
            if let match = try? WKWebExtension.MatchPattern(string: pattern) { context.setPermissionStatus(.deniedExplicitly, for: match) }
        }
        try extensionController.load(context)
        contexts[record.id] = context; extensionErrors.removeValue(forKey: record.id)
        do {
            if webExtension.hasBackgroundContent {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    context.loadBackgroundContent { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
            }
            guard isActive else { throw RikuganError.message("扩展加载期间身份已关闭。") }
        } catch {
            try? extensionController.unload(context)
            contexts.removeValue(forKey: record.id)
            throw error
        }
        if ready {
            context.didOpenWindow(self)
            for tab in tabs { context.didOpenTab(tab) }
            if let tab = activeTab { context.didActivateTab(tab, previousActiveTab: nil) }
        }
    }
    func toggleExtension(_ record: ExtensionRecord, enabled: Bool) async {
        model?.updateProfile(profileID) { profile in
            if let index = profile.extensions.firstIndex(where: { $0.id == record.id }) { profile.extensions[index].enabled = enabled }
        }
        if enabled { await loadExtension(record) }
        else if let context = contexts.removeValue(forKey: record.id) { try? extensionController.unload(context) }
        objectWillChange.send()
    }
    func removeExtension(_ record: ExtensionRecord) {
        if let context = contexts.removeValue(forKey: record.id) {
            let types = WKWebExtensionController.allExtensionDataTypes
            extensionController.fetchDataRecord(ofTypes: types, for: context) { [weak self] dataRecord in
                if let dataRecord { self?.extensionController.removeData(ofTypes: types, from: [dataRecord]) {} }
            }
            try? extensionController.unload(context)
        }
        model?.updateProfile(profileID) { $0.extensions.removeAll { $0.id == record.id } }
        if let model { try? FileManager.default.removeItem(at: model.directory(profileID).appendingPathComponent(record.relativePath)) }
        extensionErrors.removeValue(forKey: record.id)
    }
    func setHostPermission(_ pattern: String, record: ExtensionRecord, allowed: Bool) {
        model?.updateProfile(profileID) { profile in
            guard let index = profile.extensions.firstIndex(where: { $0.id == record.id }) else { return }
            profile.extensions[index].allowedPatterns.removeAll { $0 == pattern }
            if allowed { profile.extensions[index].allowedPatterns.append(pattern) }
        }
        if let match = try? WKWebExtension.MatchPattern(string: pattern) {
            contexts[record.id]?.setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly, for: match)
        }
    }
    func performExtension(_ id: UUID) {
        guard let context = contexts[id], let tab = activeTab else { model?.message = "扩展没有载入，请检查扩展详情里的错误。"; return }
        context.userGesturePerformed(in: tab)
        context.performAction(for: tab)
    }
    func openOptions(_ id: UUID) {
        guard let context = contexts[id], let url = context.optionsPageURL else { model?.message = "这个扩展没有选项页面。"; return }
        addTab(url: url, configuration: context.webViewConfiguration)
    }
    private func saveOptionalPermissions(context: WKWebExtensionContext, permissions: [String] = [], patterns: [String] = []) {
        model?.updateProfile(profileID) { profile in
            guard let index = profile.extensions.firstIndex(where: { $0.id.uuidString == context.uniqueIdentifier }) else { return }
            profile.extensions[index].allowedPermissions = Array(Set(profile.extensions[index].allowedPermissions + permissions)).sorted()
            profile.extensions[index].allowedPatterns = Array(Set(profile.extensions[index].allowedPatterns + patterns)).sorted()
            profile.extensions[index].requestedPatterns = Array(Set(profile.extensions[index].requestedPatterns + patterns)).sorted()
        }
    }
}

extension BrowserSession: WKWebExtensionControllerDelegate, WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { BrowserPresentation.presenter?.view.bounds ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { UIScreen.main.bounds }
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [self] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { self }
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard isActive else { completionHandler(nil, RikuganError.message("身份未激活。")); return }
        let tab = addTab(url: configuration.url, activate: configuration.shouldBeActive, configuration: context.webViewConfiguration)
        completionHandler(tab, nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext,
                                completionHandler: @escaping (Error?) -> Void) {
        guard let url = context.optionsPageURL else { completionHandler(RikuganError.message("扩展没有选项页。")); return }
        addTab(url: url, configuration: context.webViewConfiguration); completionHandler(nil)
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        guard isActive else { completionHandler([], nil); return }
        BrowserPresentation.confirm(title: context.webExtension.displayName ?? "扩展授权", message: "申请额外权限：\n" + permissions.map(\.rawValue).sorted().joined(separator: "\n")) { [weak self] allowed in
            if allowed { self?.saveOptionalPermissions(context: context, permissions: permissions.map(\.rawValue)) }
            completionHandler(allowed ? permissions : [], nil)
        }
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        guard isActive else { completionHandler([], nil); return }
        BrowserPresentation.confirm(title: context.webExtension.displayName ?? "网站授权", message: "允许读取和更改以下网站的数据？\n" + patterns.map(\.string).sorted().joined(separator: "\n")) { [weak self] allowed in
            if allowed { self?.saveOptionalPermissions(context: context, patterns: patterns.map(\.string)) }
            completionHandler(allowed ? patterns : [], nil)
        }
    }
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        guard isActive else { completionHandler([], nil); return }
        BrowserPresentation.confirm(title: context.webExtension.displayName ?? "网站授权", message: urls.map(\.absoluteString).sorted().joined(separator: "\n")) { allowed in completionHandler(allowed ? urls : [], nil) }
    }
    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) { objectWillChange.send() }
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard isActive, let presenter = BrowserPresentation.presenter, let content = action.popupViewController else { completionHandler(RikuganError.message("无法显示扩展弹窗。")); return }
        let popup = PopupPresenter(action: action, content: content)
        popupPresenter = popup
        presenter.present(popup.navigation, animated: true) { completionHandler(nil) }
    }
}

@MainActor final class PopupPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    let action: WKWebExtension.Action
    let navigation: UINavigationController
    init(action: WKWebExtension.Action, content: UIViewController) {
        self.action = action; navigation = UINavigationController(rootViewController: content)
        super.init()
        content.title = action.label
        content.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.dismiss() })
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.presentationController?.delegate = self
    }
    func dismiss() { navigation.dismiss(animated: true); action.closePopup() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { action.closePopup() }
}

extension BrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { session }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { session?.tabs.firstIndex(where: { $0.id == id }) ?? 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { pageTitle }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func pendingURL(for context: WKWebExtensionContext) -> URL? { isLoading ? URL(string: address) : nil }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { session?.selectedID == id }
    func size(for context: WKWebExtensionContext) -> CGSize { webView.bounds.size }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { webView.pageZoom }
    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { webView.pageZoom = min(5, max(0.25, zoomFactor)); completionHandler(nil) }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { session?.select(self); completionHandler(nil) }
    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { if selected { session?.select(self) }; completionHandler(nil) }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { navigate(url); completionHandler(nil) }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }; completionHandler(nil) }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { webView.goBack(); completionHandler(nil) }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { webView.goForward(); completionHandler(nil) }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { session?.close(self); completionHandler(nil) }
    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        completionHandler(session?.addTab(url: webView.url, activate: configuration.shouldBeActive), nil)
    }
    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext,
                      completionHandler: @escaping (UIImage?, Error?) -> Void) { webView.takeSnapshot(with: configuration, completionHandler: completionHandler) }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
}
