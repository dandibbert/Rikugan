import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Chrome-style 32 character extension IDs (a–p alphabet).
public enum ExtensionID {
    public static func fromRawID(_ raw: Data) -> String {
        let hex = raw.prefix(16).map { String(format: "%02x", $0) }.joined()
        return String(hex.map { ch -> Character in
            let value = Int(String(ch), radix: 16) ?? 0
            return Character(UnicodeScalar(UInt8(97 + value)))
        })
    }

    public static func fromPublicKey(_ key: Data) -> String {
        fromRawID(sha256(key))
    }

    /// From the base64 `key` field of manifest.json.
    public static func fromManifestKey(_ base64: String) -> String? {
        let cleaned = base64.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned), !data.isEmpty else { return nil }
        return fromPublicKey(data)
    }

    /// Deterministic ID for unpacked extensions without a key.
    public static func fromSeed(_ seed: String) -> String {
        fromRawID(sha256(Data(seed.utf8)))
    }

    public static func isValid(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }

    public static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        return data.prefix(32)
        #endif
    }
}

public struct ContentScriptEntry: Codable, Hashable {
    public var matches: [String]
    public var excludeMatches: [String]
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var js: [String]
    public var css: [String]
    public var runAt: String
    public var allFrames: Bool
    public var matchAboutBlank: Bool
    public var world: String
    public var id: String?

    public init(matches: [String], excludeMatches: [String] = [], includeGlobs: [String] = [], excludeGlobs: [String] = [],
                js: [String] = [], css: [String] = [], runAt: String = "document_idle", allFrames: Bool = false,
                matchAboutBlank: Bool = false, world: String = "ISOLATED", id: String? = nil) {
        self.matches = matches; self.excludeMatches = excludeMatches; self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs; self.js = js; self.css = css; self.runAt = runAt
        self.allFrames = allFrames; self.matchAboutBlank = matchAboutBlank; self.world = world; self.id = id
    }

    public init(json: [String: Any]) {
        self.init(matches: json["matches"] as? [String] ?? [],
                  excludeMatches: json["exclude_matches"] as? [String] ?? json["excludeMatches"] as? [String] ?? [],
                  includeGlobs: json["include_globs"] as? [String] ?? [],
                  excludeGlobs: json["exclude_globs"] as? [String] ?? [],
                  js: json["js"] as? [String] ?? [],
                  css: json["css"] as? [String] ?? [],
                  runAt: json["run_at"] as? String ?? json["runAt"] as? String ?? "document_idle",
                  allFrames: json["all_frames"] as? Bool ?? json["allFrames"] as? Bool ?? false,
                  matchAboutBlank: json["match_about_blank"] as? Bool ?? false,
                  world: json["world"] as? String ?? "ISOLATED",
                  id: json["id"] as? String)
    }

    public func includeRules() -> [URLRule] { matches.compactMap { try? URLMatcher.matchPattern($0) } }
    public func excludeRules() -> [URLRule] {
        excludeMatches.compactMap { try? URLMatcher.matchPattern($0) } + excludeGlobs.compactMap { try? URLMatcher.includeRule($0) }
    }
    public func globRules() -> [URLRule] { includeGlobs.compactMap { try? URLMatcher.includeRule($0) } }

    public func matches(_ url: URL) -> Bool {
        let value = URLMatcher.normalize(url)
        guard includeRules().contains(where: { $0.matches(normalized: value) }) else { return false }
        let globs = globRules()
        if !globs.isEmpty, !globs.contains(where: { $0.matches(normalized: value) }) { return false }
        return !excludeRules().contains { $0.matches(normalized: value) }
    }
}

public struct DNRRuleResource: Codable, Hashable {
    public var id: String
    public var enabled: Bool
    public var path: String
}

/// Parsed MV3 manifest. Raw JSON is kept for `chrome.runtime.getManifest()`.
public struct ExtensionManifest {
    public let raw: [String: Any]

