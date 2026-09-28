import Foundation

public enum UserScriptRunAt: String, Codable, CaseIterable {
    case documentStart = "document-start"
    case documentBody = "document-body"
    case documentEnd = "document-end"
    case documentIdle = "document-idle"
}

public enum UserScriptInjectInto: String, Codable {
    case auto, page, content
}

public struct UserScriptResourceRef: Codable, Hashable {
    public var name: String
    public var url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public struct MetadataIssue: Codable, Hashable, Identifiable {
    public enum Severity: String, Codable { case error, warning }
    public var line: Int
    public var message: String
    public var severity: Severity
    public var id: String { "\(line):\(message)" }
    public init(line: Int, message: String, severity: Severity) {
        self.line = line; self.message = message; self.severity = severity
    }
}

/// Parsed `// ==UserScript==` block.
public struct UserScriptMetadata: Codable, Hashable {
    public var name = ""
    public var namespace = ""
    public var version = ""
    public var description = ""
    public var author = ""
    public var matches: [String] = []
    public var includes: [String] = []
    public var excludes: [String] = []
    public var excludeMatches: [String] = []
    public var runAt: UserScriptRunAt = .documentIdle
    public var grants: [String] = []
    public var connects: [String] = []
    public var requires: [String] = []
    public var resources: [UserScriptResourceRef] = []
    public var icon: String?
    public var downloadURL: String?
    public var updateURL: String?
    public var homepage: String?
    public var noframes = false
    public var injectInto: UserScriptInjectInto = .auto
    public var raw: [String: [String]] = [:]

    public init() {}

    /// Whether the script needs the privileged GM bridge.
    public var usesGMAPIs: Bool { grants.contains { $0 != "none" } }
    public var grantsNone: Bool { grants.isEmpty || grants == ["none"] }

    /// Grants that need no native capability. A script that only uses these can run as plain page
    /// JavaScript (real `unsafeWindow`), because nothing privileged has to be reachable from there.
    public static let pageSafeGrants: Set<String> = [
        "none", "unsafeWindow", "GM_info", "GM.info", "GM_log", "GM.log",
        "GM_addStyle", "GM.addStyle", "GM_addElement", "GM.addElement", "window.onurlchange",
    ]

    /// Whether any requested grant needs the native GM bridge.
    public var needsPrivilegedBridge: Bool { grants.contains { !Self.pageSafeGrants.contains($0) } }

    /// Security rule: the native GM bridge is only reachable from the script's own isolated
    /// WKContentWorld, never from the page world (page JavaScript could forge anything a page-world
    /// script can send). Therefore:
    /// - `@inject-into content` → isolated world;
    /// - `@inject-into page` → page world, privileged GM APIs unavailable (explicit errors);
    /// - `auto` → page world only when no grant needs the bridge; otherwise isolated, where
    ///   `unsafeWindow` is the isolated window (shared DOM, page JS globals not visible).
    public var runsInPageWorld: Bool {
        switch injectInto {
        case .page: return true
        case .content: return false
        case .auto: return !needsPrivilegedBridge
        }
    }

    /// Kept for call sites that pass the source; the body no longer influences world selection
    /// (using `unsafeWindow` in a privileged script must not move it into the page world).
    public func runsInPageWorld(source: String) -> Bool { runsInPageWorld }

    /// Grants the script asked for but cannot use because it runs in the page world.
    public var unavailableInPageWorld: [String] {
        runsInPageWorld ? grants.filter { !Self.pageSafeGrants.contains($0) } : []
    }

