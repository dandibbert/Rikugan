import Foundation

struct TabGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol = "folder"
}

struct ClosedTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String
    var groupID: UUID?
    var closedAt = Date()
}

struct BookmarkFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var parentID: UUID?
}

struct ScriptResource: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var url: String
    var mime = "application/octet-stream"
    var dataBase64 = ""
    var text: String {
        guard let data = Data(base64Encoded: dataBase64) else { return "" }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
    var dataURL: String { dataBase64.isEmpty ? url : "data:\(mime);base64,\(dataBase64)" }
}

struct CustomBlockRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var enabled = true
}

struct FilterSubscription: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var enabled = true
    var body = ""
    var updatedAt: Date?
}

struct SearchEngine: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var template: String
    var keyword = ""
}

struct URLShortcut: Codable, Identifiable, Equatable {
    var id = UUID()
    var keyword: String
    var url: String
}

struct ImportedFont: Codable, Identifiable, Equatable {
    var id = UUID()
    var family: String
    var fileName: String
}

struct ReaderSettings: Codable, Equatable {
    var fontSize = 18.0
    var font = "system"
    var lineHeight = 1.6
    var theme = "sepia"
}

struct BrowserSettings: Equatable {
    var addressBar = "bottom"
    var darkMode = "off"
    var homepage = "favorites"
    var homepageURL = ""
    var immersiveWallpaper = false
    var wallpaperFile = ""
    var preventAppStoreRedirect = true
    var preventExternalAppRedirect = false
    var contentBlocking = true
    var builtInRules = true
    var customRules: [CustomBlockRule] = []
    var subscriptions: [FilterSubscription] = []
    var customEngines: [SearchEngine] = []
    var urlShortcuts: [URLShortcut] = []
    var webFontFamily = ""
    var importedFonts: [ImportedFont] = []
    var inspectable = true
    var shortcuts: [String] = []
    var translateTarget = "zh-Hans"
    var reader = ReaderSettings()
    var translationBackend = "apple"
    var searchSuggestions = true
}

extension BrowserSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case addressBar, darkMode, homepage, homepageURL, immersiveWallpaper, wallpaperFile
        case preventAppStoreRedirect, preventExternalAppRedirect, contentBlocking, builtInRules
        case customRules, subscriptions, customEngines, urlShortcuts, webFontFamily, importedFonts, inspectable
        case shortcuts, translateTarget, reader, translationBackend, searchSuggestions
    }
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addressBar = try container.decodeIfPresent(String.self, forKey: .addressBar) ?? addressBar
        darkMode = try container.decodeIfPresent(String.self, forKey: .darkMode) ?? darkMode
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage) ?? homepage
        homepageURL = try container.decodeIfPresent(String.self, forKey: .homepageURL) ?? homepageURL
        immersiveWallpaper = try container.decodeIfPresent(Bool.self, forKey: .immersiveWallpaper) ?? immersiveWallpaper
        wallpaperFile = try container.decodeIfPresent(String.self, forKey: .wallpaperFile) ?? wallpaperFile
        preventAppStoreRedirect = try container.decodeIfPresent(Bool.self, forKey: .preventAppStoreRedirect) ?? preventAppStoreRedirect
        preventExternalAppRedirect = try container.decodeIfPresent(Bool.self, forKey: .preventExternalAppRedirect) ?? preventExternalAppRedirect
        contentBlocking = try container.decodeIfPresent(Bool.self, forKey: .contentBlocking) ?? contentBlocking
        builtInRules = try container.decodeIfPresent(Bool.self, forKey: .builtInRules) ?? builtInRules
        customRules = try container.decodeIfPresent([CustomBlockRule].self, forKey: .customRules) ?? customRules
        subscriptions = try container.decodeIfPresent([FilterSubscription].self, forKey: .subscriptions) ?? subscriptions
        customEngines = try container.decodeIfPresent([SearchEngine].self, forKey: .customEngines) ?? customEngines
        urlShortcuts = try container.decodeIfPresent([URLShortcut].self, forKey: .urlShortcuts) ?? urlShortcuts
        webFontFamily = try container.decodeIfPresent(String.self, forKey: .webFontFamily) ?? webFontFamily
        importedFonts = try container.decodeIfPresent([ImportedFont].self, forKey: .importedFonts) ?? importedFonts
        inspectable = try container.decodeIfPresent(Bool.self, forKey: .inspectable) ?? inspectable
        shortcuts = try container.decodeIfPresent([String].self, forKey: .shortcuts) ?? shortcuts
        translateTarget = try container.decodeIfPresent(String.self, forKey: .translateTarget) ?? translateTarget
        reader = try container.decodeIfPresent(ReaderSettings.self, forKey: .reader) ?? reader
        translationBackend = try container.decodeIfPresent(String.self, forKey: .translationBackend) ?? translationBackend
        searchSuggestions = try container.decodeIfPresent(Bool.self, forKey: .searchSuggestions) ?? true
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(addressBar, forKey: .addressBar)
        try container.encode(darkMode, forKey: .darkMode)
        try container.encode(homepage, forKey: .homepage)
        try container.encode(homepageURL, forKey: .homepageURL)
        try container.encode(immersiveWallpaper, forKey: .immersiveWallpaper)
        try container.encode(wallpaperFile, forKey: .wallpaperFile)
        try container.encode(preventAppStoreRedirect, forKey: .preventAppStoreRedirect)
        try container.encode(preventExternalAppRedirect, forKey: .preventExternalAppRedirect)
        try container.encode(contentBlocking, forKey: .contentBlocking)
        try container.encode(builtInRules, forKey: .builtInRules)
        try container.encode(customRules, forKey: .customRules)
        try container.encode(subscriptions, forKey: .subscriptions)
        try container.encode(customEngines, forKey: .customEngines)
        try container.encode(urlShortcuts, forKey: .urlShortcuts)
        try container.encode(webFontFamily, forKey: .webFontFamily)
        try container.encode(importedFonts, forKey: .importedFonts)
        try container.encode(inspectable, forKey: .inspectable)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(translateTarget, forKey: .translateTarget)
        try container.encode(reader, forKey: .reader)
        try container.encode(translationBackend, forKey: .translationBackend)
        try container.encode(searchSuggestions, forKey: .searchSuggestions)
    }
}

