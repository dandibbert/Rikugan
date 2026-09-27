import Foundation
import Compression

enum ChromeAPIMatrix {
    struct Entry: Equatable { var api: String; var level: String; var note: String }
    static let entries: [Entry] = [
        .init(api: "runtime", level: "Supported", note: "由 WKWebExtension 实现 onMessage、sendMessage、connect、getURL、id。不是自研 chrome.runtime。sendNativeMessage / connectNative 明确禁用。"),
        .init(api: "storage", level: "Supported", note: "由 WKWebExtension 的扩展存储提供 local / sync / session，按身份隔离。"),
        .init(api: "scripting", level: "Partial", note: "扩展脚本调用 chrome.scripting.insertCSS 与 chrome.scripting.executeScript。WebKit 已实现时沿用 WebKit，不覆盖。没有这些方法时，service worker 与 content script 里的桥转发 css、func/code、args 和 files。files 从扩展包读取，缺失则返回错误。executeScript 默认 ISOLATED，在扩展 content script 世界执行；world 为 MAIN 时在页面世界执行。target.tabId 交给该标签的 content script；宿主也能按标签 UUID 或 bridgeTabID 找到 BrowserSession 里的标签。target.allFrames 会跑进同源子框架，frameIds 里 0 是顶层框架、其后是 window.frames 的顺序。insertCSS 写入页面 CSSOM，并接受 world。不是第二套完整 chrome.scripting。"),
        .init(api: "tabs", level: "Partial", note: "query、create、update、reload、remove、activate。窗口管理只覆盖 App 内窗口。"),
        .init(api: "permissions", level: "Supported", note: "安装确认、可选权限与网站权限变更都会再次询问。"),
        .init(api: "content_scripts", level: "Supported", note: "matches、exclude_matches、js、css、run_at、all_frames。"),
        .init(api: "action", level: "Supported", note: "工具栏按钮调用 WKWebExtensionContext.performAction，弹窗由 WebKit 绘制。扩展页使用 WebKit 扩展 origin。"),
        .init(api: "contextMenus", level: "Partial", note: "由 WebKit 提供的上下文菜单，不覆盖全部桌面上下文。"),
        .init(api: "commands", level: "Partial", note: "iOS 没有桌面级快捷键系统，仅保留 WebKit 能分发的命令。"),
        .init(api: "cookies", level: "Partial", note: "只能访问当前身份网站存储里 WebKit 暴露的 cookie。"),
        .init(api: "downloads", level: "Unsupported", note: "chrome.downloads 的 download、search、pause、resume、cancel、erase、removeFile、acceptDanger、show、showDefaultFolder、getFileIcon、open、setShelfEnabled、setUiOptions，以及 onCreated、onChanged、onErased、onDeterminingFilename，都会拒绝为 Unsupported: downloads.<name>。不接到 DownloadCenter。App 内下载仍是另一套。"),
        .init(api: "i18n", level: "Partial", note: "跟随扩展包内的 _locales，缺少的文案不会伪造。"),
        .init(api: "notifications", level: "Partial", note: "扩展脚本调用 chrome.notifications.create、update、clear、getAll、getPermissionLevel。create 与 update 写入通知记录、App 内列表，并提交 UNUserNotificationCenter。getPermissionLevel 在系统通知已授权时返回 granted，未授权或被拒绝时返回 denied。按钮保存在记录上。点按列表行触发 onClicked，点按按钮触发 onButtonClicked，滑掉一行或 clear 触发 onClosed，点「通知设置」触发 onShowSettings。后台轮询取回这些事件。iconUrl 和 imageUrl 从扩展包相对路径、扩展 URL 或 https 图片读取，显示在列表行上，并在系统允许时作为 UNNotificationAttachment。progress 保存 0 到 100 并显示在列表行上，update 会改它；系统通知本身没有进度条。列表行出现时，以及系统通知提交成功时，都会通过轮询触发 onShown。系统通知本身不能深链按钮。"),
        .init(api: "webNavigation", level: "Partial", note: "只覆盖 WebKit 实际发出的导航事件。"),
        .init(api: "declarativeNetRequest", level: "Partial", note: "扩展自带静态规则由 WebKit 执行，block 可以生效。Rikugan 不实现 redirect、modifyHeaders，也不调用私有 WebKit API。广告拦截是另一套引擎。"),
        .init(api: "webRequest", level: "Unsupported", note: "onBeforeRequest、onSendHeaders、onBeforeRedirect 等 blocking 事件的 addListener 会拒绝为 Unsupported，并列入 unsupportedAPIs。不能在请求发出前同步改头或观察完整请求体。"),
        .init(api: "debugger", level: "Unsupported", note: "chrome.debugger.attach、detach、sendCommand、getTargets 以及 onEvent、onDetach 会拒绝为 Unsupported，并列入 unsupportedAPIs。不使用私有 WebKit 检查器 API。"),
        .init(api: "nativeMessaging", level: "Unsupported", note: "runtime.sendNativeMessage、connectNative 与 onConnectNative.addListener 会拒绝为 Unsupported，并列入 unsupportedAPIs。")
    ]
    struct Method: Equatable { var api: String; var name: String; var level: String; var note: String }
    static let methods: [Method] = [
        .init(api: "runtime", name: "sendMessage", level: "Partial", note: "WebKit 提供时沿用。内容脚本在 background ready 之前调用会进入 BackgroundGate 队列。ready 后按顺序调用原来的 runtime.sendMessage，发送方拿到 background onMessage 的返回值。探测失败进入 failed，排队的 sendMessage 和 connect 拒绝为 background failed。shutdown 之后要等下一次 cold start 才再接受消息。"),
        .init(api: "runtime", name: "connect", level: "Partial", note: "ready 前的 Port 保持 pending，postMessage 先排队。ready 后调用原来的 runtime.connect，按顺序把排队的 postMessage 交给这个 Port，并触发 onConnect。disconnect、重新 connect、多个 port 和关闭标签都会结束对应 port。"),
        .init(api: "runtime", name: "sendNativeMessage", level: "Unsupported", note: "调用会拒绝为 Unsupported: runtime.sendNativeMessage，并列入 unsupportedAPIs。"),
        .init(api: "runtime", name: "connectNative", level: "Unsupported", note: "调用会拒绝为 Unsupported: runtime.connectNative。onConnectNative.addListener 拒绝为 Unsupported: runtime.onConnectNative。已列入 unsupportedAPIs。"),
        .init(api: "storage", name: "local", level: "Supported", note: "WKWebExtension 扩展存储，按身份隔离。"),
        .init(api: "storage", name: "sync", level: "Partial", note: "走 WebKit 的 sync 区域，不是另一套云同步。"),
        .init(api: "storage", name: "session", level: "Partial", note: "走 WebKit 的 session 区域。"),
        .init(api: "scripting", name: "executeScript", level: "Partial", note: "css/func/code/files、world、tabId、allFrames、frameIds。不是完整 chrome.scripting。"),
        .init(api: "scripting", name: "insertCSS", level: "Partial", note: "写入页面 CSSOM，接受 world。"),
        .init(api: "scripting", name: "registerContentScripts", level: "Unsupported", note: "调用 registerContentScripts、unregisterContentScripts、getRegisteredContentScripts 会拒绝为 Unsupported: scripting.registerContentScripts（以及对应方法名），并列入 unsupportedAPIs。不会动态注册 content script。"),
        .init(api: "tabs", name: "query", level: "Supported", note: "返回当前窗口里 WebKit 能看到的标签。"),
        .init(api: "tabs", name: "get", level: "Supported", note: "按标签取 URL、标题和加载状态。暂停的标签没有 live WKWebView，URL 来自保存的地址。"),
        .init(api: "tabs", name: "create", level: "Supported", note: "openNewTabUsing。"),
        .init(api: "tabs", name: "update", level: "Partial", note: "可以激活和加载 URL。不保证改写全部 Chrome update 字段。"),
        .init(api: "tabs", name: "remove", level: "Supported", note: "关闭对应标签，不退出 App。"),
        .init(api: "tabs", name: "reload", level: "Supported", note: "暂停且没有 interactionState 时加载保存的 URL。有 interactionState 时先恢复再 reload。进程被系统杀掉后重新加载保存的 URL，不恢复 JS 堆。不会对空白 WKWebView 调用 reload。"),
        .init(api: "tabs", name: "captureVisibleTab", level: "Partial", note: "只对仍有 WKWebView 的标签截图。没有 live web view 时返回空图，不挂载空白视图，也不把标签标成 liveBackground。"),
        .init(api: "permissions", name: "contains", level: "Partial", note: "安装和可选权限会再问用户。不伪造已授权。"),
        .init(api: "permissions", name: "request", level: "Partial", note: "WebKit 的权限提示回调到确认框。"),
        .init(api: "action", name: "onClicked", level: "Partial", note: "工具栏按钮走 performAction。没有浏览器 action 时由 WebKit 打开 popup。"),
        .init(api: "contextMenus", name: "create", level: "Partial", note: "只覆盖 WebKit 实际给出的菜单，不是全部桌面上下文。"),
        .init(api: "cookies", name: "getAll", level: "Partial", note: "只能读当前身份 WKWebsiteDataStore 暴露的 cookie。"),
        .init(api: "downloads", name: "download", level: "Unsupported", note: "download、search、pause、cancel 以及其余 downloads 方法和事件都会拒绝为 Unsupported: downloads.<name>。不把扩展下载接到第二套下载管理器。"),
        .init(api: "webNavigation", name: "onCommitted", level: "Partial", note: "只有 WebKit 实际发出的导航事件。"),
        .init(api: "declarativeNetRequest", name: "静态 block", level: "Partial", note: "扩展包里的 block 规则由 WebKit 执行。已有 block 测试不能被改坏。"),
        .init(api: "declarativeNetRequest", name: "redirect", level: "Unsupported", note: "updateDynamicRules 或 updateSessionRules 的 action.type 为 redirect 时拒绝为 Unsupported: declarativeNetRequest.redirect。不会变成 HTTP 2xx。WebKit 已有的其他规则调用会原样交给 WebKit。"),
        .init(api: "declarativeNetRequest", name: "modifyHeaders", level: "Unsupported", note: "action.type 为 modifyHeaders 时拒绝为 Unsupported: declarativeNetRequest.modifyHeaders。不能改请求头或响应头。"),
        .init(api: "webRequest", name: "onBeforeRequest", level: "Unsupported", note: "addListener 会拒绝为 Unsupported: webRequest.onBeforeRequest。onSendHeaders 与 onBeforeRedirect 同样拒绝。没有 blocking webRequest。"),
        .init(api: "debugger", name: "attach", level: "Unsupported", note: "调用会拒绝为 Unsupported: debugger.attach。detach、sendCommand、getTargets 同样拒绝。不使用私有检查器 API。")
    ]
    static func additions(old: [String], new: [String]) -> [String] {
        let known = Set(old)
        return new.filter { !known.contains($0) }.sorted()
    }
    static func describe(_ permission: String) -> String {
        switch permission {
        case "storage": return "保存本地数据"
        case "tabs": return "查看和切换标签页"
        case "scripting": return "在网页中运行脚本"
        case "downloads": return "管理下载"
        case "cookies": return "读取网站 Cookie"
        case "notifications": return "显示通知"
        case "webNavigation": return "观察页面跳转"
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess": return "按规则拦截网络请求"
        case "contextMenus": return "添加上下文菜单"
        case "activeTab": return "在你点击扩展时访问当前标签页"
        case "alarms": return "安排定时任务"
        case "webRequest": return "观察网络请求"
        case "<all_urls>", "*://*/*", "http://*/*", "https://*/*": return "读取和修改所有网站的数据"
        default:
            if permission.contains("://") { return "读取和修改 \(permission) 的数据" }
            return "使用 \(permission)"
        }
    }
}

