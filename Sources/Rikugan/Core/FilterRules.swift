import Foundation

/// Converts Adblock-style URL patterns (`||example.com^`, `|https://`, `*`) to the regular
/// expression subset accepted by WebKit content rule lists.
public enum ABPPattern {
    public static let domainAnchor = "^[a-z][a-z0-9.+-]*://([a-z0-9.-]+\\.)?"
    /// ABP separator: any character except a letter, digit, `_`, `-`, `.` or `%`.
    public static let separator = "[^a-zA-Z0-9_.%-]"

    public static func regex(_ pattern: String) -> String? {
        var text = pattern
        guard text.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        var prefix = ""
        var suffix = ""
        if text.hasPrefix("||") { prefix = domainAnchor; text.removeFirst(2) }
        else if text.hasPrefix("|") { prefix = "^"; text.removeFirst() }
        if text.hasSuffix("|") { suffix = "$"; text.removeLast() }
        while text.hasPrefix("*") { text.removeFirst(); if prefix == "^" { prefix = "" } }
        while text.hasSuffix("*") { text.removeLast(); suffix = "" }
        var body = ""
        let chars = Array(text)
        for (index, c) in chars.enumerated() {
            switch c {
            case "*": body += ".*"
            case "^":
                // A trailing `^` also matches the end of the address — "a separator (and anything
                // after it) or nothing". It must never match a letter/digit, so
                // `||ads.example.com^` does not match ads.example.com.evil.test or ads.example.company.
                body += index == chars.count - 1 && suffix.isEmpty ? "(" + separator + ".*)?$" : separator
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "$", "|", "\\": body += "\\" + String(c)
            default: body.append(c)
            }
        }
        if prefix == domainAnchor, body.isEmpty { return nil }
        let result = prefix + body + suffix
        if result.isEmpty { return ".*" }
        return result
    }

    /// WebKit only supports a subset of regular expressions. Converts common shorthand classes and
    /// rejects unsupported constructs (alternation, counted repetition, look-around, backrefs).
    public static func webKitRegex(from regex: String) -> String? {
        guard regex.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        var out = ""
        let chars = Array(regex)
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "d": out += inClass ? "0-9" : "[0-9]"
                case "w": out += inClass ? "a-zA-Z0-9_" : "[a-zA-Z0-9_]"
                case "s": out += inClass ? " \\t" : "[ \\t]"
                case "D", "W", "S", "b", "B": return nil
                case "1", "2", "3", "4", "5", "6", "7", "8", "9": return nil
                default: out += "\\" + String(n)
                }
                i += 2; continue
            }
            if inClass {
                if c == "]" { inClass = false }
                out.append(c); i += 1; continue
            }
            switch c {
            case "[": inClass = true; out.append(c)
            case "|", "{": return nil
            case "(":
                if i + 1 < chars.count, chars[i + 1] == "?" {
                    // Allow non-capturing groups by turning them into capturing ones.
                    if i + 2 < chars.count, chars[i + 2] == ":" { out.append("("); i += 3; continue }
                    return nil
                }
                out.append(c)
            default: out.append(c)
            }
            i += 1
        }
        return out
    }
}

public enum FilterResourceType: String, CaseIterable, Codable {
    case document, image, styleSheet = "style-sheet", script, font, raw, svgDocument = "svg-document", media, popup, ping, other

    static func from(option: String) -> [FilterResourceType]? {
        switch option {
        case "script": return [.script]
        case "image": return [.image]
        case "stylesheet", "css": return [.styleSheet]
        case "font": return [.font]
        case "media": return [.media]
        case "xmlhttprequest", "xhr", "websocket", "fetch": return [.raw]
        case "subdocument", "frame": return [.document]
        case "document", "doc": return [.document]
        case "popup": return [.popup]
        case "ping", "beacon": return [.ping]
        case "object", "object-subrequest", "other", "webrtc": return [.other]
        default: return nil
        }
    }
}

/// A network filtering rule in a portable form, convertible into WebKit JSON.
public struct NetworkRule: Hashable {
    public enum Action: Hashable { case block, allow, allowDocument, upgradeScheme, redirect, modifyHeaders }
    public var action: Action
    public var urlRegex: String
    public var caseSensitive = false
    public var resourceTypes: [FilterResourceType] = []
    public var thirdParty: Bool?
    public var ifDomains: [String] = []
    public var unlessDomains: [String] = []
    public var loadContext: [String] = []
    /// Serialized WebKit action object for redirect / modify-headers rules.
    public var actionJSON: String?
    public var priority: Int?

