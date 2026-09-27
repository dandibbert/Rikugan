import Foundation
import WebKit
import UIKit

/// Builds tab web views and (re)installs the per-document content: page hooks, page tools,
/// userscripts and extension content scripts. Scripts are chosen natively for the URL that is
/// about to commit (so main-frame scripts run unwrapped with exact semantics) while sub-frame
/// variants carry a JS-side URL guard generated from the same native rules.
@MainActor enum WebViewFactory {
    static let safariUserAgentSuffix = "Version/17.0 Mobile/15E148 Safari/604.1"

    static func makeWebView(for tab: BrowserTab, configuration external: WKWebViewConfiguration?) -> WKWebView {
        let configuration: WKWebViewConfiguration
        if let external {
            configuration = external
            // WebKit requires the opener's configuration; give the new tab its own content controller
            // so per-document scripts of the two tabs do not interfere.
            configuration.userContentController = WKUserContentController()
        } else {
            configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = tab.isPrivate ? tab.profile.privateDataStore() : tab.profile.dataStore
            configuration.userContentController = WKUserContentController()
            tab.profile.extensions.installSchemeHandler(on: configuration)
            configuration.applicationNameForUserAgent = safariUserAgentSuffix
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = true
            configuration.allowsAirPlayForMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = .audio
            configuration.preferences.isFraudulentWebsiteWarningEnabled = true
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.preferences.isElementFullscreenEnabled = true
            configuration.defaultWebpagePreferences.preferredContentMode = tab.desktopMode ? .desktop : .mobile
            configuration.dataDetectorTypes = []
        }
        registerHandlers(configuration.userContentController, profile: tab.profile)
        applyContentRuleLists(configuration.userContentController, profile: tab.profile)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = tab
        webView.uiDelegate = tab
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isFindInteractionEnabled = true
        webView.isInspectable = AppServices.shared.prefs.webInspectorEnabled
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.scrollView.keyboardDismissMode = .interactive
        webView.backgroundColor = .systemBackground
        webView.isOpaque = false
        return webView
    }

    // MARK: Message handlers & rule lists

    private static var registeredWorlds: [ObjectIdentifier: Set<String>] = [:]

    /// Registers the single "rikugan" message handler (with reply) in a content world once per controller.
    static func ensureHandler(_ controller: WKUserContentController, world: WKContentWorld, profile: ProfileContext) {
        let key = ObjectIdentifier(controller)
        let name = world.name ?? "page"
        var set = registeredWorlds[key] ?? []
        guard !set.contains(name) else { return }
        controller.addScriptMessageHandler(profile.bridge, contentWorld: world, name: Worlds.messageHandlerName)
        set.insert(name)
        registeredWorlds[key] = set
    }

    static func forget(_ controller: WKUserContentController) { registeredWorlds.removeValue(forKey: ObjectIdentifier(controller)) }

    private static func registerHandlers(_ controller: WKUserContentController, profile: ProfileContext) {
        ensureHandler(controller, world: .page, profile: profile)
        ensureHandler(controller, world: Worlds.tools, profile: profile)
    }

    static func applyContentRuleLists(_ controller: WKUserContentController, profile: ProfileContext) {
        controller.removeAllContentRuleLists()
        for list in AppServices.shared.adBlock.activeLists { controller.add(list) }
        for list in profile.extensions.dnrLists { controller.add(list) }
    }

    /// Re-applies content rule lists on every live tab (after AdBlock / DNR recompiles).
    static func refreshAllContentRuleLists() {
        for tab in TabRegistry.shared.allTabs {
            guard let webView = tab.webView else { continue }
            applyContentRuleLists(webView.configuration.userContentController, profile: tab.profile)
        }
    }

    // MARK: Per-document content