enum ExtensionCatalog {
    static func storeID(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil { return value }
        guard let url = URL(string: value) else { return nil }
        let candidates = url.path.split(separator: "/").map(String.init).reversed()
        return candidates.first { $0.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil }
    }
    static func chromeDownloadURL(id: String) -> URL? {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")
        parts?.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "131.0.6778.86"),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc")
        ]
        return parts?.url
    }
    static func edgeDownloadURL(id: String) -> URL? {
        var parts = URLComponents(string: "https://edge.microsoft.com/extensionwebstorebase/v1/crx")
        parts?.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc")
        ]
        return parts?.url
    }
}

struct ParsedManifest: Equatable {
    var name: String
    var version: String
    var description: String
    var manifestVersion: Int
    var permissions: [String]
    var hostPermissions: [String]
    var optionalPermissions: [String]
    var updateURL: String
    var background: Bool
    var popup: Bool
    var contentScripts: Int
    var declarativeNetRequest: Bool
}

enum ExtensionManifest {
    static func parse(_ data: Data) throws -> ParsedManifest {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RikuganError.message("manifest.json 不是对象。")
        }
        let version = json["manifest_version"] as? Int ?? 0
        guard version == 3 else { throw RikuganError.message("只支持 Manifest V3。这个包的 manifest_version 是 \(version == 0 ? "缺失" : String(version))。") }
        let permissions = stringList(json["permissions"])
        let optional = stringList(json["optional_permissions"])
        let hosts = stringList(json["host_permissions"])
        let action = (json["action"] as? [String: Any]) ?? [:]
        let background = json["background"] as? [String: Any]
        return ParsedManifest(
            name: (json["name"] as? String)?.isEmpty == false ? json["name"] as! String : "未命名扩展",
            version: (json["version"] as? String) ?? "0",
            description: json["description"] as? String ?? "",
            manifestVersion: version,
            permissions: permissions, hostPermissions: hosts, optionalPermissions: optional,
            updateURL: json["update_url"] as? String ?? "",
            background: background?["service_worker"] != nil,
            popup: action["default_popup"] != nil,
            contentScripts: (json["content_scripts"] as? [Any])?.count ?? 0,
            declarativeNetRequest: json["declarative_net_request"] != nil
        )
    }
    private static func stringList(_ value: Any?) -> [String] {
        (value as? [String]) ?? []
    }
}

