import Foundation

/// Converts `chrome.declarativeNetRequest` rules into WebKit content rule list JSON.
/// Supported actions: block, allow, allowAllRequests, upgradeScheme. Others are reported.
public enum DNRConverter {
    public struct Output {
        public var rules: [NetworkRule] = []
        public var skipped: [(id: Int, reason: String)] = []
    }

    /// WebKit capabilities detected at runtime (redirect / modify-headers content-rule actions
    /// exist only on newer WebKit; the app probes them by compiling a test list).
    public struct Capabilities: Equatable {
        public var redirect: Bool
        public var modifyHeaders: Bool
        public init(redirect: Bool = false, modifyHeaders: Bool = false) { self.redirect = redirect; self.modifyHeaders = modifyHeaders }
    }

    /// Builds the WebKit action for a DNR redirect, or returns a reason when not expressible.
    public static func redirectAction(_ redirect: [String: Any], baseURL: String?) -> (json: String?, reason: String?) {
        var target: [String: Any] = [:]
        if let url = redirect["url"] as? String {
            target["url"] = url
        } else if let path = redirect["extensionPath"] as? String {
            guard let baseURL else { return (nil, "extensionPath 需要扩展地址") }
            target["url"] = baseURL + (path.hasPrefix("/") ? String(path.dropFirst()) : path)
        } else if let transform = redirect["transform"] as? [String: Any] {
            var t: [String: Any] = [:]
            for key in ["scheme", "host", "port", "path", "query", "fragment", "username", "password"] {
                if let v = transform[key] as? String { t[key] = v }
            }
            if let qt = transform["queryTransform"] as? [String: Any] {
                var out: [String: Any] = [:]
                if let remove = qt["removeParams"] as? [String] { out["remove-parameters"] = remove }
                if let add = qt["addOrReplaceParams"] as? [[String: Any]] {
                    out["add-or-replace-parameters"] = add.map { p -> [String: Any] in
                        var o: [String: Any] = ["key": p["key"] as? String ?? "", "value": p["value"] as? String ?? ""]
                        if let r = p["replaceOnly"] as? Bool { o["replace-only"] = r }
                        return o
                    }
                }
                t["query-transform"] = out
            }
            target["transform"] = t
        } else if redirect["regexSubstitution"] != nil {
            return (nil, "regexSubstitution 在 WebKit 内容规则中无法等价实现")
        } else {
            return (nil, "redirect 缺少目标")
        }
        return (JSONText.encode(["type": "redirect", "redirect": target] as [String: Any]), nil)
    }

    public static func modifyHeadersAction(_ action: [String: Any]) -> (json: String?, reason: String?) {
        func map(_ list: Any?) -> [[String: Any]]? {
            guard let list = list as? [[String: Any]] else { return nil }
            return list.compactMap { h in
                guard let header = h["header"] as? String, let op = h["operation"] as? String, ["set", "append", "remove"].contains(op) else { return nil }
                var o: [String: Any] = ["header": header, "operation": op]
                if let v = h["value"] as? String { o["value"] = v }
                return o
            }
        }
        var out: [String: Any] = ["type": "modify-headers"]
        if let req = map(action["requestHeaders"]), !req.isEmpty { out["request-headers"] = req }
        if let res = map(action["responseHeaders"]), !res.isEmpty { out["response-headers"] = res }
        guard out.count > 1 else { return (nil, "modifyHeaders 没有有效的 header 操作") }
        return (JSONText.encode(out), nil)
    }

    public static func convert(_ rules: [[String: Any]]) -> Output {
        convert(rules, capabilities: Capabilities(), baseURL: nil)
    }

