import UIKit
import WebKit

extension BrowserSession {
    func noteURLChange(_ tab: BrowserTab) {
        guard let webView = tab.existingWebView else { return }
        let js = "globalThis.__rikuganOnURLChange && globalThis.__rikuganOnURLChange()"
        var worlds: [WKContentWorld] = [.page]
        for script in profile.scripts where script.enabled && script.isolated {
            worlds.append(.world(name: "rikugan.script." + script.id.uuidString))
        }
        for world in worlds {
            webView.evaluateJavaScript(js, in: nil, in: world) { _ in }
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
}

extension BrowserTab: WKScriptMessageHandler {
    func ensurePageHandler() {
        guard !pageHandlerInstalled, let webView = existingWebView else { return }
        webView.configuration.userContentController.add(self, contentWorld: .page, name: "rikuganPage")
        pageHandlerInstalled = true
    }
    func syncContentRules(forHost upcomingHost: String? = nil) {
        guard let webView = existingWebView else { return }
        guard let list = session?.contentRuleList else { contentRulesOn = false; return }
        let host = upcomingHost ?? webView.url?.host ?? URL(string: address)?.host
        let allowed = (session?.profile.settings.contentBlocking ?? true) && (session?.profile.site(for: host)?.contentBlocking ?? true)
        let controller = webView.configuration.userContentController
        if allowed && !contentRulesOn { controller.add(list); contentRulesOn = true }
        else if !allowed && contentRulesOn { controller.remove(list); contentRulesOn = false }
    }
    func setAutoRefresh(_ seconds: Int) {
        autoRefreshSeconds = min(86400, max(0, seconds))
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
        guard let webView = existingWebView else { return }
        webView.isInspectable = session?.profile.settings.inspectable ?? true
        let host = webView.url?.host
        let site = session?.profile.site(for: host)
        let mode = site?.darkMode ?? session?.profile.settings.darkMode ?? "off"
        let family = site?.webFontFamily ?? session?.profile.settings.webFontFamily ?? ""
        var face = ""
        if let font = session?.profile.settings.importedFonts.first(where: { $0.family == family }), let session, let model = session.model {
            let file = model.directory(session.profileID).appendingPathComponent("Fonts").appendingPathComponent(font.fileName)
            face = FontLibrary.faceCSS(file: file, family: family)
        }
        let clipboard = session?.profile.permission(host: host ?? "", kind: "clipboard") ?? "ask"
        let modeJS = PageTools.jsString(mode) ?? "\"off\""
        let familyJS = PageTools.jsString(family) ?? "\"\""
        let faceJS = PageTools.jsString(face) ?? "\"\""
        let blockClipboard = clipboard == "block" ? "try{if(navigator.clipboard){navigator.clipboard.readText=()=>Promise.reject(new Error('Blocked by Rikugan'));}}catch(e){}" : ""
        Task { [weak self] in
            guard let self else { return }
            guard self.existingWebView === webView else { return }
            _ = await PageTools.call("RikuganPageTools.setAppearance(\(modeJS)),RikuganPageTools.setFont(\(familyJS),\(faceJS)),\(blockClipboard)true", in: webView)
        }
    }
    func captureThumbnail() {
        guard !isHome, !isPrivate, let webView = existingWebView else { return }
        let configuration = WKSnapshotConfiguration(); configuration.snapshotWidth = 240
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, let image else { return }
            Task { @MainActor in
                guard self.session?.tabs.contains(where: { $0.id == self.id }) == true, self.existingWebView != nil else { return }
                self.session?.thumbnails[self.id] = image
            }
        }
    }
    func captureIcon() {
        guard !isPrivate, let webView = existingWebView else { return }
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
        let literal = PageTools.jsString(query) ?? "\"\""
        let value = await PageTools.call("RikuganPageTools.find(\(literal), \(direction))", in: webView) as? [String: Any]
        return (Self.number(value?["index"]), Self.number(value?["total"]))
    }
    func clearFind() { Task { _ = await PageTools.call("RikuganPageTools.clearFind()", in: webView) } }
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
        guard let view = BrowserPresentation.presenter(for: webView)?.view else { return }
        controller.present(from: view.bounds, in: view, animated: true, completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "rikuganPage", let body = message.body as? [String: Any], body["action"] as? String == "picker",
              let selector = body["selector"] as? String, !selector.isEmpty, let host = webView.url?.host else { return }
        let rule = "\(host)##\(selector)"
        BrowserPresentation.confirm(title: "隐藏这个元素？", message: rule, from: webView) { [weak self] allowed in
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
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL, ["http", "https"].contains(url.scheme ?? "") else { completionHandler(nil); return }
        let menu = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "打开") { _ in self?.navigate(url) },
                UIAction(title: "新标签页打开") { _ in guard let self else { return }; self.session?.addTab(url: url, activate: true, isPrivate: self.isPrivate, groupID: self.groupID) },
                UIAction(title: "后台打开") { _ in guard let self else { return }; self.session?.addTab(url: url, activate: false, isPrivate: self.isPrivate, groupID: self.groupID) },
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