enum ZipArchive {
    static func store(_ files: [(String, Data)]) -> Data {
        var local = Data(), central = Data()
        var offset = 0
        for (name, content) in files {
            let nameData = Data(name.utf8)
            let crc = checksum(content)
            var header = Data()
            header.append(uint32(0x04034b50)); header.append(uint16(20)); header.append(uint16(0)); header.append(uint16(0))
            header.append(uint16(0)); header.append(uint16(0)); header.append(uint32(crc))
            header.append(uint32(UInt32(content.count))); header.append(uint32(UInt32(content.count)))
            header.append(uint16(UInt16(nameData.count))); header.append(uint16(0)); header.append(nameData)
            local.append(header); local.append(content)
            var item = Data()
            item.append(uint32(0x02014b50)); item.append(uint16(20)); item.append(uint16(20)); item.append(uint16(0)); item.append(uint16(0))
            item.append(uint16(0)); item.append(uint16(0)); item.append(uint32(crc))
            item.append(uint32(UInt32(content.count))); item.append(uint32(UInt32(content.count)))
            item.append(uint16(UInt16(nameData.count))); item.append(uint16(0)); item.append(uint16(0)); item.append(uint16(0)); item.append(uint16(0))
            item.append(uint32(0)); item.append(uint32(UInt32(offset))); item.append(nameData)
            central.append(item)
            offset += header.count + content.count
        }
        var end = Data()
        end.append(uint32(0x06054b50)); end.append(uint16(0)); end.append(uint16(0))
        end.append(uint16(UInt16(files.count))); end.append(uint16(UInt16(files.count)))
        end.append(uint32(UInt32(central.count))); end.append(uint32(UInt32(local.count))); end.append(uint16(0))
        return local + central + end
    }

