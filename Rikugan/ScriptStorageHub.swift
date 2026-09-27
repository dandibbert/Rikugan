import Foundation

/// Per-browser-session revisions, with separate ordinary/private namespaces.
/// Persistence must succeed before an event or a successful write is reported.
@MainActor final class ScriptStorageHub {
    private var revisions: [String: Int] = [:]
    private func domain(_ id: UUID, _ isPrivate: Bool) -> String { id.uuidString + (isPrivate ? "/private" : "/normal") }
    func values(_ script: UserScript, in session: BrowserSession, isPrivate: Bool) -> [String: Any] {
        let json = isPrivate ? (session.privateScriptStorage[script.id] ?? "{}") : script.storageJSON
        guard let data = json.data(using: .utf8), let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }
    func snapshot(_ script: UserScript, in session: BrowserSession, isPrivate: Bool) -> [String: Any] {
        ["revision": revisions[domain(script.id, isPrivate), default: 0], "values": values(script, in: session, isPrivate: isPrivate)]
    }
    func mutate(_ script: UserScript, in session: BrowserSession, isPrivate: Bool,
                key: String, value: Any?, deleting: Bool, writer: String) throws -> [String: Any] {
        guard key.utf8.count < 4096 else { throw RikuganError.message("无效的存储键。") }
        var values = values(script, in: session, isPrivate: isPrivate)
        let old = values[key], existed = values.keys.contains(key)
        if deleting { values.removeValue(forKey: key) } else { values[key] = value ?? NSNull() }
        let before = try JSONSerialization.data(withJSONObject: ["value": old ?? NSNull(), "exists": existed], options: .sortedKeys)
        let after = try JSONSerialization.data(withJSONObject: ["value": values[key] ?? NSNull(), "exists": !deleting], options: .sortedKeys)
        let id = domain(script.id, isPrivate)
        guard before != after else { return ["changed": false, "revision": revisions[id, default: 0], "values": values] }
        let data = try JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
        guard data.count <= 2_000_000, let json = String(data: data, encoding: .utf8) else { throw RikuganError.message("GM 存储超过 2 MB。") }
        if isPrivate { session.privateScriptStorage[script.id] = json }
        else {
            guard let model = session.model, let p = model.state.profiles.firstIndex(where: { $0.id == session.profileID }),
                  let s = model.state.profiles[p].scripts.firstIndex(where: { $0.id == script.id }) else { throw RikuganError.message("脚本身份已关闭。") }
            var next = model.state; next.profiles[p].scripts[s].storageJSON = json
            try model.save(next)
        }
        revisions[id, default: 0] += 1
        let event: [String: Any] = ["changed": true, "revision": revisions[id]!, "key": key,
            "oldExists": existed, "oldValue": old ?? NSNull(), "newExists": !deleting,
            "newValue": values[key] ?? NSNull(), "writer": writer]
        for tab in session.tabs where tab.isPrivate == isPrivate {
            tab.scriptEngine.deliverStorageChange(scriptID: script.id, event: event)
        }
        session.scheduleScriptRefresh()
        return event
    }
}
