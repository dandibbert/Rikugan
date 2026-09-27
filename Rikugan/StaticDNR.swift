import Foundation
import CoreFoundation
import WebKit

/// Public-API execution path for the static block/allow DNR subset. The native
/// extension API accepted the test rules but did not block their page requests.
/// Compile a separate list per extension; never mix its allow rules with those
/// of another extension or with the browser's own content blocker.
enum StaticDNR {
    static let notice = "静态 DNR 兼容模式：宿主编译并执行 block/allow、优先级、URL 过滤及资源类型。动态/session 规则、运行时规则集修改、redirect/modifyHeaders 和不支持的条件会明确报错，不会假装成功。"
    static let unsupportedAPIs = [
        "updateDynamicRules", "updateSessionRules", "updateEnabledRulesets", "updateStaticRules",
        "setExtensionActionOptions", "getMatchedRules", "testMatchOutcome"
    ].flatMap { method in
        ["browser.declarativeNetRequest." + method, "chrome.declarativeNetRequest." + method, "declarativeNetRequest." + method]
    }

    struct Compiled { let json: String; let count: Int }
    private struct Rule {
        let id: Int
        let priority: Int
        let allow: Bool
        let triggers: [[String: Any]]
    }
    private static func error(_ message: String) -> RikuganError {
        .message("静态 DNR：" + message)
    }
    static func compile(rulesets: [[String: Any]], read: (String) throws -> Data) throws -> Compiled {
        guard rulesets.count <= 50 else { throw error("最多支持 50 个静态规则集。") }
        var names = Set<String>(), rules: [Rule] = [], totalBytes = 0
        for resource in rulesets {
            guard let name = resource["id"] as? String, !name.isEmpty, name.count <= 128, names.insert(name).inserted,
                  let path = resource["path"] as? String, ExtensionCompatibility.safeRelativePath(path), !path.hasSuffix("/"),
                  let enabled = resource["enabled"] as? Bool else { throw error("规则集标识、路径或 enabled 无效。") }
            guard enabled else { continue }
            let data = try read(path); totalBytes += data.count
            guard data.count <= 8_000_000, totalBytes <= 16_000_000,
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  rules.count + objects.count <= 5000 else { throw error("规则集无效或超过 5000 条 / 16 MB。") }
            var ids = Set<Int>()
            for object in objects {
                guard let id = integer(object["id"]), id > 0, ids.insert(id).inserted,
                      let priority = integer(object["priority"] ?? 1), priority > 0 else { throw error("规则 ID/优先级无效或重复（\(name)）。") }
                do {
                    guard Set(object.keys).isSubset(of: ["id", "priority", "action", "condition"]),
                          let action = object["action"] as? [String: Any], action.count == 1,
                          let kind = action["type"] as? String, ["block", "allow"].contains(kind),
                          let condition = object["condition"] as? [String: Any] else { throw error("不支持的 action 或规则字段；仅接受 block/allow。") }
                    rules.append(Rule(id: id, priority: priority, allow: kind == "allow", triggers: try triggers(condition)))
                } catch { throw Self.error("\(name) #\(id)：\(error.localizedDescription)") }
            }
        }
        // WebKit ignore-previous-rules only cancels preceding matching actions.
        // Ascending priority, block before allow at ties, implements the DNR
        // block/allow ordering without widening any condition.
        rules.sort { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            if a.allow != b.allow { return !a.allow }
            return a.id < b.id
        }
        let converted: [[String: Any]] = rules.flatMap { rule in
            rule.triggers.map { ["trigger": $0, "action": ["type": rule.allow ? "ignore-previous-rules" : "block"]] }
        }
        guard converted.count <= 30000 else { throw error("规则展开后超过 30000 条。") }
        let data = try JSONSerialization.data(withJSONObject: converted, options: .sortedKeys)
        return Compiled(json: String(decoding: data, as: UTF8.self), count: rules.count)
    }