    public static func referencesUnsafeWindow(_ source: String) -> Bool {
        let body = source.range(of: "==/UserScript==").map { String(source[$0.upperBound...]) } ?? source
        return body.range(of: #"\bunsafeWindow\b"#, options: .regularExpression) != nil
    }

    /// Compiled include rules (matches + includes).
    public func includeRules() -> [URLRule] {
        matches.compactMap { try? URLMatcher.matchPattern($0) } + includes.compactMap { try? URLMatcher.includeRule($0) }
    }

    public func excludeRules() -> [URLRule] {
        excludes.compactMap { try? URLMatcher.includeRule($0) } + excludeMatches.compactMap { try? URLMatcher.matchPattern($0) }
    }

    public func matches(_ url: URL) -> Bool {
        let normalized = URLMatcher.normalize(url)
        guard includeRules().contains(where: { $0.matches(normalized: normalized) }) else { return false }
        return !excludeRules().contains(where: { $0.matches(normalized: normalized) })
    }
}

/// GM API compatibility table. Declared explicitly so the manager can show the level
/// of every grant instead of failing silently.
public enum GMCompatibility {
    public static let table: [(api: String, level: SupportLevel, note: String)] = [
        ("GM_getValue / GM.getValue", .supported, "每个脚本独立存储，不使用网页 localStorage"),
        ("GM_setValue / GM.setValue", .supported, "写入原生存储并同步到其他标签页"),
        ("GM_deleteValue / GM.deleteValue", .supported, ""),
        ("GM_listValues / GM.listValues", .supported, ""),
        ("GM_getValues / GM_setValues / GM_deleteValues", .supported, "Violentmonkey 批量接口"),
        ("GM_addValueChangeListener", .supported, "跨标签页 remote 变更通知"),
        ("GM_addStyle / GM.addStyle", .supported, "受 CSP 限制时自动改用 adoptedStyleSheets"),
        ("GM_addElement", .supported, ""),
        ("GM_setClipboard / GM.setClipboard", .supported, "通过原生剪贴板"),
        ("GM_xmlhttpRequest / GM.xmlHttpRequest", .supported, "原生网络请求，遵守 @connect；支持 text/json/blob/arraybuffer/document/stream，真实下载进度，cookie / nocache / revalidate / anonymous 选项；不支持上传进度"),
        ("GM_download / GM.download", .supported, "交给下载管理器；下载完成后才触发 onload，支持 onprogress / abort / timeout / saveAs"),
        ("GM_openInTab / GM.openInTab", .supported, "active / insert / incognito；返回的对象支持 close()、closed 和 onclose"),
        ("GM_registerMenuCommand", .supported, "显示在页面菜单 → 脚本命令"),
        ("GM_unregisterMenuCommand", .supported, ""),
        ("GM_getResourceText / GM.getResourceText", .supported, "@resource 安装时下载"),
        ("GM_getResourceURL / GM.getResourceUrl", .supported, "返回 data: URL"),
        ("GM_info / GM.info", .supported, ""),
        ("GM_log", .supported, ""),
        ("GM_notification / GM.notification", .partial, "应用内横幅 + 本地通知；支持 onclick / ondone / timeout / highlight / url，不支持图片、tag 替换和进度"),
        ("GM_getTab / GM_saveTab / GM_getTabs", .supported, "按标签页保存，App 重启后仍在，标签页关闭后清除；无痕标签页不保存"),
        ("GM_cookie / GM.cookie", .supported, "list / set / delete，可读写 HttpOnly Cookie；仅限当前网页所在网站和脚本 @match / @include / @connect 覆盖的域名"),
        ("GM_audio / GM.audio", .partial, "setMute / getState / 状态监听；静音作用于网页中的 video / audio 元素（含之后新加入的），不含 Web Audio 和未插入网页的 Audio 对象；状态监听每秒检查一次"),
        ("unsafeWindow", .partial, "只申请无特权 @grant（none / unsafeWindow / GM_info / GM_addStyle / GM_addElement / GM_log）的脚本运行在页面环境，unsafeWindow 是真正的页面 window；同时申请特权 GM API 的脚本出于安全运行在隔离环境，unsafeWindow 等同隔离环境的 window（共享 DOM，看不到页面 JS 全局变量）"),
        ("@inject-into page + 特权 GM API", .partial, "页面环境中不提供原生 GM 桥（网页脚本可伪造其中的任何调用），这些 API 调用时明确报错；需要特权 API 时请改用 @inject-into content / auto"),
        ("window.onurlchange", .partial, "通过 history API 钩子实现"),
        ("window.close / window.focus", .supported, ""),
        ("GM_webRequest", .unsupported, "WKWebView 不能拦截或改写网页请求，调用时返回 Unsupported API 错误（Tampermonkey 也已不推荐）"),
    ]

