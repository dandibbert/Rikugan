import UIKit
import WebKit

@MainActor final class PreparedExtension: Identifiable {
    let id: UUID
    let profileID: UUID
    let relativePath: String
    let name: String
    let version: String
    let detail: String
    let permissions: [String]
    let patterns: [String]
    let warnings: String
    var updateURL = ""
    var storeID = ""
    private let object: Any
    @available(iOS 18.4, *)
    var webExtension: WKWebExtension { object as! WKWebExtension }
    @available(iOS 18.4, *)
    init(id: UUID, profileID: UUID, relativePath: String, webExtension: WKWebExtension) {
        self.id = id
        self.profileID = profileID
        self.relativePath = relativePath
        self.object = webExtension
        name = webExtension.displayName ?? "未命名扩展"
        version = webExtension.version ?? "1.0"
        detail = webExtension.displayDescription ?? ""
        permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
        patterns = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
        warnings = webExtension.errors.map(\.localizedDescription).joined(separator: "\n")
    }
}

extension BrowserSession {
    func prepareExtension(_ input: URL) async throws -> PreparedExtension {
        guard #available(iOS 18.4, *) else { throw RikuganError.message(Self.extensionOSMessage) }
        guard let model else { throw RikuganError.message("身份已关闭。") }
        let id = UUID()
        var source = input
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        if input.pathExtension.lowercased() == "crx" {
            let zip = try CRXArchive.zipData(from: Data(contentsOf: input))
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString + ".zip")
            try zip.write(to: temp)
            source = temp
            temporary = temp
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let directory = values.isDirectory == true
        let relative = "Extensions/" + id.uuidString + (directory ? "" : ".zip")
        let destination = model.directory(profileID).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if directory {
            guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else { throw RikuganError.message("所选文件夹的根目录缺少 manifest.json。") }
            let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys) else { throw RikuganError.message("不能读取扩展文件夹。") }
            var count = 0, size = 0
            for case let file as URL in enumerator {
                let info = try file.resourceValues(forKeys: Set(keys)); count += 1; size += info.fileSize ?? 0
                guard info.isSymbolicLink != true, count <= 10000, size <= 128 * 1024 * 1024 else { throw RikuganError.message("文件夹含符号链接或超过扩展大小限制。") }
            }
        } else {
            guard (values.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw RikuganError.message("扩展 ZIP 不能超过 32 MB。") }
            try ArchiveValidator.validate(Data(contentsOf: source))
        }
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            try ExtensionBridge.install(at: destination, directory: directory, source: ExtensionBridge.source)
            let manifest = Self.manifestData(at: destination, directory: directory)
            var parsed: ParsedManifest?
            if let manifest {
                parsed = try ExtensionManifest.parse(manifest)
            }
            let webExtension = try await WKWebExtension(resourceBaseURL: destination)
            guard isActive else { throw RikuganError.message("导入期间切换了身份，请在目标身份重新导入。") }
            var prepared = PreparedExtension(id: id, profileID: profileID, relativePath: relative, webExtension: webExtension)
            prepared.updateURL = parsed?.updateURL ?? ""
            return prepared
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    private static func manifestData(at url: URL, directory: Bool) -> Data? {
        if directory { return try? Data(contentsOf: url.appendingPathComponent("manifest.json")) }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ZipArchive.extract(data: data, path: "manifest.json")
    }
    func discardExtension(_ prepared: PreparedExtension) {
        guard let model else { return }
        try? FileManager.default.removeItem(at: model.directory(prepared.profileID).appendingPathComponent(prepared.relativePath))
    }
    func installExtension(_ prepared: PreparedExtension) throws {
        guard #available(iOS 18.4, *) else { throw RikuganError.message(Self.extensionOSMessage) }
        guard prepared.profileID == profileID, isActive else { throw RikuganError.message("身份已切换，请重新导入扩展。") }
        var record = ExtensionRecord(id: prepared.id, name: prepared.name, version: prepared.version,
                                     detail: prepared.detail, relativePath: prepared.relativePath,
                                     allowedPermissions: prepared.permissions, allowedPatterns: prepared.patterns, requestedPatterns: prepared.patterns)
        record.updateURL = prepared.updateURL
        record.storeID = prepared.storeID
        try activateExtension(prepared.webExtension, record: record)
        model?.updateProfile(profileID) { $0.extensions.append(record) }
    }
    func loadExtension(_ record: ExtensionRecord) async {
        guard #available(iOS 18.4, *) else {
            extensionErrors[record.id] = Self.extensionOSMessage
            extensionPhase = .failed
            extensionPhaseError = Self.extensionOSMessage
            return
        }
        guard let model else { return }
        extensionPhase = ExtensionRuntime.beginLoad(from: extensionPhase)
        do {
            let base = model.directory(profileID).appendingPathComponent(record.relativePath)
            let directory = (try? base.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            try ExtensionBridge.install(at: base, directory: directory, source: ExtensionBridge.source)
            let extensionObject = try await WKWebExtension(resourceBaseURL: base)
            guard isActive else { return }
            try activateExtension(extensionObject, record: record)
            extensionPhase = .ready
            extensionPhaseError = ""
        } catch {
            extensionErrors[record.id] = error.localizedDescription
            extensionPhase = .failed
            extensionPhaseError = error.localizedDescription
            model.noteRuntime("extension load failed: \(error.localizedDescription)")
        }
    }
    @available(iOS 18.4, *)
    private func activateExtension(_ webExtension: WKWebExtension, record: ExtensionRecord) throws {
        if let previous = removeExtensionContext(id: record.id) { try? extensionController.unload(previous) }
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = record.id.uuidString
        context.baseURL = URL(string: "webkit-extension://" + record.id.uuidString.lowercased() + "/")!
        context.isInspectable = true
        context.hasAccessToPrivateData = false
        context.unsupportedAPIs = [
            "runtime.sendNativeMessage", "runtime.connectNative", "runtime.onConnectNative",
            "downloads", "downloads.download", "downloads.search", "downloads.pause", "downloads.resume",
            "downloads.cancel", "downloads.erase", "downloads.removeFile", "downloads.acceptDanger",
            "downloads.show", "downloads.showDefaultFolder", "downloads.getFileIcon", "downloads.open",
            "downloads.setShelfEnabled", "downloads.setUiOptions",
            "downloads.onCreated", "downloads.onChanged", "downloads.onErased", "downloads.onDeterminingFilename",
            "debugger", "debugger.attach", "debugger.detach", "debugger.sendCommand", "debugger.getTargets",
            "debugger.onEvent", "debugger.onDetach",
            "webRequest", "webRequest.handlerBehaviorChanged", "webRequest.onBeforeRequest",
            "webRequest.onBeforeSendHeaders", "webRequest.onSendHeaders", "webRequest.onHeadersReceived",
            "webRequest.onAuthRequired", "webRequest.onBeforeRedirect",
            "webRequest.onResponseStarted", "webRequest.onCompleted", "webRequest.onErrorOccurred",
            "scripting.registerContentScripts", "scripting.unregisterContentScripts", "scripting.getRegisteredContentScripts"
        ]
        if let controller = context.webViewConfiguration?.userContentController {
            ExtensionBridge.attach(to: controller, handler: extensionPageBridge)
        }
        for permission in record.allowedPermissions { context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission)) }
        for pattern in record.allowedPatterns {
            if let match = try? WKWebExtension.MatchPattern(string: pattern) { context.setPermissionStatus(.grantedExplicitly, for: match) }
        }
        try extensionController.load(context)
        storeExtensionContext(context, id: record.id); extensionErrors.removeValue(forKey: record.id)
        if ready {
            context.didOpenWindow(self)
            for tab in tabs { context.didOpenTab(tab) }
            if let tab = activeTab { context.didActivateTab(tab, previousActiveTab: nil) }
        }
    }
    func toggleExtension(_ record: ExtensionRecord, enabled: Bool) async {
        guard #available(iOS 18.4, *) else { extensionErrors[record.id] = Self.extensionOSMessage; model?.message = Self.extensionOSMessage; return }
        model?.updateProfile(profileID) { profile in
            if let index = profile.extensions.firstIndex(where: { $0.id == record.id }) { profile.extensions[index].enabled = enabled }
        }
        if enabled { await loadExtension(record) }
        else if let context = removeExtensionContext(id: record.id) { try? extensionController.unload(context) }
        objectWillChange.send()
    }
    func removeExtension(_ record: ExtensionRecord) {
        if #available(iOS 18.4, *) {
            if let context = removeExtensionContext(id: record.id) {
                let types = WKWebExtensionController.allExtensionDataTypes
                extensionController.fetchDataRecord(ofTypes: types, for: context) { [weak self] dataRecord in
                    guard #available(iOS 18.4, *), let self, let dataRecord else { return }
                    let stored = WKWebExtensionController.allExtensionDataTypes
                    self.extensionController.removeData(ofTypes: stored, from: [dataRecord]) {}
                }
                try? extensionController.unload(context)
            }
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
        if #available(iOS 18.4, *) {
            if let match = try? WKWebExtension.MatchPattern(string: pattern) {
                extensionContext(id: record.id)?.setPermissionStatus(allowed ? .grantedExplicitly : .deniedExplicitly, for: match)
            }
        }
    }
    func actionPresentation(_ id: UUID) -> (icon: UIImage?, badge: String) {
        guard #available(iOS 18.4, *) else { return (nil, "") }
        guard let context = extensionContext(id: id) else { return (nil, "") }
        let action = context.action(for: activeTab)
        let icon = action?.icon(for: CGSize(width: 22, height: 22)) ?? context.webExtension.actionIcon(for: CGSize(width: 22, height: 22))
        return (icon, action?.badgeText ?? "")
    }
    func performExtension(_ id: UUID) {
        guard #available(iOS 18.4, *) else { model?.message = Self.extensionOSMessage; return }
        guard let context = extensionContext(id: id), let tab = activeTab else { model?.message = "扩展没有载入，请检查扩展详情里的错误。"; return }
        context.userGesturePerformed(in: tab)
        context.performAction(for: tab)
    }
    func installFromStore(_ input: String) async {
        guard let id = ExtensionCatalog.storeID(from: input) else { model?.message = "没有识别到 32 位扩展 ID。"; return }
        let edge = input.contains("edge.microsoft")
        guard let url = edge ? ExtensionCatalog.edgeDownloadURL(id: id) : ExtensionCatalog.chromeDownloadURL(id: id) else { return }
        model?.working = true
        defer { model?.working = false }
        do {
            let data = try await Self.extensionPackage(from: url)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(id + ".crx")
            try data.write(to: temp)
            var prepared = try await prepareExtension(temp)
            prepared.storeID = id
            model?.preparedExtension = prepared
        } catch { model?.message = error.localizedDescription }
    }
    func updateExtension(_ record: ExtensionRecord) async {
        let address = record.updateURL.isEmpty ? (record.storeID.isEmpty ? "" : (ExtensionCatalog.chromeDownloadURL(id: record.storeID)?.absoluteString ?? "")) : record.updateURL
        guard let url = URL(string: address), url.scheme == "https" else { model?.message = "这个扩展没有 HTTPS 更新地址。"; return }
        model?.working = true
        defer { model?.working = false }
        do {
            let data = try await Self.extensionPackage(from: url)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(record.id.uuidString + ".crx")
            try data.write(to: temp)
            let prepared = try await prepareExtension(temp)
            let version = prepared.version
            guard VersionComparator.isNewer(version, than: record.version) else { model?.message = "已是最新版本 \(record.version)。"; discardExtension(prepared); return }
            let added = ChromeAPIMatrix.additions(old: record.allowedPermissions + record.requestedPatterns, new: prepared.permissions + prepared.patterns)
            let install = { [weak self] in
                guard let self else { return }
                guard #available(iOS 18.4, *) else { self.model?.message = Self.extensionOSMessage; return }
                self.discardInstalledFiles(record)
                var updated = record
                updated.version = version
                updated.relativePath = prepared.relativePath
                updated.allowedPermissions = prepared.permissions
                updated.allowedPatterns = prepared.patterns
                updated.requestedPatterns = prepared.patterns
                self.model?.updateProfile(self.profileID) { profile in
                    if let index = profile.extensions.firstIndex(where: { $0.id == record.id }) { profile.extensions[index] = updated }
                }
                try? self.activateExtension(prepared.webExtension, record: updated)
            }
            if added.isEmpty { install() }
            else {
                BrowserPresentation.confirm(title: "更新需要新权限", message: added.map(ChromeAPIMatrix.describe).joined(separator: "\n")) { allowed in
                    if allowed { install() } else { self.discardExtension(prepared) }
                }
            }
        } catch { model?.message = error.localizedDescription }
    }
    static func extensionPackage(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count > 16 else {
            throw RikuganError.message("没有返回安装包（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        if let manifest = ExtensionUpdateManifest.package(in: data) {
            var follow = URLRequest(url: manifest.url)
            follow.setValue(request.value(forHTTPHeaderField: "User-Agent"), forHTTPHeaderField: "User-Agent")
            let (file, fileResponse) = try await URLSession.shared.data(for: follow)
            guard let fileHTTP = fileResponse as? HTTPURLResponse, (200..<300).contains(fileHTTP.statusCode), file.count > 16 else {
                throw RikuganError.message("更新清单指向的 CRX 下载失败。")
            }
            return file
        }
        return data
    }
    func checkExtensionUpdates() async {
        let records = profile.extensions.filter { !$0.updateURL.isEmpty || !$0.storeID.isEmpty }
        guard !records.isEmpty else { model?.message = "没有带更新地址的扩展。"; return }
        for record in records { await updateExtension(record) }
    }
    private func discardInstalledFiles(_ record: ExtensionRecord) {
        guard let model else { return }
        try? FileManager.default.removeItem(at: model.directory(profileID).appendingPathComponent(record.relativePath))
    }
    func openOptions(_ id: UUID) {
        guard #available(iOS 18.4, *) else { model?.message = Self.extensionOSMessage; return }
        guard let context = extensionContext(id: id), let url = context.optionsPageURL else { model?.message = "这个扩展没有选项页面。"; return }
        addTab(url: url, configuration: context.webViewConfiguration)
    }
    @available(iOS 18.4, *)
    private func saveOptionalPermissions(context: WKWebExtensionContext, permissions: [String] = [], patterns: [String] = []) {
        model?.updateProfile(profileID) { profile in
            guard let index = profile.extensions.firstIndex(where: { $0.id.uuidString == context.uniqueIdentifier }) else { return }
            profile.extensions[index].allowedPermissions = Array(Set(profile.extensions[index].allowedPermissions + permissions)).sorted()
            profile.extensions[index].allowedPatterns = Array(Set(profile.extensions[index].allowedPatterns + patterns)).sorted()
            profile.extensions[index].requestedPatterns = Array(Set(profile.extensions[index].requestedPatterns + patterns)).sorted()
        }
    }
}

