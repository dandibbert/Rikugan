import Foundation

/// A compiled URL rule. Every rule is represented by a regular expression that uses only the
/// syntax subset shared by ICU (NSRegularExpression) and ECMAScript, so the exact same rule can be
/// evaluated natively and inside injected JavaScript (e.g. for sub-frames).
public struct URLRule: Codable, Hashable {
    public enum Kind: String, Codable { case matchPattern, glob, regex }
    public let kind: Kind
    public let source: String
    public let regex: String
    public let caseInsensitive: Bool

    /// ECMAScript expression creating the RegExp.
    public var jsExpression: String {
        "new RegExp(\(regex.jsLiteral)\(caseInsensitive ? ", 'i'" : ""))"
    }

    public func matches(_ url: URL) -> Bool { matches(normalized: URLMatcher.normalize(url)) }

    public func matches(normalized value: String) -> Bool {
        guard let expression = URLMatcher.cachedRegex(regex, caseInsensitive: caseInsensitive) else { return false }
        return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

public enum URLMatcher {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func cachedRegex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = (caseInsensitive ? "i:" : "s:") + pattern
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = compiled
        return compiled
    }

    /// Normalises a URL the same way `location.href` does (lower-case scheme/host, no fragment).
    public static func normalize(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        if let host = components.host { components.host = host.lowercased() }
        if components.percentEncodedPath.isEmpty, components.host != nil { components.percentEncodedPath = "/" }
        if let port = components.port {
            if (components.scheme == "http" && port == 80) || (components.scheme == "https" && port == 443) { components.port = nil }
        }
        return components.string ?? url.absoluteString
    }

    /// Escapes regular-expression meta characters for the ICU / ECMAScript common subset.
    public static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\^$.|?*+()[]{}/".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: Chrome match patterns

    public static let allURLsSchemes = ["http", "https", "file", "ws", "wss", "ftp"]

    /// Parses a Chrome / Tampermonkey match pattern (`<all_urls>`, `*://*.example.com/*`, ...).
    public static func matchPattern(_ pattern: String) throws -> URLRule {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        if pattern == "<all_urls>" || pattern == "*" {
            return URLRule(kind: .matchPattern, source: pattern, regex: "^(https?|wss?|file|ftp)://", caseInsensitive: false)
        }
        guard let sep = pattern.range(of: "://") else { throw RikuganError("无效的匹配规则（缺少 ://）：\(pattern)") }
        let scheme = String(pattern[..<sep.lowerBound]).lowercased()
        let rest = pattern[sep.upperBound...]
        let validSchemes = ["*", "http", "https", "file", "ws", "wss", "ftp", "urn", "chrome-extension", "http*"]
        guard validSchemes.contains(scheme) else { throw RikuganError("匹配规则的协议不受支持：\(pattern)") }
        let schemeRegex: String
        switch scheme {
        case "*", "http*": schemeRegex = "https?"
        default: schemeRegex = escape(scheme)
        }
        let hostPart: Substring
        let pathPart: Substring
        if let slash = rest.firstIndex(of: "/") {
            hostPart = rest[..<slash]; pathPart = rest[slash...]
        } else if scheme == "file" {
            throw RikuganError("file 匹配规则缺少路径：\(pattern)")
        } else {
            // Tampermonkey tolerates missing path; treat as "/*".
            hostPart = rest; pathPart = "/*"
        }
        var host = String(hostPart).lowercased()
        var hostRegex: String
        if scheme == "file" {
            hostRegex = ""
        } else if host == "*" {
            hostRegex = "[^/]*"
        } else {
            if host.contains("@") { throw RikuganError("匹配规则主机不能包含用户名：\(pattern)") }
            var portRegex = "(:[0-9]+)?"
            if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") {
                let port = host[host.index(after: colon)...]
                host = String(host[..<colon])
                if port == "*" { portRegex = "(:[0-9]+)?" }
                else if port.allSatisfy(\.isNumber), !port.isEmpty { portRegex = ":" + port }
                else { throw RikuganError("匹配规则端口无效：\(pattern)") }
            }
            var subdomains = false
            if host.hasPrefix("*.") { subdomains = true; host.removeFirst(2) }
            if host.contains("*") {
                // Tampermonkey extension: `.tld` and inner wildcards.
                guard !host.isEmpty else { throw RikuganError("匹配规则主机无效：\(pattern)") }
            }
            guard !host.isEmpty else { throw RikuganError("匹配规则主机为空：\(pattern)") }
            var core = escape(host).replacingOccurrences(of: "\\*", with: "[^/:]*")
            if host.hasSuffix(".tld") {
                core = String(core.dropLast(5)) + "\\.[a-z]{2,}(\\.[a-z]{2,})?"
            }
            hostRegex = (subdomains ? "([^/:@]*\\.)?" : "") + core + portRegex
        }
        let pathRegex = globBody(String(pathPart))
        return URLRule(kind: .matchPattern, source: pattern,
                       regex: "^" + schemeRegex + "://" + hostRegex + pathRegex + "$",
                       caseInsensitive: false)
    }