    /// MV3 minimum for extension pages: no remote or inline script, no eval.
    public static let defaultExtensionPagesCSP = "script-src 'self' 'wasm-unsafe-eval'; object-src 'self';"

    /// The Content-Security-Policy applied to the extension's own pages: the manifest's
    /// `content_security_policy.extension_pages` (MV3) / string policy (MV2), but never weaker than
    /// the MV3 minimum for scripts (remote hosts and 'unsafe-inline' / 'unsafe-eval' are dropped
    /// from script-src, as Chrome refuses them for MV3 extension pages).
    public var extensionPagesCSP: String {
        let declared: String? = (raw["content_security_policy"] as? [String: Any])?["extension_pages"] as? String
            ?? raw["content_security_policy"] as? String
        guard let declared, !declared.trimmingCharacters(in: .whitespaces).isEmpty else { return Self.defaultExtensionPagesCSP }
        var directives: [String] = []
        var hasScript = false, hasObject = false
        for part in declared.split(separator: ";") {
            let tokens = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = tokens.first?.lowercased() else { continue }
            if name == "script-src" || name == "script-src-elem" {
                hasScript = hasScript || name == "script-src"
                let allowed = tokens.dropFirst().filter { ["'self'", "'wasm-unsafe-eval'", "'none'"].contains($0.lowercased()) || $0.lowercased().hasPrefix("'sha") }
                directives.append(([name] + (allowed.isEmpty ? ["'self'"] : allowed)).joined(separator: " "))
            } else {
                if name == "object-src" { hasObject = true }
                directives.append(tokens.joined(separator: " "))
            }
        }
        if !hasScript { directives.append("script-src 'self' 'wasm-unsafe-eval'") }
        if !hasObject { directives.append("object-src 'self'") }
        return directives.joined(separator: "; ") + ";"
    }
    public let manifestVersion: Int
    public let name: String
    public let shortName: String?
    public let version: String
    public let description: String
    public let defaultLocale: String?
    public let icons: [String: String]
    public let actionPopup: String?
    public let actionTitle: String?
    public let actionIcons: [String: String]
    public let serviceWorker: String?
    public let backgroundType: String?
    public let backgroundScripts: [String]
    public let backgroundPage: String?
    public let contentScripts: [ContentScriptEntry]
    public let permissions: [String]
    public let optionalPermissions: [String]
    public let hostPermissions: [String]
    public let optionalHostPermissions: [String]
    public let webAccessibleResources: [[String: Any]]
    public let optionsPage: String?
    public let optionsOpenInTab: Bool
    public let commands: [String: Any]
    public let ruleResources: [DNRRuleResource]
    public let key: String?
    public let updateURL: String?
    public let homepageURL: String?
    public let minimumChromeVersion: String?