    static func fromPackage(_ root: URL, permissions: [String]) throws -> Compiled {
        let directory = try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let archive = directory ? nil : try Data(contentsOf: root)
        func read(_ path: String) throws -> Data {
            guard ExtensionCompatibility.safeRelativePath(path) else { throw error("资源路径越界。") }
            if let archive {
                guard let data = ZipArchive.extract(data: archive, path: path) else { throw error("缺少资源 \(path)。") }
                return data
            }
            let file = root.appendingPathComponent(path)
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/"),
                  (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8_000_000 else { throw error("资源路径不安全或超过 8 MB。") }
            return try Data(contentsOf: file)
        }
        guard let manifest = try JSONSerialization.jsonObject(with: read("manifest.json")) as? [String: Any] else { throw error("无效的 manifest.json。") }
        guard let declaration = manifest["declarative_net_request"] as? [String: Any] else { return Compiled(json: "[]", count: 0) }
        guard permissions.contains("declarativeNetRequest") else {
            throw error("需要 declarativeNetRequest 授权；WithHostAccess 条件执行尚未接通，未放宽权限。")
        }
        guard let resources = declaration["rule_resources"] as? [[String: Any]] else { throw error("缺少 rule_resources。") }
        return try compile(rulesets: resources, read: read)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              (1...2_147_483_647).contains(number.doubleValue) else { return nil }
        return number.intValue
    }
    static func urlPatterns(_ filter: String) throws -> [String] {
        guard !filter.isEmpty, filter.utf8.count <= 2000, filter.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
            throw error("urlFilter 需要 1–2000 字节 ASCII 文本。")
        }
        var body = filter, start = "", end = ""
        if body.hasPrefix("||") { start = "^[^:/]+://([^/?#]*\\.)?"; body.removeFirst(2) }
        else if body.hasPrefix("|") { start = "^"; body.removeFirst() }
        if body.hasSuffix("|") { end = "$"; body.removeLast() }
        guard !body.contains("|") else { throw error("urlFilter 的 | 只能出现在开头或结尾。") }
        var pattern = start, terminalPatterns: [String] = []
        let characters = Array(body)
        for (index, character) in characters.enumerated() {
            if character == "*" { pattern += ".*" }
            else if character == "^" {
                // End-of-URL can only satisfy the remaining filter when every
                // following token can match empty. Do not emit '$' in the middle
                // of a WebKit regex, or broaden ^ to an optional separator.
                if characters.dropFirst(index + 1).allSatisfy({ $0 == "*" || $0 == "^" }) {
                    terminalPatterns.append(pattern + "$")
                }
                pattern += "[^A-Za-z0-9_.%\\-]"
            } else { pattern += NSRegularExpression.escapedPattern(for: String(character)) }
        }
        let final = pattern + end
        return Array(Set(terminalPatterns + [final.isEmpty ? ".*" : final])).sorted()
    }
    private static func triggers(_ condition: [String: Any]) throws -> [[String: Any]] {
        let supported: Set<String> = ["urlFilter", "regexFilter", "isUrlFilterCaseSensitive", "resourceTypes", "excludedResourceTypes"]
        guard Set(condition.keys).isSubset(of: supported) else {
            throw error("不支持条件 \(Set(condition.keys).subtracting(supported).sorted().joined(separator: ", "))；未忽略条件扩大拦截范围。")
        }
        let patterns: [String]
        if let regex = condition["regexFilter"] as? String {
            guard condition["urlFilter"] == nil, !regex.isEmpty, regex.utf8.count <= 2000,
                  regex.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else { throw error("无效的 regexFilter。") }
            // The public compiler below rejects unsupported regex constructs.
            patterns = [regex]
        } else if let filter = condition["urlFilter"] as? String { patterns = try urlPatterns(filter) }
        else if condition["urlFilter"] != nil || condition["regexFilter"] != nil { throw error("URL 条件必须为字符串。") }
        else { patterns = [".*"] }
        let mapped = ["image": "image", "stylesheet": "style-sheet", "script": "script", "font": "font", "media": "media", "xmlhttprequest": "fetch", "ping": "ping", "websocket": "websocket", "other": "other"]
        let supportedTypes = Set(mapped.keys).union(["main_frame", "sub_frame"])
        var types = Set(mapped.keys).union(["sub_frame"])
        if let requested = condition["resourceTypes"] {
            guard let values = requested as? [String], !values.isEmpty, Set(values).isSubset(of: supportedTypes) else { throw error("不支持的 resourceTypes。") }
            types = Set(values)
        }
        if let excluded = condition["excludedResourceTypes"] {
            guard condition["resourceTypes"] == nil, let values = excluded as? [String], Set(values).isSubset(of: supportedTypes) else { throw error("不支持的 excludedResourceTypes。") }
            types.subtract(values)
        }
        guard condition["isUrlFilterCaseSensitive"] == nil || condition["isUrlFilterCaseSensitive"] is Bool else { throw error("isUrlFilterCaseSensitive 必须为布尔值。") }
        var groups: [[String: Any]] = []
        let resources = types.compactMap { mapped[$0] }.sorted()
        if !resources.isEmpty { groups.append(["resource-type": resources]) }
        if types.contains("main_frame") { groups.append(["resource-type": ["document"], "load-context": ["top-frame"]]) }
        if types.contains("sub_frame") { groups.append(["resource-type": ["document"], "load-context": ["child-frame"]]) }
        return patterns.flatMap { pattern in groups.map { group in
            var trigger = group; trigger["url-filter"] = pattern
            trigger["url-filter-is-case-sensitive"] = condition["isUrlFilterCaseSensitive"] as? Bool ?? false
            return trigger
        } }
    }
}

extension BrowserSession {
    func prepareStaticDNR(_ record: ExtensionRecord) async throws -> (WKContentRuleList?, Int) {
        guard let model else { throw RikuganError.message("身份已关闭。") }
        let compiled = try StaticDNR.fromPackage(model.directory(profileID).appendingPathComponent(record.relativePath), permissions: record.allowedPermissions)
        guard compiled.json != "[]" else { return (nil, 0) }
        guard let store = WKContentRuleListStore.default() else { throw RikuganError.message("内容规则存储不可用，未启用 DNR。") }
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: "rikugan.dnr." + profileID.uuidString + "." + record.id.uuidString, encodedContentRuleList: compiled.json) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? RikuganError.message("无法编译静态 DNR。")) }
            }
        }
        return (list, compiled.count)
    }
    func removeStaticDNR(_ id: UUID) {
        extensionDNRLists[id] = nil; extensionDNRCounts[id] = nil
        for tab in tabs { tab.syncExtensionDNR() }
    }
}

extension BrowserTab {
    func syncExtensionDNR() {
        guard let view = existingWebView else { return }
        let wanted = isPrivate ? [:] : session?.extensionDNRLists ?? [:]
        for (id, previous) in appliedExtensionDNR where wanted[id] !== previous {
            view.configuration.userContentController.remove(previous); appliedExtensionDNR[id] = nil
        }
        for (id, list) in wanted where appliedExtensionDNR[id] == nil {
            view.configuration.userContentController.add(list); appliedExtensionDNR[id] = list
        }
    }
}