    public static func isValidMatchPattern(_ pattern: String) -> Bool { (try? matchPattern(pattern)) != nil }

    private static func globBody(_ glob: String) -> String {
        glob.split(separator: "*", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: ".*")
    }

    // MARK: Greasemonkey @include / @exclude

    /// `@include` / `@exclude` rule: glob with `*`, `/regex/flags`, or `.tld` magic.
    public static func includeRule(_ pattern: String) throws -> URLRule {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        if pattern.count > 2, pattern.hasPrefix("/"), let last = pattern.lastIndex(of: "/"), last != pattern.startIndex {
            let body = String(pattern[pattern.index(after: pattern.startIndex)..<last])
            let flags = pattern[pattern.index(after: last)...]
            guard flags.allSatisfy({ "gimsuy".contains($0) }) else { throw RikuganError("@include 正则标志无效：\(pattern)") }
            guard (try? NSRegularExpression(pattern: body)) != nil else { throw RikuganError("@include 正则无效：\(pattern)") }
            return URLRule(kind: .regex, source: pattern, regex: body, caseInsensitive: flags.contains("i"))
        }
        if pattern == "*" { return URLRule(kind: .glob, source: pattern, regex: "^.*$", caseInsensitive: false) }
        var regex = globBody(pattern)
        regex = regex.replacingOccurrences(of: "\\.tld", with: "\\.[a-z]{2,}(\\.[a-z]{2,})?")
        return URLRule(kind: .glob, source: pattern, regex: "^" + regex + "$", caseInsensitive: true)
    }

    /// Convenience: check a list of match patterns.
    public static func anyMatch(_ rules: [URLRule], _ url: URL) -> Bool {
        let normalized = normalize(url)
        return rules.contains { $0.matches(normalized: normalized) }
    }

    /// Returns the host of a match pattern for permission display, or nil for all hosts.
    public static func displayHost(ofPattern pattern: String) -> String? {
        if pattern == "<all_urls>" { return nil }
        guard let sep = pattern.range(of: "://") else { return pattern }
        let rest = pattern[sep.upperBound...]
        let host = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if host == "*" || host.isEmpty { return nil }
        return host
    }

    /// Checks whether a granted host pattern covers another pattern (used for permission diffs).
    public static func pattern(_ granted: String, covers requested: String) -> Bool {
        if granted == requested { return true }
        if granted == "<all_urls>" { return true }
        if displayHost(ofPattern: granted) == nil, requested != "<all_urls>" { return true }
        guard let rule = try? matchPattern(granted) else { return false }
        // Test a representative URL of the requested pattern.
        var sample = requested.replacingOccurrences(of: "*://", with: "https://")
        sample = sample.replacingOccurrences(of: "://*.", with: "://")
        sample = sample.replacingOccurrences(of: "*", with: "x")
        guard let url = URL(string: sample) else { return false }
        return rule.matches(url)
    }
}