    public init(data: Data) throws {
        let stripped = ExtensionManifest.stripComments(String(decoding: data, as: UTF8.self))
        guard let object = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] else {
            throw RikuganError("manifest.json 不是有效的 JSON")
        }
        try self.init(json: object)
    }

    public init(json: [String: Any]) throws {
        raw = json
        manifestVersion = json["manifest_version"] as? Int ?? 0
        guard manifestVersion == 3 else {
            throw RikuganError("仅支持 Manifest V3 扩展（当前 manifest_version = \(manifestVersion)）")
        }
        guard let name = json["name"] as? String, !name.isEmpty else { throw RikuganError("manifest.json 缺少 name") }
        guard let version = json["version"] as? String, !version.isEmpty else { throw RikuganError("manifest.json 缺少 version") }
        self.name = name
        self.version = version
        shortName = json["short_name"] as? String
        description = json["description"] as? String ?? ""
        defaultLocale = json["default_locale"] as? String
        icons = ExtensionManifest.iconMap(json["icons"])
        let action = json["action"] as? [String: Any] ?? json["browser_action"] as? [String: Any] ?? [:]
        actionPopup = (action["default_popup"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        actionTitle = action["default_title"] as? String
        actionIcons = ExtensionManifest.iconMap(action["default_icon"])
        let background = json["background"] as? [String: Any] ?? [:]
        serviceWorker = background["service_worker"] as? String
        backgroundType = background["type"] as? String
        backgroundScripts = background["scripts"] as? [String] ?? []
        backgroundPage = background["page"] as? String
        contentScripts = (json["content_scripts"] as? [[String: Any]] ?? []).map(ContentScriptEntry.init(json:))
        permissions = json["permissions"] as? [String] ?? []
        optionalPermissions = json["optional_permissions"] as? [String] ?? []
        hostPermissions = json["host_permissions"] as? [String] ?? []
        optionalHostPermissions = json["optional_host_permissions"] as? [String] ?? []
        webAccessibleResources = json["web_accessible_resources"] as? [[String: Any]] ?? []
        let optionsUI = json["options_ui"] as? [String: Any]
        optionsPage = (optionsUI?["page"] as? String) ?? (json["options_page"] as? String)
        optionsOpenInTab = optionsUI?["open_in_tab"] as? Bool ?? (json["options_page"] != nil)
        commands = json["commands"] as? [String: Any] ?? [:]
        let dnr = json["declarative_net_request"] as? [String: Any]
        ruleResources = (dnr?["rule_resources"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let path = item["path"] as? String else { return nil }
            return DNRRuleResource(id: id, enabled: item["enabled"] as? Bool ?? false, path: path)
        }
        key = json["key"] as? String
        updateURL = json["update_url"] as? String
        homepageURL = json["homepage_url"] as? String
        minimumChromeVersion = json["minimum_chrome_version"] as? String
    }

    static func iconMap(_ value: Any?) -> [String: String] {
        if let path = value as? String { return ["128": path] }
        if let dict = value as? [String: Any] { return dict.compactMapValues { $0 as? String } }
        return [:]
    }

    /// Chrome tolerates `//` comments in manifest.json.
    static func stripComments(_ text: String) -> String {
        var out = ""
        var inString = false, escaped = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1; continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2; continue
            }
            out.append(c); i += 1
        }
        return out
    }

    /// Host patterns requested at install time (host_permissions + content script matches).
    public var requestedHostPatterns: [String] {
        var set: [String] = []
        for pattern in hostPermissions + contentScripts.flatMap(\.matches) where !set.contains(pattern) { set.append(pattern) }
        // MV2-style host entries inside permissions.
        for p in permissions where p.contains("://") || p == "<all_urls>" { if !set.contains(p) { set.append(p) } }
        return set
    }

    public var apiPermissions: [String] { permissions.filter { !$0.contains("://") && $0 != "<all_urls>" } }

    public var backgroundKind: String {
        if serviceWorker != nil { return "service_worker" }
        if backgroundPage != nil { return "page" }
        if !backgroundScripts.isEmpty { return "scripts" }
        return "none"
    }

    public func bestIcon(prefer size: Int = 64) -> String? {
        let all = actionIcons.isEmpty ? icons : actionIcons.merging(icons) { a, _ in a }
        let sorted = all.compactMap { key, value in Int(key).map { ($0, value) } }.sorted { $0.0 < $1.0 }
        return (sorted.first { $0.0 >= size } ?? sorted.last)?.1
    }

    /// Whether `path` is declared as web accessible for `url`.
    public func isWebAccessible(_ path: String, from url: URL?) -> Bool {
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        for entry in webAccessibleResources {
            let resources = entry["resources"] as? [String] ?? []
            let matches = entry["matches"] as? [String] ?? []
            let resourceOK = resources.contains { glob in
                (try? URLMatcher.includeRule(glob.hasPrefix("/") ? String(glob.dropFirst()) : glob))?.matches(normalized: path) ?? false
            }
            guard resourceOK else { continue }
            guard let url else { return true }
            if matches.isEmpty || URLMatcher.anyMatch(matches.compactMap { try? URLMatcher.matchPattern($0) }, url) { return true }
        }
        return false
    }
}