    public static func convert(_ rules: [[String: Any]], capabilities: Capabilities, baseURL: String?) -> Output {
        var output = Output()
        // Chrome evaluates by priority; WebKit uses order (later rules win for ignore-previous-rules).
        let sorted = rules.sorted { ($0["priority"] as? Int ?? 1) < ($1["priority"] as? Int ?? 1) }
        var blocks: [NetworkRule] = [], allows: [NetworkRule] = []
        for rule in sorted {
            let id = rule["id"] as? Int ?? 0
            let action = rule["action"] as? [String: Any] ?? [:]
            let condition = rule["condition"] as? [String: Any] ?? [:]
            let type = action["type"] as? String ?? ""
            let mapped: NetworkRule.Action
            switch type {
            case "block": mapped = .block
            case "allow": mapped = .allow
            case "allowAllRequests": mapped = .allowDocument
            case "upgradeScheme": mapped = .upgradeScheme
            case "redirect":
                guard capabilities.redirect else { output.skipped.append((id, "WebKit 不执行 App 内容规则中的 redirect（已实测），规则被跳过")); continue }
                mapped = .redirect
            case "modifyHeaders":
                guard capabilities.modifyHeaders else { output.skipped.append((id, "WebKit 不支持 App 内容规则中的 modify-headers，规则被跳过")); continue }
                mapped = .modifyHeaders
            default:
                output.skipped.append((id, "未知动作 \(type)")); continue
            }
            // A condition WebKit cannot express makes the whole rule unusable: applying it without
            // that condition would make it match more than the extension asked for.
            let inexpressible = ["requestMethods", "excludedRequestMethods", "tabIds", "excludedTabIds", "excludedRequestDomains",
                                 "responseHeaders", "excludedResponseHeaders", "topDomains", "excludedTopDomains"]
            if let key = inexpressible.first(where: { condition[$0] != nil }) {
                output.skipped.append((id, "条件 \(key) 无法在 WebKit 内容规则中表达，规则未应用")); continue
            }
            var regexes: [String] = []
            if let filter = condition["urlFilter"] as? String {
                guard let regex = ABPPattern.regex(filter) else { output.skipped.append((id, "urlFilter 无法转换")); continue }
                regexes = [regex]
            } else if let regexFilter = condition["regexFilter"] as? String {
                guard let regex = ABPPattern.webKitRegex(from: regexFilter) else { output.skipped.append((id, "regexFilter 使用了 WebKit 不支持的语法")); continue }
                regexes = [regex]
            } else {
                regexes = [".*"]
            }
            let requestDomains = condition["requestDomains"] as? [String] ?? []
            let hasURLCondition = condition["urlFilter"] != nil || condition["regexFilter"] != nil
            if !requestDomains.isEmpty, mapped != .allowDocument {
                // "request domain AND url filter" needs a conjunction WebKit's url-filter lacks.
                guard !hasURLCondition else {
                    output.skipped.append((id, "requestDomains 与 urlFilter / regexFilter 同时使用无法等价表达，规则未应用")); continue
                }
                regexes = requestDomains.map { ABPPattern.domainAnchor + URLMatcher.escape($0.lowercased()) + ABPPattern.separator }
            }
            var base = NetworkRule(action: mapped, urlRegex: ".*")
            base.priority = rule["priority"] as? Int
            if mapped == .redirect {
                let result = redirectAction(action["redirect"] as? [String: Any] ?? [:], baseURL: baseURL)
                guard let json = result.json else { output.skipped.append((id, result.reason ?? "redirect 无法转换")); continue }
                base.actionJSON = json
            } else if mapped == .modifyHeaders {
                let result = modifyHeadersAction(action)
                guard let json = result.json else { output.skipped.append((id, result.reason ?? "modifyHeaders 无法转换")); continue }
                base.actionJSON = json
            }
            base.caseSensitive = condition["isUrlFilterCaseSensitive"] as? Bool ?? false
            if let domainType = condition["domainType"] as? String { base.thirdParty = domainType == "thirdParty" }
            let initiators = (condition["initiatorDomains"] as? [String]) ?? (condition["domains"] as? [String]) ?? []
            let excludedInitiators = (condition["excludedInitiatorDomains"] as? [String]) ?? (condition["excludedDomains"] as? [String]) ?? []
            // WebKit allows if-domain or unless-domain on a trigger, not both.
            if !initiators.isEmpty, !excludedInitiators.isEmpty {
                output.skipped.append((id, "initiatorDomains 与 excludedInitiatorDomains 同时使用无法等价表达，规则未应用")); continue
            }
            base.ifDomains = initiators
            base.unlessDomains = excludedInitiators
            var types: [FilterResourceType] = []
            var contexts: Set<String> = []
            let resourceTypes = condition["resourceTypes"] as? [String]
            let excludedTypes = condition["excludedResourceTypes"] as? [String] ?? []
            let effective = resourceTypes ?? (mapped == .allowDocument ? ["main_frame", "sub_frame"] :
                ["sub_frame", "stylesheet", "script", "image", "font", "object", "xmlhttprequest", "ping", "media", "websocket", "other"]
                    .filter { !excludedTypes.contains($0) })
            for t in effective {
                switch t {
                case "main_frame": types.append(.document); contexts.insert("top-frame")
                case "sub_frame": types.append(.document); contexts.insert("child-frame")
                case "stylesheet": types.append(.styleSheet)
                case "script": types.append(.script)
                case "image": types.append(.image)
                case "font": types.append(.font)
                case "xmlhttprequest", "websocket", "webtransport": types.append(.raw)
                case "ping", "csp_report": types.append(.ping)
                case "media": types.append(.media)
                default: types.append(.other)
                }
            }
            base.resourceTypes = Array(Set(types)).sorted { $0.rawValue < $1.rawValue }
            if contexts.count == 1, !types.contains(where: { $0 != .document }) { base.loadContext = Array(contexts) }
            if mapped == .allowDocument {
                // Expressed as "ignore earlier rules for every request of documents on these
                // domains". Only a document-domain condition (requestDomains) maps exactly; a URL
                // filter or an initiator condition does not, and such a rule is not applied at all
                // (turning it into ".*" would disable the extension's blocking everywhere).
                if hasURLCondition || !initiators.isEmpty || !excludedInitiators.isEmpty {
                    output.skipped.append((id, "allowAllRequests 只支持 requestDomains 条件，规则未应用")); continue
                }
                base.resourceTypes = []
                base.loadContext = []
                base.ifDomains = requestDomains
                base.unlessDomains = []
                regexes = [".*"]
            }
            for regex in regexes {
                var converted = base
                converted.urlRegex = regex
                if mapped == .allow || mapped == .allowDocument { allows.append(converted) } else { blocks.append(converted) }
            }
        }
        output.rules = blocks + allows
        return output
    }
}

