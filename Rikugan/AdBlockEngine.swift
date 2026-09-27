import Foundation

/// AdGuard-compatible subset: network rules, exceptions, and cosmetic element hiding.
enum AdBlockEngine {
    struct Compiled: Equatable {
        var json: String
        var networkJSON: String
        var globalCSS: String
        var hostSelectors: [String: [String]]
        var blockedSamples: [String]
    }

    static let builtin: [String] = [
        "||doubleclick.net^", "||googlesyndication.com^", "||googleadservices.com^",
        "||google-analytics.com^", "||googletagservices.com^", "||googletagmanager.com^",
        "||adservice.google.com^", "||adnxs.com^", "||adsrvr.org^", "||amazon-adsystem.com^",
        "||scorecardresearch.com^", "||outbrain.com^", "||taboola.com^", "||criteo.com^",
        "||criteo.net^", "||rubiconproject.com^", "||pubmatic.com^", "||openx.net^",
        "||moatads.com^", "||chartbeat.com^", "||hotjar.com^", "||connect.facebook.net^",
        "||ads.yahoo.com^", "||ads-twitter.com^", "||securepubads.g.doubleclick.net^",
        "##.adsbygoogle", "##.ad-banner", "##ins.adsbygoogle", "##[id^=\"div-gpt-ad\"]",
        "##[id^=\"google_ads_iframe\"]", "##.taboola-recommended", "##.OUTBRAIN"
    ]

    enum Verdict: String { case block, allow, none }

    static func lines(settings: BrowserSettings) -> [String] {
        guard settings.contentBlocking else { return [] }
        var rows: [String] = []
        if settings.builtInRules { rows.append(contentsOf: builtin) }
        for rule in settings.customRules where rule.enabled { rows.append(rule.text) }
        for subscription in settings.subscriptions where subscription.enabled {
            rows.append(contentsOf: subscription.body.components(separatedBy: .newlines))
        }
        return rows
    }

    static func compile(lines input: [String], limit: Int = 1500) -> Compiled {
        var network: [[String: Any]] = []
        var allows: [[String: Any]] = []
        var global: [String] = []
        var hosts: [String: [String]] = [:]
        var exceptions = Set<String>()
        for raw in input.prefix(8000) {
            guard let rule = parse(raw) else { continue }
            switch rule {
            case .allow(let filter):
                if let trigger = trigger(filter) { allows.append(["trigger": trigger, "action": ["type": "ignore-previous-rules"]]) }
            case .block(let filter, let options):
                if var trigger = trigger(filter) {
                    if let types = options.resourceTypes { trigger["resource-type"] = types }
                    if options.thirdParty == true { trigger["load-type"] = ["third-party"] }
                    if options.thirdParty == false { trigger["load-type"] = ["first-party"] }
                    if !options.ifDomains.isEmpty { trigger["if-domain"] = options.ifDomains }
                    if !options.unlessDomains.isEmpty { trigger["unless-domain"] = options.unlessDomains }
                    network.append(["trigger": trigger, "action": ["type": "block"]])
                }
            case .cosmetic(let domains, let selector):
                guard safe(selector) else { continue }
                if domains.isEmpty { global.append(selector) }
                else { for domain in domains { hosts[domain, default: []].append(selector) } }
            case .unhide(let selector):
                exceptions.insert(selector)
            }
        }
        global.removeAll { exceptions.contains($0) }
        for key in hosts.keys { hosts[key]?.removeAll { exceptions.contains($0) } }
        var cosmetic: [[String: Any]] = []
        if !global.isEmpty {
            cosmetic.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": global.prefix(200).joined(separator: ", ")]])
        }
        for (host, selectors) in hosts.prefix(200) where !selectors.isEmpty {
            cosmetic.append([
                "trigger": ["url-filter": ".*", "if-domain": [host]],
                "action": ["type": "css-display-none", "selector": selectors.prefix(40).joined(separator: ", ")]
            ])
        }
        let networkCapped = Array(network.prefix(limit))
        let full = allows + networkCapped + cosmetic
        return Compiled(
            json: stringify(full),
            networkJSON: stringify(allows + networkCapped),
            globalCSS: global.isEmpty ? "" : global.prefix(200).joined(separator: ",") + "{display:none!important}",
            hostSelectors: hosts.mapValues { Array($0.prefix(40)) },
            blockedSamples: []
        )
    }

    static func verdict(url: URL, lines: [String]) -> Verdict {
        guard let host = url.host?.lowercased() else { return .none }
        let absolute = url.absoluteString.lowercased()
        var blocked = false
        for raw in lines {
            guard let rule = parse(raw) else { continue }
            switch rule {
            case .allow(let filter):
                if matches(filter, host: host, absolute: absolute) { return .allow }
            case .block(let filter, _):
                if matches(filter, host: host, absolute: absolute) { blocked = true }
            default:
                break
            }
        }
        return blocked ? .block : .none
    }