@available(iOS 18.4, *)
extension BrowserSession: WKWebExtensionControllerDelegate, WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { activeTab?.isPrivate == true }
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

@available(iOS 18.4, *)
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

@available(iOS 18.4, *)
extension BrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { session }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { session?.tabs.firstIndex(where: { $0.id == id }) ?? 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webViewIfLive() }
    func title(for context: WKWebExtensionContext) -> String? { pageTitle }
    func url(for context: WKWebExtensionContext) -> URL? { webViewIfLive()?.url ?? URL(string: address) }
    func pendingURL(for context: WKWebExtensionContext) -> URL? { isLoading ? URL(string: address) : nil }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { session?.selectedID == id }
    func size(for context: WKWebExtensionContext) -> CGSize { webViewIfLive()?.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webViewIfLive()?.pageZoom ?? 1) }
    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        let factor = min(5, max(0.25, zoomFactor))
        prepareExtensionNavigation(.zoom)?.pageZoom = factor
        completionHandler(nil)
    }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { session?.select(self); completionHandler(nil) }
    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { if selected { session?.select(self) }; completionHandler(nil) }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { navigate(url); completionHandler(nil) }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        switch extensionEffect(.reload) {
        case .navigateSavedURL:
            _ = prepareExtensionNavigation(.reload)
        case .restoreInteractionThenPerform, .performOnLiveView:
            if let view = prepareExtensionNavigation(.reload) {
                if fromOrigin { view.reloadFromOrigin() } else { view.reload() }
            }
        case .skipSnapshot, .duplicateSavedURL:
            break
        }
        completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        prepareExtensionNavigation(.back)?.goBack()
        completionHandler(nil)
    }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        prepareExtensionNavigation(.forward)?.goForward()
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { session?.close(self); completionHandler(nil) }
    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext,
                   completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        let url = webViewIfLive()?.url ?? ExtensionTabPolicy.savedURL(address)
        completionHandler(session?.addTab(url: url, activate: configuration.shouldBeActive), nil)
    }
    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext,
                      completionHandler: @escaping (UIImage?, Error?) -> Void) {
        guard extensionEffect(.snapshot) == .performOnLiveView, let view = webViewIfLive() else {
            completionHandler(nil, nil)
            return
        }
        view.takeSnapshot(with: configuration, completionHandler: completionHandler)
    }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
}