/// Host / domain helpers shared by site settings, ad blocking and permissions.
public enum DomainTools {
    /// Whether `host` equals `domain` or is a sub-domain of it.
    public static func host(_ host: String, isWithin domain: String) -> Bool {
        let host = host.lowercased(), domain = domain.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    /// `a.b.example.com` → [`a.b.example.com`, `b.example.com`, `example.com`, `com`]
    public static func suffixes(of host: String) -> [String] {
        var parts = host.lowercased().split(separator: ".").map(String.init)
        var result: [String] = []
        while !parts.isEmpty {
            result.append(parts.joined(separator: "."))
            parts.removeFirst()
        }
        return result
    }

    /// Hosting platforms where every sub-domain belongs to a different owner (a subset of the
    /// Public Suffix List's private section).
    static let privateSuffixes: Set<String> = [
        "github.io", "gitlab.io", "pages.dev", "workers.dev", "vercel.app", "netlify.app", "herokuapp.com", "appspot.com",
        "blogspot.com", "cloudfront.net", "azurewebsites.net", "firebaseapp.com", "web.app", "glitch.me", "repl.co",
        "fly.dev", "onrender.com", "surge.sh", "neocities.org", "wordpress.com", "tumblr.com", "myshopify.com",
    ]
    static let secondLevelLabels: Set<String> = ["co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "mil", "nom", "gob", "gen"]

    /// Conservative public-suffix test: a single label, `<co|com|org…>.<ccTLD>`, or a known hosting
    /// platform. Errs on the side of treating something as a suffix (then it is refused).
    public static func isPublicSuffix(_ domain: String) -> Bool {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let parts = d.split(separator: ".").map(String.init)
        if parts.count <= 1 { return true }
        if privateSuffixes.contains(d) { return true }
        if parts.count == 2, parts[1].count == 2, secondLevelLabels.contains(parts[0]) { return true }
        return false
    }

    /// Registrable domain (eTLD+1) using `isPublicSuffix`.
    public static func registrableDomain(_ host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count > 1 else { return host.lowercased() }
        for n in 1..<parts.count where isPublicSuffix(parts.suffix(n).joined(separator: ".")) && !isPublicSuffix(parts.suffix(n + 1).joined(separator: ".")) {
            return parts.suffix(n + 1).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    public static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { UInt8($0) != nil }
    }
}

/// Cookie domain rules shared by chrome.cookies and GM_cookie (RFC 6265 §5.3).
public enum CookieScope {
    /// Whether a stored cookie would be sent with a request to `url` (RFC 6265 §5.4): host-only vs
    /// domain match, path prefix, Secure only over https, not expired.
    public static func cookie(_ cookie: HTTPCookie, appliesTo url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let isDomainCookie = cookie.domain.hasPrefix(".")
        let domain = (isDomainCookie ? String(cookie.domain.dropFirst()) : cookie.domain).lowercased()
        let domainOK = isDomainCookie ? DomainTools.host(host, isWithin: domain) : host == domain
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let pathOK = path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
        let secureOK = !cookie.isSecure || url.scheme?.lowercased() == "https"
        let fresh = cookie.expiresDate.map { $0 > now } ?? true
        return domainOK && pathOK && secureOK && fresh
    }

    /// The `Domain` a cookie set for `url` may carry, or nil when the request is not allowed:
    /// the domain must domain-match the URL's host and must not be a public suffix; IP hosts only
    /// allow host-only cookies. nil `requested` means a host-only cookie for the URL's host.
    public static func domain(requested: String?, for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        guard let raw = requested?.lowercased(), !raw.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty else { return host }
        let d = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if DomainTools.isIPAddress(host) { return d == host ? host : nil }
        guard DomainTools.host(host, isWithin: d), !DomainTools.isPublicSuffix(d) else { return nil }
        return "." + d
    }
}