    private enum Rule {
        case block(String, Options)
        case allow(String)
        case cosmetic([String], String)
        case unhide(String)
    }
    private struct Options {
        var thirdParty: Bool?
        var resourceTypes: [String]?
        var ifDomains: [String] = []
        var unlessDomains: [String] = []
    }

    private static func parse(_ raw: String) -> Rule? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("["), !line.hasPrefix("#%#") else { return nil }
        if line.contains("#@#") {
            let selector = line.components(separatedBy: "#@#").last ?? ""
            return safe(selector) ? .unhide(selector) : nil
        }
        if line.contains("#$#") || line.contains("#?#") { return nil }
        if let range = line.range(of: "##") {
            let domainPart = String(line[..<range.lowerBound])
            let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard safe(selector) else { return nil }
            let domains = domainPart.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "~", with: "") }.filter { !$0.isEmpty }
            return .cosmetic(domains, selector)
        }
        var body = line
        var allow = false
        if body.hasPrefix("@@") { allow = true; body.removeFirst(2) }
        var options = Options()
        if let dollar = body.lastIndex(of: "$"), body[..<dollar].contains("/") || body.hasPrefix("||") || body.hasPrefix("|") {
            let mods = body[body.index(after: dollar)...]
            body = String(body[..<dollar])
            guard apply(&options, modifiers: String(mods)) else { return nil }
        }
        guard body.hasPrefix("||") || body.hasPrefix("|") else { return nil }
        return allow ? .allow(body) : .block(body, options)
    }

    private static func apply(_ options: inout Options, modifiers: String) -> Bool {
        var types: [String] = []
        for part in modifiers.split(separator: ",") {
            let token = String(part)
            switch token {
            case "third-party": options.thirdParty = true
            case "~third-party": options.thirdParty = false
            case "script": types.append("script")
            case "image": types.append("image")
            case "stylesheet": types.append("style-sheet")
            case "xmlhttprequest": types.append("raw")
            case "media": types.append("media")
            case "font": types.append("font")
            case "document", "other", "important", "ping", "websocket", "popup", "all": break
            default:
                if token.hasPrefix("domain=") {
                    for domain in token.dropFirst(7).split(separator: "|") {
                        let value = String(domain)
                        if value.hasPrefix("~") { options.unlessDomains.append(String(value.dropFirst())) }
                        else { options.ifDomains.append(value) }
                    }
                } else if token.contains("=") { return false }
                else { return false }
            }
        }
        if !types.isEmpty { options.resourceTypes = types }
        return true
    }

    private static func matches(_ filter: String, host: String, absolute: String) -> Bool {
        var pattern = filter
        if pattern.hasPrefix("|") && !pattern.hasPrefix("||") { pattern.removeFirst() }
        let anchored = pattern.hasPrefix("||")
        if anchored { pattern.removeFirst(2) }
        pattern = pattern.replacingOccurrences(of: "^", with: "")
        let pieces = pattern.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let domain = String(pieces.first ?? "").lowercased()
        guard !domain.isEmpty else { return false }
        let hostOK = host == domain || host.hasSuffix("." + domain)
        guard anchored ? hostOK : absolute.contains(domain) else { return false }
        if pieces.count > 1 {
            let path = "/" + pieces[1].lowercased()
            guard absolute.contains(path) || absolute.contains(domain + path) else { return false }
        }
        return true
    }

    private static func trigger(_ filter: String) -> [String: Any]? {
        var pattern = filter
        if pattern.hasPrefix("|") && !pattern.hasPrefix("||") { pattern.removeFirst() }
        guard pattern.hasPrefix("||") else { return nil }
        pattern.removeFirst(2)
        pattern = pattern.replacingOccurrences(of: "^", with: "")
        let parts = pattern.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let domain = String(parts.first ?? "")
        guard domain.range(of: #"^[A-Za-z0-9.*-]+$"#, options: .regularExpression) != nil else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: domain.replacingOccurrences(of: "*.", with: ""))
        let host = "^https?://([^/?#]*\\.)?" + escaped
        let regex = parts.count > 1 ? host + "/" + NSRegularExpression.escapedPattern(for: String(parts[1])) : host + "([/?#]|$)"
        return ["url-filter": regex, "url-filter-is-case-sensitive": false]
    }

    private static func safe(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count < 240, !selector.contains("{"), !selector.contains("<"), !selector.contains("\\") else { return false }
        return selector.range(of: #"^[A-Za-z0-9_\-.#:\[\]="~|^$* >+(),]+$"#, options: .regularExpression) != nil
    }

    private static func stringify(_ rules: [[String: Any]]) -> String {
        guard JSONSerialization.isValidJSONObject(rules), let data = try? JSONSerialization.data(withJSONObject: rules),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
