import Foundation

public enum TriState: String, Codable, CaseIterable {
    case auto, on, off
}

public enum PermissionDecision: String, Codable, CaseIterable {
    case ask, allow, block
}

public enum ToolbarPosition: String, Codable, CaseIterable { case top, bottom }

public enum HomepageMode: String, Codable, CaseIterable { case start, blank, custom }

public enum ToolbarAction: String, Codable, CaseIterable, Identifiable {
    case newTab, closeTab, reload, darkMode, translate, userscripts, media, desktopSite, readerMode, findInPage,
         share, bookmarks, privateTab, images, extensions, elementPicker
    // Navigation / app actions usable as bottom-toolbar buttons, long-press actions and gestures.
    case back, forward, tabSwitcher, pageMenu, home, downloads, history, settings, addBookmark, scrollToTop,
         reopenClosedTab, nextTab, previousTab, webTools, none
    public var id: String { rawValue }

    /// Actions that make sense as a quick-action / long-press / gesture target.
    public static var assignable: [ToolbarAction] { allCases.filter { $0 != .none && $0 != .pageMenu } }
}

/// What the collapsed address bar shows (editing always shows the full URL).
public enum AddressBarDisplay: String, Codable, CaseIterable, Identifiable {
    case domain, fullURL, title, titleAndDomain
    public var id: String { rawValue }
}

/// Bottom toolbar (iPhone): the button in each slot and what a long press on that slot does.
public struct ToolbarLayout: Codable, Equatable {
    public var buttons: [ToolbarAction]
    /// Long-press action per slot index; `.none` (or missing) = the button's built-in long press
    /// (history list for back / forward, tab menu for tabs, customise for other buttons).
    public var longPress: [ToolbarAction]

    public static let slotCount = 5
    public static let `default` = ToolbarLayout(buttons: [.back, .forward, .darkMode, .tabSwitcher, .pageMenu],
                                                longPress: Array(repeating: .none, count: slotCount))

    public init(buttons: [ToolbarAction], longPress: [ToolbarAction]) {
        self.buttons = buttons
        self.longPress = longPress
    }

    /// Always exactly `slotCount` slots and always one page-menu button (settings stay reachable).
    public var normalized: ToolbarLayout {
        var b = Array(buttons.prefix(Self.slotCount))
        while b.count < Self.slotCount { b.append(Self.default.buttons[b.count]) }
        if !b.contains(.pageMenu) { b[Self.slotCount - 1] = .pageMenu }
        var l = Array(longPress.prefix(Self.slotCount))
        while l.count < Self.slotCount { l.append(.none) }
        return ToolbarLayout(buttons: b, longPress: l)
    }
}

/// App-wide preferences (per install, not per profile).
public struct Preferences: Codable, Equatable {
    public var searchEngineID = "google"
    public var customEngines: [SearchEngine] = []
    public var searchSuggestions = true
    public var shortcuts: [URLShortcut] = [
        URLShortcut(keyword: "gh", template: "https://github.com/search?q={query}"),
        URLShortcut(keyword: "wiki", template: "https://zh.wikipedia.org/w/index.php?search={query}"),
        URLShortcut(keyword: "yt", template: "https://www.youtube.com/results?search_query={query}"),
    ]
    public var toolbarPosition: ToolbarPosition = .bottom
    public var quickActions: [ToolbarAction] = [.darkMode]
    public var toolbarLayout: ToolbarLayout = .default
    public var addressBarDisplay: AddressBarDisplay = .titleAndDomain
    /// Gestures: swipe left / right on the address bar switches tabs; swipe up on the bottom
    /// toolbar opens the tab switcher; double-tap on the address bar is up to the action.
    public var swipeAddressBarSwitchesTabs = true
    public var swipeUpToolbarAction: ToolbarAction = .tabSwitcher
    public var doubleTapAddressBarAction: ToolbarAction = .none
    /// Ask for file name and destination before a download starts.
    public var downloadConfirm = true
    /// Keep tab thumbnails on disk so the tab switcher still shows them after a relaunch.
    public var persistTabThumbnails = true
    public var homepageMode: HomepageMode = .start
    public var homepageURL = ""
    public var showFrequentlyVisited = true
    public var wallpaperFileName: String?
    public var immersiveWallpaper = false
    public var pageDarkMode: TriState = .off
    public var darkModeBrightness = 100
    public var darkModeContrast = 100
    public var preventAppStoreRedirect = true
    public var preventExternalAppRedirect = false
    public var blockPopups = true
    public var adBlockEnabled = true
    public var translationProvider = "google"
    public var translationTargetLanguage = "zh-CN"
    public var translationServerURL = ""
    public var translationAPIKey = ""
    public var autoTranslateLanguages: [String] = []
    public var readerFontSize = 19
    public var readerFontFamily = "-apple-system"
    public var readerLineHeight = 1.7
    public var readerTheme = "auto"
    public var webFontEnabled = false
    public var webFontFamily = ""
    public var webFontKeepMonospace = true
    public var webFontExcludedHosts: [String] = []
    /// Optional separate fonts for headings and monospace text (empty = keep the page's font).
    public var webFontHeading = ""
    public var webFontMono = ""
    /// Debug / development settings.
    public var showDiagnostics = false
    public var backgroundIdleSeconds = 300
    public var maxLiveBackgroundTabs = 5
    public var webInspectorEnabled = false
    public var consoleCaptureEnabled = false
    public var restoreTabs = true
    public var openLinksInBackground = false
    public var defaultDesktopMode = false
    public var mediaSnifferEnabled = true
    public var downloadAskLocation = false
    public var autofillEnabled = true
    public var geolocationShim = true

