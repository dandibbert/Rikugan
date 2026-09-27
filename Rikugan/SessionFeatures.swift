import UIKit
import WebKit

extension BrowserSession {
    func noteURLChange(_ tab: BrowserTab) {
        let js = "globalThis.__rikuganOnURLChange && globalThis.__rikuganOnURLChange()"
        var worlds: [WKContentWorld] = [.page]
        for script in profile.scripts where script.enabled && script.isolated {
            worlds.append(.world(name: "rikugan.script." + script.id.uuidString))
        }
        for world in worlds {
            tab.webView.evaluateJavaScript(js, in: nil, in: world) { _, _ in }
        }
    }
    func closeOthers(keeping tab: BrowserTab) {
        for other in tabs.filter({ $0.id != tab.id }) { close(other) }
    }
    func closeAllTabs() {
        for tab in Array(tabs) { close(tab) }
    }
    func reopenClosed() {
        guard let closed = profile.closedTabs.first, let url = URL(string: closed.url) else { return }
        model?.updateProfile(profileID) { if !$0.closedTabs.isEmpty { $0.closedTabs.removeFirst() } }
        let tab = addTab(url: url, groupID: closed.groupID)
        tab.groupID = closed.groupID
    }
    func addGroup(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model?.updateProfile(profileID) { $0.tabGroups.append(TabGroup(name: String(trimmed.prefix(40)))) }
    }
    func renameGroup(_ id: UUID, to name: String) {
        model?.updateProfile(profileID) { profile in
            guard let index = profile.tabGroups.firstIndex(where: { $0.id == id }) else { return }
            profile.tabGroups[index].name = String(name.prefix(40))
        }
    }
    func deleteGroup(_ id: UUID) {
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        model?.updateProfile(profileID) { $0.tabGroups.removeAll { $0.id == id } }
        persistTabs()
    }
    func move(_ tab: BrowserTab, to groupID: UUID?) { tab.groupID = groupID; persistTabs() }
    func loadThumbnails() {
        guard let model else { return }
        let folder = model.directory(profileID).appendingPathComponent("Thumbnails", isDirectory: true)
        for tab in tabs where !tab.isPrivate {
            let file = folder.appendingPathComponent(tab.id.uuidString + ".jpg")
            if let image = UIImage(contentsOfFile: file.path) { thumbnails[tab.id] = image }
        }
    }
    func removeThumbnail(_ id: UUID) {
        thumbnails[id] = nil
        guard let model else { return }
        let file = model.directory(profileID).appendingPathComponent("Thumbnails", isDirectory: true).appendingPathComponent(id.uuidString + ".jpg")
        try? FileManager.default.removeItem(at: file)
    }
}