    static func extract(data: Data, path: String) -> Data? {
        let bytes = [UInt8](data)
        guard let directory = centralDirectory(bytes) else { return nil }
        for entry in directory where entry.name == path {
            guard entry.offset + 30 <= bytes.count else { return nil }
            let nameLength = int16(bytes, entry.offset + 26)
            let extra = int16(bytes, entry.offset + 28)
            let start = entry.offset + 30 + nameLength + extra
            guard start + entry.compressed <= bytes.count else { return nil }
            let slice = Data(bytes[start..<(start + entry.compressed)])
            if entry.method == 0 { return slice }
            if entry.method == 8 { return inflate(slice, expected: entry.uncompressed) }
            return nil
        }
        return nil
    }

    static func unpack(_ data: Data) -> [(String, Data)]? {
        let bytes = [UInt8](data)
        guard let directory = centralDirectory(bytes) else { return nil }
        var files: [(String, Data)] = []
        for entry in directory {
            if entry.name.isEmpty || entry.name.hasSuffix("/") { continue }
            guard entry.offset + 30 <= bytes.count else { return nil }
            let nameLength = int16(bytes, entry.offset + 26)
            let extra = int16(bytes, entry.offset + 28)
            let start = entry.offset + 30 + nameLength + extra
            guard start >= 0, start + entry.compressed <= bytes.count else { return nil }
            let slice = Data(bytes[start..<(start + entry.compressed)])
            let file: Data?
            if entry.method == 0 { file = slice }
            else if entry.method == 8 { file = inflate(slice, expected: entry.uncompressed) }
            else { return nil }
            guard let file else { return nil }
            files.append((entry.name, file))
        }
        return files
    }

