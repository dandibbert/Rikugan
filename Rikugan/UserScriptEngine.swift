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
    private static let template: String = {
        guard let url = Bundle.main.url(forResource: "UserscriptRuntime", withExtension: "js"), let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }()

    func configure(_ controller: WKUserContentController, scripts enabledScripts: [UserScript]) {
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
            let storage = (script.storageJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? [:]
            let configuration: [String: Any] = [
                "id": script.id.uuidString, "name": script.name, "version": script.version,
                "handler": name, "matches": script.matches, "includes": script.includes,
                "excludes": script.excludes, "excludeMatches": script.excludeMatches,
                "grants": script.grants, "runAt": script.runAt, "storage": storage
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { continue }
            let source = Self.template
                .replacingOccurrences(of: "/*__CONFIG__*/", with: json)
                .replacingOccurrences(of: "/*__SOURCE__*/", with: script.dependencies.joined(separator: "\n;\n") + "\n;\n" + script.source)
            let userScript = WKUserScript(source: source, injectionTime: script.runAt == "document-start" ? .atDocumentStart : .atDocumentEnd,
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
            let storage = Self.values(script)
            replyHandler(operation == "listValues" ? Array(storage.keys) : (storage[args["key"] as? String ?? ""] ?? NSNull()), nil)
        case "setValue", "deleteValue":
            guard let key = args["key"] as? String, key.utf8.count < 4096 else { replyHandler(nil, "无效的存储键。"); return }
            var values = Self.values(script)
            if operation == "deleteValue" { values.removeValue(forKey: key) } else { values[key] = args["value"] ?? NSNull() }
            guard JSONSerialization.isValidJSONObject(values), let data = try? JSONSerialization.data(withJSONObject: values), data.count <= 2_000_000,
                  let json = String(data: data, encoding: .utf8) else { replyHandler(nil, "脚本存储必须为 JSON，且不能超过 2 MB。"); return }
            session.model?.updateProfile(session.profileID) { profile in
                if let index = profile.scripts.firstIndex(where: { $0.id == script.id }) { profile.scripts[index].storageJSON = json }
            }
            session.scheduleScriptRefresh()
            replyHandler(true, nil)
        case "setClipboard":
            UIPasteboard.general.string = String((args["text"] as? String ?? "").prefix(1_000_000))
            replyHandler(true, nil)
        case "openInTab":
            guard let raw = args["url"] as? String, let url = URL(string: raw, relativeTo: origin)?.absoluteURL,
                  ["http", "https"].contains(url.scheme ?? "") else { replyHandler(nil, "只能打开 HTTP(S) 页面。"); return }
            session.addTab(url: url, activate: !(args["background"] as? Bool ?? false))
            replyHandler(true, nil)
        case "registerMenuCommand":
            guard message.frameInfo.isMainFrame, let id = args["id"] as? String, let title = args["title"] as? String else { replyHandler(nil, "菜单命令仅支持顶层页面。"); return }
            session.commands.removeAll { $0.id == id && $0.tabID == tab.id }
            session.commands.append(ScriptCommand(id: id, title: String(title.prefix(120)), scriptID: script.id, tabID: tab.id))
            replyHandler(id, nil)
        case "unregisterMenuCommand":
            session.commands.removeAll { $0.id == args["id"] as? String && $0.scriptID == script.id && $0.tabID == tab.id }
            replyHandler(true, nil)
        case "xmlHttpRequest":
            guard let raw = args["url"] as? String, let url = URL(string: raw, relativeTo: origin)?.absoluteURL else { replyHandler(nil, "无效的请求 URL。"); return }
            var request = URLRequest(url: url)
            request.httpMethod = args["method"] as? String ?? "GET"
            request.httpBody = (args["data"] as? String)?.data(using: .utf8)
            if let headers = args["headers"] as? [String: String] {
                for (key, value) in headers where !["host", "content-length", "connection"].contains(key.lowercased()) { request.setValue(value, forHTTPHeaderField: key) }
            }
            let rules = script.connects + ["self"]
            ScriptNetwork.fetch(request, permits: { URLRules.connectionAllowed($0, origin: origin, rules: rules) }) { result in
                switch result { case .success(let value): replyHandler(value, nil); case .failure(let error): replyHandler(nil, error.localizedDescription) }
            }
        default: replyHandler(nil, "尚未支持此 API。")
        }
    }
    static func values(_ script: UserScript) -> [String: Any] {
        guard let data = script.storageJSON.data(using: .utf8), let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }
}

