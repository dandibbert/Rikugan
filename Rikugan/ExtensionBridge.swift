import Foundation
import UIKit
import WebKit

struct ExtensionNoticeRecord: Equatable {
    var id: String
    var title: String
    var message: String
    var buttons: [String] = []
    var iconURL: String = ""
    var imageURL: String = ""
    var progress: Int? = nil
    var extensionID: String = ""
}

struct ExtensionNotificationEvent: Equatable {
    var type: String
    var notificationID: String
    var buttonIndex: Int = -1
    var byUser = false
    var extensionID: String = ""
}

struct ExtensionHostCall: Equatable {
    var kind: String = ""
    var css: String? = nil
    var code: String? = nil
    var files: [String] = []
    var isolated: Bool = false
    var allFrames = false
    var frameIDs: [Int] = []
    var tabID: String = ""
    var error: String? = nil
}

struct ExtensionHostOutcome {
    var result: Any? = nil
    var error: String? = nil
}

enum ExtensionBridge {
    static let marker = "/* rikugan-extension-bridge */"
    static let fileName = "rikugan-host-bridge.js"
    static let handlerName = "rikuganExtension"

    static var source: String = {
        guard let url = Bundle.main.url(forResource: "ExtensionBridge", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8), text.contains(marker) else {
            return marker + "\nfunction installRikuganExtensionBridge(){}"
        }
        return text
    }()

    static func patchWorker(_ text: String, bridge: String) -> String {
        text.contains(marker) ? text : bridge + "\n" + text
    }

    static func command(api: String, details: [String: Any]) -> ExtensionHostCall {
        let files = stringList(details["files"])
        let target = details["target"] as? [String: Any] ?? [:]
        let frames = frameRequest(target)
        switch api {
        case "scripting.insertCSS":
            let css = details["css"] as? String
            if css == nil && files.isEmpty { return ExtensionHostCall(error: "css string or files is required") }
            return ExtensionHostCall(kind: "css", css: css, files: files, allFrames: frames.all, frameIDs: frames.ids, tabID: tabToken(target["tabId"]))
        case "scripting.executeScript":
            let world = (details["world"] as? String)?.uppercased() ?? "ISOLATED"
            let isolated = world != "MAIN"
            if !files.isEmpty { return ExtensionHostCall(kind: "script", files: files, isolated: isolated, allFrames: frames.all, frameIDs: frames.ids, tabID: tabToken(target["tabId"])) }
            if let code = details["code"] as? String, !code.isEmpty { return ExtensionHostCall(kind: "script", code: code, isolated: isolated, allFrames: frames.all, frameIDs: frames.ids, tabID: tabToken(target["tabId"])) }
            if let function = details["func"] as? String, !function.isEmpty {
                return ExtensionHostCall(kind: "script", code: "(\(function)).apply(null, \(jsonText(details["args"] ?? [])))", isolated: isolated, allFrames: frames.all, frameIDs: frames.ids, tabID: tabToken(target["tabId"]))
            }
            return ExtensionHostCall(error: "func, code, or files is required")
        default:
            return ExtensionHostCall(error: "unsupported")
        }
    }

    static func spansFrames(allFrames: Bool, frameIDs: [Int]) -> Bool {
        if allFrames { return true }
        return !frameIDs.isEmpty && frameIDs != [0]
    }

    static func frameRunner(sources: [String], frameIDs: [Int], allFrames: Bool) -> String {
        let ids = allFrames ? "null" : jsonText(frameIDs)
        return """
        (function(){
          var sources = \(jsonText(sources));
          var ids = \(ids);
          function collect(win, bag) {
            bag.push(win);
            var count = 0;
            try { count = win.frames.length; } catch (error) { count = 0; }
            for (var index = 0; index < count; index += 1) {
              try { collect(win.frames[index], bag); } catch (error) { bag.push(null); }
            }
          }
          var frames = [];
          collect(window, frames);
          var chosen = ids || frames.map(function (_, index) { return index; });
          var results = [];
          chosen.forEach(function (index) {
            var frame = frames[index];
            if (!frame) { results.push({ error: 'frame unavailable' }); return; }
            sources.forEach(function (source) {
              try { results.push({ result: frame.eval(String(source)) }); }
              catch (error) { results.push({ error: String(error && error.message || error) }); }
            });
          });
          return results;
        })()
        """
    }