struct SiteSettings: Codable, Equatable, Identifiable {
    var id: String { host }
    var host: String
    var desktopMode: Bool?
    var darkMode: String?
    var contentBlocking: Bool?
    var externalNavigation: String?
    var userScriptsEnabled: Bool?
    var javascriptEnabled: Bool?
    var popups: String?
    var fontFamily: String?
}

struct WebPermission: Codable, Equatable, Identifiable {
    var id: String { host + ":" + kind }
    var host: String
    var kind: String
    var decision: String
}

struct DownloadRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var fileName: String
    var total: Int64 = 0
    var received: Int64 = 0
    var state = "finished"
    var created = Date()
    var resumable = false
    var source = ""
}

struct PortableBackup: Codable, Equatable {
    var version = 2
    var exportedAt = Date()
    var tabs: [SavedTab] = []
    var tabGroups: [TabGroup] = []
    var selectedTabID: UUID?
    var bookmarks: [PageRecord] = []
    var bookmarkFolders: [BookmarkFolder] = []
    var settings = BrowserSettings()
    var siteSettings: [SiteSettings] = []
    var searchEngine = "https://www.google.com/search?q="
    var searchHistory: [String] = []
}

enum SearchEngines {
    static let builtins: [(name: String, template: String, keyword: String)] = [
        ("Google", "https://www.google.com/search?q={query}", "g"),
        ("Bing", "https://www.bing.com/search?q={query}", "b"),
        ("DuckDuckGo", "https://duckduckgo.com/?q={query}", "d"),
        ("Brave", "https://search.brave.com/search?q={query}", "br"),
        ("Yahoo", "https://search.yahoo.com/search?p={query}", "y"),
        ("Baidu", "https://www.baidu.com/s?wd={query}", "bd"),
        ("Startpage", "https://www.startpage.com/sp/search?query={query}", "s"),
        ("Naver", "https://search.naver.com/search.naver?query={query}", "n"),
        ("Yandex", "https://yandex.com/search/?text={query}", "ya")
    ]
    static func template(for keyword: String, custom: [SearchEngine]) -> String? {
        let key = keyword.lowercased()
        if let custom = custom.first(where: { $0.keyword.lowercased() == key && !$0.keyword.isEmpty }) { return custom.template }
        return builtins.first { $0.keyword == key }?.template
    }
}

struct OmniboxSuggestion: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var target: String
}

enum Omnibox {
    static func suggestions(input: String, profile: BrowserProfile) -> [OmniboxSuggestion] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var rows: [OmniboxSuggestion] = []
        let needle = query.lowercased()
        for page in profile.bookmarks where page.title.lowercased().contains(needle) || page.url.lowercased().contains(needle) {
            rows.append(OmniboxSuggestion(id: "b" + page.id.uuidString, title: page.title, subtitle: page.url, target: page.url))
            if rows.count == 4 { break }
        }
        for page in profile.history where page.title.lowercased().contains(needle) || page.url.lowercased().contains(needle) {
            let id = "h" + page.id.uuidString
            guard !rows.contains(where: { $0.target == page.url }) else { continue }
            rows.append(OmniboxSuggestion(id: id, title: page.title, subtitle: page.url, target: page.url))
            if rows.count == 7 { break }
        }
        for term in profile.searchHistory where term.lowercased().contains(needle) && term.lowercased() != needle {
            rows.append(OmniboxSuggestion(id: "s" + term, title: term, subtitle: "搜索历史", target: term))
            if rows.count == 9 { break }
        }
        if URLRules.directURL(query) == nil {
            rows.insert(OmniboxSuggestion(id: "search", title: "搜索「\(query)」", subtitle: profile.searchEngine, target: query), at: 0)
        }
        return rows
    }
}

