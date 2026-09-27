import Foundation
import Compression

enum ChromeAPIMatrix {
    struct Entry: Equatable { var api: String; var level: String; var note: String }
    static let entries: [Entry] = [
        .init(api: "runtime", level: "Supported", note: "由 WKWebExtension 实现 onMessage、sendMessage、connect、getURL、id。不是自研 chrome.runtime。sendNativeMessage / connectNative 明确禁用。"),
        .init(api: "storage", level: "Supported", note: "由 WKWebExtension 的扩展存储提供 local / sync / session，按身份隔离。"),
        .init(api: "scripting", level: "Partial", note: "扩展脚本调用 chrome.scripting.insertCSS 与 chrome.scripting.executeScript。WebKit 已实现时沿用 WebKit，不覆盖。没有这些方法时，service worker 与 content script 里的桥把 css 字符串、func/code 字符串转发到 BrowserSession.insertExtensionCSS / executeExtensionScript，目标是扩展点名的标签页，否则是当前标签页的顶层页面世界。world 与 files 丢弃，files 返回错误。不是第二套完整 chrome.scripting。"),
        .init(api: "tabs", level: "Partial", note: "query、create、update、reload、remove、activate。窗口管理只覆盖 App 内窗口。"),
        .init(api: "permissions", level: "Supported", note: "安装确认、可选权限与网站权限变更都会再次询问。"),
        .init(api: "content_scripts", level: "Supported", note: "matches、exclude_matches、js、css、run_at、all_frames。"),
        .init(api: "action", level: "Supported", note: "工具栏按钮调用 WKWebExtensionContext.performAction，弹窗由 WebKit 绘制。扩展页使用 WebKit 扩展 origin。"),
        .init(api: "contextMenus", level: "Partial", note: "由 WebKit 提供的上下文菜单，不覆盖全部桌面上下文。"),
        .init(api: "commands", level: "Partial", note: "iOS 没有桌面级快捷键系统，仅保留 WebKit 能分发的命令。"),
        .init(api: "cookies", level: "Partial", note: "只能访问当前身份网站存储里 WebKit 暴露的 cookie。"),
        .init(api: "downloads", level: "Partial", note: "浏览器自己的下载管理器可用；chrome.downloads 取决于 WebKit。"),
        .init(api: "i18n", level: "Partial", note: "跟随扩展包内的 _locales，缺少的文案不会伪造。"),
        .init(api: "notifications", level: "Partial", note: "扩展脚本调用 chrome.notifications.create、clear、getAll 时，桥把记录交给 App 内通知列表和 SystemNotifications.deliver。页面 Notification 仍走同一条系统通知。onClicked、按钮和 update 没有。不是完整 chrome.notifications。"),
        .init(api: "webNavigation", level: "Partial", note: "只覆盖 WebKit 实际发出的导航事件。"),
        .init(api: "declarativeNetRequest", level: "Partial", note: "扩展自带 DNR 由 WebKit 执行。Rikugan 的广告拦截是独立引擎，不把扩展改写成用户脚本。"),
        .init(api: "debugger", level: "Unsupported", note: "已列入 unsupportedAPIs。不暴露 chrome.debugger，也不使用私有 WebKit 检查器 API。"),
        .init(api: "nativeMessaging", level: "Unsupported", note: "runtime.sendNativeMessage 与 connectNative 已列入 unsupportedAPIs。")
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
            var stream = compression_stream()
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