/// `_locales/*/messages.json` handling, shared with the JS runtime (messages are passed down).
public struct ExtensionLocalization {
    public var messages: [String: [String: Any]]
    public var locale: String

    public init(messages: [String: [String: Any]] = [:], locale: String = "en") {
        self.messages = messages; self.locale = locale
    }

    /// Loads the best matching locale from an unpacked extension directory.
    public static func load(from directory: URL, defaultLocale: String?, preferred: [String]) -> ExtensionLocalization {
        let localesDir = directory.appendingPathComponent("_locales")
        let available = (try? FileManager.default.contentsOfDirectory(atPath: localesDir.path)) ?? []
        guard !available.isEmpty else { return ExtensionLocalization() }
        var candidates: [String] = []
        for language in preferred {
            let normalized = language.replacingOccurrences(of: "-", with: "_")
            candidates.append(normalized)
            if normalized.hasPrefix("zh_Hans") { candidates.append("zh_CN") }
            if normalized.hasPrefix("zh_Hant") { candidates.append("zh_TW") }
            if let base = normalized.split(separator: "_").first { candidates.append(String(base)) }
        }
        if let defaultLocale { candidates.append(defaultLocale) }
        candidates.append("en")
        var merged: [String: [String: Any]] = [:]
        var chosen = defaultLocale ?? "en"
        // Load fallback first, then overlay the preferred locale.
        for locale in [defaultLocale, candidates.first(where: { c in available.contains { $0.lowercased() == c.lowercased() } })].compactMap({ $0 }) {
            guard let folder = available.first(where: { $0.lowercased() == locale.lowercased() }) else { continue }
            let file = localesDir.appendingPathComponent(folder).appendingPathComponent("messages.json")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: Data(ExtensionManifest.stripComments(String(decoding: data, as: UTF8.self)).utf8)) as? [String: Any] else { continue }
            for (key, value) in json {
                if let dict = value as? [String: Any] { merged[key.lowercased()] = dict }
            }
            chosen = folder
        }
        return ExtensionLocalization(messages: merged, locale: chosen)
    }

    public func message(_ key: String, substitutions: [String] = [], extensionID: String = "") -> String {
        let lower = key.lowercased()
        switch lower {
        case "@@extension_id": return extensionID
        case "@@ui_locale": return locale
        case "@@bidi_dir": return "ltr"
        case "@@bidi_reversed_dir": return "rtl"
        case "@@bidi_start_edge": return "left"
        case "@@bidi_end_edge": return "right"
        default: break
        }
        guard let entry = messages[lower], var text = entry["message"] as? String else { return "" }
        let placeholders = entry["placeholders"] as? [String: Any] ?? [:]
        for (name, value) in placeholders {
            guard let content = (value as? [String: Any])?["content"] as? String else { continue }
            let resolved = ExtensionLocalization.applyNumbered(content, substitutions)
            text = text.replacingOccurrences(of: "$\(name)$", with: resolved, options: .caseInsensitive)
        }
        return ExtensionLocalization.applyNumbered(text, substitutions).replacingOccurrences(of: "$$", with: "$")
    }

    static func applyNumbered(_ text: String, _ substitutions: [String]) -> String {
        var result = text
        for index in stride(from: 9, through: 1, by: -1) {
            let value = index <= substitutions.count ? substitutions[index - 1] : ""
            result = result.replacingOccurrences(of: "$\(index)", with: value)
        }
        return result
    }

    /// Replaces `__MSG_key__` tokens.
    public func localize(_ text: String?, extensionID: String = "") -> String? {
        guard var text, text.contains("__MSG_") else { return text }
        while let start = text.range(of: "__MSG_"), let end = text.range(of: "__", range: start.upperBound..<text.endIndex) {
            let key = String(text[start.upperBound..<end.lowerBound])
            text.replaceSubrange(start.lowerBound..<end.upperBound, with: message(key, extensionID: extensionID))
        }
        return text
    }

    /// JSON-friendly representation passed to the JS runtime.
    public var jsonMessages: [String: Any] { messages }
}

