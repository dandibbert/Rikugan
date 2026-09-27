import Foundation

/// Compiles built-in rules, user rules, and third-party AdGuard lists.
/// Network and cosmetic rules become WKContentRuleList chunks installed by `BrowserTab.syncContentRules`.
/// `#%#` / `##+js` scriptlets in the built-in set run from `PageTools.applyScriptlets`.
/// `$redirect` and `$redirect-rule` compile as `block` because content rules cannot redirect.
/// noopjs, empty, and 1x1 also install a page scriptlet that defines the empty value
/// (`__rgRedirect.noopjs` / `.empty` / `.pixel`) and prevent-fetch for that host.
/// `$removeparam` is applied to main-frame navigations. `$replace` rewrites text in the page
/// after load and in fetch/XHR bodies; binary responses are left alone.
/// This is not a bundled EasyList.
///
/// WebKit does not publish a hard WKContentRuleList cap. Safari's older content-blocker
/// extension limit was 50_000 rules, and oversized lists fail inside `compileContentRuleList`.
/// Network rules are split into chunks of `limit` (default 50_000). Cosmetic hiding is applied
/// again as CSS so it still works when a chunk is rejected.
enum AdBlockEngine {
    static let chunkDefault = 50_000
    static let maxLines = 500_000

    struct Compiled: Equatable {
        var chunks: [String]
        var networkChunks: [String]
        var json: String
        var networkJSON: String
        var globalCSS: String
        var hostCSS: [String: String]
        var hostSelectors: [String: [String]]
        var proceduralJSON: String
        var scriptletJSON: String
        var cspJSON: String
        var replaceJSON: String
        var removeParams: [QueryStrip]
        var blockedSamples: [String]
    }

    struct BodyReplace: Equatable {
        var needle: String
        var regex: String
        var replacement: String
        var flags: String
    }

    struct QueryStrip: Equatable {
        var domains: [String]
        var key: String
        var regex: Bool
    }

    static let scriptletNames: Set<String> = [
        "abort-on-property-read", "abort-on-property-write", "json-prune", "set-constant", "prevent-fetch", "prevent-xhr"
    ]

