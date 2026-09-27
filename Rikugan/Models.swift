import Foundation

struct BrowserProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var symbol = "person.crop.circle"
    var tabs: [SavedTab] = []
    var selectedTabID: UUID?
    var bookmarks: [PageRecord] = []
    var history: [PageRecord] = []
    var scripts: [UserScript] = []
    var extensions: [ExtensionRecord] = []
    var searchEngine = "https://www.google.com/search?q="
    var tabGroups: [TabGroup] = []
    var closedTabs: [ClosedTab] = []
    var bookmarkFolders: [BookmarkFolder] = []
    var siteSettings: [SiteSettings] = []
    var webPermissions: [WebPermission] = []
    var settings = BrowserSettings()
    var searchHistory: [String] = []
    var downloads: [DownloadRecord] = []

    func site(for host: String?) -> SiteSettings? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        return siteSettings.filter { $0.host.lowercased() == host || host.hasSuffix("." + $0.host.lowercased()) }
            .max { $0.host.count < $1.host.count }
    }
    func permission(host: String, kind: String) -> String {
        webPermissions.first { $0.host.lowercased() == host.lowercased() && $0.kind == kind }?.decision ?? "ask"
    }
}

enum WebPermissionPolicy {
    static func aggregate(_ decisions: [String]) -> String {
        if decisions.contains("block") { return "block" }
        if !decisions.isEmpty && decisions.allSatisfy({ $0 == "allow" }) { return "allow" }
        return "ask"
    }
}

struct SavedTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var url = ""
    var title = "新标签页"
    var desktop = false
    var groupID: UUID? = nil
    var isPrivate = false
    var autoRefreshSeconds = 0
}

struct PageRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var date = Date()
    var folderID: UUID? = nil
}

struct ExtensionRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var version: String
    var detail: String
    var relativePath: String
    var enabled = true
    var allowedPermissions: [String]
    var allowedPatterns: [String]
    var requestedPatterns: [String]
    var updateURL = ""
    var storeID = ""
    var backgroundMode: String?
}

struct AppState: Codable {
    var schema = 2
    var profiles: [BrowserProfile]
    var activeProfileID: UUID
    static func fresh() -> AppState {
        let profile = BrowserProfile(name: "个人", symbol: "person.crop.circle")
        return AppState(profiles: [profile], activeProfileID: profile.id)
    }
}