/// Human readable permission warnings shown at install / update time.
public enum PermissionDescriber {
    public struct Line: Hashable, Identifiable {
        public let text: String
        public let level: SupportLevel
        public var id: String { text }
    }

    public static let apiDescriptions: [String: String] = [
        "tabs": "读取你的浏览记录（标签页地址和标题）",
        "downloads": "管理下载",
        "storage": "保存本地数据",
        "unlimitedStorage": "存储不受限制的数据",
        "cookies": "读取和修改 Cookie",
        "notifications": "显示通知",
        "contextMenus": "向长按菜单添加项目",
        "scripting": "在网页中执行脚本",
        "activeTab": "在你点击扩展时访问当前网页",
        "declarativeNetRequest": "屏蔽网页上的内容",
        "declarativeNetRequestWithHostAccess": "屏蔽或修改网页请求",
        "declarativeNetRequestFeedback": "读取屏蔽统计",
        "webNavigation": "读取你的浏览记录（页面导航事件）",
        "clipboardWrite": "修改你复制和粘贴的数据",
        "clipboardRead": "读取你复制和粘贴的数据",
        "alarms": "定时执行任务",
        "i18n": "多语言",
        "commands": "键盘快捷键",
        "history": "读取和修改浏览历史",
        "bookmarks": "读取和修改书签",
        "webRequest": "观察网络请求",
        "webRequestBlocking": "拦截网络请求",
        "nativeMessaging": "与本机应用通信",
        "offscreen": "创建离屏文档",
        "sidePanel": "显示侧边栏",
        "identity": "使用账号登录",
        "management": "管理应用、扩展程序和主题",
        "privacy": "更改隐私相关设置",
        "proxy": "读取和修改代理设置",
        "debugger": "访问页面调试器后端",
        "tabGroups": "查看和管理标签页组",
        "favicon": "读取网站图标",
        "search": "使用默认搜索引擎搜索",
        "sessions": "读取最近关闭的标签页",
        "topSites": "读取常用网站列表",
        "userScripts": "管理用户脚本",
        "background": "在后台运行",
        "idle": "检测设备空闲状态",
        "power": "阻止设备休眠",
        "system.display": "读取显示器信息",
        "contentSettings": "更改网站设置",
        "declarativeContent": "根据网页内容执行操作",
        "fontSettings": "读取和修改字体设置",
        "gcm": "接收推送消息",
        "geolocation": "读取你的位置",
        "tts": "朗读文本",
    ]

    public static func describe(apiPermissions: [String], hostPatterns: [String]) -> [Line] {
        var lines: [Line] = []
        let hosts = hostPatterns.filter { !$0.isEmpty }
        if hosts.contains(where: { URLMatcher.displayHost(ofPattern: $0) == nil }) {
            lines.append(Line(text: "读取和修改所有网站的数据", level: .supported))
        } else if !hosts.isEmpty {
            let names = Array(Set(hosts.compactMap { URLMatcher.displayHost(ofPattern: $0) })).sorted()
            let shown = names.prefix(4).joined(separator: "、")
            lines.append(Line(text: "读取和修改你在 \(shown)\(names.count > 4 ? " 等 \(names.count) 个网站" : "") 上的数据", level: .supported))
        }
        for permission in apiPermissions {
            let text = apiDescriptions[permission] ?? permission
            let level = ChromeAPIMatrix.permissionLevel(permission)
            lines.append(Line(text: text + (level == .supported ? "" : "（\(level == .partial ? "部分支持" : "不支持")）"), level: level))
        }
        return lines
    }
}
