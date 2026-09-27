import Foundation

public struct SearchEngine: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Template containing `{query}` (or `%s`).
    public var searchTemplate: String
    /// OpenSearch-JSON suggestion endpoint template, optional.
    public var suggestTemplate: String?
    public var isBuiltIn: Bool

    public init(id: String, name: String, searchTemplate: String, suggestTemplate: String? = nil, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.searchTemplate = searchTemplate
        self.suggestTemplate = suggestTemplate; self.isBuiltIn = isBuiltIn
    }

    public static let builtIn: [SearchEngine] = [
        .init(id: "google", name: "Google", searchTemplate: "https://www.google.com/search?q={query}",
              suggestTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&q={query}", isBuiltIn: true),
        .init(id: "bing", name: "Bing", searchTemplate: "https://www.bing.com/search?q={query}",
              suggestTemplate: "https://api.bing.com/osjson.aspx?query={query}", isBuiltIn: true),
        .init(id: "duckduckgo", name: "DuckDuckGo", searchTemplate: "https://duckduckgo.com/?q={query}",
              suggestTemplate: "https://duckduckgo.com/ac/?q={query}&type=list", isBuiltIn: true),
        .init(id: "brave", name: "Brave", searchTemplate: "https://search.brave.com/search?q={query}",
              suggestTemplate: "https://search.brave.com/api/suggest?q={query}", isBuiltIn: true),
        .init(id: "yahoo", name: "Yahoo", searchTemplate: "https://search.yahoo.com/search?p={query}",
              suggestTemplate: "https://search.yahoo.com/sugg/os?command={query}&output=fxjson", isBuiltIn: true),
        .init(id: "baidu", name: "百度", searchTemplate: "https://www.baidu.com/s?wd={query}",
              suggestTemplate: "https://www.baidu.com/sugrec?prod=pc&wd={query}", isBuiltIn: true),
        .init(id: "startpage", name: "Startpage", searchTemplate: "https://www.startpage.com/do/search?q={query}", isBuiltIn: true),
        .init(id: "naver", name: "Naver", searchTemplate: "https://search.naver.com/search.naver?query={query}", isBuiltIn: true),
        .init(id: "yandex", name: "Yandex", searchTemplate: "https://yandex.com/search/?text={query}",
              suggestTemplate: "https://suggest.yandex.com/suggest-ff.cgi?part={query}", isBuiltIn: true),
    ]

    public func searchURL(for query: String) -> URL? { SearchEngine.fill(searchTemplate, query) }
    public func suggestURL(for query: String) -> URL? { suggestTemplate.flatMap { SearchEngine.fill($0, query) } }

    public static func fill(_ template: String, _ query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/;:@$,")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let filled = template.replacingOccurrences(of: "{query}", with: encoded)
            .replacingOccurrences(of: "{searchTerms}", with: encoded)
            .replacingOccurrences(of: "%s", with: encoded)
        return URL(string: filled)
    }

    public static func isValidTemplate(_ template: String) -> Bool {
        guard template.contains("{query}") || template.contains("%s") || template.contains("{searchTerms}") else { return false }
        return fill(template, "test")?.scheme?.hasPrefix("http") == true
    }

    /// Parses OpenSearch JSON (`["q", ["a", "b"]]`) and the Baidu sugrec variant.
    public static func parseSuggestions(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            // Some engines answer in legacy encodings; try Latin-1 repair.
            return []
        }
        if let array = object as? [Any], array.count > 1, let list = array[1] as? [Any] {
            return list.compactMap { item in
                if let text = item as? String { return text }
                if let dict = item as? [String: Any] { return dict["phrase"] as? String ?? dict["q"] as? String }
                return nil
            }
        }
        if let dict = object as? [String: Any], let g = dict["g"] as? [[String: Any]] {
            return g.compactMap { $0["q"] as? String }
        }
        if let array = object as? [[String: Any]] {
            return array.compactMap { $0["phrase"] as? String }
        }
        return []
    }
}

/// Keyword shortcut: typing `gh swift` searches GitHub.
public struct URLShortcut: Codable, Hashable, Identifiable {
    public var id: UUID
    public var keyword: String
    public var template: String
    public init(id: UUID = UUID(), keyword: String, template: String) {
        self.id = id; self.keyword = keyword; self.template = template
    }
}

