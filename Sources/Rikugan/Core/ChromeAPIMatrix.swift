import Foundation

/// Explicit capability matrix of the Chrome extension API surface implemented by Rikugan.
/// The JS runtime exposes every namespace listed here; `unsupported` namespaces are stubs that
/// throw / reject with `Unsupported API` rather than being `undefined`.
public enum ChromeAPIMatrix {
    public struct Entry: Hashable, Identifiable {
        public let namespace: String
        public let level: SupportLevel
        public let note: String
        public var id: String { namespace }
    }

    public static let entries: [Entry] = [
        .init(namespace: "runtime", level: .supported, note: "sendMessage / onMessage / connect / Port / getURL / getManifest / onInstalled / onStartup / openOptionsPage / getPlatformInfo"),
        .init(namespace: "storage", level: .supported, note: "local / sync / session / managed（只读空）/ onChanged，按扩展隔离的原生存储"),
        .init(namespace: "scripting", level: .supported, note: "executeScript（func / files，ISOLATED / MAIN，allFrames）/ insertCSS / removeCSS / registerContentScripts"),
        .init(namespace: "tabs", level: .partial, note: "query / get / create / update / remove / reload / sendMessage / connect / captureVisibleTab / 事件；无 move、discard、zoom"),
        .init(namespace: "permissions", level: .supported, note: "contains / getAll / request（弹出确认）/ remove / 事件"),
        .init(namespace: "action", level: .supported, note: "popup / badge / title / icon / onClicked / openPopup"),
        .init(namespace: "i18n", level: .supported, note: "getMessage / getUILanguage / getAcceptLanguages / detectLanguage"),
        .init(namespace: "contextMenus", level: .partial, note: "页面与链接长按菜单中的扩展菜单项；无子菜单图标"),
        .init(namespace: "commands", level: .partial, note: "getAll；iPad 硬件键盘快捷键不可用，onCommand 仅从菜单触发"),
        .init(namespace: "cookies", level: .partial, note: "get / getAll / set / remove，需主机权限；onChanged 不触发"),
        .init(namespace: "downloads", level: .partial, note: "download / search / cancel / onChanged，交给下载管理器"),
        .init(namespace: "notifications", level: .partial, note: "create / clear / onClicked（本地通知 / 应用内横幅）"),
        .init(namespace: "webNavigation", level: .partial, note: "onBeforeNavigate / onCommitted / onDOMContentLoaded / onCompleted / onHistoryStateUpdated / getAllFrames"),
        .init(namespace: "declarativeNetRequest", level: .partial, note: "block / allow / allowAllRequests / upgradeScheme 编译为 WKContentRuleList；redirect、modifyHeaders 不支持"),
        .init(namespace: "alarms", level: .partial, note: "应用运行期间有效，iOS 后台不保证计时"),
        .init(namespace: "windows", level: .partial, note: "getCurrent / getAll / getLastFocused / create（新标签）"),
        .init(namespace: "extension", level: .partial, note: "getURL / getViews（空）/ isAllowedIncognitoAccess"),
        .init(namespace: "tabGroups", level: .unsupported, note: ""),
        .init(namespace: "webRequest", level: .unsupported, note: "WKWebView 无法观察或拦截请求"),
        .init(namespace: "history", level: .unsupported, note: ""),
        .init(namespace: "bookmarks", level: .unsupported, note: ""),
        .init(namespace: "sidePanel", level: .unsupported, note: ""),
        .init(namespace: "offscreen", level: .unsupported, note: ""),
        .init(namespace: "identity", level: .unsupported, note: ""),
        .init(namespace: "management", level: .unsupported, note: ""),
        .init(namespace: "debugger", level: .unsupported, note: ""),
        .init(namespace: "devtools", level: .unsupported, note: ""),
        .init(namespace: "proxy", level: .unsupported, note: ""),
        .init(namespace: "privacy", level: .unsupported, note: ""),
        .init(namespace: "sessions", level: .unsupported, note: ""),
        .init(namespace: "topSites", level: .unsupported, note: ""),
        .init(namespace: "search", level: .unsupported, note: ""),
        .init(namespace: "tts", level: .unsupported, note: ""),
        .init(namespace: "idle", level: .unsupported, note: ""),
        .init(namespace: "power", level: .unsupported, note: ""),
        .init(namespace: "gcm", level: .unsupported, note: ""),
        .init(namespace: "userScripts", level: .unsupported, note: "请使用 Rikugan 内置用户脚本系统"),
        .init(namespace: "declarativeContent", level: .unsupported, note: ""),
        .init(namespace: "fontSettings", level: .unsupported, note: ""),
        .init(namespace: "contentSettings", level: .unsupported, note: ""),
        .init(namespace: "browsingData", level: .unsupported, note: ""),
        .init(namespace: "system", level: .unsupported, note: ""),
        .init(namespace: "enterprise", level: .unsupported, note: ""),
        .init(namespace: "readingList", level: .unsupported, note: ""),
    ]

    public static func level(of namespace: String) -> SupportLevel {
        entries.first { $0.namespace == namespace }?.level ?? .unsupported
    }

    public static var unsupportedNamespaces: [String] { entries.filter { $0.level == .unsupported }.map(\.namespace) }

    public static func permissionLevel(_ permission: String) -> SupportLevel {
        switch permission {
        case "storage", "unlimitedStorage", "scripting", "activeTab", "tabs", "i18n", "background": return .supported
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess", "declarativeNetRequestFeedback",
             "contextMenus", "cookies", "downloads", "notifications", "webNavigation", "alarms", "commands",
             "clipboardWrite", "clipboardRead", "favicon": return .partial
        default:
            if permission.contains("://") || permission == "<all_urls>" { return .supported }
            return level(of: permission)
        }
    }
}