extension BrowserTab: WKScriptMessageHandler {
    func ensurePageHandler() {
        guard !pageHandlerInstalled else { return }
        webView.configuration.userContentController.add(self, contentWorld: .page, name: "rikuganPage")
        pageHandlerInstalled = true
    }
    func removeContentRules() {
        let controller = webView.configuration.userContentController
        for list in installedRuleLists { controller.remove(list) }
        installedRuleLists = []
        contentRulesOn = false
    }
    func syncContentRules() {
        removeContentRules()
        let host = webView.url?.host ?? URL(string: address)?.host
        let allowed = (session?.profile.settings.contentBlocking ?? true) && (session?.profile.site(for: host)?.contentBlocking ?? true)
        guard allowed, let lists = session?.contentRuleLists, !lists.isEmpty else { return }
        let controller = webView.configuration.userContentController
        for list in lists { controller.add(list); installedRuleLists.append(list) }
        contentRulesOn = true
    }
    func setAutoRefresh(_ seconds: Int) {
        autoRefreshSeconds = max(0, seconds)
        refreshTask?.cancel()
        refreshTask = nil
        guard autoRefreshSeconds > 0 else { session?.persistTabs(); return }
        let interval = autoRefreshSeconds
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.session?.isActive == true, self.session?.activeTab?.id == self.id, !self.isHome,
                      UIApplication.shared.applicationState == .active else { continue }
                self.webView.reload()
            }
        }
        session?.persistTabs()
    }
    func applyDecorations() {
        webView.isInspectable = session?.profile.settings.inspectable ?? true
        let host = webView.url?.host
        let site = session?.profile.site(for: host)
        let mode = site?.darkMode ?? session?.profile.settings.darkMode ?? "off"
        let siteFont = site?.fontFamily
        let family = siteFont ?? session?.profile.settings.webFontFamily ?? ""
        var face = ""
        if let font = session?.profile.settings.importedFonts.first(where: { $0.family == family }), let session, let model = session.model {
            let file = model.directory(session.profileID).appendingPathComponent("Fonts").appendingPathComponent(font.fileName)
            face = FontLibrary.faceCSS(file: file, family: family)
        }
        let clipboard = session?.profile.permission(host: host ?? "", kind: "clipboard") ?? "ask"
        let notifications = session?.profile.permission(host: host ?? "", kind: "notification") ?? "ask"
        let modeJS = PageTools.jsString(mode) ?? "\"off\""
        let familyJS = PageTools.jsString(family) ?? "\"\""
        let faceJS = PageTools.jsString(face) ?? "\"\""
        let notifyJS = PageTools.jsString(notifications) ?? "\"ask\""
        let blockClipboard = clipboard == "block" ? "try{if(navigator.clipboard){navigator.clipboard.readText=()=>Promise.reject(new Error('Blocked by Rikugan'));}}catch(e){}" : ""
        let hostJSON = (session?.hostCSS).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let procedural = session?.proceduralJSON ?? "[]"
        let css = PageTools.jsString(session?.globalCosmetic ?? "") ?? "\"\""
        Task { [weak self] in
            guard let self else { return }
            _ = await PageTools.call("RikuganPageTools.setAppearance(\(modeJS)),RikuganPageTools.setFont(\(familyJS),\(faceJS)),RikuganPageTools.applyBlocking(\(css), \(hostJSON), \(procedural)),RikuganPageTools.installNotifications(\(notifyJS)),RikuganPageTools.installConsole(),\(blockClipboard)true", in: self.webView)
        }
    }
    func captureThumbnail() {
        guard !isHome, !isPrivate else { return }
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, let image else { return }
            Task { @MainActor in
                self.session?.thumbnails[self.id] = image
                guard let session = self.session, let model = session.model, let data = image.jpegData(compressionQuality: 0.55) else { return }
                let folder = model.directory(session.profileID).appendingPathComponent("Thumbnails", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: folder.appendingPathComponent(self.id.uuidString + ".jpg"), options: .atomic)
            }
        }
    }
    func captureIcon() {
        Task { [weak self] in
            guard let self else { return }
            guard let href = await PageTools.call("(function(){var n=document.querySelector('link[rel*=\"icon\"]');return n&&n.href||'';})()", in: webView) as? String,
                  let url = URL(string: href), ["http", "https"].contains(url.scheme ?? "") else { return }
            var request = URLRequest(url: url); request.timeoutInterval = 8
            guard let (data, _) = try? await URLSession.shared.data(for: request), data.count < 400_000, let image = UIImage(data: data) else { return }
            session?.favicons[id] = image
        }
    }
    func findInPage(_ query: String, direction: Int) async -> (Int, Int) {
        let trimmed = query
        guard !trimmed.isEmpty else { clearFind(); return (0, 0) }
        let literal = PageTools.jsString(trimmed) ?? "\"\""
        let total = Self.number(await PageTools.call("RikuganPageTools.countMatches(\(literal))", in: webView))
        let configuration = WKFindConfiguration()
        configuration.backwards = direction < 0
        configuration.wraps = true
        let matched: Bool = await withCheckedContinuation { continuation in
            webView.find(trimmed, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
        guard matched, total > 0 else { findCursor = 0; findNeedle = trimmed; return (0, total) }
        if findNeedle != trimmed || findCursor == 0 {
            findNeedle = trimmed
            findCursor = direction < 0 ? total : 1
        } else if direction < 0 {
            findCursor = findCursor <= 1 ? total : findCursor - 1
        } else {
            findCursor = findCursor >= total ? 1 : findCursor + 1
        }
        return (findCursor, total)
    }
    func clearFind() {
        findCursor = 0
        findNeedle = ""
        let configuration = WKFindConfiguration()
        webView.find("", configuration: configuration) { _ in }
        Task { _ = await PageTools.call("RikuganPageTools.clearFind()", in: webView) }
    }
    func beginElementPicker() { Task { _ = await PageTools.call("RikuganPageTools.startPicker()", in: webView) } }
    func video(_ action: String) {
        Task { [weak self] in
            guard let self else { return }
            let literal = PageTools.jsString(action) ?? "\"\""
            let result = await PageTools.call("RikuganPageTools.videoAction(\(literal))", in: webView) as? String
            if result == "no-video" { session?.model?.message = "当前页面没有 HTML5 视频。" }
            else if result == "unsupported" { session?.model?.message = "这个视频不支持该操作。FairPlay / Widevine / DRM 不在功能范围内。" }
        }
    }
    func makePDF() async -> URL? {
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                webView.createPDF(configuration: WKPDFConfiguration()) { continuation.resume(with: $0) }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rikugan.pdf")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            session?.model?.message = error.localizedDescription
            return nil
        }
    }
    func printPage() {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = pageTitle
        controller.printInfo = info
        controller.printFormatter = webView.viewPrintFormatter()
        guard let view = BrowserPresentation.presenter?.view else { return }
        controller.present(from: view.bounds, in: view, animated: true, completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "rikuganPage", let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if action == "console" {
            let line = (body["level"] as? String ?? "log") + ": " + (body["text"] as? String ?? "")
            consoleLines.append(String(line.prefix(2000)))
            if consoleLines.count > 200 { consoleLines.removeFirst(consoleLines.count - 200) }
            return
        }
        if action == "texts", let items = body["items"] as? [[String: Any]] {
            let rows: [[String: String]] = items.compactMap { item in
                guard let id = item["id"] as? String, let text = item["text"] as? String else { return nil }
                return ["id": id, "text": text]
            }
            if !rows.isEmpty { liveTexts = rows }
            return
        }
        if action == "show-notification" {
            let title = body["title"] as? String ?? "通知"
            let text = body["body"] as? String ?? ""
            let host = webView.url?.host ?? ""
            let saved = session?.profile.permission(host: host, kind: "notification") ?? "ask"
            if saved == "block" { return }
            session?.model?.deliverNotice(host: host, title: title, body: text)
            return
        }
        if action == "notification", let id = body["id"] as? String {
            let host = webView.url?.host ?? ""
            let saved = session?.profile.permission(host: host, kind: "notification") ?? "ask"
            if saved != "ask" {
                resolveNotification(id, decision: saved == "allow" ? "granted" : "denied")
                return
            }
            BrowserPresentation.choice(title: host.isEmpty ? "通知" : host, message: "这个网页想显示通知。允许后会出现在 App 内通知列表，iOS 不会弹出系统横幅。") { [weak self] choice in
                guard let self else { return }
                if choice != "ask" {
                    self.session?.model?.updateProfile(self.session?.profileID ?? UUID()) { profile in
                        profile.webPermissions.removeAll { $0.host == host && $0.kind == "notification" }
                        profile.webPermissions.append(WebPermission(host: host, kind: "notification", decision: choice))
                    }
                }
                self.resolveNotification(id, decision: choice == "allow" ? "granted" : "denied")
            }
            return
        }
        guard action == "picker", let selector = body["selector"] as? String, !selector.isEmpty, let host = webView.url?.host else { return }
        let rule = "\(host)##\(selector)"
        BrowserPresentation.confirm(title: "隐藏这个元素？", message: rule) { [weak self] allowed in
            guard allowed, let self, let session = self.session else { return }
            session.model?.updateProfile(session.profileID) { profile in
                profile.settings.customRules.append(CustomBlockRule(text: rule))
            }
            Task { @MainActor in
                await BlockListCoordinator.rebuild(session, announce: true)
                if let css = PageTools.jsString(selector + "{display:none!important}") {
                    _ = await PageTools.call("RikuganPageTools.ensureStyle('rikugan-live-hide', \(css))", in: self.webView)
                }
            }
        }
    }
    private func resolveNotification(_ id: String, decision: String) {
        let idJS = PageTools.jsString(id) ?? "\"\""
        let decisionJS = PageTools.jsString(decision) ?? "\"denied\""
        Task { _ = await PageTools.call("(function(){var fn=window.__rgNotify&&window.__rgNotify[\(idJS)];if(fn)fn(\(decisionJS));})()", in: webView) }
    }
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL, ["http", "https"].contains(url.scheme ?? "") else { completionHandler(nil); return }
        let menu = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "打开") { _ in self?.navigate(url) },
                UIAction(title: "新标签页打开") { _ in self?.session?.addTab(url: url, activate: true) },
                UIAction(title: "后台打开") { _ in self?.session?.addTab(url: url, activate: false) },
                UIAction(title: "复制链接") { _ in UIPasteboard.general.url = url }
            ])
        }
        completionHandler(menu)
    }
    private static func number(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        return 0
    }
}