    public static let supportedGrants: Set<String> = [
        "none", "unsafeWindow", "window.close", "window.focus", "window.onurlchange",
        "GM_info", "GM.info", "GM_log", "GM.log",
        "GM_getValue", "GM.getValue", "GM_setValue", "GM.setValue", "GM_deleteValue", "GM.deleteValue",
        "GM_listValues", "GM.listValues", "GM_getValues", "GM.getValues", "GM_setValues", "GM.setValues",
        "GM_deleteValues", "GM.deleteValues",
        "GM_addValueChangeListener", "GM.addValueChangeListener", "GM_removeValueChangeListener", "GM.removeValueChangeListener",
        "GM_addStyle", "GM.addStyle", "GM_addElement", "GM.addElement",
        "GM_setClipboard", "GM.setClipboard", "GM_xmlhttpRequest", "GM.xmlHttpRequest", "GM.xmlhttpRequest",
        "GM_download", "GM.download", "GM_openInTab", "GM.openInTab",
        "GM_registerMenuCommand", "GM.registerMenuCommand", "GM_unregisterMenuCommand", "GM.unregisterMenuCommand",
        "GM_getResourceText", "GM.getResourceText", "GM_getResourceURL", "GM.getResourceUrl", "GM.getResourceURL",
        "GM_notification", "GM.notification", "GM_getTab", "GM.getTab", "GM_saveTab", "GM.saveTab", "GM_getTabs", "GM.getTabs",
        "GM_cookie", "GM.cookie", "GM_audio", "GM.audio",
    ]
}

public enum MetadataParser {
    public struct Result {
        public var metadata: UserScriptMetadata
        public var issues: [MetadataIssue]
        public var hasErrors: Bool { issues.contains { $0.severity == .error } }
        public var firstError: String? { issues.first { $0.severity == .error }?.message }
    }

    static let multiValueKeys: Set<String> = ["match", "include", "exclude", "exclude-match", "grant", "connect", "require", "resource"]