    static func frameCSS(sheets: [String], frameIDs: [Int], allFrames: Bool) -> String {
        let ids = allFrames ? "null" : jsonText(frameIDs)
        return """
        (function(){
          var sheets = \(jsonText(sheets));
          var ids = \(ids);
          function collect(win, bag) {
            bag.push(win);
            var count = 0;
            try { count = win.frames.length; } catch (error) { count = 0; }
            for (var index = 0; index < count; index += 1) {
              try { collect(win.frames[index], bag); } catch (error) { bag.push(null); }
            }
          }
          function insert(frame, css) {
            var doc = frame.document;
            if (!doc || !doc.createElement) return false;
            var style = doc.createElement('style');
            style.setAttribute('data-rikugan-extension', '1');
            style.textContent = css;
            (doc.head || doc.documentElement).appendChild(style);
            return true;
          }
          var frames = [];
          collect(window, frames);
          var chosen = ids || frames.map(function (_, index) { return index; });
          var inserted = false;
          chosen.forEach(function (index) {
            var frame = frames[index];
            if (!frame) return;
            sheets.forEach(function (css) { if (insert(frame, css)) inserted = true; });
          });
          return inserted;
        })()
        """
    }

    static func permissionLevel(authorized: Bool) -> String { authorized ? "granted" : "denied" }