    private struct Entry { var name: String; var method: Int; var compressed: Int; var uncompressed: Int; var offset: Int }
    private static func centralDirectory(_ bytes: [UInt8]) -> [Entry]? {
        guard bytes.count >= 22 else { return nil }
        var end: Int?
        for index in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) where int32(bytes, index) == 0x06054b50 {
            end = index; break
        }
        guard let end else { return nil }
        let count = int16(bytes, end + 10), offset = int32(bytes, end + 16)
        var cursor = offset, entries: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= end, int32(bytes, cursor) == 0x02014b50 else { return nil }
            let method = int16(bytes, cursor + 10)
            let compressed = int32(bytes, cursor + 20)
            let uncompressed = int32(bytes, cursor + 24)
            let nameLength = int16(bytes, cursor + 28)
            let extra = int16(bytes, cursor + 30)
            let comment = int16(bytes, cursor + 32)
            let local = int32(bytes, cursor + 42)
            let name = String(bytes: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) ?? ""
            entries.append(Entry(name: name, method: method, compressed: compressed, uncompressed: uncompressed, offset: local))
            cursor += 46 + nameLength + extra + comment
        }
        return entries
    }

    private static func inflate(_ input: Data, expected: Int) -> Data? {
        guard !input.isEmpty else { return Data() }
        let capacity = max(expected, 65_536)
        return input.withUnsafeBytes { raw -> Data? in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var stream = compression_stream(dst_ptr: nil, dst_size: 0, src_ptr: nil, src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = source
            stream.src_size = input.count
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            var output = Data()
            while output.count <= 8_000_000 {
                stream.dst_ptr = buffer
                stream.dst_size = capacity
                let status = compression_stream_process(&stream, 1)
                let produced = capacity - stream.dst_size
                if produced > 0 { output.append(buffer, count: produced) }
                if status == COMPRESSION_STATUS_END { return output }
                if status == COMPRESSION_STATUS_ERROR || produced == 0 { return nil }
            }
            return nil
        }
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1) }
        }
        return crc ^ 0xFFFF_FFFF
    }
    private static func uint16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private static func uint32(_ value: UInt32) -> Data { uint16(UInt16(value & 0xFFFF)) + uint16(UInt16(value >> 16)) }
    private static func int16(_ bytes: [UInt8], _ index: Int) -> Int { Int(bytes[index]) | Int(bytes[index + 1]) << 8 }
    private static func int32(_ bytes: [UInt8], _ index: Int) -> Int { int16(bytes, index) | int16(bytes, index + 2) << 16 }
}

enum CRXArchive {
    static func zipData(from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 16, String(bytes: bytes.prefix(4), encoding: .utf8) == "Cr24" else {
            throw RikuganError.message("不是 CRX 包。请使用 Chrome 扩展的 .crx，或已经解出的 ZIP。")
        }
        let version = ZipArchive.int32Public(bytes, 4)
        let zip: Data
        if version == 2 {
            let pub = ZipArchive.int32Public(bytes, 8), sig = ZipArchive.int32Public(bytes, 12)
            let start = 16 + pub + sig
            guard pub >= 0, sig >= 0, start < bytes.count else { throw RikuganError.message("CRX2 头损坏。") }
            zip = Data(bytes[start...])
        } else if version == 3 {
            let header = ZipArchive.int32Public(bytes, 8)
            let start = 12 + header
            guard header >= 0, start < bytes.count else { throw RikuganError.message("CRX3 头损坏。") }
            zip = Data(bytes[start...])
        } else {
            throw RikuganError.message("不支持的 CRX 版本 \(version)。")
        }
        try ArchiveValidator.validate(zip)
        return zip
    }
}

extension ZipArchive {
    static func int32Public(_ bytes: [UInt8], _ index: Int) -> Int { Int(bytes[index]) | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 24 }
}

enum ExtensionUpdateManifest {
    /// Chrome/Edge update manifests are XML (`<gupdate><updatecheck codebase version>`), not the CRX itself.
    static func package(in data: Data) -> (url: URL, version: String)? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let lowered = text.lowercased()
        guard lowered.contains("<updatecheck"), lowered.contains("codebase") else { return nil }
        guard let codebase = attribute("codebase", in: text), let url = URL(string: codebase), url.scheme?.lowercased() == "https" else { return nil }
        return (url, attribute("version", in: text) ?? "")
    }
    private static func attribute(_ name: String, in text: String) -> String? {
        let pattern = name + #"\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found]).replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum InternalPages {
    static func kind(_ url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = (url.host ?? "").lowercased()
        guard scheme == "rikugan" || scheme == "chrome" || scheme == "edge" else { return nil }
        if host == "extensions" || url.path == "/extensions" || url.absoluteString.contains("extensions") { return "extensions" }
        if host == "settings" { return "settings" }
        return "extensions"
    }
}