    public func webKitJSON() -> [String: Any] {
        var trigger: [String: Any] = ["url-filter": urlRegex]
        if caseSensitive { trigger["url-filter-is-case-sensitive"] = true }
        if !resourceTypes.isEmpty { trigger["resource-type"] = Array(Set(resourceTypes.map(\.rawValue))).sorted() }
        if let thirdParty { trigger["load-type"] = [thirdParty ? "third-party" : "first-party"] }
        if !ifDomains.isEmpty { trigger["if-domain"] = ifDomains.map { "*" + $0.lowercased() } }
        else if !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains.map { "*" + $0.lowercased() } }
        if !loadContext.isEmpty { trigger["load-context"] = loadContext }
        let actionType: String
        switch action {
        case .block: actionType = "block"
        case .allow, .allowDocument: actionType = "ignore-previous-rules"
        case .upgradeScheme: actionType = "make-https"
        case .redirect, .modifyHeaders:
            let action = actionJSON.flatMap { JSONText.decode($0) as? [String: Any] } ?? ["type": "block"]
            return ["trigger": trigger, "action": action]
        }
        return ["trigger": trigger, "action": ["type": actionType]]
    }
}

/// Cosmetic (element hiding) index: generic and per-domain selectors plus exceptions.
public struct CosmeticIndex: Codable, Equatable {
    public var generic: [String] = []
    /// Generic selectors that must not apply on the listed domains (`~a.com##.ad`).
    public var genericExcept: [String: [String]] = [:]
    public var specific: [String: [String]] = [:]
    public var exceptions: [String: [String]] = [:]
    public var cssInjections: [String: [String]] = [:]
    public var genericCSSInjections: [String] = []
    public var elemhideDomains: Set<String> = []
    public var generichideDomains: Set<String> = []

    public init() {}

    public var selectorCount: Int { generic.count + specific.values.reduce(0) { $0 + $1.count } }

    public mutating func merge(_ other: CosmeticIndex) {
        generic += other.generic
        genericExcept.merge(other.genericExcept) { $0 + $1 }
        specific.merge(other.specific) { $0 + $1 }
        exceptions.merge(other.exceptions) { $0 + $1 }
        cssInjections.merge(other.cssInjections) { $0 + $1 }
        genericCSSInjections += other.genericCSSInjections
        elemhideDomains.formUnion(other.elemhideDomains)
        generichideDomains.formUnion(other.generichideDomains)
    }

    /// Selectors and CSS declarations that apply on `host`.
    public func rules(forHost host: String) -> (selectors: [String], css: [String]) {
        let suffixes = DomainTools.suffixes(of: host)
        if suffixes.contains(where: elemhideDomains.contains) { return ([], []) }
        var excluded = Set<String>()
        for suffix in suffixes { excluded.formUnion(exceptions[suffix] ?? []) }
        var selectors: [String] = []
        var seen = Set<String>()
        let genericDisabled = suffixes.contains(where: generichideDomains.contains)
        if !genericDisabled {
            for selector in generic where !excluded.contains(selector) {
                if let blocked = genericExcept[selector], suffixes.contains(where: blocked.contains) { continue }
                if seen.insert(selector).inserted { selectors.append(selector) }
            }
        }
        var css = genericDisabled ? [] : genericCSSInjections
        for suffix in suffixes {
            for selector in specific[suffix] ?? [] where !excluded.contains(selector) {
                if seen.insert(selector).inserted { selectors.append(selector) }
            }
            css += cssInjections[suffix] ?? []
        }
        return (selectors, css)
    }
}

public struct FilterParseResult {
    public var network: [NetworkRule] = []
    public var cosmetic = CosmeticIndex()
    public var unsupported = 0
    public var comments = 0
    public var total = 0
    public init() {}
}

/// AdGuard / Adblock Plus filter list parser.
public enum FilterListParser {
    static let unsupportedCosmeticMarkers = ["#?#", "#@?#", "#%#", "#@%#", "##+js", "#@#+js", "##^", "#@#^", "$$", "$@$"]
    static let extendedPseudo = [":-abp-", ":has-text(", ":contains(", ":matches-css", ":xpath(", ":upward(", ":remove(",
                                 ":matches-attr(", ":matches-property(", ":nth-ancestor(", ":min-text-length(", ":watch-attr(",
                                 ":matches-path(", ":others(", ":if(", ":if-not(", ":style(", ":-ext-"]
    static let unsupportedOptions: Set<String> = ["redirect", "redirect-rule", "removeparam", "queryprune", "csp", "replace", "cookie",
                                                  "header", "removeheader", "hls", "jsonprune", "xmlprune", "network", "app", "permissions",
                                                  "denyallow", "badfilter", "rewrite", "empty", "mp4", "extension", "stealth", "urltransform",
                                                  "to", "method", "strict1p", "strict3p", "referrerpolicy", "specifichide", "shide"]

    public static func parse(_ text: String) -> FilterParseResult {
        var result = FilterParseResult()
        text.enumerateLines { line, _ in
            parseLine(line.trimmingCharacters(in: .whitespaces), into: &result)
        }
        return result
    }