    static func packagedImage(_ reference: String, packages: [(url: URL, directory: Bool)]) -> Data? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("data:") { return dataImage(trimmed) }
        guard let relative = packagePath(trimmed) else { return nil }
        for package in packages {
            if let data = readBytes(relative, package: package.url, directory: package.directory), looksLikeImage(data) { return data }
        }
        return nil
    }

    static func notificationBytes(_ reference: String, packages: [(url: URL, directory: Bool)]) async -> Data? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("https://"), let url = URL(string: trimmed) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 2_000_000, looksLikeImage(data) else { return nil }
            return data
        }
        return packagedImage(trimmed, packages: packages)
    }

    static func apply(api: String, details: [String: Any], records: inout [String: ExtensionNoticeRecord], deliver: (ExtensionNoticeRecord) -> Void) -> ExtensionHostOutcome {
        switch api {
        case "notifications.create":
            let options = details["options"] as? [String: Any] ?? [:]
            let explicit = details["id"] as? String ?? ""
            let id = explicit.isEmpty ? UUID().uuidString : explicit
            let record = ExtensionNoticeRecord(id: id, title: options["title"] as? String ?? "", message: noticeMessage(options), buttons: buttonTitles(options["buttons"]), iconURL: options["iconUrl"] as? String ?? "", imageURL: options["imageUrl"] as? String ?? "", progress: options["progress"] == nil ? nil : progressValue(options["progress"]), extensionID: details["extensionId"] as? String ?? "")
            records[id] = record
            deliver(record)
            return ExtensionHostOutcome(result: id)
        case "notifications.update":
            let id = details["id"] as? String ?? ""
            guard var record = records[id] else { return ExtensionHostOutcome(result: false) }
            let options = details["options"] as? [String: Any] ?? [:]
            if let title = options["title"] as? String { record.title = title }
            if options["message"] != nil || options["body"] != nil { record.message = noticeMessage(options) }
            if options["buttons"] != nil { record.buttons = buttonTitles(options["buttons"]) }
            if options["iconUrl"] != nil { record.iconURL = options["iconUrl"] as? String ?? "" }
            if options["imageUrl"] != nil { record.imageURL = options["imageUrl"] as? String ?? "" }
            if options["progress"] != nil, let progress = progressValue(options["progress"]) { record.progress = progress }
            if let extensionID = details["extensionId"] as? String, !extensionID.isEmpty { record.extensionID = extensionID }
            records[id] = record
            deliver(record)
            return ExtensionHostOutcome(result: true)
        case "notifications.clear":
            let id = details["id"] as? String ?? ""
            if id.isEmpty {
                records.removeAll()
                return ExtensionHostOutcome(result: true)
            }
            return ExtensionHostOutcome(result: records.removeValue(forKey: id) != nil)
        case "notifications.getAll":
            var map: [String: [String: Any]] = [:]
            for (key, value) in records {
                var item: [String: Any] = ["title": value.title, "message": value.message, "buttons": value.buttons, "iconUrl": value.iconURL, "imageUrl": value.imageURL]
                if let progress = value.progress { item["progress"] = progress }
                map[key] = item
            }
            return ExtensionHostOutcome(result: map)
        default:
            return ExtensionHostOutcome(error: "unsupported")
        }
    }

    static func loadSources(_ names: [String], packages: [(url: URL, directory: Bool)], strict: Bool) -> Result<[String], String> {
        guard !names.isEmpty else { return .success([]) }
        for name in names {
            if safeRelative(name) == nil { return .failure("invalid file \(name)") }
        }
        let candidates = strict ? Array(packages.prefix(1)) : packages
        guard !candidates.isEmpty else { return .failure("missing file \(names[0])") }
        var missing = names[0]
        for package in candidates {
            var texts: [String] = []
            var failed = false
            for name in names {
                switch readSource(name, package: package.url, directory: package.directory) {
                case .success(let text): texts.append(text)
                case .failure(let error):
                    missing = error
                    failed = true
                }
                if failed { break }
            }
            if !failed { return .success(texts) }
        }
        return .failure(missing)
    }

    static func install(at url: URL, directory: Bool, source: String) throws {
        if directory {
            let manifestURL = url.appendingPathComponent("manifest.json")
            let plan = try plan(manifest: Data(contentsOf: manifestURL))
            try plan.manifest.write(to: manifestURL, options: .atomic)
            try Data(source.utf8).write(to: url.appendingPathComponent(fileName), options: .atomic)
            for relative in plan.prepend {
                let fileURL = url.appendingPathComponent(relative)
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                try Data(patchWorker(text, bridge: source).utf8).write(to: fileURL, options: .atomic)
            }
            return
        }
        guard let unpacked = ZipArchive.unpack(try Data(contentsOf: url)) else { throw RikuganError.message("不能读取扩展 ZIP。") }
        let files = try repack(unpacked, source: source)
        let packed = ZipArchive.store(files)
        try ArchiveValidator.validate(packed)
        try packed.write(to: url, options: .atomic)
    }

    static func patchManifest(_ data: Data) throws -> Data { try plan(manifest: data).manifest }

    static func pageReply(id: String, result: Any?, error: String?) -> String {
        let json = jsonText(replyObject(id: id, result: result, error: error))
        return "(function(){var fn=window.__rgExtHostDone;if(typeof fn==='function')fn(\(json));})()"
    }

    static func pendingReply(id: String, result: Any?, error: String?) -> String {
        let json = jsonText(replyObject(id: id, result: result, error: error))
        let key = PageTools.jsString(id) ?? "\"\""
        return "(function(){var pending=globalThis.__rgExtPending&&globalThis.__rgExtPending[\(key)];if(typeof pending==='function')pending(\(json));})()"
    }

    static func attach(to controller: WKUserContentController, handler: WKScriptMessageHandler) {
        if !controller.userScripts.contains(where: { $0.source.contains(marker) }) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        controller.removeScriptMessageHandler(forName: handlerName)
        controller.add(handler, name: handlerName)
    }

    static func boxed(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is NSNull { return NSNull() }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number }
        if let array = value as? [Any] { return array.map { boxed($0) } }
        if let array = value as? NSArray { return array.map { boxed($0) } }
        if let object = value as? [String: Any] {
            var copy: [String: Any] = [:]
            for (key, item) in object { copy[key] = boxed(item) }
            return copy
        }
        if let object = value as? NSDictionary {
            var copy: [String: Any] = [:]
            for (key, item) in object {
                guard let key = key as? String else { continue }
                copy[key] = boxed(item)
            }
            return copy
        }
        return NSNull()
    }

    private struct Plan { var manifest: Data; var prepend: [String] }

    private static func plan(manifest data: Data) throws -> Plan {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RikuganError.message("manifest.json 不是对象。")
        }
        var scripts = json["content_scripts"] as? [[String: Any]] ?? []
        for index in scripts.indices {
            var files = stringList(scripts[index]["js"])
            if !files.contains(fileName) { files.insert(fileName, at: 0); scripts[index]["js"] = files }
        }
        var matches = Set<String>()
        for script in scripts { matches.formUnion(stringList(script["matches"])) }
        for host in stringList(json["host_permissions"]) where host.contains("://") || host == "<all_urls>" { matches.insert(host) }
        let hasStart = scripts.contains { stringList($0["js"]).contains(fileName) && ($0["run_at"] as? String) == "document_start" }
        if !matches.isEmpty && !hasStart {
            scripts.append(["matches": matches.sorted(), "js": [fileName], "run_at": "document_start", "all_frames": true])
        }
        if !scripts.isEmpty { json["content_scripts"] = scripts }
        var prepend: [String] = []
        if let background = json["background"] as? [String: Any], let worker = safeRelative(background["service_worker"] as? String) {
            prepend.append(worker)
        }
        for script in scripts {
            for file in stringList(script["js"]) where file != fileName {
                if let relative = safeRelative(file), !prepend.contains(relative) { prepend.append(relative) }
            }
        }
        for page in [popupPage(json), optionsPage(json)] {
            guard let page, page.lowercased().hasSuffix(".js"), let relative = safeRelative(page), !prepend.contains(relative) else { continue }
            prepend.append(relative)
        }
        let manifest = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return Plan(manifest: manifest, prepend: prepend)
    }

    private static func repack(_ files: [(String, Data)], source: String) throws -> [(String, Data)] {
        guard let manifestIndex = files.firstIndex(where: { $0.0 == "manifest.json" }) else { throw RikuganError.message("扩展 ZIP 缺少 manifest.json。") }
        let plan = try plan(manifest: files[manifestIndex].1)
        var output = files
        output[manifestIndex].1 = plan.manifest
        if let bridgeIndex = output.firstIndex(where: { $0.0 == fileName }) { output[bridgeIndex].1 = Data(source.utf8) }
        else { output.append((fileName, Data(source.utf8))) }
        for relative in plan.prepend {
            guard let index = output.firstIndex(where: { $0.0 == relative }), let text = String(data: output[index].1, encoding: .utf8) else { continue }
            output[index].1 = Data(patchWorker(text, bridge: source).utf8)
        }
        return output
    }

    private static func popupPage(_ json: [String: Any]) -> String? {
        let action = (json["action"] as? [String: Any]) ?? (json["browser_action"] as? [String: Any]) ?? [:]
        return action["default_popup"] as? String
    }

    private static func optionsPage(_ json: [String: Any]) -> String? {
        if let options = json["options_ui"] as? [String: Any], let page = options["page"] as? String { return page }
        return json["options_page"] as? String
    }

    private static func safeRelative(_ path: String?) -> String? {
        guard let path, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return nil }
        if path.split(separator: "/").contains("..") { return nil }
        return path
    }

    private static func noticeMessage(_ options: [String: Any]) -> String {
        (options["message"] as? String) ?? (options["body"] as? String) ?? ""
    }

    private static func progressValue(_ value: Any?) -> Int? {
        let number: Int?
        if let value = value as? Int { number = value }
        else if let value = value as? NSNumber { number = value.intValue }
        else { return nil }
        guard let number else { return nil }
        return min(100, max(0, number))
    }

    static func packagePath(_ reference: String) -> String? {
        var text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.lowercased().hasPrefix("data:"), !text.lowercased().hasPrefix("https://"), !text.lowercased().hasPrefix("http://") else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["chrome-extension", "webkit-extension", "moz-extension"].contains(scheme) {
            text = url.path
        }
        while text.hasPrefix("/") { text.removeFirst() }
        return safeRelative(text)
    }

    private static func dataImage(_ reference: String) -> Data? {
        guard let comma = reference.firstIndex(of: ","), reference.lowercased().hasPrefix("data:image/") else { return nil }
        let meta = reference[..<comma].lowercased()
        guard meta.contains(";base64") else { return nil }
        let payload = String(reference[reference.index(after: comma)...])
        guard let data = Data(base64Encoded: payload), data.count <= 2_000_000, looksLikeImage(data) else { return nil }
        return data
    }

    private static func readBytes(_ name: String, package: URL, directory: Bool) -> Data? {
        guard let relative = safeRelative(name) else { return nil }
        let data: Data?
        if directory {
            data = try? Data(contentsOf: package.appendingPathComponent(relative))
        } else if let packed = try? Data(contentsOf: package) {
            data = ZipArchive.extract(data: packed, path: relative)
        } else { data = nil }
        guard let data, (1...2_000_000).contains(data.count) else { return nil }
        return data
    }

    private static func looksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if bytes.starts(with: [0xFF, 0xD8]) { return true }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        if bytes.count >= 12, bytes.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return true }
        return UIImage(data: data) != nil
    }

    private static func buttonTitles(_ value: Any?) -> [String] {
        let list = value as? [Any] ?? []
        return list.compactMap { item in
            if let text = item as? String { return text }
            if let object = item as? [String: Any] { return object["title"] as? String }
            if let object = item as? NSDictionary { return object["title"] as? String }
            return nil
        }
    }

    private static func readSource(_ name: String, package: URL, directory: Bool) -> Result<String, String> {
        guard let relative = safeRelative(name) else { return .failure("invalid file \(name)") }
        if directory {
            let file = package.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .failure("missing file \(relative)") }
            return .success(text)
        }
        guard let data = try? Data(contentsOf: package), let bytes = ZipArchive.extract(data: data, path: relative), let text = String(data: bytes, encoding: .utf8) else {
            return .failure("missing file \(relative)")
        }
        return .success(text)
    }

    private static func frameRequest(_ target: [String: Any]) -> (all: Bool, ids: [Int]) {
        let all = (target["allFrames"] as? Bool) ?? (target["allFrames"] as? NSNumber)?.boolValue ?? false
        let ids = (target["frameIds"] as? [Any] ?? []).compactMap { item -> Int? in
            if let value = item as? Int { return value }
            if let value = item as? NSNumber { return value.intValue }
            return nil
        }
        return (all, ids)
    }

    private static func tabToken(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if let number = value as? Int { return String(number) }
        return ""
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        if let list = value as? [Any] { return list.compactMap { $0 as? String } }
        return []
    }

    private static func replyObject(id: String, result: Any?, error: String?) -> [String: Any] {
        ["id": id, "result": boxed(result), "error": error ?? NSNull()]
    }

    static func jsonText(_ value: Any) -> String {
        let object = boxed(value)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}

final class ExtensionPageBridge: NSObject, WKScriptMessageHandler {
    weak var session: BrowserSession?
    init(session: BrowserSession) { self.session = session; super.init() }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == ExtensionBridge.handlerName, let body = message.body as? [String: Any] else { return }
        let webView = message.webView
        let id = body["id"] as? String ?? ""
        let api = body["api"] as? String ?? ""
        let details = body["details"] as? [String: Any] ?? [:]
        Task { @MainActor in
            let outcome = await self.session?.handleExtensionHost(api: api, details: details, tab: nil) ?? ExtensionHostOutcome(error: "扩展没有载入。")
            let script = ExtensionBridge.pendingReply(id: id, result: outcome.result, error: outcome.error)
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}
