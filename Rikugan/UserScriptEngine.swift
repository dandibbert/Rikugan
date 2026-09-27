import UIKit
import WebKit

struct ScriptCommand: Identifiable {
    var id: String
    var title: String
    var scriptID: UUID
    var tabID: UUID
}

@MainActor final class UserScriptEngine: NSObject, WKScriptMessageHandlerWithReply {
    weak var tab: BrowserTab?
    private var handlers: [(name: String, world: WKContentWorld)] = []
    private var scripts: [String: UserScript] = [:]
    private struct Client {
        let scriptID: UUID
        let frame: WKFrameInfo
        let world: WKContentWorld
    }
    private var clients: [String: Client] = [:]
    private var requests: [String: (scriptID: UUID, worker: ScriptNetwork)] = [:]
    private static let template: String = {
        guard let url = Bundle.main.url(forResource: "UserscriptRuntime", withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    func configure(_ controller: WKUserContentController, scripts enabledScripts: [UserScript]) {
        let previous = scripts
        for (id, request) in requests {
            let old = previous.values.first { $0.id == request.scriptID }
            let next = enabledScripts.first { $0.id == request.scriptID && $0.enabled }
            if next == nil || next?.source != old?.source { request.worker.cancel(); requests.removeValue(forKey: id) }
        }
        clients = clients.filter { _, client in
            guard let next = enabledScripts.first(where: { $0.id == client.scriptID && $0.enabled }),
                  let old = previous.values.first(where: { $0.id == client.scriptID }) else { return false }
            return next.source == old.source
        }
        for handler in handlers { controller.removeScriptMessageHandler(forName: handler.name, contentWorld: handler.world) }
        handlers.removeAll(); scripts.removeAll()
        controller.removeAllUserScripts()
        for script in enabledScripts where script.enabled {
            let world: WKContentWorld = script.isolated ? .world(name: "rikugan.script." + script.id.uuidString) : .page
            let name = "rg_" + script.id.uuidString.replacingOccurrences(of: "-", with: "")
            if script.isolated {
                controller.addScriptMessageHandler(self, contentWorld: world, name: name)
                handlers.append((name, world)); scripts[name] = script
            }
            let jsonStorage = tab?.isPrivate == true ? (tab?.session?.privateScriptStorage[script.id] ?? "{}") : script.storageJSON
            let storage = (jsonStorage.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? [:]
            let resources = Dictionary(uniqueKeysWithValues: script.resources.map { ($0.name, ["text": $0.text, "url": $0.dataURL]) })
            let siteRules: [[String: Any]] = (tab?.session?.profile.siteSettings ?? [])
                .sorted { $0.host.count > $1.host.count }
                .map { ["host": $0.host.lowercased(), "enabled": $0.userScriptsEnabled ?? true] }
            let configuration: [String: Any] = [
                "id": script.id.uuidString, "name": script.name, "namespace": script.namespace, "author": script.author,
                "version": script.version, "handler": name, "matches": script.matches, "includes": script.includes,
                "excludes": script.excludes, "excludeMatches": script.excludeMatches,
                "grants": script.grants, "runAt": script.runAt, "storage": storage, "resources": resources,
                "isolated": script.isolated, "siteRules": siteRules
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
        resetDocument()
        for handler in handlers { controller.removeScriptMessageHandler(forName: handler.name, contentWorld: handler.world) }
        handlers.removeAll(); scripts.removeAll()
    }
    func resetDocument() {
        clients.removeAll()
        for request in requests.values { request.worker.cancel() }
        requests.removeAll()
    }
    func deliverStorageChange(scriptID: UUID, event: [String: Any]) {
        guard let webView = tab?.existingWebView else { return }
        for (id, client) in clients where client.scriptID == scriptID {
            webView.callAsyncJavaScript("globalThis.__rikuganStorageChange?.(clientID, event); return true", arguments: ["clientID": id, "event": event], in: client.frame, in: client.world) { [weak self] result in
                if case .failure = result { self?.clients.removeValue(forKey: id) }
            }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let tab, let session = tab.session, session.isActive,
              let cached = scripts[message.name], let script = session.profile.scripts.first(where: { $0.id == cached.id && $0.enabled }),
              let origin = message.frameInfo.request.url, script.matchesURL(origin), (!script.noFrames || message.frameInfo.isMainFrame),
              session.profile.site(for: origin.host)?.userScriptsEnabled != false,
              let body = message.body as? [String: Any], let operation = body["operation"] as? String else {
            replyHandler(nil, "脚本或页面未授权。"); return
        }
        let storageAccess = ["getValue", "setValue", "deleteValue", "listValues", "addValueChangeListener"].contains { script.permits($0) }
        guard script.permits(operation) || (operation == "observeStorage" && storageAccess) || (operation == "abortRequest" && script.permits("xmlHttpRequest")) else { replyHandler(nil, "缺少 @grant GM.\(operation)"); return }
        let args = body["args"] as? [String: Any] ?? [:]
        let clientID = body["client"] as? String ?? ""
        switch operation {
        case "observeStorage":
            guard !clientID.isEmpty, clientID.count <= 128, clients[clientID] != nil || clients.count < 128 else { replyHandler(nil, "脚本页面订阅超过限制。"); return }
            clients[clientID] = Client(scriptID: script.id, frame: message.frameInfo, world: .world(name: "rikugan.script." + script.id.uuidString))
            replyHandler(session.scriptStorage.snapshot(script, in: session, isPrivate: tab.isPrivate), nil)
        case "getValue", "listValues":
            let storage = session.scriptStorage.values(script, in: session, isPrivate: tab.isPrivate)
            if operation == "listValues" { replyHandler(Array(storage.keys), nil) }
            else {
                let key = args["key"] as? String ?? ""
                replyHandler(["exists": storage.keys.contains(key), "value": storage[key] ?? NSNull()], nil)
            }
        case "setValue", "deleteValue":
            guard let key = args["key"] as? String, key.utf8.count < 4096 else { replyHandler(nil, "无效的存储键。"); return }
            do {
                let event = try session.scriptStorage.mutate(script, in: session, isPrivate: tab.isPrivate, key: key,
                    value: args["value"], deleting: operation == "deleteValue", writer: clientID)
                replyHandler(event, nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        case "setClipboard":
            UIPasteboard.general.string = String((args["text"] as? String ?? "").prefix(1_000_000))
            replyHandler(true, nil)
        case "openInTab":
            guard let raw = args["url"] as? String, let url = URL(string: raw, relativeTo: origin)?.absoluteURL,
                  ["http", "https"].contains(url.scheme ?? "") else { replyHandler(nil, "只能打开 HTTP(S) 页面。"); return }
            session.addTab(url: url, activate: !(args["background"] as? Bool ?? false), isPrivate: tab.isPrivate, groupID: tab.groupID)
            replyHandler(true, nil)
        case "registerMenuCommand":
            guard message.frameInfo.isMainFrame, let id = args["id"] as? String, let title = args["title"] as? String else { replyHandler(nil, "菜单命令仅支持顶层页面。"); return }
            session.commands.removeAll { $0.id == id && $0.tabID == tab.id }
            session.commands.append(ScriptCommand(id: id, title: String(title.prefix(120)), scriptID: script.id, tabID: tab.id))
            replyHandler(id, nil)
        case "unregisterMenuCommand":
            session.commands.removeAll { $0.id == args["id"] as? String && $0.scriptID == script.id && $0.tabID == tab.id }
            replyHandler(true, nil)
        case "getResourceText", "getResourceURL":
            guard let name = args["name"] as? String, let resource = script.resources.first(where: { $0.name == name }) else {
                replyHandler(nil, "找不到 @resource \(args["name"] as? String ?? "")。"); return
            }
            replyHandler(operation == "getResourceURL" ? resource.dataURL : resource.text, nil)
        case "abortRequest":
            let id = script.id.uuidString + "/" + clientID + "/" + (args["id"] as? String ?? "")
            requests.removeValue(forKey: id)?.worker.cancel()
            replyHandler(true, nil)
        case "xmlHttpRequest":
            do {
                guard let requestID = args["id"] as? String, !requestID.isEmpty, requestID.count < 128,
                      !clientID.isEmpty, clientID.count < 128, requests.count < 16 else { throw RikuganError.message("请求标识无效或并发请求超过 16 个。") }
                let id = script.id.uuidString + "/" + clientID + "/" + requestID
                guard requests[id] == nil else { throw RikuganError.message("重复的请求标识。") }
                let built = try ScriptRequest.build(args, origin: origin)
                let rules = script.connects + ["self"]
                let frame = message.frameInfo, world = WKContentWorld.world(name: "rikugan.script." + script.id.uuidString)
                let worker = ScriptNetwork.fetch(built.request, permits: { URLRules.connectionAllowed($0, origin: origin, rules: rules) }, timeout: built.timeout,
                    progress: { [weak self] value in
                        self?.tab?.existingWebView?.callAsyncJavaScript("globalThis.__rikuganXHRProgress?.(clientID, requestID, value); return true",
                            arguments: ["clientID": clientID, "requestID": requestID, "value": value], in: frame, in: world) { [weak self] result in
                                if case .failure = result { self?.requests.removeValue(forKey: id)?.worker.cancel() }
                            }
                    }) { [weak self] result in
                        self?.requests.removeValue(forKey: id)
                        switch result {
                        case .success(let value): replyHandler(value, nil)
                        case .failure(let error):
                            let code = (error as NSError).code
                            replyHandler(["error": error.localizedDescription, "kind": code == NSURLErrorCancelled ? "abort" : code == NSURLErrorTimedOut ? "timeout" : "error"], nil)
                        }
                    }
                if let worker { requests[id] = (script.id, worker) }
            } catch { replyHandler(["error": error.localizedDescription, "kind": "error"], nil) }
        default: replyHandler(nil, "尚未支持此 API。")
        }
    }
    static func values(_ script: UserScript) -> [String: Any] {
        guard let data = script.storageJSON.data(using: .utf8), let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }
}