    public static func parseLine(_ rawLine: String, into result: inout FilterParseResult) {
        var line = rawLine
        guard !line.isEmpty else { return }
        for prefix in ["0.0.0.0 ", "127.0.0.1 ", "0.0.0.0\t", "127.0.0.1\t"] where line.hasPrefix(prefix) {
            let host = line.dropFirst(prefix.count).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "#" }).first.map(String.init) ?? ""
            guard !host.isEmpty, host != "localhost", host != "0.0.0.0" else { return }
            line = "||" + host + "^"
        }
        result.total += 1
        if line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("#!") || line.hasPrefix("# ") || line == "#" {
            result.comments += 1; return
        }
        if unsupportedCosmeticMarkers.contains(where: { line.contains($0) }) && !line.hasPrefix("/") && !line.hasPrefix("|") {
            result.unsupported += 1; return
        }
        if let range = line.range(of: "#@$#") ?? line.range(of: "#$#") {
            let isException = line[range].hasPrefix("#@")
            let domains = parseDomainList(String(line[..<range.lowerBound]), separator: ",")
            let body = String(line[range.upperBound...])
            guard !isException, body.contains("{"), body.hasSuffix("}"), !extendedPseudo.contains(where: body.contains) else {
                result.unsupported += 1; return
            }
            if domains.include.isEmpty { result.cosmetic.genericCSSInjections.append(body) }
            for domain in domains.include { result.cosmetic.cssInjections[domain, default: []].append(body) }
            return
        }
        if let range = line.range(of: "#@#") {
            let domains = parseDomainList(String(line[..<range.lowerBound]), separator: ",")
            let selector = String(line[range.upperBound...])
            guard !selector.isEmpty else { return }
            if domains.include.isEmpty {
                // Generic exception: disable the selector everywhere.
                result.cosmetic.generic.removeAll { $0 == selector }
            }
            for domain in domains.include { result.cosmetic.exceptions[domain, default: []].append(selector) }
            return
        }
        if let range = line.range(of: "##") {
            let domains = parseDomainList(String(line[..<range.lowerBound]), separator: ",")
            let selector = String(line[range.upperBound...])
            guard !selector.isEmpty, isSupportedSelector(selector) else { result.unsupported += 1; return }
            if domains.include.isEmpty {
                result.cosmetic.generic.append(selector)
                if !domains.exclude.isEmpty { result.cosmetic.genericExcept[selector, default: []] += domains.exclude }
            } else {
                for domain in domains.include { result.cosmetic.specific[domain, default: []].append(selector) }
                for domain in domains.exclude { result.cosmetic.exceptions[domain, default: []].append(selector) }
            }
            return
        }
        guard let rule = parseNetwork(line, cosmetic: &result.cosmetic) else { result.unsupported += 1; return }
        if let rule { result.network.append(rule) }
    }

    static func isSupportedSelector(_ selector: String) -> Bool {
        guard selector.count < 2000, !selector.contains("{"), !selector.contains("}") else { return false }
        let lower = selector.lowercased()
        return !extendedPseudo.contains(where: lower.contains)
    }

    public static func parseDomainList(_ text: String, separator: Character) -> (include: [String], exclude: [String]) {
        var include: [String] = [], exclude: [String] = []
        for raw in text.split(separator: separator) {
            var domain = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !domain.isEmpty else { continue }
            let negated = domain.hasPrefix("~")
            if negated { domain.removeFirst() }
            if domain.hasSuffix(".*") { domain = String(domain.dropLast(2)) } // tld wildcard – approximate
            guard !domain.contains("/"), !domain.isEmpty else { continue }
            if negated { exclude.append(domain) } else { include.append(domain) }
        }
        return (include, exclude)
    }

    /// Returns `nil` when unsupported, `.some(nil)` when the rule only affected cosmetic state.
    static func parseNetwork(_ original: String, cosmetic: inout CosmeticIndex) -> NetworkRule?? {
        var line = original
        var exception = false
        if line.hasPrefix("@@") { exception = true; line.removeFirst(2) }
        var pattern = line
        var options: [String] = []
        if let dollar = optionsSeparator(line) {
            pattern = String(line[..<dollar])
            options = line[line.index(after: dollar)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        var rule = NetworkRule(action: exception ? .allow : .block, urlRegex: ".*")
        var types: [FilterResourceType] = []
        var excludedTypes: [FilterResourceType] = []
        var documentLevel = false
        var elemhide = false, generichide = false
        for option in options {
            let negated = option.hasPrefix("~")
            let name = negated ? String(option.dropFirst()) : option
            let key = name.split(separator: "=", maxSplits: 1).first.map(String.init) ?? name
            if unsupportedOptions.contains(key) { return nil }
            switch key {
            case "third-party", "3p": rule.thirdParty = !negated
            case "first-party", "1p": rule.thirdParty = negated
            case "match-case": rule.caseSensitive = !negated
            case "important", "all": break
            case "domain", "from":
                let value = name.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                let parsed = parseDomainList(value, separator: "|")
                rule.ifDomains = parsed.include; rule.unlessDomains = parsed.exclude
            case "elemhide", "ehide": elemhide = true
            case "generichide", "ghide": generichide = true
            case "content", "jsinject", "urlblock", "genericblock", "stealth": documentLevel = true
            case "document", "doc":
                if exception { documentLevel = true } else { types += [.document]; rule.loadContext = ["top-frame"] }
            case "subdocument", "frame":
                if negated { excludedTypes += [.document] } else { types += [.document]; rule.loadContext = ["child-frame"] }
            default:
                guard let mapped = FilterResourceType.from(option: key) else { return nil }
                if negated { excludedTypes += mapped } else { types += mapped }
            }
        }
        let host = hostOfDomainPattern(pattern)
        if exception && (elemhide || generichide) {
            if let host {
                if elemhide { cosmetic.elemhideDomains.insert(host) }
                if generichide { cosmetic.generichideDomains.insert(host) }
            }
            if !documentLevel && types.isEmpty { return .some(nil) }
        }
        if !excludedTypes.isEmpty && types.isEmpty {
            types = FilterResourceType.allCases.filter { !excludedTypes.contains($0) && $0 != .popup }
        }
        rule.resourceTypes = types
        if exception && documentLevel {
            guard let host else { return nil }
            rule.action = .allowDocument
            rule.urlRegex = ".*"
            rule.ifDomains = [host]
            rule.resourceTypes = []
            return .some(rule)
        }
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            guard let regex = ABPPattern.webKitRegex(from: String(pattern.dropFirst().dropLast())) else { return nil }
            rule.urlRegex = regex
        } else {
            guard let regex = ABPPattern.regex(pattern) else { return nil }
            rule.urlRegex = regex
        }
        if rule.urlRegex == ".*", rule.ifDomains.isEmpty, rule.resourceTypes.isEmpty, !exception { return nil }
        return .some(rule)
    }

    static func optionsSeparator(_ line: String) -> String.Index? {
        guard let dollar = line.lastIndex(of: "$") else { return nil }
        let after = line[line.index(after: dollar)...]
        if after.isEmpty { return nil }
        // A trailing `$/` belongs to a regex, not options.
        if line.hasPrefix("/") && after.contains("/") && !after.contains("=") { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~,=|.*:/&%")
        return after.unicodeScalars.allSatisfy(allowed.contains) ? dollar : nil
    }

    static func hostOfDomainPattern(_ pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        let rest = pattern.dropFirst(2)
        let end = rest.firstIndex(where: { "^/*|:".contains($0) }) ?? rest.endIndex
        let host = String(rest[..<end]).lowercased()
        return host.isEmpty ? nil : host
    }
}

/// Converts network rules into one or more WebKit content rule list JSON documents.
public enum ContentBlockerCompiler {
    public static let maxRulesPerList = 45_000

    public static func compile(_ rules: [NetworkRule], allowlistedHosts: [String]) -> [String] {
        let blocking = rules.filter { $0.action == .block || $0.action == .upgradeScheme || $0.action == .redirect || $0.action == .modifyHeaders }
        let exceptions = rules.filter { $0.action == .allow || $0.action == .allowDocument }
        var allow: [[String: Any]] = exceptions.map { $0.webKitJSON() }
        if !allowlistedHosts.isEmpty {
            for chunk in stride(from: 0, to: allowlistedHosts.count, by: 200) {
                let hosts = Array(allowlistedHosts[chunk..<min(chunk + 200, allowlistedHosts.count)])
                allow.append(["trigger": ["url-filter": ".*", "if-domain": hosts.map { "*" + $0 }],
                              "action": ["type": "ignore-previous-rules"]])
            }
        }
        let budget = max(1000, maxRulesPerList - allow.count)
        var documents: [String] = []
        var index = 0
        repeat {
            let slice = blocking[index..<min(index + budget, blocking.count)]
            let list: [[String: Any]] = slice.map { $0.webKitJSON() } + allow
            if !slice.isEmpty || documents.isEmpty {
                let payload: [[String: Any]] = list.isEmpty ? [placeholderRule] : list
                documents.append(JSONText.encode(payload))
            }
            index += budget
        } while index < blocking.count
        return documents
    }

    /// WebKit rejects empty lists; this rule never matches.
    public static let placeholderRule: [String: Any] = [
        "trigger": ["url-filter": "^rikugan-never-match://"], "action": ["type": "block"],
    ]
}