public enum OmniboxInput: Equatable {
    case url(URL)
    case search(String)
    case internalPage(String)
}

public enum Omnibox {
    static let knownSchemes: Set<String> = ["http", "https", "file", "about", "data", "ftp", "blob", "view-source", "chrome-extension"]
    static let internalSchemes: Set<String> = ["rikugan", "chrome", "edge"]
    static let fileExtensionsNotTLD: Set<String> = ["js", "py", "txt", "json", "html", "htm", "exe", "swift", "java", "cpp", "hpp",
                                                    "jpg", "jpeg", "png", "gif", "pdf", "zip", "rar", "doc", "docx", "xls", "xlsx",
                                                    "ts", "tsx", "jsx", "css", "rb", "kt", "go", "rs", "c", "h", "m", "mm", "plist", "log", "yml", "yaml"]

    /// Classifies what the user typed as a URL or a search.
    public static func classify(_ input: String, shortcuts: [URLShortcut] = []) -> OmniboxInput {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .search("") }
        if let space = text.firstIndex(of: " ") {
            let keyword = text[..<space].lowercased()
            if let shortcut = shortcuts.first(where: { $0.keyword.lowercased() == keyword }) {
                let query = text[text.index(after: space)...].trimmingCharacters(in: .whitespaces)
                if let url = SearchEngine.fill(shortcut.template, query) { return .url(url) }
            }
        }
        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon].lowercased()
            if internalSchemes.contains(scheme), text.dropFirst(scheme.count + 1).hasPrefix("//") {
                let page = String(text[text.index(colon, offsetBy: 3)...]).lowercased()
                return .internalPage(page.split(separator: "/").first.map(String.init) ?? page)
            }
            if knownSchemes.contains(scheme), !text.contains(" ") || scheme == "data" {
                if let url = URL(string: text) { return .url(url) }
                if let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(["#"])),
                   let url = URL(string: encoded) { return .url(url) }
            }
        }
        if text.contains(where: { $0.isWhitespace }) { return .search(text) }
        let hostEnd = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        var hostPort = String(text[..<hostEnd])
        if let at = hostPort.lastIndex(of: "@") { hostPort = String(hostPort[hostPort.index(after: at)...]) }
        var host = hostPort
        if let colon = hostPort.lastIndex(of: ":"), !hostPort.hasPrefix("[") {
            let port = hostPort[hostPort.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return .search(text) }
            host = String(hostPort[..<colon])
        }
        let lowerHost = host.lowercased()
        if lowerHost == "localhost" || isIPv4(lowerHost) || (hostPort.hasPrefix("[") && hostPort.contains("]")) {
            return URL(string: "http://" + text).map(OmniboxInput.url) ?? .search(text)
        }
        let labels = lowerHost.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return .search(text) }
        let hostChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.").union(.init(charactersIn: "\u{80}"..."\u{10FFFF}"))
        guard lowerHost.unicodeScalars.allSatisfy({ hostChars.contains($0) }) else { return .search(text) }
        let tld = String(labels.last!)
        let tldIsAlpha = tld.count >= 2 && tld.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || $0.value > 0x7F || $0 == "-" }
        guard tldIsAlpha || tld.hasPrefix("xn--") else { return .search(text) }
        if fileExtensionsNotTLD.contains(tld), hostEnd == text.endIndex { return .search(text) }
        let candidate = "https://" + text
        if let url = URL(string: candidate) { return .url(url) }
        if let encoded = candidate.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(["#"])),
           let url = URL(string: encoded) { return .url(url) }
        return .search(text)
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// Resolves user input into a URL to load, using the chosen search engine for searches.
    public static func resolve(_ input: String, engine: SearchEngine, shortcuts: [URLShortcut] = []) -> URL? {
        switch classify(input, shortcuts: shortcuts) {
        case .url(let url): return url
        case .search(let query): return query.isEmpty ? nil : engine.searchURL(for: query)
        case .internalPage(let page): return URL(string: "rikugan://" + page)
        }
    }

    /// Human-friendly URL for display in the address bar when not editing.
    public static func displayText(for url: URL?) -> String {
        guard let url else { return "" }
        if url.scheme == "https" || url.scheme == "http" {
            var host = url.host ?? url.absoluteString
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
        return url.absoluteString
    }
}
