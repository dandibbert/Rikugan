import WebKit

enum PageTools {
    static let source: String = {
        guard let url = Bundle.main.url(forResource: "PageTools", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return "globalThis.RikuganPageTools = globalThis.RikuganPageTools || {};"
        }
        let fontSource = Bundle.main.url(forResource: "WebFontEngine", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return fontSource + "\n" + text
    }()

    static func install(on controller: WKUserContentController, cosmeticCSS: String) {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        guard !cosmeticCSS.isEmpty, let literal = jsString(cosmeticCSS) else { return }
        let css = "(function(){try{var s=document.createElement('style');s.id='rikugan-cosmetic';s.textContent=\(literal);(document.documentElement||document.head).appendChild(s);}catch(e){}})();"
        controller.addUserScript(WKUserScript(source: css, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    static func call(_ expression: String, in webView: WKWebView) async -> Any? {
        let script = "(function(){try{if(!globalThis.RikuganPageTools){\(source)} return \(expression);}catch(e){return {error:String(e)};}})()"
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value) }
        }
    }

    static func jsString(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]), var text = String(data: data, encoding: .utf8) else { return nil }
        text.removeFirst(); text.removeLast()
        return text
    }
}

enum BlockListCoordinator {
    @MainActor static func rebuild(_ session: BrowserSession, announce: Bool = false) async {
        let settings = session.profile.settings
        let compiled = AdBlockEngine.compile(lines: AdBlockEngine.lines(settings: settings))
        session.globalCosmetic = compiled.globalCSS
        let store = WKContentRuleListStore.default()
        let identifier = "rikugan.rules"
        if let existing = session.contentRuleList {
            for tab in session.tabs {
                tab.webView.configuration.userContentController.remove(existing)
                tab.contentRulesOn = false
            }
            session.contentRuleList = nil
        }
        for tab in session.tabs { tab.contentRulesOn = false }
        guard let store, compiled.json != "[]" else { session.refreshScripts(); return }
        do {
            let list = try await compile(store, identifier: identifier, json: compiled.json)
            session.contentRuleList = list
        } catch {
            if let list = try? await compile(store, identifier: identifier, json: compiled.networkJSON) {
                session.contentRuleList = list
            } else {
                if announce { session.model?.message = "内容规则没有编译成功，已保留样式隐藏。\(error.localizedDescription)" }
            }
        }
        session.refreshScripts()
        for tab in session.tabs { tab.syncContentRules() }
    }

    private static func compile(_ store: WKContentRuleListStore, identifier: String, json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? RikuganError.message("无法编译内容规则。")) }
            }
        }
    }
}
