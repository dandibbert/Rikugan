import Foundation
import WebKit
import UIKit

/// Navigation policy, redirect control (spec §31), downloads, userscript install detection,
/// permissions and dialogs for a tab.
extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]

    // MARK: Policy

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let target = navigationAction.request.url else { decisionHandler(.cancel, preferences); return }
        let scheme = target.scheme?.lowercased() ?? ""
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let site = profile.siteSettings.settings(for: target.host)

        if navigationAction.shouldPerformDownload { decisionHandler(.download, preferences); return }

        // Internal pages: rikugan://extensions, chrome://extensions, ...
        if ["rikugan", "chrome", "edge"].contains(scheme) {
            decisionHandler(.cancel, preferences)
            InternalPages.open(target.host ?? "", from: self)
            return
        }

        if scheme == profile.extensions.scheme {
            let allowed = !isPrivate && profile.extensions.canNavigate(to: target, from: webView.url)
            // An extension page (options, dashboard) in a normal tab gets its chrome.* runtime like
            // the popup does; the previous page's scripts are replaced.
            if allowed, isMainFrame { WebViewFactory.prepareContent(for: self, url: target) }
            decisionHandler(allowed ? .allow : .cancel, preferences)
            return
        }

        if !Self.webSchemes.contains(scheme) {
            decisionHandler(.cancel, preferences)
            handleExternalScheme(target, site: site, userInitiated: navigationAction.navigationType == .linkActivated)
            return
        }

        if isMainFrame, ["http", "https"].contains(scheme), target.path.lowercased().hasSuffix(".user.js"),
           navigationAction.navigationType != .formSubmitted, navigationAction.request.httpMethod ?? "GET" == "GET" {
            decisionHandler(.cancel, preferences)
            UserscriptInstallCoordinator.shared.beginInstall(from: target, tab: self)
            return
        }

        if isMainFrame, ["http", "https"].contains(scheme), target.host?.lowercased() == "apps.apple.com",
           services.prefs.preventAppStoreRedirect, navigationAction.navigationType != .linkActivated, webView.url != nil {
            decisionHandler(.cancel, preferences)
            ToastCenter.shared.show("已阻止跳转到 App Store", symbol: "hand.raised", actionTitle: "打开") { UIApplication.shared.open(target) }
            return
        }

        let desktop = site.desktopMode ?? desktopMode
        preferences.preferredContentMode = desktop ? .desktop : .mobile
        preferences.allowsContentJavaScript = site.javaScript ?? true
        if isMainFrame {
            loadError = nil
            WebViewFactory.prepareContent(for: self, url: target)
            profile.extensions.webNavigation(.beforeNavigate, tab: self, url: target, frameID: 0)
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let mime = response.mimeType?.lowercased() ?? ""
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if let url = response.url, mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.contains("mpegurl") {
            addSniffedMedia(MediaItem(url: url, kind: mime.hasPrefix("audio/") ? "audio" : (mime.contains("mpegurl") ? "hls" : "video"),
                                      source: "response", size: response.expectedContentLength, contentType: mime))
        }
        if disposition.hasPrefix("attachment") || !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        if navigationResponse.isForMainFrame, let url = response.url {
            if url.path.lowercased().hasSuffix(".user.js") || mime == "text/x-userscript" {
                decisionHandler(.cancel)
                UserscriptInstallCoordinator.shared.beginInstall(from: url, tab: self)
                return
            }
            WebViewFactory.prepareContent(for: self, url: url)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        services.downloads.attach(download, sourceTab: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        services.downloads.attach(download, sourceTab: self, suggestedResponse: navigationResponse.response)
    }

    // MARK: Lifecycle

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        profile.extensions.tabUpdated(self, changes: ["status": "loading"])
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        documentDidCommit()
        if let url = webView.url {
            profile.extensions.webNavigation(.committed, tab: self, url: url, frameID: 0)
            profile.extensions.tabUpdated(self, changes: ["status": "loading", "url": url.absoluteString])
        }
        if let host = webView.url?.host {
            let site = profile.siteSettings.settings(for: host)
            desktopMode = site.desktopMode ?? services.prefs.defaultDesktopMode
            if let seconds = site.autoRefreshSeconds, autoRefreshInterval == nil { autoRefreshInterval = TimeInterval(seconds) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        restoreFinished()
        guard let url = webView.url else { return }
        if !isPrivate, ["http", "https"].contains(url.scheme ?? "") { profile.history.record(url: url, title: webView.title ?? "") }
        refreshFavicon()
        profile.extensions.webNavigation(.completed, tab: self, url: url, frameID: 0)
        profile.extensions.tabUpdated(self, changes: ["status": "complete", "title": title])
        manager?.scheduleSave()
        if manager?.activeTab === self { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.captureThumbnail() } }
        TranslationCoordinator.autoTranslateIfNeeded(self)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error)
    }

    private func handleLoadError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) { return } // interrupted by policy / plugin
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 101 { return }
        loadError = nsError.localizedDescription
        profile.extensions.webNavigation(.errorOccurred, tab: self, url: webView?.url ?? url ?? URL(string: "about:blank")!, frameID: 0)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ErrorLog.shared.record("WebContent process terminated", source: "tab \(numericID)")
        contentProcessTerminated()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let alert = UIAlertController(title: "登录 \(challenge.protectionSpace.host)", message: challenge.protectionSpace.realm, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "用户名"; $0.textContentType = .username }
        alert.addTextField { $0.placeholder = "密码"; $0.isSecureTextEntry = true; $0.textContentType = .password }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(.cancelAuthenticationChallenge, nil) })
        alert.addAction(UIAlertAction(title: "登录", style: .default) { _ in
            let user = alert.textFields?[0].text ?? "", pass = alert.textFields?[1].text ?? ""
            completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .forSession))
        })
        Presenter.present(alert, from: webView)
    }

    // MARK: External apps (spec §31)

    func handleExternalScheme(_ target: URL, site: SiteSettings, userInitiated: Bool) {
        let scheme = target.scheme?.lowercased() ?? ""
        let prefs = services.prefs
        if scheme == "intent" {
            // Android intent: use the browser fallback URL when present.
            let text = target.absoluteString
            if let range = text.range(of: "S.browser_fallback_url="),
               let fallback = text[range.upperBound...].split(separator: ";").first?.removingPercentEncoding,
               let url = URL(string: fallback) {
                load(url)
            } else {
                ToastCenter.shared.show("已忽略 Android intent 链接", symbol: "hand.raised")
            }
            return
        }
        if ["itms-apps", "itms-appss", "itms", "itmss"].contains(scheme) {
            if prefs.preventAppStoreRedirect && !userInitiated {
                ToastCenter.shared.show("已阻止跳转到 App Store", symbol: "hand.raised", actionTitle: "打开") { UIApplication.shared.open(target) }
                return
            }
        }
        if ["tel", "mailto", "sms", "facetime", "facetime-audio", "maps"].contains(scheme) {
            UIApplication.shared.open(target); return
        }
        let decision = site.externalNavigation ?? (prefs.preventExternalAppRedirect ? .block : .ask)
        switch decision {
        case .allow:
            UIApplication.shared.open(target)
        case .block:
            ToastCenter.shared.show("已阻止打开外部 App（\(scheme)）", symbol: "hand.raised", actionTitle: "打开") { UIApplication.shared.open(target) }
        case .ask:
            let pageHost = webView?.url?.host ?? "此网页"
            Task {
                let appName = ExternalAppNames.name(for: scheme)
                if await Presenter.confirm(title: "\(pageHost) 想要打开 \(appName)", message: target.absoluteString.prefix(120).description,
                                           confirm: "打开", from: webView) {
                    UIApplication.shared.open(target) { success in
                        if !success { Task { @MainActor in ToastCenter.shared.show("没有能打开该链接的 App", symbol: "exclamationmark.triangle") } }
                    }
                }
            }
        }
    }

    // MARK: UI delegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let site = profile.siteSettings.settings(for: webView.url?.host)
        if site.popups == .block {
            ToastCenter.shared.show("已阻止弹出窗口", symbol: "hand.raised")
            return nil
        }
        guard let manager else { return nil }
        let background = services.prefs.openLinksInBackground && navigationAction.navigationType == .linkActivated
        let tab = manager.newTab(url: nil, background: background, isPrivate: isPrivate, opener: self, configuration: configuration)
        if let url = navigationAction.request.url, url.absoluteString != "about:blank", let newWebView = tab.webView {
            WebViewFactory.prepareContent(for: tab, url: url)
            tab.title = url.host ?? "新标签页"
            _ = newWebView
        }
        profile.extensions.webNavigation(.createdNavigationTarget, tab: tab, url: navigationAction.request.url ?? URL(string: "about:blank")!,
                                         frameID: 0, sourceTab: self)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        manager?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        guard Presenter.topController(from: webView) != nil else { completionHandler(); return }
        Presenter.present(alert, from: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: frame.securityOrigin.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
        guard Presenter.topController(from: webView) != nil else { completionHandler(false); return }
        Presenter.present(alert, from: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: frame.securityOrigin.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        guard Presenter.topController(from: webView) != nil else { completionHandler(nil); return }
        Presenter.present(alert, from: webView)
    }

    /// Camera / microphone (spec §48): per-site Ask / Allow / Block.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let host = origin.host
        let keys: [String]
        switch type {
        case .camera: keys = ["camera"]
        case .microphone: keys = ["microphone"]
        default: keys = ["camera", "microphone"]
        }
        let site = profile.siteSettings.settings(for: host)
        let decisions = keys.map { site.permissions[$0] ?? .ask }
        if decisions.contains(.block) { decisionHandler(.deny); return }
        if decisions.allSatisfy({ $0 == .allow }) { decisionHandler(.grant); return }
        let what = keys.map { $0 == "camera" ? "摄像头" : "麦克风" }.joined(separator: "和")
        Task {
            let answer = await Presenter.permission(title: "“\(host)” 想要使用你的\(what)", message: nil, from: webView)
            switch answer {
            case .allow?:
                for key in keys { profile.siteSettings.update(host) { $0.permissions[key] = .allow } }
                decisionHandler(.grant)
            case .ask?: decisionHandler(.grant)
            case .block?:
                for key in keys { profile.siteSettings.update(host) { $0.permissions[key] = .block } }
                decisionHandler(.deny)
            case nil: decisionHandler(.deny)
            }
        }
    }

    /// Long-press link menu with extension context menu items.
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let link = elementInfo.linkURL else { completionHandler(nil); return }
        let manager = self.manager
        let isPrivate = self.isPrivate
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            var actions: [UIMenuElement] = [
                UIAction(title: "在新标签页中打开", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    manager?.newTab(url: link, background: false, isPrivate: isPrivate, opener: self)
                },
                UIAction(title: "在后台打开", image: UIImage(systemName: "square.on.square.dashed")) { _ in
                    manager?.newTab(url: link, background: true, isPrivate: isPrivate, opener: self)
                    ToastCenter.shared.show("已在后台打开", symbol: "square.on.square")
                },
                UIAction(title: "在无痕标签页中打开", image: UIImage(systemName: "hand.raised")) { _ in
                    manager?.newTab(url: link, background: false, isPrivate: true, opener: nil)
                },
                UIAction(title: "拷贝链接", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.url = link },
                UIAction(title: "下载链接文件", image: UIImage(systemName: "arrow.down.circle")) { _ in
                    AppServices.shared.downloads.downloadInteractively(url: link, suggestedName: nil, from: self)
                },
                UIAction(title: "添加到书签", image: UIImage(systemName: "book")) { _ in
                    self?.profile.bookmarks.add(title: link.host ?? link.absoluteString, url: link.absoluteString, parent: nil)
                    ToastCenter.shared.show("已添加书签", symbol: "book")
                },
                UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { _ in Presenter.share([link], from: webView) },
            ]
            if let self {
                let extensionItems = self.profile.extensions.contextMenuItems(for: ["link", "all"], tab: self, linkURL: link)
                if !extensionItems.isEmpty { actions.append(UIMenu(title: "扩展", options: .displayInline, children: extensionItems)) }
            }
            if link.path.lowercased().hasSuffix(".user.js") {
                actions.insert(UIAction(title: "安装用户脚本", image: UIImage(systemName: "curlybraces")) { _ in
                    if let self { UserscriptInstallCoordinator.shared.beginInstall(from: link, tab: self) }
                }, at: 0)
            }
            return UIMenu(title: link.absoluteString, children: actions + suggested.filter { _ in false })
        }
        completionHandler(configuration)
    }

    func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating) {
        guard let link = elementInfo.linkURL else { return }
        animator.addCompletion { [weak self] in self?.load(link) }
    }
}

enum ExternalAppNames {
    static let known: [String: String] = [
        "youtube": "YouTube", "vnd.youtube": "YouTube", "twitter": "X", "x": "X", "fb": "Facebook", "instagram": "Instagram",
        "weixin": "微信", "wechat": "微信", "alipay": "支付宝", "alipays": "支付宝", "taobao": "淘宝", "tbopen": "淘宝",
        "openapp.jdmobile": "京东", "zhihu": "知乎", "bilibili": "哔哩哔哩", "snssdk1128": "抖音", "sinaweibo": "微博",
        "spotify": "Spotify", "tg": "Telegram", "whatsapp": "WhatsApp", "itms-apps": "App Store", "itms-appss": "App Store",
        "googlechrome": "Chrome", "firefox": "Firefox", "slack": "Slack", "zoomus": "Zoom", "discord": "Discord",
    ]
    static func name(for scheme: String) -> String { known[scheme] ?? "外部 App（\(scheme)）" }
}