/// HLS playlist parsing used by the media downloader.
public enum M3U8 {
    public struct Variant: Hashable { public let url: URL; public let bandwidth: Int; public let resolution: String? }
    public struct Segment: Hashable { public let url: URL; public let duration: Double }
    public struct MediaPlaylist {
        public var segments: [Segment] = []
        public var initSegment: URL?
        public var encryption: String?
        public var isFMP4: Bool { initSegment != nil }
        public var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    }

    public static func isMaster(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    public static func variants(_ text: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            let attributes = parseAttributes(String(line.drop(while: { $0 != ":" }).dropFirst()))
            guard let uriLine = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uriLine, relativeTo: base)?.absoluteURL else { continue }
            result.append(Variant(url: url, bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0, resolution: attributes["RESOLUTION"]))
        }
        return result.sorted { $0.bandwidth > $1.bandwidth }
    }

    public static func media(_ text: String, base: URL) -> MediaPlaylist {
        var playlist = MediaPlaylist()
        var pendingDuration: Double?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                pendingDuration = Double(line.dropFirst(8).split(separator: ",").first ?? "0") ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = parseAttributes(String(line.dropFirst(11)))
                let method = attributes["METHOD"] ?? "NONE"
                if method != "NONE" { playlist.encryption = method }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = parseAttributes(String(line.dropFirst(11)))
                if let uri = attributes["URI"] { playlist.initSegment = URL(string: uri, relativeTo: base)?.absoluteURL }
            } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: base)?.absoluteURL {
                playlist.segments.append(Segment(url: url, duration: pendingDuration ?? 0))
                pendingDuration = nil
            }
        }
        return playlist
    }

    static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, inQuotes = false
        func flush() {
            if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
            key = ""; value = ""; inKey = true
        }
        for c in text {
            if inKey {
                if c == "=" { inKey = false } else if c != "," { key.append(c) }
            } else if c == "\"" {
                inQuotes.toggle()
            } else if c == ",", !inQuotes {
                flush()
            } else {
                value.append(c)
            }
        }
        flush()
        return result
    }
}
