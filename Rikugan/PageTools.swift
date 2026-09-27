import WebKit

enum PageTools {
    static let source: String = {
        guard let url = Bundle.main.url(forResource: "PageTools", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return "globalThis.RikuganPageTools = globalThis.RikuganPageTools || {};"
        }
        return text
    }()

    static func install(on controller: WKUserContentController, cosmeticCSS: String, hostCSS: String = "{}", procedural: String = "[]", scriptlets: String = "[]", csp: String = "[]") {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let css = jsString(cosmeticCSS) ?? "\"\""
        let host = hostCSS.isEmpty ? "{}" : hostCSS
        let rules = procedural.isEmpty ? "[]" : procedural
        let lets = scriptlets.isEmpty ? "[]" : scriptlets
        let policies = csp.isEmpty ? "[]" : csp
        let boot = "(function(){try{if(globalThis.RikuganPageTools){RikuganPageTools.applyBlocking(\(css), \(host), \(rules));RikuganPageTools.applyScriptlets(\(lets));RikuganPageTools.applyCSP(\(policies));RikuganPageTools.installConsole();}}catch(e){}})();"
        controller.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
        session.hostCSS = compiled.hostCSS
        session.proceduralJSON = compiled.proceduralJSON
        session.scriptletJSON = compiled.scriptletJSON
        session.cspJSON = compiled.cspJSON
        session.removeParams = compiled.removeParams
        let store = WKContentRuleListStore.default()
        for tab in session.tabs { tab.removeContentRules() }
        session.contentRuleLists = []
        session.contentRuleList = nil
        guard let store else { session.refreshScripts(); return }
        let chunks = compiled.chunks.isEmpty ? [] : compiled.chunks
        if chunks.isEmpty { session.refreshScripts(); return }
        var lists: [WKContentRuleList] = []
        var failed = false
        for (index, chunk) in chunks.enumerated() where chunk != "[]" {
            do { lists.append(try await compile(store, identifier: "rikugan.rules.\(index)", json: chunk)) }
            catch {
                failed = true
                if announce { session.model?.message = "有一段内容规则没有编译成功，已改用网络规则和样式隐藏。\(error.localizedDescription)" }
                break
            }
        }
        if failed {
            lists = []
            for (index, chunk) in compiled.networkChunks.enumerated() where chunk != "[]" {
                if let list = try? await compile(store, identifier: "rikugan.rules.network.\(index)", json: chunk) { lists.append(list) }
            }
        }
        session.contentRuleLists = lists
        session.contentRuleList = lists.first
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