struct UserScript: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var version: String
    var description: String
    var source: String
    var matches: [String]
    var includes: [String]
    var excludes: [String]
    var excludeMatches: [String]
    var grants: [String]
    var connects: [String]
    var requires: [String]
    var dependencies: [String] = []
    var runAt: String
    var noFrames: Bool
    var enabled = true
    var storageJSON = "{}"
    var namespace = ""
    var author = ""
    var icon = ""
    var downloadURL = ""
    var updateURL = ""
    var resources: [ScriptResource] = []
    var updatedAt = Date()
    var isolated: Bool { !grants.isEmpty && !grants.contains("none") }

    static let supportedGrants: Set<String> = [
        "none", "GM_info", "GM.info", "GM_addStyle", "GM.addStyle", "GM_log", "GM.log",
        "GM_getValue", "GM.getValue", "GM_setValue", "GM.setValue", "GM_deleteValue", "GM.deleteValue",
        "GM_listValues", "GM.listValues", "GM_xmlhttpRequest", "GM.xmlHttpRequest",
        "GM_addValueChangeListener", "GM.addValueChangeListener", "GM_removeValueChangeListener", "GM.removeValueChangeListener",
        "GM_setClipboard", "GM.setClipboard", "GM_openInTab", "GM.openInTab",
        "GM_registerMenuCommand", "GM.registerMenuCommand", "GM_unregisterMenuCommand", "GM.unregisterMenuCommand",
        "GM_getResourceText", "GM.getResourceText", "GM_getResourceURL", "GM.getResourceURL", "unsafeWindow"
    ]

    static let capabilityNotes: [String: String] = [
        "GM_getValue": "Supported。同步镜像通过原生通知跨标签/iframe 更新；兼容旧 JSON，并支持 undefined、特殊数字、BigInt、Date、RegExp、Map、Set、ArrayBuffer 和常见 TypedArray。",
        "GM_addValueChangeListener": "Supported。提供旧值、新值和 remote；按脚本、身份、无痕会话隔离，删除使用 undefined。",
        "GM_xmlhttpRequest": "Partial。支持真实取消、超时、下载进度、FormData/二进制正文和常见响应类型；不自动附带登录 Cookie，不支持 stream/同步请求。响应最多 8 MB，正文 2 MB。",
        "GM_getResourceText": "Supported。安装时下载 @resource，文本以缓存提供。",
        "GM_getResourceURL": "Supported。返回 data URL，不是 blob: 临时地址。",
        "unsafeWindow": "Partial。@grant none 就是页面 window；隔离脚本只能用 unsafeWindow.eval，或给 JSON 可序列化属性赋值。",
        "document-body": "Supported。document-start 注入后等到 body 存在再执行。"
    ]

    static func parse(_ source: String) throws -> UserScript {
        guard source.utf8.count <= 2_000_000,
              let start = source.range(of: "// ==UserScript=="),
              let end = source.range(of: "// ==/UserScript==", range: start.upperBound..<source.endIndex) else {
            throw RikuganError.message("不是有效的用户脚本：需要完整的 ==UserScript== 元数据头，且文件不能超过 2 MB。")
        }
        var metadata: [String: [String]] = [:]
        for line in source[start.upperBound..<end.lowerBound].components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { continue }
            let field = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard field.hasPrefix("@") else { continue }
            let parts = field.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let key = parts.first else { continue }
            metadata[String(key), default: []].append(parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "")
        }
        let grants = metadata["grant"] ?? []
        let unsupported = grants.filter { !supportedGrants.contains($0) }
        guard unsupported.isEmpty else { throw RikuganError.message("此版尚不支持这些脚本 API：\(unsupported.joined(separator: ", "))。没有静默安装不兼容脚本。") }
        guard !(grants.contains("none") && grants.count > 1) else { throw RikuganError.message("@grant none 不能与其他授权混用。") }
        if grants.contains("none") == false && !grants.isEmpty,
           metadata["inject-into"]?.contains("page") == true {
            throw RikuganError.message("带原生权限的脚本只能运行在隔离环境，暂不支持 @inject-into page。")
        }
        let matches = metadata["match"] ?? [], includes = metadata["include"] ?? []
        guard !matches.isEmpty || !includes.isEmpty else { throw RikuganError.message("脚本必须声明 @match 或 @include，不会默认在所有网站运行。") }
        for pattern in matches + (metadata["exclude-match"] ?? []) {
            guard URLRules.validMatchPattern(pattern) else { throw RikuganError.message("无效的 @match 规则：\(pattern)") }
        }
        let runAt = metadata["run-at"]?.first ?? "document-end"
        guard ["document-start", "document-body", "document-end", "document-idle"].contains(runAt) else {
            throw RikuganError.message("暂不支持注入时机 \(runAt)。")
        }
        let requires = metadata["require"] ?? []
        guard requires.count <= 8 else { throw RikuganError.message("一个脚本最多允许 8 个 @require 依赖。") }
        try UserScriptSyntax.validate(source)
        let resources = try resourceList(metadata["resource"] ?? [])
        var script = UserScript(name: metadata["name"]?.first ?? "未命名脚本", version: metadata["version"]?.first ?? "1.0",
                          description: metadata["description"]?.first ?? "", source: source, matches: matches, includes: includes,
                          excludes: metadata["exclude"] ?? [], excludeMatches: metadata["exclude-match"] ?? [],
                          grants: grants, connects: metadata["connect"] ?? [], requires: requires,
                          runAt: runAt, noFrames: metadata["noframes"] != nil)
        script.namespace = metadata["namespace"]?.first ?? ""
        script.author = metadata["author"]?.first ?? ""
        script.icon = metadata["icon"]?.first ?? ""
        script.downloadURL = httpsOnly(metadata["downloadURL"]?.first)
        script.updateURL = httpsOnly(metadata["updateURL"]?.first)
        script.resources = resources
        return script
    }

    private static func httpsOnly(_ value: String?) -> String {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https" else { return "" }
        return url.absoluteString
    }
    private static func resourceList(_ rows: [String]) throws -> [ScriptResource] {
        guard rows.count <= 8 else { throw RikuganError.message("一个脚本最多 8 个 @resource。") }
        var resources: [ScriptResource] = []
        for raw in rows {
            let parts = raw.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let url = URL(string: String(parts[1])), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw RikuganError.message("@resource 需要名称和 HTTP(S) 地址：\(raw)")
            }
            let name = String(parts[0])
            guard !resources.contains(where: { $0.name == name }) else { throw RikuganError.message("@resource 名称重复：\(name)") }
            resources.append(ScriptResource(name: name, url: url.absoluteString))
        }
        return resources
    }

    func matchesURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let included = matches.contains { URLRules.match($0, url: url) } || includes.contains { URLRules.glob($0, value: url.absoluteString) }
        return included && !excludes.contains { URLRules.glob($0, value: url.absoluteString) }
            && !excludeMatches.contains { URLRules.match($0, url: url) }
    }

    func permits(_ operation: String) -> Bool {
        let name = operation == "xmlHttpRequest" ? "xmlhttpRequest" : operation
        return grants.contains("GM_" + name) || grants.contains("GM." + operation)
    }
}

