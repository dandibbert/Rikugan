import UIKit
import WebKit

/// Isolated closures that cannot be serialized post `iso-call` on `rikuganPage`.
/// Swift evaluates the function in that script's content world and writes the JSON
/// result onto `window.__rgResults` in the page. There is no synchronous custom-scheme
/// request, because that request deadlocks `evaluateJavaScript` in the same web view.

struct ScriptCommand: Identifiable {
    var id: String
    var title: String
    var scriptID: UUID
    var tabID: UUID
    var isolated = true
}

@MainActor final class UserScriptEngine: NSObject, WKScriptMessageHandlerWithReply {
    weak var tab: BrowserTab?
    private var handlers: [(name: String, world: WKContentWorld)] = []
    private var scripts: [String: UserScript] = [:]
    private var exchanges: [String: ScriptExchange] = [:]
    private static let template: String = {
        guard let url = Bundle.main.url(forResource: "UserscriptRuntime", withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    func invokeIsolated(handler: String, id: Int, args: Any, webView: WKWebView, completion: ((String) -> Void)? = nil) {
        guard let script = scripts[handler], JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { completion?("{\"t\":\"err\",\"e\":\"missing script\"}"); return }
        let world: WKContentWorld = script.isolated ? .world(name: "rikugan.script." + script.id.uuidString) : .page
        let scriptSource = "JSON.stringify((globalThis.__rikuganInvokeIsolated&&globalThis.__rikuganInvokeIsolated(\(id),\(json)))||{t:'val',u:1})"
        webView.evaluateJavaScript(scriptSource, in: nil, in: world) { value, _ in
            completion?(value as? String ?? "{\"t\":\"val\",\"u\":1}")
        }
    }

    func configure(_ controller: WKUserContentController, scripts enabledScripts: [UserScript]) {
        for handler in handlers { controller.removeScriptMessageHandler(forName: handler.name, contentWorld: handler.world) }
        handlers.removeAll(); scripts.removeAll()
        controller.removeAllUserScripts()
        for script in enabledScripts where script.enabled {
            let world: WKContentWorld = script.isolated ? .world(name: "rikugan.script." + script.id.uuidString) : .page
            let name = "rg_" + script.id.uuidString.replacingOccurrences(of: "-", with: "")
            controller.addScriptMessageHandler(self, contentWorld: world, name: name)
            handlers.append((name, world)); scripts[name] = script
            let storage = (script.storageJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? [:]
            let resources = Dictionary(uniqueKeysWithValues: script.resources.map { ($0.name, ["text": $0.text, "url": $0.dataURL]) })
            let configuration: [String: Any] = [
                "id": script.id.uuidString, "name": script.name, "namespace": script.namespace, "author": script.author,
                "version": script.version, "handler": name, "matches": script.matches, "includes": script.includes,
                "excludes": script.excludes, "excludeMatches": script.excludeMatches,
                "grants": script.grants, "runAt": script.runAt, "storage": storage, "resources": resources, "isolated": script.isolated
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { continue }
            let source = Self.template
                .replacingOccurrences(of: "/*__CONFIG__*/", with: json)
                .replacingOccurrences(of: "/*__SOURCE__*/", with: script.dependencies.joined(separator: "\n;\n") + "\n;\n" + script.source)
            let early = script.runAt == "document-start" || script.runAt == "document-body"
            let userScript = WKUserScript(source: source, injectionTime: early ? .atDocumentStart : .atDocumentEnd,
                                          forMainFrameOnly: script.noFrames, in: world)
            controller.addUserScript(userScript)
        }
    }
    func teardown(_ controller: WKUserContentController) {
        for handler in handlers { controller.removeScriptMessageHandler(forName: handler.name, contentWorld: handler.world) }
        handlers.removeAll(); scripts.removeAll()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let tab, let session = tab.session, session.isActive,
              let cached = scripts[message.name], let script = session.profile.scripts.first(where: { $0.id == cached.id && $0.enabled }),
              let origin = message.frameInfo.request.url, script.matchesURL(origin), (!script.noFrames || message.frameInfo.isMainFrame),
              let body = message.body as? [String: Any], let operation = body["operation"] as? String else {
            replyHandler(nil, "脚本或页面未授权。"); return
        }
        guard script.permits(operation) else { replyHandler(nil, "缺少 @grant GM.\(operation)"); return }
        let args = body["args"] as? [String: Any] ?? [:]
        switch operation {
        case "getValue", "listValues":
            let storage = values(for: script, tab: tab, session: session)
            replyHandler(operation == "listValues" ? Array(storage.keys) : (storage[args["key"] as? String ?? ""] ?? NSNull()), nil)
        case "setValue", "deleteValue":
            guard let key = args["key"] as? String, key.utf8.count < 4096 else { replyHandler(nil, "无效的存储键。"); return }
            var stored = values(for: script, tab: tab, session: session)
            if operation == "deleteValue" { stored.removeValue(forKey: key) } else { stored[key] = args["value"] ?? NSNull() }
            guard JSONSerialization.isValidJSONObject(stored), let data = try? JSONSerialization.data(withJSONObject: stored), data.count <= 2_000_000,
                  let json = String(data: data, encoding: .utf8) else { replyHandler(nil, "脚本存储必须为 JSON，且不能超过 2 MB。"); return }
            if !ScriptVault.persists(isPrivate: tab.isPrivate) {
                session.privateScriptValues[script.id] = stored
            } else {
                session.model?.updateProfile(session.profileID) { profile in
                    if let index = profile.scripts.firstIndex(where: { $0.id == script.id }) { profile.scripts[index].storageJSON = json }
                }
            }
            broadcastValue(script: script, key: key, value: operation == "deleteValue" ? nil : stored[key], except: tab, session: session)
            replyHandler(true, nil)
        case "setClipboard":
            UIPasteboard.general.string = String((args["text"] as? String ?? "").prefix(1_000_000))
            replyHandler(true, nil)
        case "openInTab":
            guard let raw = args["url"] as? String, let url = URL(string: raw, relativeTo: origin)?.absoluteURL,
                  ["http", "https"].contains(url.scheme ?? "") else { replyHandler(nil, "只能打开 HTTP(S) 页面。"); return }
            session.addTab(url: url, activate: !(args["background"] as? Bool ?? false), windowID: tab.windowID)
            replyHandler(true, nil)
        case "registerMenuCommand":
            guard message.frameInfo.isMainFrame, let id = args["id"] as? String, let title = args["title"] as? String else { replyHandler(nil, "菜单命令仅支持顶层页面。"); return }
            session.commands.removeAll { $0.id == id && $0.tabID == tab.id }
            session.commands.append(ScriptCommand(id: id, title: String(title.prefix(120)), scriptID: script.id, tabID: tab.id, isolated: script.isolated))
            replyHandler(id, nil)
        case "unregisterMenuCommand":
            session.commands.removeAll { $0.id == args["id"] as? String && $0.scriptID == script.id && $0.tabID == tab.id }
            replyHandler(true, nil)
        case "getResourceText", "getResourceURL":
            guard let name = args["name"] as? String, let resource = script.resources.first(where: { $0.name == name }) else {
                replyHandler(nil, "找不到 @resource \(args["name"] as? String ?? "")。"); return
            }
            replyHandler(operation == "getResourceURL" ? resource.dataURL : resource.text, nil)
        case "xmlHttpRequest":
            guard let raw = args["url"] as? String, let url = URL(string: raw, relativeTo: origin)?.absoluteURL else { replyHandler(nil, "无效的请求 URL。"); return }
            var request = URLRequest(url: url)
            request.httpMethod = args["method"] as? String ?? "GET"
            request.httpBody = (args["data"] as? String)?.data(using: .utf8)
            if let headers = args["headers"] as? [String: String] {
                for (key, value) in headers where !["host", "content-length", "connection"].contains(key.lowercased()) { request.setValue(value, forHTTPHeaderField: key) }
            }
            let rules = script.connects + ["self"]
            let requestID = args["id"] as? String ?? UUID().uuidString
            let world: WKContentWorld = script.isolated ? .world(name: "rikugan.script." + script.id.uuidString) : .page
            let exchange = ScriptExchange.start(request, permits: { URLRules.connectionAllowed($0, origin: origin, rules: rules) }) { [weak self] result in
                self?.exchanges[requestID] = nil
                switch result { case .success(let value): replyHandler(value, nil); case .failure(let error): replyHandler(nil, error.localizedDescription) }
            }
            exchange?.onProgress = { [weak self] loaded, total in self?.reportProgress(id: requestID, loaded: loaded, total: total, world: world) }
            if let exchange { exchanges[requestID] = exchange }
        case "abortRequest":
            if let id = args["id"] as? String { exchanges.removeValue(forKey: id)?.cancel() }
            replyHandler(true, nil)
        default: replyHandler(nil, "尚未支持此 API。")
        }
    }
    private func values(for script: UserScript, tab: BrowserTab, session: BrowserSession) -> [String: Any] {
        if tab.isPrivate {
            if session.privateScriptValues[script.id] == nil { session.privateScriptValues[script.id] = Self.values(script) }
            return session.privateScriptValues[script.id] ?? [:]
        }
        return Self.values(script)
    }
    private func broadcastValue(script: UserScript, key: String, value: Any?, except tab: BrowserTab, session: BrowserSession) {
        let payload: Any = value ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: [payload]), var text = String(data: data, encoding: .utf8) else { return }
        text.removeFirst(); text.removeLast()
        let keyJS = PageTools.jsString(key) ?? "\"\""
        let world: WKContentWorld = script.isolated ? .world(name: "rikugan.script." + script.id.uuidString) : .page
        let source = "globalThis.__rikuganValueChanged && globalThis.__rikuganValueChanged(\(keyJS), \(text), true)"
        for other in session.tabs where other.id != tab.id && other.isPrivate == tab.isPrivate {
            other.webView.evaluateJavaScript(source, in: nil, in: world) { _, _ in }
        }
    }
    private func reportProgress(id: String, loaded: Int, total: Int, world: WKContentWorld) {
        guard let tab else { return }
        let payload: [String: Any] = ["id": id, "loaded": loaded, "total": total]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        tab.webView.evaluateJavaScript("globalThis.__rikuganXHREvent && globalThis.__rikuganXHREvent(\(json))", in: nil, in: world) { _, _ in }
    }
    static func values(_ script: UserScript) -> [String: Any] {
        guard let data = script.storageJSON.data(using: .utf8), let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }
}