    public init() {}

    public var allEngines: [SearchEngine] { SearchEngine.builtIn + customEngines }
    public var searchEngine: SearchEngine { allEngines.first { $0.id == searchEngineID } ?? SearchEngine.builtIn[0] }

    // Tolerant decoding keeps settings when new fields are added.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: DynamicKey.self)
        func v<T: Decodable>(_ key: String, _ current: T) -> T {
            guard let decoded = try? c.decodeIfPresent(T.self, forKey: DynamicKey(key)) else { return current }
            return decoded
        }
        searchEngineID = v("searchEngineID", searchEngineID)
        customEngines = v("customEngines", customEngines)
        searchSuggestions = v("searchSuggestions", searchSuggestions)
        shortcuts = v("shortcuts", shortcuts)
        toolbarPosition = v("toolbarPosition", toolbarPosition)
        quickActions = v("quickActions", quickActions)
        // Older settings only had the single quick-action slot: carry it into the layout.
        toolbarLayout = v("toolbarLayout", ToolbarLayout(buttons: [.back, .forward, quickActions.first ?? .darkMode, .tabSwitcher, .pageMenu],
                                                         longPress: ToolbarLayout.default.longPress)).normalized
        addressBarDisplay = v("addressBarDisplay", addressBarDisplay)
        swipeAddressBarSwitchesTabs = v("swipeAddressBarSwitchesTabs", swipeAddressBarSwitchesTabs)
        swipeUpToolbarAction = v("swipeUpToolbarAction", swipeUpToolbarAction)
        doubleTapAddressBarAction = v("doubleTapAddressBarAction", doubleTapAddressBarAction)
        downloadConfirm = v("downloadConfirm", downloadConfirm)
        persistTabThumbnails = v("persistTabThumbnails", persistTabThumbnails)
        homepageMode = v("homepageMode", homepageMode)
        homepageURL = v("homepageURL", homepageURL)
        showFrequentlyVisited = v("showFrequentlyVisited", showFrequentlyVisited)
        wallpaperFileName = v("wallpaperFileName", wallpaperFileName)
        immersiveWallpaper = v("immersiveWallpaper", immersiveWallpaper)
        pageDarkMode = v("pageDarkMode", pageDarkMode)
        darkModeBrightness = v("darkModeBrightness", darkModeBrightness)
        darkModeContrast = v("darkModeContrast", darkModeContrast)
        preventAppStoreRedirect = v("preventAppStoreRedirect", preventAppStoreRedirect)
        preventExternalAppRedirect = v("preventExternalAppRedirect", preventExternalAppRedirect)
        blockPopups = v("blockPopups", blockPopups)
        adBlockEnabled = v("adBlockEnabled", adBlockEnabled)
        translationProvider = v("translationProvider", translationProvider)
        translationTargetLanguage = v("translationTargetLanguage", translationTargetLanguage)
        translationServerURL = v("translationServerURL", translationServerURL)
        translationAPIKey = v("translationAPIKey", translationAPIKey)
        autoTranslateLanguages = v("autoTranslateLanguages", autoTranslateLanguages)
        readerFontSize = v("readerFontSize", readerFontSize)
        readerFontFamily = v("readerFontFamily", readerFontFamily)
        readerLineHeight = v("readerLineHeight", readerLineHeight)
        readerTheme = v("readerTheme", readerTheme)
        webFontEnabled = v("webFontEnabled", webFontEnabled)
        webFontFamily = v("webFontFamily", webFontFamily)
        webFontKeepMonospace = v("webFontKeepMonospace", webFontKeepMonospace)
        webFontExcludedHosts = v("webFontExcludedHosts", webFontExcludedHosts)
        webFontHeading = v("webFontHeading", webFontHeading)
        webFontMono = v("webFontMono", webFontMono)
        showDiagnostics = v("showDiagnostics", showDiagnostics)
        backgroundIdleSeconds = v("backgroundIdleSeconds", backgroundIdleSeconds)
        maxLiveBackgroundTabs = v("maxLiveBackgroundTabs", maxLiveBackgroundTabs)
        webInspectorEnabled = v("webInspectorEnabled", webInspectorEnabled)
        consoleCaptureEnabled = v("consoleCaptureEnabled", consoleCaptureEnabled)
        restoreTabs = v("restoreTabs", restoreTabs)
        openLinksInBackground = v("openLinksInBackground", openLinksInBackground)
        defaultDesktopMode = v("defaultDesktopMode", defaultDesktopMode)
        mediaSnifferEnabled = v("mediaSnifferEnabled", mediaSnifferEnabled)
        downloadAskLocation = v("downloadAskLocation", downloadAskLocation)
        autofillEnabled = v("autofillEnabled", autofillEnabled)
        geolocationShim = v("geolocationShim", geolocationShim)
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Per-host settings (spec §47).
public struct SiteSettings: Codable, Equatable, Identifiable {
    public var host: String
    public var desktopMode: Bool?
    public var darkMode: TriState?
    public var javaScript: Bool?
    public var popups: PermissionDecision?
    public var externalNavigation: PermissionDecision?
    public var contentBlocking: Bool?
    public var userScriptsEnabled: Bool?
    public var extensionsEnabled: Bool?
    public var webFont: Bool?
    public var permissions: [String: PermissionDecision] = [:]
    public var autoRefreshSeconds: Int?
    /// Per-site font override (nil = use global). `webFont == false` disables fonts on the site.
    public var fontBody: String?
    public var fontHeading: String?
    public var fontMono: String?
    public var id: String { host }

