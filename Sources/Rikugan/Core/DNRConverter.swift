import Foundation

/// Converts `chrome.declarativeNetRequest` rules into WebKit content rule list JSON.
/// Supported actions: block, allow, allowAllRequests, upgradeScheme. Others are reported.
public enum DNRConverter {
    public struct Output {
        public var rules: [NetworkRule] = []
        public var skipped: [(id: Int, reason: String)] = []
    }

    public static func convert(_ rules: [[String: Any]]) -> Output {
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
            case "redirect", "modifyHeaders":
                output.skipped.append((id, "不支持的动作 \(type)")); continue
            default:
                output.skipped.append((id, "未知动作 \(type)")); continue
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
            if !requestDomains.isEmpty {
                // Combining a request domain with an arbitrary filter is not expressible; keep the filter then.
                if regexes == [".*"] {
                    regexes = requestDomains.map { ABPPattern.domainAnchor + URLMatcher.escape($0.lowercased()) + ABPPattern.separator }
                }
            }
            var base = NetworkRule(action: mapped, urlRegex: ".*")
            base.caseSensitive = condition["isUrlFilterCaseSensitive"] as? Bool ?? false
            if let domainType = condition["domainType"] as? String { base.thirdParty = domainType == "thirdParty" }
            let initiators = (condition["initiatorDomains"] as? [String]) ?? (condition["domains"] as? [String]) ?? []
            let excludedInitiators = (condition["excludedInitiatorDomains"] as? [String]) ?? (condition["excludedDomains"] as? [String]) ?? []
            base.ifDomains = initiators
            if initiators.isEmpty { base.unlessDomains = excludedInitiators }
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
                // Applies to every request of matching documents.
                base.resourceTypes = []
                if let host = initiators.first ?? requestDomains.first {
                    base.ifDomains = [host]; base.unlessDomains = []
                } else if regexes != [".*"] {
                    output.skipped.append((id, "allowAllRequests 仅支持 initiator / request 域名条件（已近似处理）"))
                }
                regexes = [".*"]
            }
            for regex in regexes {
                var converted = base
                converted.urlRegex = regex
                if mapped == .block || mapped == .upgradeScheme { blocks.append(converted) } else { allows.append(converted) }
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
