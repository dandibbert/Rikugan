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

struct BrowserSettings: Codable, Equatable {
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
    var webFontFamily = ""
    var importedFonts: [ImportedFont] = []
    var inspectable = true
    var shortcuts: [String] = []
    var translateTarget = "zh-Hans"
    var reader = ReaderSettings()
    var translationBackend = "apple"
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
    var webFontFamily: String?
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
    var version = 3
    var format = "com.dandibbert.rikugan.backup"
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