enum URLRules {
    static func validMatchPattern(_ pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        return pattern.range(of: #"^(\*|https?)://(\*|\*\.[^/*:]+|[^/*:]+)(:\d+)?/.*$"#, options: .regularExpression) != nil
    }
    static func glob(_ pattern: String, value: String) -> Bool {
        if pattern.hasPrefix("/"), pattern.hasSuffix("/"), pattern.count > 2 {
            return value.range(of: String(pattern.dropFirst().dropLast()), options: .regularExpression) != nil
        }
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return value.range(of: regex, options: .regularExpression) != nil
    }
    static func match(_ pattern: String, url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return false }
        if pattern == "<all_urls>" { return true }
        let parts = pattern.components(separatedBy: "://")
        guard parts.count == 2, parts[0] == "*" || parts[0] == scheme, let slash = parts[1].firstIndex(of: "/") else { return false }
        let hostRule = String(parts[1][..<slash]).lowercased()
        let actualHost = url.port.map { host + ":" + String($0) } ?? host
        let hostOK = hostRule == "*" || hostRule == host || hostRule == actualHost || (hostRule.hasPrefix("*.") && (host == String(hostRule.dropFirst(2)) || host.hasSuffix(String(hostRule.dropFirst()))))
        guard hostOK else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/") + (components?.percentEncodedQuery.map { "?" + $0 } ?? "")
        return glob(String(parts[1][slash...]), value: path)
    }
    static func directURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["https", "http", "rikugan", "chrome", "edge"].contains(scheme) else { return nil }
        return url
    }
    static func inputURL(_ input: String, searchEngine: String, customEngines: [SearchEngine] = []) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let direct = directURL(value) { return direct }
        if let space = value.firstIndex(where: { $0.isWhitespace }) {
            let key = String(value[..<space])
            let rest = value[value.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if let template = SearchEngines.template(for: key, custom: customEngines), !rest.isEmpty {
                return searchURL(String(rest), template: template)
            }
        }
        if !value.contains(where: { $0.isWhitespace }), value.contains(".") || value.hasPrefix("localhost") {
            return URL(string: "https://" + value)
        }
        return searchURL(value, template: searchEngine)
    }
    static func searchURL(_ query: String, template: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        if template.contains("{query}") { return URL(string: template.replacingOccurrences(of: "{query}", with: encoded)) }
        return URL(string: template + encoded)
    }
    static func isSearch(_ input: String) -> Bool {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if directURL(value) != nil { return false }
        if !value.contains(where: { $0.isWhitespace }), (value.contains(".") || value.hasPrefix("localhost")) { return false }
        return !value.isEmpty
    }
    static func connectionAllowed(_ url: URL, origin: URL, rules: [String]) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        return rules.contains { rule in
            let r = rule.lowercased()
            let scheme = url.scheme?.lowercased(), originScheme = origin.scheme?.lowercased()
            let sameOrigin = host == origin.host?.lowercased() && scheme == originScheme
                && (url.port ?? (scheme == "https" ? 443 : 80)) == (origin.port ?? (originScheme == "https" ? 443 : 80))
            return r == "*" || (r == "self" && sameOrigin) || (r != "self" && (host == r || host.hasSuffix("." + r)))
        }
    }
}

enum RikuganError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ArchiveValidator {
    /// Validate ZIP central directory before handing an untrusted archive to WebKit.
    static func validate(_ data: Data) throws {
        guard data.count >= 22, data.count <= 32 * 1024 * 1024 else { throw RikuganError.message("扩展 ZIP 大小必须在 22 字节到 32 MB 之间。") }
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        var end: Int?
        for i in stride(from: b.count - 22, through: max(0, b.count - 65557), by: -1) {
            if u32(i) == 0x06054b50 && i + 22 + u16(i+20) == b.count { end = i; break }
        }
        guard let e = end, u16(e+4) == 0, u16(e+6) == 0, u16(e+8) == u16(e+10) else { throw RikuganError.message("ZIP 目录损坏或使用了不支持的分卷格式。") }
        let count = u16(e+10), size = u32(e+12), offset = u32(e+16)
        guard count > 0, count <= 10000, offset < e, size <= e - offset else { throw RikuganError.message("ZIP 目录过大或无效，暂不支持 ZIP64。") }
        var p = offset, total = 0, manifest = false
        for _ in 0..<count {
            guard p + 46 <= e, u32(p) == 0x02014b50 else { throw RikuganError.message("ZIP 文件目录损坏。") }
            let nameLength = u16(p+28), extra = u16(p+30), comment = u16(p+32)
            guard p + 46 + nameLength + extra + comment <= e else { throw RikuganError.message("ZIP 文件路径损坏。") }
            let name = String(bytes: b[(p+46)..<(p+46+nameLength)], encoding: .utf8) ?? ""
            let mode = u32(p+38) >> 16
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.split(separator: "/").contains(".."), mode & 0xF000 != 0xA000, u16(p+8) & 1 == 0 else {
                throw RikuganError.message("扩展 ZIP 含危险路径、符号链接或加密内容，已拒绝。")
            }
            total += u32(p+24)
            guard total <= 128 * 1024 * 1024 else { throw RikuganError.message("扩展解压后超过 128 MB。") }
            manifest = manifest || name == "manifest.json"
            p += 46 + nameLength + extra + comment
        }
        guard manifest else { throw RikuganError.message("ZIP 根目录必须有 manifest.json。请压缩扩展文件本身，而不是其外层文件夹。CRX 请先转换为标准 ZIP。") }
    }
}