enum SearchSuggest {
    static func endpoint(template: String, query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 200 else { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let lower = template.lowercased()
        if lower.contains("google.") { return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)") }
        if lower.contains("bing.") { return URL(string: "https://api.bing.com/osjson.aspx?query=\(encoded)") }
        if lower.contains("duckduckgo.") { return URL(string: "https://duckduckgo.com/ac/?q=\(encoded)&type=list") }
        return nil
    }
    static func parse(_ data: Data) -> [String] {
        if let rows = try? JSONSerialization.jsonObject(with: data) as? [Any], rows.count > 1, let suggestions = rows[1] as? [String] {
            return Array(suggestions.prefix(8))
        }
        if let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return Array(rows.compactMap { $0["phrase"] as? String }.prefix(8))
        }
        return []
    }
    static func fetch(query: String, template: String) async -> [String] {
        guard let url = endpoint(template: template, query: query) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("Rikugan", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        return parse(data)
    }
}

struct PlaylistVariant: Equatable {
    var url: String
    var bandwidth: Int
    var width: Int
    var height: Int
    var kind: String
}

enum PlaylistText {
    static func parseM3U8(_ text: String, base: URL) -> [PlaylistVariant] {
        guard text.contains("#EXTM3U") else { return [] }
        let lines = text.components(separatedBy: .newlines)
        var variants: [PlaylistVariant] = []
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { continue }
            let bandwidth = capture(#"BANDWIDTH=(\d+)"#, line).flatMap(Int.init) ?? 0
            let size = capture(#"RESOLUTION=(\d+)x(\d+)"#, line)
            let width = Int(size?.0 ?? "") ?? 0
            let height = Int(size?.1 ?? "") ?? 0
            let next = index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : ""
            guard !next.isEmpty, !next.hasPrefix("#"), let url = URL(string: next, relativeTo: base)?.absoluteString else { continue }
            variants.append(PlaylistVariant(url: url, bandwidth: bandwidth, width: width, height: height, kind: "hls"))
        }
        return variants
    }
    static func parseMPD(_ text: String, base: URL) -> [PlaylistVariant] {
        guard text.contains("<MPD") || text.contains("<mpd") else { return [] }
        var variants: [PlaylistVariant] = []
        for block in blocks(text) {
            guard let raw = capture("<BaseURL>([^<]+)</BaseURL>", block)?.0,
                  let url = URL(string: raw.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteString else { continue }
            let bandwidth = Int(capture(#"bandwidth="(\d+)""#, block)?.0 ?? "") ?? 0
            let width = Int(capture(#"width="(\d+)""#, block)?.0 ?? "") ?? 0
            let height = Int(capture(#"height="(\d+)""#, block)?.0 ?? "") ?? 0
            variants.append(PlaylistVariant(url: url, bandwidth: bandwidth, width: width, height: height, kind: "dash"))
        }
        return variants
    }
    private static func blocks(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<Representation\b[^>]*>[\s\S]*?</Representation>"#, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
    private static func capture(_ pattern: String, _ text: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let first = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
        let second = match.numberOfRanges > 2 ? Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? "" : ""
        return (first, second)
    }
}

enum VersionComparator {
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let left = parts(remote), right = parts(local)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
    static func parts(_ value: String) -> [Int] {
        value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

enum AppGroupID {
    static let suite = "group.com.dandibbert.Rikugan"
}

enum ShortcutCatalog {
    static let all: [(id: String, title: String, symbol: String)] = [
        ("newTab", "新标签页", "plus"),
        ("closeTab", "关闭标签", "xmark"),
        ("dark", "暗黑模式", "moon"),
        ("translate", "翻译", "character.book.closed"),
        ("userscripts", "用户脚本", "curlybraces"),
        ("media", "媒体", "play.rectangle"),
        ("reload", "重新载入", "arrow.clockwise"),
        ("desktop", "桌面版", "desktopcomputer"),
        ("reader", "阅读模式", "text.alignleft"),
        ("find", "页内查找", "doc.text.magnifyingglass")
    ]
    static func title(_ id: String) -> String { all.first { $0.id == id }?.title ?? id }
    static func symbol(_ id: String) -> String { all.first { $0.id == id }?.symbol ?? "circle" }
}