    static let builtin: [String] = [
        "||doubleclick.net^", "||googlesyndication.com^", "||googleadservices.com^",
        "||google-analytics.com^", "||googletagservices.com^", "||googletagmanager.com^",
        "||adservice.google.com^", "||pagead2.googlesyndication.com^",
        "||securepubads.g.doubleclick.net^", "||tpc.googlesyndication.com^",
        "||ads.yahoo.com^", "||ads-twitter.com^", "||static.ads-twitter.com^",
        "||adnxs.com^", "||adsrvr.org^", "||amazon-adsystem.com^", "||scorecardresearch.com^",
        "||outbrain.com^", "||taboola.com^", "||criteo.com^", "||criteo.net^",
        "||rubiconproject.com^", "||pubmatic.com^", "||openx.net^", "||moatads.com^",
        "||chartbeat.com^", "||hotjar.com^", "||connect.facebook.net^", "||facebook.net/signals^",
        "||ads.facebook.com^", "||an.facebook.com^", "||ads.linkedin.com^",
        "||ads.reddit.com^", "||ads-api.twitter.com^", "||advertising.com^",
        "||adform.net^", "||adform.com^", "||adroll.com^", "||casalemedia.com^",
        "||contextweb.com^", "||districtm.io^", "||exponential.com^", "||media.net^",
        "||mgid.com^", "||revcontent.com^", "||sharethrough.com^", "||smartadserver.com^",
        "||spotxchange.com^", "||teads.tv^", "||tremorhub.com^", "||yieldmo.com^",
        "||zemanta.com^", "||bidswitch.net^", "||rlcdn.com^", "||bluekai.com^",
        "||exelator.com^", "||demdex.net^", "||omtrdc.net^", "||everesttech.net^",
        "||krxd.net^", "||liadm.com^", "||quantserve.com^", "||scorecardresearch.com^",
        "||imrworldwide.com^", "||newrelic.com^", "||nr-data.net^", "||mixpanel.com^",
        "||segment.io^", "||segment.com^", "||optimizely.com^", "||branch.io^",
        "||appsflyer.com^", "||adjust.com^", "||doubleverify.com^", "||adsafeprotected.com^",
        "||moatpixel.com^", "||serving-sys.com^", "||flashtalking.com^", "||sizmek.com^",
        "||adsymptotic.com^", "||adtechus.com^", "||2mdn.net^", "||googlesyndication.com^$script,third-party",
        "##.adsbygoogle", "##.ad-banner", "##ins.adsbygoogle", "##[id^=\"div-gpt-ad\"]",
        "##[id^=\"google_ads_iframe\"]", "##.taboola-recommended", "##.OUTBRAIN",
        "##iframe[src*=\"doubleclick.net\"]", "##[id^=\"taboola-\"]", "##.ad-container"
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

    static func compile(lines input: [String], limit: Int = chunkDefault) -> Compiled {
        let chunk = max(1, limit)
        var blocks: [[String: Any]] = []
        var allows: [[String: Any]] = []
        var global: [String] = []
        var hosts: [String: [String]] = [:]
        var hostStyle: [String: [String]] = [:]
        var unless: [(String, [String])] = []
        var procedural: [[String: Any]] = []
        var scriptlets: [[String: Any]] = []
        var policies: [[String: Any]] = []
        var strips: [QueryStrip] = []
        var replacements: [[String: String]] = []
        var exceptions = Set<String>()
        for raw in input.prefix(maxLines) {
            guard let rule = parse(raw) else { continue }
            switch rule {
            case .allow(let filter, let options):
                if var trigger = trigger(filter) {
                    apply(options, to: &trigger)
                    allows.append(["trigger": trigger, "action": ["type": "ignore-previous-rules"]])
                }
            case .block(let filter, let options):
                if !options.removeParams.isEmpty {
                    strips.append(contentsOf: options.removeParams.map { QueryStrip(domains: hosts(of: filter), key: $0.key, regex: $0.regex) })
                }
                if let policy = options.csp {
                    policies.append(["domains": hosts(of: filter), "policy": policy])
                }
                if !options.replaces.isEmpty {
                    let needle = hosts(of: filter).first ?? ""
                    for item in options.replaces {
                        replacements.append(["needle": needle, "regex": item.regex, "replacement": item.replacement, "flags": item.flags])
                    }
                }
                if options.prunesJSON, !options.jsonPrunes.isEmpty {
                    scriptlets.append(["domains": hosts(of: filter), "name": "json-prune", "args": [options.jsonPrunes.joined(separator: "|"), needle(of: filter)]])
                }
                if let resource = options.redirectResource {
                    scriptlets.append(contentsOf: redirectStubs(resource: resource, filter: filter))
                }
                let network = options.redirect || (options.removeParams.isEmpty && options.csp == nil && options.replaces.isEmpty && !options.prunesJSON)
                if network, var trigger = trigger(filter) {
                    apply(options, to: &trigger)
                    blocks.append(["trigger": trigger, "action": ["type": "block"]])
                }
            case .scriptlet(let domains, let name, let args):
                scriptlets.append(["domains": domains, "name": name, "args": args])
            case .hide(let include, let exclude, let selector):
                guard safeSelector(selector) else { continue }
                if include.isEmpty && exclude.isEmpty { global.append(selector) }
                else if include.isEmpty { unless.append((selector, exclude)) }
                else { for domain in include { hosts[domain, default: []].append(selector) } }
            case .style(let domains, let css):
                if domains.isEmpty { hostStyle["*", default: []].append(css) }
                else { for domain in domains { hostStyle[domain, default: []].append(css) } }
            case .procedural(let domains, let kind, let selector, let text):
                procedural.append(["domains": domains, "kind": kind, "selector": selector, "text": text])
            case .unhide(let selector):
                exceptions.insert(selector)
            }
        }
        global.removeAll { exceptions.contains($0) }
        for key in hosts.keys { hosts[key]?.removeAll { exceptions.contains($0) } }
        var cosmetic: [[String: Any]] = []
        func hideRule(_ selectors: [String], domains: [String]? = nil, unlessDomains: [String]? = nil) {
            var seen = Set<String>()
            let unique = selectors.filter { seen.insert($0).inserted }
            var index = 0
            while index < unique.count {
                let slice = unique[index..<min(index + 40, unique.count)]
                var trigger: [String: Any] = ["url-filter": ".*"]
                if let domains, !domains.isEmpty { trigger["if-domain"] = domains }
                if let unlessDomains, !unlessDomains.isEmpty { trigger["unless-domain"] = unlessDomains }
                cosmetic.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": slice.joined(separator: ", ")]])
                index += 40
            }
        }
        if !global.isEmpty { hideRule(global) }
        for (host, selectors) in hosts where !selectors.isEmpty { hideRule(selectors, domains: [host]) }
        for (selector, excluded) in unless { hideRule([selector], unlessDomains: excluded) }
        global = capped(global, budget: 350_000)
        for key in hosts.keys { hosts[key] = capped(hosts[key] ?? [], budget: 20_000) }
        let network = allows + blocks
        let full = network + cosmetic
        var hostCSS: [String: String] = [:]
        for (host, selectors) in hosts where !selectors.isEmpty {
            hostCSS[host, default: ""] += selectors.joined(separator: ",") + "{display:none!important}"
        }
        for (host, styles) in hostStyle {
            hostCSS[host, default: ""] += styles.joined(separator: "\n")
        }
        let proceduralData = (try? JSONSerialization.data(withJSONObject: procedural)) ?? Data("[]".utf8)
        let scriptletData = (try? JSONSerialization.data(withJSONObject: scriptlets)) ?? Data("[]".utf8)
        let cspData = (try? JSONSerialization.data(withJSONObject: policies)) ?? Data("[]".utf8)
        let replaceData = (try? JSONSerialization.data(withJSONObject: replacements)) ?? Data("[]".utf8)
        return Compiled(
            chunks: pack(full, size: chunk),
            networkChunks: pack(network, size: chunk),
            json: stringify(Array(full.prefix(chunk))),
            networkJSON: stringify(Array(network.prefix(chunk))),
            globalCSS: global.isEmpty ? "" : global.joined(separator: ",") + "{display:none!important}",
            hostCSS: hostCSS,
            hostSelectors: hosts,
            proceduralJSON: String(data: proceduralData, encoding: .utf8) ?? "[]",
            scriptletJSON: String(data: scriptletData, encoding: .utf8) ?? "[]",
            cspJSON: String(data: cspData, encoding: .utf8) ?? "[]",
            replaceJSON: String(data: replaceData, encoding: .utf8) ?? "[]",
            removeParams: strips,
            blockedSamples: []
        )
    }

    static func urlByStripping(_ url: URL, rules: [QueryStrip]) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var items = components.queryItems, !items.isEmpty else { return nil }
        let host = url.host?.lowercased() ?? ""
        var changed = false
        for rule in rules {
            let domains = rule.domains.map { $0.lowercased() }
            if !domains.isEmpty && !domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { continue }
            let before = items.count
            if rule.key.isEmpty { items.removeAll() }
            else if rule.regex { items.removeAll { $0.name.range(of: rule.key, options: .regularExpression) != nil } }
            else { items.removeAll { $0.name == rule.key } }
            if items.count != before { changed = true }
        }
        guard changed else { return nil }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    static func verdict(url: URL, lines: [String], kind: String = "") -> Verdict {
        guard let host = url.host?.lowercased() else { return .none }
        let absolute = url.absoluteString.lowercased()
        let wanted = canonicalResource(kind)
        var blocked = false
        for raw in lines {
            guard let rule = parse(raw) else { continue }
            switch rule {
            case .allow(let filter, let options):
                if matches(filter, host: host, absolute: absolute), resourceAllows(options, kind: wanted) { return .allow }
            case .block(let filter, let options):
                if matches(filter, host: host, absolute: absolute), resourceAllows(options, kind: wanted) { blocked = true }
            default:
                break
            }
        }
        return blocked ? .block : .none
    }

    static func canonicalResource(_ kind: String) -> String {
        switch kind.lowercased() {
        case "": return ""
        case "navigation", "document", "main_frame", "main-frame", "sub_frame", "subframe": return "document"
        case "fetch", "xhr", "xmlhttprequest": return "raw"
        case "image": return "image"
        case "script": return "script"
        case "css", "stylesheet", "style-sheet": return "style-sheet"
        case "media", "hls", "m3u8": return "media"
        case "download": return "download"
        default: return kind.lowercased()
        }
    }

    private static func resourceAllows(_ options: Options, kind: String) -> Bool {
        guard !kind.isEmpty, let types = options.resourceTypes, !types.isEmpty else { return true }
        return types.contains(kind)
    }

    private enum Rule {
        case block(String, Options)
        case allow(String, Options)
        case hide([String], [String], String)
        case style([String], String)
        case procedural([String], String, String, String)
        case scriptlet([String], String, [String])
        case unhide(String)
    }
    private struct ParamRule {
        var key: String
        var regex: Bool
    }
    private struct Options {
        var thirdParty: Bool?
        var resourceTypes: [String]?
        var ifDomains: [String] = []
        var unlessDomains: [String] = []
        var redirect = false
        var redirectResource: String?
        var removeParams: [ParamRule] = []
        var csp: String?
        var replaces: [(regex: String, replacement: String, flags: String)] = []
        var prunesJSON = false
        var jsonPrunes: [String] = []
    }

    private static func parse(_ raw: String) -> Rule? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { return nil }
        if line.contains("#%#") || line.contains("##+js(") { return scriptletRule(line) }
        if line.contains("#@?#") || line.contains("#@$#") || line.contains("#@#") {
            let selector = line.components(separatedBy: "#@").last?.trimmingCharacters(in: CharacterSet(charactersIn: "#?$ ")) ?? ""
            let cosmetic = selector.split(separator: "#", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? selector
            return cosmetic.isEmpty ? nil : .unhide(cosmetic)
        }
        if let range = line.range(of: "#?#") {
            let domains = domainList(String(line[..<range.lowerBound])).include
            let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let procedural = procedural(selector) {
                return .procedural(domains, procedural.kind, procedural.selector, procedural.text)
            }
            guard safeSelector(selector) else { return nil }
            return .hide(domains, [], selector)
        }
        if let range = line.range(of: "#$#") {
            let domains = domainList(String(line[..<range.lowerBound])).include
            let css = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return safeCSS(css) ? .style(domains, css) : nil
        }
        if let range = line.range(of: "##") {
            let parsed = domainList(String(line[..<range.lowerBound]))
            let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard safeSelector(selector) else { return nil }
            return .hide(parsed.include, parsed.exclude, selector)
        }
        var body = line
        var allow = false
        if body.hasPrefix("@@") { allow = true; body.removeFirst(2) }
        let split = splitOptions(body)
        body = split.pattern
        var options = Options()
        if let mods = split.modifiers, !apply(&options, modifiers: mods) { return nil }
        guard !body.isEmpty else { return nil }
        return allow ? .allow(body, options) : .block(body, options)
    }

    private static func scriptletRule(_ line: String) -> Rule? {
        let domains: [String]
        let body: String
        if let range = line.range(of: "#%#") {
            domains = domainList(String(line[..<range.lowerBound])).include
            body = String(line[range.upperBound...])
        } else if let range = line.range(of: "##+js(") {
            domains = domainList(String(line[..<range.lowerBound])).include
            body = String(line[range.upperBound...])
        } else { return nil }
        guard let parsed = scriptletCall(body) else { return nil }
        return .scriptlet(domains, parsed.name, parsed.args)
    }

    private static func scriptletCall(_ body: String) -> (name: String, args: [String])? {
        var text = body.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("//scriptlet(") { text = String(text.dropFirst("//scriptlet(".count)) }
        if text.hasSuffix(")") { text.removeLast() }
        var args: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let quote, character == quote { quote = nil; continue }
            if quote == nil, character == "'" || character == "\"" { quote = character; continue }
            if quote == nil, character == "," { args.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(character)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty || !args.isEmpty { args.append(tail) }
        guard let name = args.first?.trimmingCharacters(in: .whitespaces), scriptletNames.contains(name) else { return nil }
        return (name, args.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private static func parseReplace(_ raw: String) -> (regex: String, replacement: String, flags: String)? {
        guard raw.hasPrefix("/") else { return nil }
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in raw.dropFirst() {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == "/" { parts.append(current); current = ""; if parts.count == 3 { break }; continue }
            current.append(character)
        }
        if parts.count == 2 { parts.append(current) }
        guard parts.count >= 2, !parts[0].isEmpty, parts[0].count < 300, parts[1].count < 300 else { return nil }
        let flags = parts.count > 2 ? String(parts[2].prefix(8).filter { "gimsuy".contains($0) }) : ""
        return (parts[0], parts[1], flags)
    }

    private static func redirectStubs(resource: String, filter: String) -> [[String: Any]] {
        let domains = hosts(of: filter)
        let pattern = domains.first ?? ""
        let key = resource.lowercased()
        let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        let constant: [String]
        switch key {
        case "noopjs", "noop.js": constant = ["__rgRedirect.noopjs", "noopFunc"]
        case "empty": constant = ["__rgRedirect.empty", "''"]
        case "1x1", "1x1.gif": constant = ["__rgRedirect.pixel", pixel]
        default: return []
        }
        var rows: [[String: Any]] = [["domains": domains, "name": "set-constant", "args": constant]]
        if !pattern.isEmpty { rows.append(["domains": domains, "name": "prevent-fetch", "args": [pattern]]) }
        return rows
    }

    static func pruneKeys(_ raw: String) -> [String] {
        raw.split(separator: "|").compactMap { part in
            var token = String(part).replacingOccurrences(of: "\\", with: "")
            token = token.trimmingCharacters(in: .whitespaces)
            if token.hasPrefix("$") { token.removeFirst() }
            let pieces = token.split(whereSeparator: { ".$[]*".contains($0) }).map(String.init).filter { !$0.isEmpty }
            return pieces.last
        }
    }

    private static func needle(of filter: String) -> String {
        var pattern = filter.trimmingCharacters(in: .whitespaces)
        if pattern.hasPrefix("@@") { pattern.removeFirst(2) }
        if pattern.hasPrefix("||") { pattern.removeFirst(2) }
        else if pattern.hasPrefix("|") { pattern.removeFirst() }
        return pattern.replacingOccurrences(of: "^", with: "").replacingOccurrences(of: "*", with: "")
    }

    private static func hosts(of filter: String) -> [String] {
        var pattern = filter
        guard pattern.hasPrefix("||") else { return [] }
        pattern.removeFirst(2)
        pattern = pattern.replacingOccurrences(of: "^", with: "")
        let domain = String(pattern.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard !domain.isEmpty, domain != "*", domain.range(of: #"^[A-Za-z0-9.*-]+$"#, options: .regularExpression) != nil else { return [] }
        return [domain.replacingOccurrences(of: "*.", with: "")]
    }

    private static func unescapedDollars(_ body: String) -> [String.Index] {
        var indexes: [String.Index] = []
        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == "$" {
                var slashes = 0
                var cursor = index
                while cursor > body.startIndex {
                    let previous = body.index(before: cursor)
                    if body[previous] != "\\" { break }
                    slashes += 1
                    cursor = previous
                }
                if slashes % 2 == 0 { indexes.append(index) }
            }
            index = body.index(after: index)
        }
        return indexes
    }

    private static func plausibleModifiers(_ mods: String) -> Bool {
        guard !mods.isEmpty else { return false }
        let known = ["redirect", "redirect-rule", "removeparam", "csp", "replace", "jsonprune"]
        return mods.split(separator: ",").allSatisfy { token in
            let value = String(token)
            if known.contains(where: { value == $0 || value.hasPrefix($0 + "=") }) { return true }
            guard !value.isEmpty, !value.contains(" "), !value.contains("$"), let first = value.first, first.isLetter || first == "~" else { return false }
            return value.unicodeScalars.allSatisfy { CharacterSet.modifierChars.contains($0) || $0 == "=" || $0 == "|" || $0 == "." || $0 == "*" }
        }
    }

    private static func splitOptions(_ body: String) -> (pattern: String, modifiers: String?) {
        for dollar in unescapedDollars(body).reversed() {
            let head = String(body[..<dollar])
            let mods = String(body[body.index(after: dollar)...])
            if head.hasPrefix("/"), head.hasSuffix("/") { return (body, nil) }
            if plausibleModifiers(mods) { return (head, mods) }
        }
        return (body, nil)
    }

    private static func apply(_ options: inout Options, modifiers: String) -> Bool {
        var types: [String] = []
        for part in modifiers.split(separator: ",") {
            let token = String(part)
            switch token {
            case "third-party": options.thirdParty = true
            case "~third-party", "first-party": options.thirdParty = false
            case "script": types.append("script")
            case "image": types.append("image")
            case "stylesheet": types.append("style-sheet")
            case "xmlhttprequest", "xhr", "other", "ping", "websocket": types.append("raw")
            case "media": types.append("media")
            case "font": types.append("font")
            case "document", "subdocument": types.append("document")
            case "popup": types.append("popup")
            case "all", "important", "match-case": break
            case "redirect", "redirect-rule":
                options.redirect = true
                if options.redirectResource == nil { options.redirectResource = "empty" }
            default:
                if token.hasPrefix("redirect=") || token.hasPrefix("redirect-rule=") {
                    options.redirect = true
                    let raw = token.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                    if !raw.isEmpty { options.redirectResource = raw }
                    continue
                }
                if token == "removeparam" || token.hasPrefix("removeparam=") {
                    let raw = token.hasPrefix("removeparam=") ? String(token.dropFirst("removeparam=".count)) : ""
                    if raw.hasPrefix("/"), raw.hasSuffix("/"), raw.count > 2 {
                        options.removeParams.append(ParamRule(key: String(raw.dropFirst().dropLast()), regex: true))
                    } else {
                        options.removeParams.append(ParamRule(key: raw, regex: false))
                    }
                    continue
                }
                if token.hasPrefix("csp=") {
                    let policy = String(token.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    if !policy.isEmpty, policy.count < 500, !policy.lowercased().contains("javascript:") { options.csp = policy }
                    continue
                }
                if token.hasPrefix("replace=") {
                    if let parsed = Self.parseReplace(String(token.dropFirst("replace=".count))) { options.replaces.append(parsed) }
                    continue
                }
                if token == "jsonprune" || token.hasPrefix("jsonprune=") {
                    options.prunesJSON = true
                    let raw = token.hasPrefix("jsonprune=") ? String(token.dropFirst("jsonprune=".count)) : ""
                    options.jsonPrunes.append(contentsOf: pruneKeys(raw))
                    continue
                }
                if token.hasPrefix("domain=") {
                    for domain in token.dropFirst(7).split(separator: "|") {
                        let value = String(domain)
                        if value.hasPrefix("~") { options.unlessDomains.append(String(value.dropFirst())) }
                        else if !value.isEmpty { options.ifDomains.append(value) }
                    }
                } else if token.contains("=") { return false }
            }
        }
        if !types.isEmpty { options.resourceTypes = types }
        return true
    }

    private static func apply(_ options: Options, to trigger: inout [String: Any]) {
        if let types = options.resourceTypes { trigger["resource-type"] = types }
        if options.thirdParty == true { trigger["load-type"] = ["third-party"] }
        if options.thirdParty == false { trigger["load-type"] = ["first-party"] }
        if !options.ifDomains.isEmpty { trigger["if-domain"] = options.ifDomains }
        if !options.unlessDomains.isEmpty { trigger["unless-domain"] = options.unlessDomains }
    }

    private static func domainList(_ part: String) -> (include: [String], exclude: [String]) {
        var include: [String] = []
        var exclude: [String] = []
        for raw in part.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.hasPrefix("~") { exclude.append(String(token.dropFirst())) }
            else if !token.isEmpty { include.append(token) }
        }
        return (include, exclude)
    }

    private static func procedural(_ selector: String) -> (kind: String, selector: String, text: String)? {
        let markers = ["has-text", "contains", "-abp-contains", "xpath", "matches-css", "upward", "remove", "style"]
        for marker in markers {
            let token = ":" + marker + "("
            guard let start = selector.range(of: token) else { continue }
            let head = String(selector[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = selector[start.upperBound...]
            guard let end = rest.lastIndex(of: ")") else { return nil }
            let text = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
            let base = head.isEmpty ? (marker == "xpath" ? "" : "*") : head
            if marker != "xpath", base != "*", !safeSelector(base) { return nil }
            switch marker {
            case "xpath":
                guard !text.isEmpty, text.count < 400, !text.contains("<"), !text.lowercased().contains("javascript") else { return nil }
                return ("xpath", base, text)
            case "remove":
                return ("remove", base, "")
            case "style":
                guard text.count < 500, safeCSS(text.contains("{") ? text : "x{" + text + "}") else { return nil }
                return ("style", base, text)
            case "upward":
                guard !text.isEmpty, text.count < 160, !text.contains("{") else { return nil }
                return ("upward", base, text)
            case "matches-css":
                guard !text.isEmpty, text.count < 160, !text.contains("{") else { return nil }
                return ("matches-css", base, text)
            default:
                guard !text.isEmpty, text.count < 160 else { return nil }
                return (marker == "has-text" ? "has-text" : "contains", base, text)
            }
        }
        return nil
    }

    private static func matches(_ filter: String, host: String, absolute: String) -> Bool {
        if filter.hasPrefix("/"), filter.hasSuffix("/"), filter.count > 2 {
            return absolute.range(of: String(filter.dropFirst().dropLast()), options: .regularExpression) != nil
        }
        var pattern = filter
        if pattern.hasPrefix("|"), !pattern.hasPrefix("||") { pattern.removeFirst() }
        if !filter.hasPrefix("|") { return absolute.contains(pattern.lowercased()) }
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
            guard absolute.contains(path) else { return false }
        }
        return true
    }

    private static func trigger(_ filter: String) -> [String: Any]? {
        if filter.hasPrefix("/"), let end = filter.lastIndex(of: "/"), end != filter.startIndex {
            let pattern = String(filter[filter.index(after: filter.startIndex)..<end])
            guard pattern.count < 180, pattern.range(of: #"^[A-Za-z0-9_.*?+^$[\](){}|\\ -]+$"#, options: .regularExpression) != nil else { return nil }
            return ["url-filter": pattern, "url-filter-is-case-sensitive": false]
        }
        var pattern = filter
        if pattern.hasPrefix("|"), !pattern.hasPrefix("||") {
            pattern.removeFirst()
            let escaped = NSRegularExpression.escapedPattern(for: pattern.replacingOccurrences(of: "^", with: ""))
            return ["url-filter": "^" + escaped, "url-filter-is-case-sensitive": false]
        }
        if pattern.hasPrefix("||") {
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
        guard filter.range(of: #"^[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]{3,180}$"#, options: .regularExpression) != nil else { return nil }
        return ["url-filter": NSRegularExpression.escapedPattern(for: filter), "url-filter-is-case-sensitive": false]
    }

    private static func safeSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count < 300, !selector.contains("{"), !selector.contains("}"), !selector.contains("<"), !selector.contains("\\") else { return false }
        let lowered = selector.lowercased()
        guard !lowered.contains("url("), !lowered.contains("expression("), !lowered.contains("+js") else { return false }
        return selector.range(of: #"^[A-Za-z0-9_\-.#:\[\]="~|^$* >+(),'*]+$"#, options: .regularExpression) != nil
    }

    private static func safeCSS(_ css: String) -> Bool {
        let lowered = css.lowercased()
        guard css.contains("{"), css.count < 2_000, !lowered.contains("</"), !lowered.contains("@import"),
              !lowered.contains("javascript:"), !lowered.contains("expression("), !lowered.contains("url(") else { return false }
        return true
    }

    private static func capped(_ selectors: [String], budget: Int) -> [String] {
        var kept: [String] = []
        var length = 0
        for selector in selectors {
            if length + selector.count > budget { break }
            kept.append(selector)
            length += selector.count + 1
        }
        return kept
    }

    private static func pack(_ rules: [[String: Any]], size: Int) -> [String] {
        guard !rules.isEmpty else { return [] }
        var chunks: [String] = []
        var index = 0
        while index < rules.count {
            let end = min(index + size, rules.count)
            chunks.append(stringify(Array(rules[index..<end])))
            index = end
        }
        return chunks
    }

    private static func stringify(_ rules: [[String: Any]]) -> String {
        guard JSONSerialization.isValidJSONObject(rules), let data = try? JSONSerialization.data(withJSONObject: rules),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}

private extension CharacterSet {
    static let modifierChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~")
}