    public init(host: String) { self.host = host.lowercased() }

    enum CodingKeys: String, CodingKey {
        case host, desktopMode, darkMode, javaScript, popups, externalNavigation, contentBlocking, userScriptsEnabled,
             extensionsEnabled, webFont, permissions, autoRefreshSeconds, fontBody, fontHeading, fontMono
    }

    // Tolerant decoding: missing / unknown keys never make a whole settings file unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host).lowercased()
        desktopMode = try? c.decodeIfPresent(Bool.self, forKey: .desktopMode)
        darkMode = try? c.decodeIfPresent(TriState.self, forKey: .darkMode)
        javaScript = try? c.decodeIfPresent(Bool.self, forKey: .javaScript)
        popups = try? c.decodeIfPresent(PermissionDecision.self, forKey: .popups)
        externalNavigation = try? c.decodeIfPresent(PermissionDecision.self, forKey: .externalNavigation)
        contentBlocking = try? c.decodeIfPresent(Bool.self, forKey: .contentBlocking)
        userScriptsEnabled = try? c.decodeIfPresent(Bool.self, forKey: .userScriptsEnabled)
        extensionsEnabled = try? c.decodeIfPresent(Bool.self, forKey: .extensionsEnabled)
        webFont = try? c.decodeIfPresent(Bool.self, forKey: .webFont)
        permissions = (try? c.decodeIfPresent([String: PermissionDecision].self, forKey: .permissions)) ?? [:]
        autoRefreshSeconds = try? c.decodeIfPresent(Int.self, forKey: .autoRefreshSeconds)
        fontBody = try? c.decodeIfPresent(String.self, forKey: .fontBody)
        fontHeading = try? c.decodeIfPresent(String.self, forKey: .fontHeading)
        fontMono = try? c.decodeIfPresent(String.self, forKey: .fontMono)
    }

    public var isEmpty: Bool {
        desktopMode == nil && darkMode == nil && javaScript == nil && popups == nil && externalNavigation == nil &&
            contentBlocking == nil && userScriptsEnabled == nil && extensionsEnabled == nil && webFont == nil && permissions.isEmpty &&
            fontBody == nil && fontHeading == nil && fontMono == nil && autoRefreshSeconds == nil
    }

    public static let webPermissionKinds: [(key: String, title: String)] = [
        ("camera", "摄像头"), ("microphone", "麦克风"), ("location", "位置"), ("notifications", "通知"), ("clipboard", "剪贴板"),
    ]
}

/// Portable snapshot of tabs used for session restore and export.
public struct TabSnapshot: Codable, Equatable, Identifiable {
    public var id: UUID
    public var url: String
    public var title: String
    public var groupID: UUID?
    public var interactionState: Data?
    public var desktopMode: Bool
    public var lastActiveAt: Date
    public var pinned: Bool
    /// Vertical scroll offset captured when the tab was suspended / saved.
    public var scrollY: Double?