    static func prepareContent(for tab: BrowserTab, url: URL) {
        guard let webView = tab.webView else { return }
        if tab.lastInjectedURL == url { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let profile = tab.profile
        let prefs = AppServices.shared.prefs
        let host = url.host?.lowercased() ?? ""
        let site = profile.siteSettings.settings(for: host)
        let isWeb = ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")

        // 1. Page-world hooks.
        let hooks: [String: Any] = [
            "handler": Worlds.messageHandlerName,
            "sniff": prefs.mediaSnifferEnabled,
            "console": prefs.consoleCaptureEnabled,
            "geolocation": prefs.geolocationShim,
            "notifications": true,
            "notificationPermission": notificationPermission(site),
            "clipboardGate": site.permissions["clipboard"] == .block,
        ]
        controller.addUserScript(WKUserScript(source: JSResource.fill("PageHooks", marker: "__RK_HOOKS_CONFIG__", config: hooks),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))

        // 2. Page tools (dark mode, fonts, cosmetic filters, picker, reader, translate, media).
        var tools: [String: Any] = ["handler": Worlds.messageHandlerName, "dark": darkModeConfig(host: host, profile: profile) as Any]
        if let font = fontConfig(host: host, profile: profile) { tools["font"] = font }
        if isWeb, AppServices.shared.prefs.adBlockEnabled, site.contentBlocking != false, !AppServices.shared.adBlock.isAllowlisted(host) {
            let cosmetic = AppServices.shared.adBlock.cosmeticRules(forHost: host)
            tools["cosmetic"] = ["selectors": cosmetic.selectors, "css": cosmetic.css]
        }
        controller.addUserScript(WKUserScript(source: JSResource.fill("PageTools", marker: "__RK_TOOLS_CONFIG__", config: tools),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Worlds.tools))

        // 3. Userscripts.
        if isWeb, site.userScriptsEnabled != false {
            for script in profile.userscripts.scripts where script.enabled {
                let world = script.metadata.runsInPageWorld ? WKContentWorld.page : Worlds.userscript(script.id)
                ensureHandler(controller, world: world, profile: profile)
                for built in profile.userscripts.userScripts(for: script, mainFrameURL: url, isPrivate: tab.isPrivate) {
                    controller.addUserScript(WKUserScript(source: built.source, injectionTime: built.time, forMainFrameOnly: built.mainFrameOnly, in: world))
                }
            }
        }

        // 4. Extension content scripts.
        if isWeb || url.scheme == "about", site.extensionsEnabled != false {
            for item in profile.extensions.contentScripts(for: url, tab: tab) {
                ensureHandler(controller, world: item.world, profile: profile)
                controller.addUserScript(WKUserScript(source: item.source, injectionTime: item.time, forMainFrameOnly: item.mainFrameOnly, in: item.world))
            }
        }
        tab.markInjected(for: url)
    }

    static func notificationPermission(_ site: SiteSettings) -> String {
        switch site.permissions["notifications"] {
        case .allow?: return "granted"
        case .block?: return "denied"
        default: return "default"
        }
    }

    static func darkModeConfig(host: String, profile: ProfileContext) -> [String: Any] {
        let prefs = AppServices.shared.prefs
        let mode = profile.siteSettings.settings(for: host).darkMode ?? prefs.pageDarkMode
        let enabled: Bool
        switch mode {
        case .on: enabled = true
        case .off: enabled = false
        case .auto: enabled = UITraitCollection.current.userInterfaceStyle == .dark ||
            (Presenter.keyWindow?.traitCollection.userInterfaceStyle == .dark)
        }
        return ["enabled": enabled, "brightness": prefs.darkModeBrightness, "contrast": prefs.darkModeContrast]
    }

    static func fontConfig(host: String, profile: ProfileContext) -> [String: Any]? {
        let prefs = AppServices.shared.prefs
        guard prefs.webFontEnabled, !prefs.webFontFamily.isEmpty else { return nil }
        if profile.siteSettings.settings(for: host).webFont == false { return nil }
        if prefs.webFontExcludedHosts.contains(where: { DomainTools.host(host, isWithin: $0) }) { return nil }
        var config: [String: Any] = ["family": prefs.webFontFamily, "keepMonospace": prefs.webFontKeepMonospace]
        if let file = AppServices.shared.fonts.importedFont(family: prefs.webFontFamily) { config["fileID"] = file.id }
        return config
    }

    /// Rebuilds content for all tabs (e.g. after installing a userscript / extension). Takes effect on next load.
    static func invalidateAllTabs() {
        for tab in TabRegistry.shared.allTabs {
            tab.markInjected(for: URL(string: "about:invalid")!)
            if let url = tab.webView?.url { prepareContent(for: tab, url: url) }
        }
    }
}