    /// Parses the metadata block, returning the metadata together with editor diagnostics.
    public static func parse(_ source: String) -> Result {
        var meta = UserScriptMetadata()
        var issues: [MetadataIssue] = []
        let lines = source.components(separatedBy: "\n")
        var startLine: Int?
        var endLine: Int?
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if startLine == nil, line.hasPrefix("//"), line.dropFirst(2).trimmingCharacters(in: .whitespaces) == "==UserScript==" {
                startLine = index
            } else if startLine != nil, line.hasPrefix("//"), line.dropFirst(2).trimmingCharacters(in: .whitespaces) == "==/UserScript==" {
                endLine = index; break
            }
        }
        guard let start = startLine else {
            issues.append(MetadataIssue(line: 1, message: "缺少 // ==UserScript== 元数据头", severity: .error))
            return Result(metadata: meta, issues: issues)
        }
        guard let end = endLine else {
            issues.append(MetadataIssue(line: start + 1, message: "缺少 // ==/UserScript== 结束标记", severity: .error))
            return Result(metadata: meta, issues: issues)
        }
        for index in (start + 1)..<end {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard line.hasPrefix("//") else {
                issues.append(MetadataIssue(line: index + 1, message: "元数据块中只能包含 // 注释行", severity: .warning))
                continue
            }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            let parts = body.dropFirst().split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyPart = parts.first else { continue }
            let key = String(keyPart)
            let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            meta.raw[key, default: []].append(value)
            let lineNo = index + 1
            switch key {
            case "name": if meta.name.isEmpty { meta.name = value }
            case "namespace": meta.namespace = value
            case "version": meta.version = value
            case "description": if meta.description.isEmpty { meta.description = value }
            case "author": meta.author = value
            case "match":
                if value.isEmpty { issues.append(.init(line: lineNo, message: "@match 为空", severity: .error)); break }
                do { _ = try URLMatcher.matchPattern(value); meta.matches.append(value) }
                catch { issues.append(.init(line: lineNo, message: "\(error.localizedDescription)", severity: .error)) }
            case "include":
                do { _ = try URLMatcher.includeRule(value); meta.includes.append(value) }
                catch { issues.append(.init(line: lineNo, message: "\(error.localizedDescription)", severity: .error)) }
            case "exclude":
                do { _ = try URLMatcher.includeRule(value); meta.excludes.append(value) }
                catch { issues.append(.init(line: lineNo, message: "\(error.localizedDescription)", severity: .error)) }
            case "exclude-match":
                do { _ = try URLMatcher.matchPattern(value); meta.excludeMatches.append(value) }
                catch { issues.append(.init(line: lineNo, message: "\(error.localizedDescription)", severity: .error)) }
            case "run-at":
                if let runAt = UserScriptRunAt(rawValue: value) { meta.runAt = runAt }
                else if value == "context-menu" {
                    meta.runAt = .documentIdle
                    issues.append(.init(line: lineNo, message: "@run-at context-menu 不支持，按 document-idle 运行", severity: .warning))
                } else {
                    issues.append(.init(line: lineNo, message: "未知的 @run-at：\(value)", severity: .error))
                }
            case "grant":
                if !value.isEmpty { meta.grants.append(value) }
                if !value.isEmpty, !GMCompatibility.supportedGrants.contains(value) {
                    issues.append(.init(line: lineNo, message: "\(value) 尚未实现，调用时会抛出 Unsupported API 错误", severity: .warning))
                }
            case "connect": if !value.isEmpty { meta.connects.append(value) }
            case "require":
                if URL(string: value)?.scheme?.hasPrefix("http") == true { meta.requires.append(value) }
                else { issues.append(.init(line: lineNo, message: "@require 需要 http(s) 地址：\(value)", severity: .error)) }
            case "resource":
                let pieces = value.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
                if pieces.count == 2 {
                    let url = String(pieces[1]).trimmingCharacters(in: .whitespaces)
                    meta.resources.append(UserScriptResourceRef(name: String(pieces[0]), url: url))
                } else {
                    issues.append(.init(line: lineNo, message: "@resource 格式应为：名称 URL", severity: .error))
                }
            case "icon", "iconURL", "defaulticon": if meta.icon == nil { meta.icon = value }
            case "downloadURL": meta.downloadURL = value
            case "updateURL": meta.updateURL = value
            case "homepage", "homepageURL", "website", "source": if meta.homepage == nil { meta.homepage = value }
            case "noframes": meta.noframes = true
            case "inject-into":
                if let mode = UserScriptInjectInto(rawValue: value) { meta.injectInto = mode }
                else { issues.append(.init(line: lineNo, message: "未知的 @inject-into：\(value)", severity: .warning)) }
            default:
                if key.hasPrefix("name:") || key.hasPrefix("description:") { break }
            }
        }
        if meta.name.isEmpty { issues.append(.init(line: start + 1, message: "缺少 @name", severity: .error)) }
        if meta.matches.isEmpty && meta.includes.isEmpty {
            issues.append(.init(line: start + 1, message: "没有 @match 或 @include，脚本不会在任何网页运行", severity: .warning))
        }
        if meta.grants.contains("none") && meta.grants.count > 1 {
            issues.append(.init(line: start + 1, message: "@grant none 与其他 @grant 同时出现，将忽略 none", severity: .warning))
            meta.grants.removeAll { $0 == "none" }
        }
        if meta.version.isEmpty { meta.version = "0" }
        return Result(metadata: meta, issues: issues)
    }

    /// Compares two dotted versions (`1.2.10` > `1.2.9`). Non-numeric parts compare lexically.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
        let b = rhs.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "0", y = i < b.count ? b[i] : "0"
            if let xi = Int(x), let yi = Int(y) {
                if xi != yi { return xi < yi ? .orderedAscending : .orderedDescending }
            } else if x != y {
                return x < y ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}