    public init(id: UUID = UUID(), url: String, title: String, groupID: UUID? = nil, interactionState: Data? = nil,
                desktopMode: Bool = false, lastActiveAt: Date = Date(), pinned: Bool = false, scrollY: Double? = nil) {
        self.id = id; self.url = url; self.title = title; self.groupID = groupID
        self.interactionState = interactionState; self.desktopMode = desktopMode
        self.lastActiveAt = lastActiveAt; self.pinned = pinned; self.scrollY = scrollY
    }
}

public struct TabGroupSnapshot: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

public struct WindowSessionSnapshot: Codable, Equatable {
    public var tabs: [TabSnapshot] = []
    public var groups: [TabGroupSnapshot] = []
    public var selectedTabID: UUID?
    public var selectedGroupID: UUID?
    public init() {}
}

public struct BookmarkNode: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var url: String?
    public var parentID: UUID?
    public var isFolder: Bool
    public var order: Int
    public var createdAt: Date
    public init(id: UUID = UUID(), title: String, url: String?, parentID: UUID?, isFolder: Bool = false, order: Int = 0, createdAt: Date = Date()) {
        self.id = id; self.title = title; self.url = url; self.parentID = parentID
        self.isFolder = isFolder; self.order = order; self.createdAt = createdAt
    }
    /// Well-known folder shown on the homepage.
    public static let favoritesID = UUID(uuidString: "00000000-0000-0000-0000-00000000FA0E")!
}

/// Export / import bundle (spec §39).
public struct ExportBundle: Codable {
    public var format = "rikugan-export"
    public var version = 1
    public var exportedAt = Date()
    public var preferences: Preferences
    public var sessions: [WindowSessionSnapshot]
    public var siteSettings: [SiteSettings]
    public var bookmarks: [BookmarkNode]
    public var adBlockCustomRules: String
    public var adBlockSubscriptions: [FilterSubscription]
    public var adBlockAllowlist: [String]
    public var userscripts: [ExportedUserscript]

    public init(preferences: Preferences, sessions: [WindowSessionSnapshot], siteSettings: [SiteSettings], bookmarks: [BookmarkNode],
                adBlockCustomRules: String, adBlockSubscriptions: [FilterSubscription], adBlockAllowlist: [String], userscripts: [ExportedUserscript]) {
        self.preferences = preferences; self.sessions = sessions; self.siteSettings = siteSettings; self.bookmarks = bookmarks
        self.adBlockCustomRules = adBlockCustomRules; self.adBlockSubscriptions = adBlockSubscriptions
        self.adBlockAllowlist = adBlockAllowlist; self.userscripts = userscripts
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        e.dataEncodingStrategy = .base64
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        d.dataDecodingStrategy = .base64
        return d
    }

    public static func decode(_ data: Data) throws -> ExportBundle {
        let bundle = try decoder().decode(ExportBundle.self, from: data)
        guard bundle.format == "rikugan-export" else { throw RikuganError("不是 Rikugan 导出文件") }
        return bundle
    }
}

public struct ExportedUserscript: Codable, Equatable {
    public var source: String
    public var enabled: Bool
    public var values: [String: String]
    public init(source: String, enabled: Bool, values: [String: String]) {
        self.source = source; self.enabled = enabled; self.values = values
    }
}

public struct FilterSubscription: Codable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var url: String
    public var enabled: Bool
    public var lastUpdated: Date?
    public var ruleCount: Int
    public var isBuiltIn: Bool

    public init(id: String, name: String, url: String, enabled: Bool, lastUpdated: Date? = nil, ruleCount: Int = 0, isBuiltIn: Bool = false) {
        self.id = id; self.name = name; self.url = url; self.enabled = enabled
        self.lastUpdated = lastUpdated; self.ruleCount = ruleCount; self.isBuiltIn = isBuiltIn
    }

    public static let defaults: [FilterSubscription] = [
        .init(id: "adguard-base", name: "AdGuard Base", url: "https://filters.adtidy.org/extension/safari/filters/2_optimized.txt", enabled: true, isBuiltIn: true),
        .init(id: "adguard-tracking", name: "AdGuard Tracking Protection", url: "https://filters.adtidy.org/extension/safari/filters/3_optimized.txt", enabled: false, isBuiltIn: true),
        .init(id: "adguard-chinese", name: "AdGuard Chinese", url: "https://filters.adtidy.org/extension/safari/filters/224_optimized.txt", enabled: false, isBuiltIn: true),
        .init(id: "adguard-annoyances", name: "AdGuard Annoyances", url: "https://filters.adtidy.org/extension/safari/filters/14_optimized.txt", enabled: false, isBuiltIn: true),
        .init(id: "easylist", name: "EasyList", url: "https://easylist.to/easylist/easylist.txt", enabled: false, isBuiltIn: true),
        .init(id: "easyprivacy", name: "EasyPrivacy", url: "https://easylist.to/easylist/easyprivacy.txt", enabled: false, isBuiltIn: true),
    ]
}
