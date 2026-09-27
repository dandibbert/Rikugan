import Foundation
import WebKit
import UIKit
import NaturalLanguage
import UserNotifications

/// Native implementation of the chrome.* APIs (spec §15). Unimplemented calls throw an explicit
/// "Unsupported API" error so the JS side rejects / sets lastError instead of silently failing.
@MainActor final class ChromeAPIBridge {
    unowned let runtime: ExtensionRuntime
    private var ports: [String: PortState] = [:]
    private var notifications: [String: [String: Any]] = [:]

    init(runtime: ExtensionRuntime) { self.runtime = runtime }

    struct Endpoint {
        weak var webView: WKWebView?
        let frame: WKFrameInfo?
        let world: WKContentWorld
        let key: String
        var webViewID: ObjectIdentifier? = nil
        var tabID: Int? = nil
    }

    struct PortState {
        /// The ID the extension's JS chose (used in events delivered back to JS).
        let id: String
        let extID: String
        var opener: Endpoint
        var receivers: [Endpoint]
        /// Messages posted by the opener before the receiving side was connected.
        var pending: [Any] = []
        var connected = false
    }

    /// Who is calling.
    struct Caller {
        let ext: LoadedExtension
        let ctx: String            // content | page | background
        let message: WKScriptMessage
        var tab: BrowserTab? { message.tab }
        var webView: WKWebView? { message.webView }
        var endpoint: Endpoint {
            let world = message.world
            let frameKey = message.frameInfo.isMainFrame ? "main" : (message.frameInfo.request.url?.absoluteString ?? "sub")
            return Endpoint(webView: message.webView, frame: message.frameInfo, world: world,
                            key: "\(message.webView.map { String(describing: ObjectIdentifier($0)) } ?? "nil")|\(world.name ?? "page")|\(frameKey)",
                            webViewID: message.webView.map(ObjectIdentifier.init), tabID: message.tab?.numericID)
        }
    }

    // MARK: Entry point

    func handle(_ body: [String: Any], message: WKScriptMessage, worldName: String) async throws -> Any? {
        let api = body["api"] as? String ?? ""
        let extID = body["ext"] as? String ?? ""
        let ctx = body["ctx"] as? String ?? "content"
        do {
            let value = try await handleCall(body, message: message, worldName: worldName)
            if !api.hasPrefix("runtime._") { runtime.recordAPICall(extID, api: api, context: ctx, error: nil) }
            return value
        } catch {
            runtime.recordAPICall(extID, api: api, context: ctx, error: error.localizedDescription)
            throw error
        }
    }

    private func handleCall(_ body: [String: Any], message: WKScriptMessage, worldName: String) async throws -> Any? {
        guard let extID = body["ext"] as? String, let ext = runtime.loaded[extID], ext.record.enabled else {
            SecurityLog.shared.record("chrome call rejected: unknown or disabled extension id from world '\(worldName)'")
            throw RikuganError("Extension is not enabled")
        }
        let ctx = body["ctx"] as? String ?? "content"
        // Validate the caller: content scripts must come from the extension's world; extension pages from its origin.
        if ctx == "content" {
            // The content world is set by WebKit: page JS ("") or another extension's world cannot claim it.
            guard worldName == Worlds.extensionWorld(extID).name else {
                SecurityLog.shared.record("chrome call rejected: world '\(worldName)' claimed content script of \(ext.displayName)")
                throw RikuganError("Extension bridge world mismatch")
            }
        } else {
            // Extension pages: the frame's security origin (set by WebKit) must be chrome-extension://<extID>.
            guard message.world == .page, message.frameInfo.securityOrigin.protocol == runtime.scheme,
                  message.frameInfo.securityOrigin.host == extID else {
                SecurityLog.shared.record("chrome call rejected: origin \(message.frameInfo.securityOrigin.protocol)://\(message.frameInfo.securityOrigin.host) claimed \(ctx) of \(ext.displayName)")
                throw RikuganError("Extension page origin mismatch")
            }
        }
        let caller = Caller(ext: ext, ctx: ctx, message: message)
        let api = body["api"] as? String ?? ""
        let argsDict = body["args"] as? [String: Any] ?? [:]
        let list = argsDict["args"] as? [Any] ?? []
        func arg(_ i: Int) -> Any? { i < list.count ? (list[i] is NSNull ? nil : list[i]) : nil }
        func dict(_ i: Int) -> [String: Any] { arg(i) as? [String: Any] ?? [:] }

        let contentAllowed: Set<String> = ["runtime.sendMessage", "runtime.connect", "port.post", "port.disconnect", "runtime._ready",
                                           "runtime._readResource", "events.subscribe", "i18n.detectLanguage",
                                           "runtime._reportError", "runtime._reportUnsupported"]
        if ctx == "content", !api.hasPrefix("storage."), !contentAllowed.contains(api) {
            throw RikuganError("Unsupported API: \(api) is not available in content scripts")
        }

        switch api {
        // ---- runtime ----------------------------------------------------------------------------------
        case "runtime._ready":
            if ctx == "background" { ext.background?.markReady() }
            else if ctx == "content", let tab = caller.tab { _ = runtime.registerContentFrame(ext: ext, tab: tab, frame: message.frameInfo) }
            else if let webView = caller.webView, runtime.pageKind(of: webView) == nil, caller.tab == nil {
                runtime.registerPage(webView, extID: ext.id, kind: "page")
            }
            return nil
        case "events.subscribe":
            if ctx == "background", let event = argsDict["event"] as? String { ext.background?.noteSubscription(event) }
            return nil
        case "runtime._reportError":
            let text = String((argsDict["message"] as? String ?? "").prefix(300))
            runtime.recordRuntimeError(ext, "[\(ctx)] \(text)", context: ctx)
            return nil
        case "runtime._reportUnsupported":
            runtime.recordUnsupported(ext, argsDict["api"] as? String ?? "?", context: ctx)
            return nil
        case "runtime._readResource":
            let path = argsDict["path"] as? String ?? ""
            guard let url = ext.fileURL(path), let data = try? Data(contentsOf: url) else { throw RikuganError("Resource not found: \(path)") }
            return ["base64": data.base64EncodedString(), "mime": MIME.type(forExtension: url.pathExtension)]
        case "runtime.sendMessage":
            return try await sendToExtension(ext, message: argsDict["message"] ?? NSNull(), caller: caller)
        case "runtime.connect":
            try await connect(ext, args: argsDict, caller: caller)
            return nil
        case "port.post":
            try postToPort(argsDict["portId"] as? String ?? "", message: argsDict["message"] ?? NSNull(), caller: caller)
            return nil
        case "port.disconnect":
            try disconnectPort(argsDict["portId"] as? String ?? "", caller: caller)
            return nil
        case "runtime.openOptionsPage":
            runtime.openOptions(ext, from: TabRegistry.shared.focusedWindow?.activeTab)
            return nil
        case "runtime.reload":
            runtime.reload(ext.id)
            return nil
        case "runtime.getContexts":
            return runtime.extensionPages(of: ext).map { page in
                ["contextType": page.1 == "background" ? "BACKGROUND" : (page.1 == "popup" ? "POPUP" : "TAB"),
                 "documentUrl": page.0.url?.absoluteString ?? "", "frameId": 0, "tabId": -1, "windowId": -1, "incognito": false]
            }

        // ---- storage ----------------------------------------------------------------------------------
        case "storage.get":
            let area = argsDict["area"] as? String ?? "local"
            try requireStorage(ext)
            let all = runtime.storage(ext, area: area)
            if let keys = argsDict["keys"] as? [String] { return all.filter { keys.contains($0.key) } }
            return all
        case "storage.getKeys":
            return Array(runtime.storage(ext, area: argsDict["area"] as? String ?? "local").keys)
        case "storage.set":
            let area = argsDict["area"] as? String ?? "local"
            guard area != "managed" else { throw RikuganError("storage.managed is read-only") }
            try requireStorage(ext)
            var all = runtime.storage(ext, area: area)
            var changes: [String: [String: Any]] = [:]
            for (key, value) in argsDict["items"] as? [String: String] ?? [:] where all[key] != value {
                var change: [String: Any] = ["newValue": value]
                if let old = all[key] { change["oldValue"] = old }
                changes[key] = change
                all[key] = value
            }
            let size = all.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            if area == "sync", size > 102_400 { throw RikuganError("QUOTA_BYTES quota exceeded") }
            if area == "local", size > 10_485_760, !ext.has("unlimitedStorage") { throw RikuganError("QUOTA_BYTES quota exceeded") }
            runtime.setStorage(ext, area: area, all)
            runtime.storageChanged(ext, area: area, changes: changes)
            return nil
        case "storage.remove":
            let area = argsDict["area"] as? String ?? "local"
            var all = runtime.storage(ext, area: area)
            var changes: [String: [String: Any]] = [:]
            for key in argsDict["keys"] as? [String] ?? [] { if let old = all.removeValue(forKey: key) { changes[key] = ["oldValue": old] } }
            runtime.setStorage(ext, area: area, all)
            runtime.storageChanged(ext, area: area, changes: changes)
            return nil
        case "storage.clear":
            let area = argsDict["area"] as? String ?? "local"
            let all = runtime.storage(ext, area: area)
            runtime.setStorage(ext, area: area, [:])
            runtime.storageChanged(ext, area: area, changes: all.mapValues { ["oldValue": $0] })
            return nil
        case "storage.getBytesInUse":
            let all = runtime.storage(ext, area: argsDict["area"] as? String ?? "local")
            let keys = argsDict["keys"] as? [String]
            return all.filter { keys?.contains($0.key) ?? true }.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }

        // ---- i18n -------------------------------------------------------------------------------------
        case "i18n.detectLanguage":
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(argsDict["text"] as? String ?? "")
            let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            return ["isReliable": (hypotheses.values.max() ?? 0) > 0.6,
                    "languages": hypotheses.sorted { $0.value > $1.value }.map { ["language": $0.key.rawValue, "percentage": Int($0.value * 100)] }]

        // ---- tabs -----------------------------------------------------------------------------------------
        case "tabs.query":
            return queryTabs(dict(0), ext: ext, caller: caller)
        case "tabs.get":
            guard let id = arg(0) as? Int, let tab = TabRegistry.shared.tab(id), !tab.isPrivate else { throw RikuganError("No tab with id: \(arg(0) ?? "")") }
            return tabJSON(tab, for: ext)
        case "tabs.getCurrent":
            if let tab = caller.tab, caller.ctx != "background" { return tabJSON(tab, for: ext) }
            return nil
        case "tabs.create":
            let props = dict(0)
            let manager = (props["windowId"] as? Int).flatMap(TabRegistry.shared.window) ?? TabRegistry.shared.focusedWindow
            guard let manager else { throw RikuganError("No window") }
            let url = resolve(props["url"] as? String, ext: ext)
            let tab = manager.newTab(url: url, background: (props["active"] as? Bool) == false, isPrivate: false,
                                     opener: (props["openerTabId"] as? Int).flatMap(TabRegistry.shared.tab))
            if props["pinned"] as? Bool == true { tab.pinned = true }
            return tabJSON(tab, for: ext)
        case "tabs.update":
            let (tab, props) = try tabAndProps(arg(0), arg(1), caller: caller)
            if let raw = props["url"] as? String, let url = resolve(raw, ext: ext) {
                if url.scheme == "javascript" { throw RikuganError("javascript: URLs are not allowed") }
                tab.load(url)
            }
            if props["active"] as? Bool == true { tab.manager?.select(tab) }
            if let pinned = props["pinned"] as? Bool { tab.pinned = pinned }
            return tabJSON(tab, for: ext)
        case "tabs.remove":
            let ids = (arg(0) as? [Int]) ?? (arg(0) as? Int).map { [$0] } ?? []
            for id in ids { if let tab = TabRegistry.shared.tab(id) { tab.manager?.close(tab) } }
            return nil
        case "tabs.reload":
            let tab = try tabFor(arg(0) as? Int, caller: caller)
            if dict(1)["bypassCache"] as? Bool == true { tab.webView?.reloadFromOrigin() } else { tab.reload() }
            return nil
        case "tabs.duplicate":
            let tab = try tabFor(arg(0) as? Int, caller: caller)
            tab.manager?.duplicate(tab)
            return tab.manager?.activeTab.map { tabJSON($0, for: ext) }
        case "tabs.goBack":
            try tabFor(arg(0) as? Int, caller: caller).goBack(); return nil
        case "tabs.goForward":
            try tabFor(arg(0) as? Int, caller: caller).goForward(); return nil
        case "tabs.captureVisibleTab":
            guard let tab = TabRegistry.shared.focusedWindow?.activeTab, let webView = tab.webView else { throw RikuganError("No active tab") }
            guard ext.hostAllowed(webView.url, tabID: tab.numericID) || ext.record.grantedHosts.contains("<all_urls>") else {
                throw RikuganError("Missing host permission or activeTab for captureVisibleTab")
            }
            let options = (arg(0) as? [String: Any]) ?? dict(1)
            let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? RikuganError("Snapshot failed")) }
                }
            }
            if options["format"] as? String == "png" {
                return "data:image/png;base64," + (image.pngData()?.base64EncodedString() ?? "")
            }
            let quality = Double(options["quality"] as? Int ?? 92) / 100
            return "data:image/jpeg;base64," + (image.jpegData(compressionQuality: quality)?.base64EncodedString() ?? "")
        case "tabs.detectLanguage":
            let tab = try tabFor(arg(0) as? Int, caller: caller)
            let sample = await tab.webView?.rkTools("languageSample") as? [String: Any]
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample?["sample"] as? String ?? "")
            return recognizer.dominantLanguage?.rawValue ?? (sample?["lang"] as? String ?? "und")
        case "tabs.sendMessage":
            guard let tabID = argsDict["tabId"] as? Int, let tab = TabRegistry.shared.tab(tabID) else {
                throw RikuganError("Could not establish connection. Receiving end does not exist.")
            }
            return try await sendToTab(ext, tab: tab, frameID: argsDict["frameId"] as? Int, message: argsDict["message"] ?? NSNull(), caller: caller)

        // ---- windows ----------------------------------------------------------------------------------
        case "windows.get":
            guard let id = arg(0) as? Int, let window = TabRegistry.shared.window(id) else { throw RikuganError("No window with id: \(arg(0) ?? "")") }
            return windowJSON(window, ext: ext, populate: dict(1)["populate"] as? Bool ?? false)
        case "windows.getCurrent", "windows.getLastFocused":
            guard let window = caller.tab?.manager ?? TabRegistry.shared.focusedWindow else { throw RikuganError("No window") }
            return windowJSON(window, ext: ext, populate: dict(0)["populate"] as? Bool ?? false)
        case "windows.getAll":
            return TabRegistry.shared.allWindows.map { windowJSON($0, ext: ext, populate: dict(0)["populate"] as? Bool ?? false) }
        case "windows.create":
            let props = dict(0)
            guard let manager = TabRegistry.shared.focusedWindow else { throw RikuganError("No window") }
            let urls: [String] = (props["url"] as? [String]) ?? (props["url"] as? String).map { [$0] } ?? []
            if urls.isEmpty { manager.newTab(isPrivate: false) }
            for raw in urls { manager.newTab(url: resolve(raw, ext: ext), isPrivate: false) }
            return windowJSON(manager, ext: ext, populate: true)
        case "windows.update":
            guard let id = arg(0) as? Int, let window = TabRegistry.shared.window(id) else { throw RikuganError("No window") }
            return windowJSON(window, ext: ext, populate: false)

        // ---- scripting ------------------------------------------------------------------------------
        case "scripting.executeScript":
            return try await executeScript(ext, args: argsDict, caller: caller)
        case "scripting.insertCSS", "scripting.removeCSS":
            let injection = argsDict["args"] == nil ? argsDict : dict(0)
            try await css(ext, injection: injection, remove: api == "scripting.removeCSS", caller: caller)
            return nil
        case "scripting.registerContentScripts":
            let scripts = (arg(0) as? [[String: Any]] ?? []).map(ContentScriptEntry.init(json:))
            for s in scripts {
                guard let id = s.id, !id.isEmpty else { throw RikuganError("Content script id is required") }
                if ext.record.dynamicScripts.contains(where: { $0.id == id }) { throw RikuganError("Duplicate script ID '\(id)'") }
                for pattern in s.matches where !URLMatcher.isValidMatchPattern(pattern) { throw RikuganError("Invalid match pattern '\(pattern)'") }
            }
            runtime.updateRecord(ext.id) { $0.dynamicScripts += scripts }
            WebViewFactory.invalidateAllTabs()
            return nil
        case "scripting.getRegisteredContentScripts":
            let ids = dict(0)["ids"] as? [String]
            return ext.record.dynamicScripts.filter { ids?.contains($0.id ?? "") ?? true }.map(scriptJSON)
        case "scripting.unregisterContentScripts":
            let ids = dict(0)["ids"] as? [String]
            runtime.updateRecord(ext.id) { record in record.dynamicScripts.removeAll { ids?.contains($0.id ?? "") ?? true } }
            WebViewFactory.invalidateAllTabs()
            return nil
        case "scripting.updateContentScripts":
            let updates = (arg(0) as? [[String: Any]] ?? [])
            runtime.updateRecord(ext.id) { record in
                for update in updates {
                    guard let id = update["id"] as? String, let index = record.dynamicScripts.firstIndex(where: { $0.id == id }) else { continue }
                    var merged = scriptJSON(record.dynamicScripts[index])
                    merged.merge(update) { _, new in new }
                    record.dynamicScripts[index] = ContentScriptEntry(json: merged)
                }
            }
            WebViewFactory.invalidateAllTabs()
            return nil

        // ---- permissions ------------------------------------------------------------------------------
        case "permissions.getAll":
            return ["permissions": ext.record.grantedPermissions, "origins": ext.record.grantedHosts]
        case "permissions.contains":
            let request = dict(0)
            let perms = request["permissions"] as? [String] ?? []
            let origins = request["origins"] as? [String] ?? []
            return perms.allSatisfy(ext.has) && origins.allSatisfy { origin in ext.record.grantedHosts.contains { URLMatcher.pattern($0, covers: origin) } }
        case "permissions.request":
            return await requestPermissions(ext, dict(0))
        case "permissions.remove":
            let request = dict(0)
            let perms = (request["permissions"] as? [String] ?? []).filter { ext.manifest.optionalPermissions.contains($0) }
            let origins = request["origins"] as? [String] ?? []
            runtime.updateRecord(ext.id) { record in
                record.grantedPermissions.removeAll { perms.contains($0) }
                record.grantedHosts.removeAll { origins.contains($0) && !ext.manifest.requestedHostPatterns.contains($0) }
            }
            runtime.dispatch(ext, "permissions.onRemoved", [["permissions": perms, "origins": origins]])
            WebViewFactory.invalidateAllTabs()
            return true

        // ---- action -------------------------------------------------------------------------------------
        case let name where name.hasPrefix("action."):
            return try await actionAPI(String(name.dropFirst(7)), ext: ext, details: dict(0), arg0: arg(0), caller: caller)

        // ---- contextMenus -------------------------------------------------------------------------------
        case "contextMenus.create":
            let p = dict(0)
            let item = ExtensionMenuItem(id: (p["id"] as? String) ?? UUID().uuidString, title: p["title"] as? String ?? "",
                                         contexts: p["contexts"] as? [String] ?? ["page"], parentID: (p["parentId"] as? String) ?? (p["parentId"] as? Int).map(String.init),
                                         type: p["type"] as? String ?? "normal", checked: p["checked"] as? Bool ?? false,
                                         enabled: p["enabled"] as? Bool ?? true, visible: p["visible"] as? Bool ?? true,
                                         documentURLPatterns: p["documentUrlPatterns"] as? [String] ?? [],
                                         targetURLPatterns: p["targetUrlPatterns"] as? [String] ?? [])
            ext.menuItems.removeAll { $0.id == item.id }
            ext.menuItems.append(item)
            return item.id
        case "contextMenus.update":
            let id = (arg(0) as? String) ?? (arg(0) as? Int).map(String.init) ?? ""
            guard let index = ext.menuItems.firstIndex(where: { $0.id == id }) else { throw RikuganError("Cannot find menu item with id \(id)") }
            let p = dict(1)
            if let title = p["title"] as? String { ext.menuItems[index].title = title }
            if let checked = p["checked"] as? Bool { ext.menuItems[index].checked = checked }
            if let enabled = p["enabled"] as? Bool { ext.menuItems[index].enabled = enabled }
            if let visible = p["visible"] as? Bool { ext.menuItems[index].visible = visible }
            if let contexts = p["contexts"] as? [String] { ext.menuItems[index].contexts = contexts }
            return nil
        case "contextMenus.remove":
            let id = (arg(0) as? String) ?? (arg(0) as? Int).map(String.init) ?? ""
            ext.menuItems.removeAll { $0.id == id || $0.parentID == id }
            return nil
        case "contextMenus.removeAll":
            ext.menuItems.removeAll()
            return nil

        // ---- fontSettings (font list only) ---------------------------------------------------------------
        case "fontSettings.getFontList":
            try requirePermission(ext, "fontSettings")
            let fonts = AppServices.shared.fonts
            if fonts.systemFamilies.isEmpty { fonts.reload() }
            return fonts.allFamilies.map { ["fontId": $0, "displayName": $0] }

        // ---- commands ------------------------------------------------------------------------------------
        case "commands.getAll":
            return ext.manifest.commands.map { name, value -> [String: Any] in
                let d = value as? [String: Any] ?? [:]
                let key = (d["suggested_key"] as? [String: Any])?["default"] as? String ?? ""
                return ["name": name, "description": d["description"] as? String ?? "", "shortcut": key]
            }

        // ---- cookies ---------------------------------------------------------------------------------------
        case let name where name.hasPrefix("cookies."):
            try requirePermission(ext, "cookies")
            return try await cookiesAPI(String(name.dropFirst(8)), ext: ext, details: dict(0))

        // ---- downloads -----------------------------------------------------------------------------------
        case let name where name.hasPrefix("downloads."):
            try requirePermission(ext, "downloads")
            return try downloadsAPI(String(name.dropFirst(10)), ext: ext, arg0: arg(0), caller: caller)

        // ---- notifications ---------------------------------------------------------------------------------
        case "notifications.create", "notifications.update":
            try requirePermission(ext, "notifications")
            let id = arg(0) as? String ?? UUID().uuidString
            let options = dict(1)
            notifications[ext.id + ":" + id] = options
            let title = options["title"] as? String ?? ext.displayName
            let text = options["message"] as? String ?? ""
            ToastCenter.shared.show("\(title)：\(text)", symbol: "bell", actionTitle: "查看", duration: 5) { [weak self] in
                self?.runtime.dispatch(ext, "notifications.onClicked", [id])
            }
            if UIApplication.shared.applicationState != .active {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = text
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(ext.id).\(id)", content: content, trigger: nil))
            }
            return api == "notifications.create" ? id : true
        case "notifications.clear":
            let id = arg(0) as? String ?? ""
            let existed = notifications.removeValue(forKey: ext.id + ":" + id) != nil
            if existed { runtime.dispatch(ext, "notifications.onClosed", [id, false]) }
            return existed
        case "notifications.getAll":
            var result: [String: Bool] = [:]
            for key in notifications.keys where key.hasPrefix(ext.id + ":") { result[String(key.dropFirst(ext.id.count + 1))] = true }
            return result

        // ---- webNavigation ---------------------------------------------------------------------------------
        case "webNavigation.getFrame":
            let d = dict(0)
            guard let tab = (d["tabId"] as? Int).flatMap(TabRegistry.shared.tab) else { return nil }
            let frameID = d["frameId"] as? Int ?? 0
            if frameID == 0 { return ["url": tab.webView?.url?.absoluteString ?? "", "parentFrameId": -1, "errorOccurred": false, "frameId": 0] }
            return ext.contentFrames[tab.numericID]?.first { $0.frameID == frameID }.map { ["url": $0.url, "parentFrameId": 0, "errorOccurred": false, "frameId": $0.frameID] }
        case "webNavigation.getAllFrames":
            guard let tab = (dict(0)["tabId"] as? Int).flatMap(TabRegistry.shared.tab) else { return nil }
            var frames: [[String: Any]] = [["url": tab.webView?.url?.absoluteString ?? "", "parentFrameId": -1, "errorOccurred": false, "frameId": 0, "processId": -1]]
            for record in ext.contentFrames[tab.numericID] ?? [] where record.frameID != 0 {
                frames.append(["url": record.url, "parentFrameId": 0, "errorOccurred": false, "frameId": record.frameID, "processId": -1])
            }
            return frames

        // ---- declarativeNetRequest -------------------------------------------------------------------------
        case let name where name.hasPrefix("declarativeNetRequest."):
            return try dnrAPI(String(name.dropFirst(22)), ext: ext, details: dict(0))

        // ---- alarms -------------------------------------------------------------------------------------
        case let name where name.hasPrefix("alarms."):
            return alarmsAPI(String(name.dropFirst(7)), ext: ext, arg0: arg(0), arg1: dict(1))

        default:
            throw RikuganError("Unsupported API: chrome.\(api)")
        }
    }

    // MARK: Helpers

    private func requirePermission(_ ext: LoadedExtension, _ permission: String) throws {
        guard ext.has(permission) else { throw RikuganError("Permission '\(permission)' is required. Declare it in manifest.json.") }
    }

    private func requireStorage(_ ext: LoadedExtension) throws {
        guard ext.has("storage") || ext.has("unlimitedStorage") else {
            throw RikuganError("Permission 'storage' is required to use chrome.storage")
        }
    }

    private func resolve(_ raw: String?, ext: LoadedExtension) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: raw, relativeTo: URL(string: ext.baseURL))?.absoluteURL
    }

    private func tabFor(_ id: Int?, caller: Caller) throws -> BrowserTab {
        if let id {
            guard let tab = TabRegistry.shared.tab(id), !tab.isPrivate else { throw RikuganError("No tab with id: \(id)") }
            return tab
        }
        guard let tab = caller.tab ?? TabRegistry.shared.focusedWindow?.activeTab else { throw RikuganError("No active tab") }
        return tab
    }

    private func tabAndProps(_ a: Any?, _ b: Any?, caller: Caller) throws -> (BrowserTab, [String: Any]) {
        if let id = a as? Int { return (try tabFor(id, caller: caller), b as? [String: Any] ?? [:]) }
        return (try tabFor(nil, caller: caller), a as? [String: Any] ?? [:])
    }

    func canSeeTabDetails(_ tab: BrowserTab, ext: LoadedExtension) -> Bool {
        ext.has("tabs") || ext.hostAllowed(tab.webView?.url ?? tab.url, tabID: tab.numericID)
    }

    func tabJSON(_ tab: BrowserTab, for ext: LoadedExtension) -> [String: Any] {
        let manager = tab.manager
        let index = manager?.tabs.filter { !$0.isPrivate }.firstIndex { $0.id == tab.id } ?? 0
        let active = manager?.activeTabID == tab.id
        var json: [String: Any] = [
            "id": tab.numericID, "index": index, "windowId": manager?.numericID ?? 1, "active": active, "highlighted": active,
            "selected": active, "pinned": tab.pinned, "incognito": tab.isPrivate, "status": tab.isLoading ? "loading" : "complete",
            "discarded": tab.webView == nil, "autoDiscardable": true, "groupId": -1, "audible": false, "mutedInfo": ["muted": false],
            "frozen": false, "lastAccessed": tab.lastActiveAt.timeIntervalSince1970 * 1000,
            "width": Int(tab.webView?.bounds.width ?? 0), "height": Int(tab.webView?.bounds.height ?? 0),
        ]
        if let opener = tab.opener { json["openerTabId"] = opener.numericID }
        if canSeeTabDetails(tab, ext: ext) {
            json["url"] = (tab.webView?.url ?? tab.url)?.absoluteString ?? "about:blank"
            json["title"] = tab.title
            if let host = tab.host { json["favIconUrl"] = "https://\(host)/favicon.ico" }
        }
        return json
    }

    private func windowJSON(_ window: TabManager, ext: LoadedExtension, populate: Bool) -> [String: Any] {
        let bounds = Presenter.keyWindow?.bounds ?? .zero
        var json: [String: Any] = ["id": window.numericID, "focused": TabRegistry.shared.focusedWindow === window, "top": 0, "left": 0,
                                   "width": Int(bounds.width), "height": Int(bounds.height), "incognito": false, "type": "normal",
                                   "state": "normal", "alwaysOnTop": false]
        if populate { json["tabs"] = window.tabs.filter { !$0.isPrivate }.map { tabJSON($0, for: ext) } }
        return json
    }

    private func scriptJSON(_ s: ContentScriptEntry) -> [String: Any] {
        ["id": s.id ?? "", "matches": s.matches, "excludeMatches": s.excludeMatches, "js": s.js, "css": s.css,
         "runAt": s.runAt, "allFrames": s.allFrames, "world": s.world, "persistAcrossSessions": true]
    }

    private func queryTabs(_ q: [String: Any], ext: LoadedExtension, caller: Caller) -> [[String: Any]] {
        let focused = TabRegistry.shared.focusedWindow
        let currentWindow = caller.tab?.manager ?? focused
        let urlPatterns = ((q["url"] as? [String]) ?? (q["url"] as? String).map { [$0] } ?? []).compactMap { try? URLMatcher.matchPattern($0) }
        let titleRule = (q["title"] as? String).flatMap { try? URLMatcher.includeRule($0) }
        return TabRegistry.shared.allTabs.filter { tab in
            guard !tab.isPrivate, let manager = tab.manager else { return false }
            let isActive = manager.activeTabID == tab.id
            if let active = q["active"] as? Bool, active != isActive { return false }
            if let highlighted = q["highlighted"] as? Bool, highlighted != isActive { return false }
            if let current = q["currentWindow"] as? Bool, current != (manager === currentWindow) { return false }
            if let last = q["lastFocusedWindow"] as? Bool, last != (manager === focused) { return false }
            if let windowID = q["windowId"] as? Int {
                if windowID == -2 { if manager !== currentWindow { return false } } else if manager.numericID != windowID { return false }
            }
            if let pinned = q["pinned"] as? Bool, pinned != tab.pinned { return false }
            if let status = q["status"] as? String, status != (tab.isLoading ? "loading" : "complete") { return false }
            if let audible = q["audible"] as? Bool, audible { return false }
            if let index = q["index"] as? Int, manager.tabs.filter({ !$0.isPrivate }).firstIndex(where: { $0.id == tab.id }) != index { return false }
            if !urlPatterns.isEmpty {
                guard canSeeTabDetails(tab, ext: ext), let url = tab.webView?.url ?? tab.url, URLMatcher.anyMatch(urlPatterns, url) else { return false }
            }
            if let titleRule {
                guard canSeeTabDetails(tab, ext: ext), titleRule.matches(normalized: tab.title) else { return false }
            }
            return true
        }.map { tabJSON($0, for: ext) }
    }

    // MARK: Messaging (spec §16)

    private func sender(for caller: Caller) -> [String: Any] {
        var sender: [String: Any] = ["id": caller.ext.id]
        let frameURL = caller.message.frameInfo.request.url?.absoluteString ?? caller.webView?.url?.absoluteString ?? ""
        sender["url"] = frameURL
        sender["origin"] = URL(string: frameURL).map { "\($0.scheme ?? "")://\($0.host ?? "")" + ($0.port.map { ":\($0)" } ?? "") } ?? ""
        if caller.ctx == "content", let tab = caller.tab {
            sender["tab"] = tabJSON(tab, for: caller.ext)
            sender["frameId"] = caller.ext.contentFrames[tab.numericID]?.first { $0.url == frameURL && $0.frame.isMainFrame == caller.message.frameInfo.isMainFrame }?.frameID
                ?? (caller.message.frameInfo.isMainFrame ? 0 : 1)
            sender["documentLifecycle"] = "active"
        } else if let tab = caller.tab {
            sender["tab"] = tabJSON(tab, for: caller.ext)
            sender["frameId"] = 0
        }
        return sender
    }

    /// Extension-context receivers for runtime.sendMessage / connect. Waits for (and wakes) the
    /// background runtime first, so a message sent during a cold start is delivered, not dropped.
    private func extensionTargets(_ ext: LoadedExtension, caller: Caller) async throws -> [(WKWebView, String)] {
        if let bg = ext.background, caller.ctx != "background" {
            let ready = await bg.awaitReady()
            if !ready {
                let others = runtime.extensionPages(of: ext).filter { $0.0 !== caller.webView && $0.1 != "background" }
                if others.isEmpty {
                    throw RikuganError("Could not establish connection. Background runtime is unavailable: \(bg.failureReason ?? bg.state.rawValue)")
                }
            }
        }
        return runtime.extensionPages(of: ext).filter { $0.0 !== caller.webView }
    }

    private func sendToExtension(_ ext: LoadedExtension, message: Any, caller: Caller) async throws -> Any? {
        let targets = try await extensionTargets(ext, caller: caller)
        guard !targets.isEmpty else { throw RikuganError("Could not establish connection. Receiving end does not exist.") }
        let senderInfo = sender(for: caller)
        var anyListener = false
        for (webView, _) in targets {
            let result = try? await webView.rkCall("return await globalThis.__rikuganChrome.deliverMessage(m, s);",
                                                   arguments: ["m": message, "s": senderInfo], world: .page) as? [String: Any]
            guard let result else { continue }
            if result["none"] as? Bool == true { if result["listened"] as? Bool == true { anyListener = true }; continue }
            anyListener = true
            if let error = result["error"] as? String { throw RikuganError(error) }
            if result["has"] as? Bool == true { return result["response"] }
        }
        if !anyListener { throw RikuganError("Could not establish connection. Receiving end does not exist.") }
        return nil
    }

    private func sendToTab(_ ext: LoadedExtension, tab: BrowserTab, frameID: Int?, message: Any, caller: Caller) async throws -> Any? {
        guard let webView = tab.webView else { throw RikuganError("Could not establish connection. Receiving end does not exist.") }
        let frames = (ext.contentFrames[tab.numericID] ?? []).filter { frameID == nil || $0.frameID == frameID }
        guard !frames.isEmpty else { throw RikuganError("Could not establish connection. Receiving end does not exist.") }
        let senderInfo = sender(for: caller)
        var anyListener = false
        for record in frames.sorted(by: { $0.frameID < $1.frameID }) {
            let result = try? await webView.rkCall("return await globalThis.__rikuganChrome.deliverMessage(m, s);",
                                                   arguments: ["m": message, "s": senderInfo], frame: record.frame,
                                                   world: Worlds.extensionWorld(ext.id)) as? [String: Any]
            guard let result else { continue }
            if result["none"] as? Bool == true { if result["listened"] as? Bool == true { anyListener = true }; continue }
            anyListener = true
            if let error = result["error"] as? String { throw RikuganError(error) }
            if result["has"] as? Bool == true { return result["response"] }
        }
        if !anyListener { throw RikuganError("Could not establish connection. Receiving end does not exist.") }
        return nil
    }

    private func connect(_ ext: LoadedExtension, args: [String: Any], caller: Caller) async throws {
        guard let portID = args["portId"] as? String, !portID.isEmpty else { return }
        // Port IDs are chosen by extension JS: keep them per extension and never let a new connect
        // replace a live port (that would hijack it).
        let key = Self.portKey(ext.id, portID)
        guard ports[key] == nil else {
            SecurityLog.shared.record("runtime.connect rejected: port id already in use (\(ext.displayName))")
            throw RikuganError("Port id already in use")
        }
        let name = args["name"] as? String ?? ""
        let senderInfo = sender(for: caller)
        let opener = caller.endpoint
        ports[key] = PortState(id: portID, extID: ext.id, opener: opener, receivers: [])
        var receivers: [Endpoint] = []
        let open = "return globalThis.__rikuganChrome ? globalThis.__rikuganChrome.openPort(id, n, s) : false;"
        if args["target"] as? String == "tab", let tabID = args["tabId"] as? Int, let tab = TabRegistry.shared.tab(tabID), let webView = tab.webView {
            let frameFilter = args["frameId"] as? Int
            for record in ext.contentFrames[tabID] ?? [] where frameFilter == nil || record.frameID == frameFilter {
                let world = Worlds.extensionWorld(ext.id)
                if (try? await webView.rkCall(open, arguments: ["id": portID, "n": name, "s": senderInfo], frame: record.frame, world: world)) as? Bool == true {
                    receivers.append(Endpoint(webView: webView, frame: record.frame, world: world,
                                              key: "\(ObjectIdentifier(webView))|\(world.name ?? "")|\(record.frame.isMainFrame ? "main" : record.url)",
                                              webViewID: ObjectIdentifier(webView), tabID: tabID))
                }
            }
        } else {
            for (webView, _) in try await extensionTargets(ext, caller: caller) {
                if (try? await webView.rkCall(open, arguments: ["id": portID, "n": name, "s": senderInfo], world: .page)) as? Bool == true {
                    receivers.append(Endpoint(webView: webView, frame: nil, world: .page, key: "\(ObjectIdentifier(webView))|page|main",
                                              webViewID: ObjectIdentifier(webView), tabID: TabRegistry.shared.tab(for: webView)?.numericID))
                }
            }
        }
        guard !receivers.isEmpty, var state = ports[key] else {
            ports.removeValue(forKey: key)
            deliverPortEvent(opener, portID: portID, type: "disconnect", message: nil)
            return
        }
        state.receivers = receivers
        state.connected = true
        let queued = state.pending
        state.pending = []
        ports[key] = state
        for message in queued {
            for target in receivers { deliverPortEvent(target, portID: portID, type: "message", message: message) }
        }
    }

    static func portKey(_ extID: String, _ portID: String) -> String { extID + "|" + portID }

    /// Only an endpoint of the port (its opener or a receiver) may use it, and only within its own
    /// extension (the key is namespaced by the caller's verified extension ID).
    private func ownedPort(_ portID: String, caller: Caller, action: String) throws -> (String, PortState)? {
        let key = Self.portKey(caller.ext.id, portID)
        guard let state = ports[key] else { return nil }
        let endpoint = caller.endpoint.key
        guard state.opener.key == endpoint || state.receivers.contains(where: { $0.key == endpoint }) else {
            SecurityLog.shared.record("\(action) rejected: caller is not an endpoint of the port (\(caller.ext.displayName))")
            throw RikuganError("Port is not owned by this context")
        }
        return (key, state)
    }

    private func postToPort(_ portID: String, message: Any, caller: Caller) throws {
        guard let (key, found) = try ownedPort(portID, caller: caller, action: "port.post") else { return }
        var state = found
        let endpoint = caller.endpoint.key
        if state.opener.key == endpoint && !state.connected {
            state.pending.append(message)
            ports[key] = state
            return
        }
        let targets = state.opener.key == endpoint ? state.receivers : [state.opener]
        for target in targets { deliverPortEvent(target, portID: state.id, type: "message", message: message) }
    }

    private func disconnectPort(_ portID: String, caller: Caller) throws {
        guard let (key, state) = try ownedPort(portID, caller: caller, action: "port.disconnect") else { return }
        ports.removeValue(forKey: key)
        let targets = state.opener.key == caller.endpoint.key ? state.receivers : [state.opener]
        for target in targets { deliverPortEvent(target, portID: state.id, type: "disconnect", message: nil) }
    }

    func portCount(extID: String) -> Int { ports.values.filter { $0.extID == extID && $0.connected }.count }
    func hasOpenPorts(extID: String) -> Bool { ports.values.contains { $0.extID == extID && $0.connected } }
    var openPortCount: Int { ports.count }

    /// A web view went away (tab closed / suspended, background suspended): disconnect its ports.
    func endpointsGone(webView: WKWebView) { endpointsGone { $0.webViewID == ObjectIdentifier(webView) } }
    func endpointsGone(tabID: Int) { endpointsGone { $0.tabID == tabID } }

    private func endpointsGone(where gone: (Endpoint) -> Bool) {
        for (key, state) in ports {
            if gone(state.opener) {
                ports.removeValue(forKey: key)
                for r in state.receivers where !gone(r) { deliverPortEvent(r, portID: state.id, type: "disconnect", message: nil) }
                continue
            }
            let remaining = state.receivers.filter { !gone($0) }
            if remaining.count != state.receivers.count {
                if remaining.isEmpty {
                    ports.removeValue(forKey: key)
                    deliverPortEvent(state.opener, portID: state.id, type: "disconnect", message: nil)
                } else {
                    var copy = state
                    copy.receivers = remaining
                    ports[key] = copy
                }
            }
        }
    }

    private func deliverPortEvent(_ endpoint: Endpoint, portID: String, type: String, message: Any?) {
        guard let webView = endpoint.webView else { return }
        let js = "globalThis.__rikuganChrome && globalThis.__rikuganChrome.portEvent(\(portID.jsLiteral), \(type.jsLiteral), \(JSONText.encode(message)))"
        webView.rkEval(js, frame: endpoint.frame, world: endpoint.world)
    }

    // MARK: scripting.executeScript / insertCSS

    private func targetFrames(_ target: [String: Any], ext: LoadedExtension, caller: Caller) throws -> (BrowserTab, [WKFrameInfo?]) {
        let tab = try tabFor(target["tabId"] as? Int, caller: caller)
        guard ext.hostAllowed(tab.webView?.url, tabID: tab.numericID) else {
            throw RikuganError("Cannot access contents of the page. Extension manifest must request permission to access the respective host.")
        }
        var frames: [WKFrameInfo?] = [nil]
        let known = (ext.contentFrames[tab.numericID] ?? []) + tab.frameRecords
        if target["allFrames"] as? Bool == true {
            frames += known.filter { !$0.frame.isMainFrame }.map { $0.frame }
        } else if let ids = target["frameIds"] as? [Int] {
            frames = ids.compactMap { id in id == 0 ? nil : known.first { $0.frameID == id }?.frame }
            if ids.contains(0) { frames.insert(nil, at: 0) }
        }
        return (tab, frames)
    }

    private func executeScript(_ ext: LoadedExtension, args: [String: Any], caller: Caller) async throws -> Any? {
        let target = args["target"] as? [String: Any] ?? [:]
        let (tab, frames) = try targetFrames(target, ext: ext, caller: caller)
        guard let webView = tab.webView else { throw RikuganError("Tab has no document") }
        let world = (args["world"] as? String) == "MAIN" ? WKContentWorld.page : Worlds.extensionWorld(ext.id)
        var results: [[String: Any]] = []
        for frame in frames {
            if world != .page { try await ensureShim(ext, webView: webView, frame: frame) }
            var value: Any?
            if let fn = args["func"] as? String {
                let body = "const __f = (\(fn)); const __r = await __f(...(__args || [])); return __r === undefined ? null : JSON.parse(JSON.stringify(__r));"
                value = try await webView.rkCall(body, arguments: ["__args": args["args"] as? [Any] ?? []], frame: frame, world: world)
            } else if let code = args["code"] as? String {
                value = try await evaluate(code, webView: webView, frame: frame, world: world)
            } else if let files = args["files"] as? [String] {
                for file in files {
                    guard let code = ext.text(file) else { throw RikuganError("Could not load file: '\(file)'") }
                    value = try await evaluate(code + "\n//# sourceURL=\(ext.baseURL)\(file)", webView: webView, frame: frame, world: world)
                }
            }
            let frameID = frame.map { f in (ext.contentFrames[tab.numericID] ?? []).first { $0.frame.request.url == f.request.url }?.frameID ?? 1 } ?? 0
            results.append(["frameId": frameID, "result": value ?? NSNull(), "documentId": "\(tab.numericID)-\(frameID)"])
        }
        return results
    }

    private func evaluate(_ code: String, webView: WKWebView, frame: WKFrameInfo?, world: WKContentWorld) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(code, in: frame, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value is NSNull ? nil : value)
                case .failure(let error):
                    // `undefined` completion values surface as "unsupported type" errors; treat as null.
                    if (error as NSError).code == 5 { continuation.resume(returning: nil) } else { continuation.resume(throwing: error) }
                }
            }
        }
    }

    private func ensureShim(_ ext: LoadedExtension, webView: WKWebView, frame: WKFrameInfo?) async throws {
        let world = Worlds.extensionWorld(ext.id)
        WebViewFactory.ensureHandler(webView.configuration.userContentController, world: world, profile: runtime.profile)
        let present = (try? await webView.rkCall("return typeof globalThis.__rikuganChrome !== 'undefined';", frame: frame, world: world)) as? Bool ?? false
        if !present { _ = try? await evaluate(runtime.shimSource(ext, ctx: "content"), webView: webView, frame: frame, world: world) }
    }

    private func css(_ ext: LoadedExtension, injection: [String: Any], remove: Bool, caller: Caller) async throws {
        let target = injection["target"] as? [String: Any] ?? [:]
        let (tab, frames) = try targetFrames(target, ext: ext, caller: caller)
        guard let webView = tab.webView else { return }
        var css = injection["css"] as? String ?? ""
        for file in injection["files"] as? [String] ?? [] { css += "\n" + (ext.text(file) ?? "") }
        let key = String(css.hashValue)
        let body = remove ?
            "const m = window.__rkExtCSS || {}; const s = m[k]; if (s) { document.adoptedStyleSheets = document.adoptedStyleSheets.filter(x => x !== s); delete m[k]; } return null;" :
            "window.__rkExtCSS = window.__rkExtCSS || {}; const s = new CSSStyleSheet(); s.replaceSync(c); window.__rkExtCSS[k] = s; document.adoptedStyleSheets = [...document.adoptedStyleSheets, s]; return null;"
        for frame in frames {
            _ = try await webView.rkCall(body, arguments: ["k": key, "c": css], frame: frame, world: Worlds.extensionWorld(ext.id))
        }
    }

    // MARK: permissions.request

    private func requestPermissions(_ ext: LoadedExtension, _ request: [String: Any]) async -> Bool {
        let perms = (request["permissions"] as? [String] ?? []).filter { !ext.has($0) }
        let origins = (request["origins"] as? [String] ?? []).filter { origin in !ext.record.grantedHosts.contains { URLMatcher.pattern($0, covers: origin) } }
        if perms.isEmpty && origins.isEmpty { return true }
        let declared = Set(ext.manifest.optionalPermissions + ext.manifest.permissions)
        let declaredHosts = ext.manifest.optionalHostPermissions + ext.manifest.hostPermissions
        guard perms.allSatisfy(declared.contains),
              origins.allSatisfy({ o in declaredHosts.contains { URLMatcher.pattern($0, covers: o) } }) else { return false }
        let lines = PermissionDescriber.describe(apiPermissions: perms, hostPatterns: origins)
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OnceFlag()
            runtime.permissionRequest = ExtensionRuntime.PermissionPrompt(extName: ext.displayName, lines: lines) { value in
                if once.fire() { continuation.resume(returning: value) }
            }
        }
        guard granted else { return false }
        runtime.updateRecord(ext.id) { record in
            record.grantedPermissions = Array(Set(record.grantedPermissions + perms)).sorted()
            record.grantedHosts = Array(Set(record.grantedHosts + origins)).sorted()
        }
        runtime.dispatch(ext, "permissions.onAdded", [["permissions": perms, "origins": origins]])
        WebViewFactory.invalidateAllTabs()
        if perms.contains(where: { $0.hasPrefix("declarativeNetRequest") }) { runtime.compileDNR() }
        return true
    }

    // MARK: action

    private func actionAPI(_ method: String, ext: LoadedExtension, details: [String: Any], arg0: Any?, caller: Caller) async throws -> Any? {
        let tabID = details["tabId"] as? Int
        func mutate(_ change: (inout ActionState) -> Void) {
            if let tabID { var s = ext.tabActions[tabID] ?? ActionState(); s.badgeText = ext.tabActions[tabID]?.badgeText ?? ""; change(&s); ext.tabActions[tabID] = s }
            else { change(&ext.action) }
            runtime.objectWillChange.send()
        }
        let state = ext.actionState(for: tabID ?? TabRegistry.shared.focusedWindow?.activeTab?.numericID)
        switch method {
        case "setBadgeText": mutate { $0.badgeText = details["text"] as? String ?? "" }; return nil
        case "getBadgeText": return state.badgeText
        case "setBadgeBackgroundColor": mutate { $0.badgeColor = Self.color(details["color"]) ?? .systemRed }; return nil
        case "getBadgeBackgroundColor": return Self.rgba(state.badgeColor)
        case "setBadgeTextColor": mutate { $0.badgeTextColor = Self.color(details["color"]) ?? .white }; return nil
        case "getBadgeTextColor": return Self.rgba(state.badgeTextColor)
        case "setTitle": mutate { $0.title = details["title"] as? String }; return nil
        case "getTitle": return state.title ?? ext.displayName
        case "setPopup": mutate { $0.popup = details["popup"] as? String ?? "" }; return nil
        case "getPopup": return state.popup.map { ext.baseURL + $0 } ?? ""
        case "enable": mutate { $0.enabled = true }; return nil
        case "disable": mutate { $0.enabled = false }; return nil
        case "isEnabled": return state.enabled
        case "setIcon":
            var image: UIImage?
            if let urls = details["imageDataURL"] as? [String: String], let best = urls.values.first,
               let data = Data(base64Encoded: String(best.split(separator: ",").last ?? "")) { image = UIImage(data: data) }
            if image == nil {
                let path = (details["path"] as? String) ?? ((details["path"] as? [String: String]).flatMap { dict in
                    dict.sorted { (Int($0.key) ?? 0) > (Int($1.key) ?? 0) }.first?.value })
                if let path { image = ext.loadIcon(path: path) }
            }
            mutate { $0.icon = image }
            return nil
        case "openPopup":
            runtime.performAction(ext, tab: TabRegistry.shared.focusedWindow?.activeTab)
            return nil
        default:
            throw RikuganError("Unsupported API: chrome.action.\(method)")
        }
    }

    static func color(_ value: Any?) -> UIColor? {
        if let array = value as? [Int], array.count >= 3 {
            return UIColor(red: CGFloat(array[0]) / 255, green: CGFloat(array[1]) / 255, blue: CGFloat(array[2]) / 255,
                           alpha: array.count > 3 ? CGFloat(array[3]) / 255 : 1)
        }
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        let named: [String: UIColor] = ["red": .systemRed, "green": .systemGreen, "blue": .systemBlue, "black": .black, "white": .white,
                                        "gray": .systemGray, "grey": .systemGray, "orange": .systemOrange, "yellow": .systemYellow, "purple": .systemPurple]
        if let color = named[text] { return color }
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let v = UInt64(text, radix: 16) else { return nil }
        if text.count == 8 {
            return UIColor(red: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255, blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func rgba(_ color: UIColor) -> [Int] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255)]
    }

    // MARK: cookies

    private func cookiesAPI(_ method: String, ext: LoadedExtension, details: [String: Any]) async throws -> Any? {
        let store = runtime.profile.dataStore.httpCookieStore
        let url = (details["url"] as? String).flatMap(URL.init(string:))
        if method == "getAllCookieStores" {
            return [["id": "0", "tabIds": TabRegistry.shared.allTabs.filter { !$0.isPrivate }.map(\.numericID)]]
        }
        if let url, !ext.hostAllowed(url) { throw RikuganError("No host permissions for cookies at url: \"\(url.absoluteString)\".") }
        let all = await store.allCookies()
        func matches(_ cookie: HTTPCookie) -> Bool {
            if let url {
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                guard DomainTools.host(url.host ?? "", isWithin: domain), url.path.hasPrefix(cookie.path) || cookie.path == "/" else { return false }
            } else {
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                guard ext.hostAllowed(URL(string: "https://\(domain)/")) else { return false }
            }
            if let name = details["name"] as? String, cookie.name != name { return false }
            if let domain = details["domain"] as? String, !DomainTools.host(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")), isWithin: domain) { return false }
            if let path = details["path"] as? String, cookie.path != path { return false }
            if let secure = details["secure"] as? Bool, cookie.isSecure != secure { return false }
            if let session = details["session"] as? Bool, cookie.isSessionOnly != session { return false }
            return true
        }
        switch method {
        case "get":
            return all.filter(matches).sorted { $0.path.count > $1.path.count }.first.map(cookieJSON)
        case "getAll":
            return all.filter(matches).map(cookieJSON)
        case "set":
            guard let url else { throw RikuganError("cookies.set requires url") }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: details["name"] as? String ?? "", .value: details["value"] as? String ?? "",
                .path: details["path"] as? String ?? "/", .domain: details["domain"] as? String ?? (url.host ?? ""),
            ]
            if details["secure"] as? Bool == true { props[.secure] = "TRUE" }
            if let expiry = details["expirationDate"] as? Double { props[.expires] = Date(timeIntervalSince1970: expiry) }
            if details["httpOnly"] as? Bool == true { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite = details["sameSite"] as? String, sameSite != "unspecified" {
                props[.sameSitePolicy] = sameSite == "strict" ? HTTPCookieStringPolicy.sameSiteStrict : HTTPCookieStringPolicy.sameSiteLax
            }
            guard let cookie = HTTPCookie(properties: props) else { throw RikuganError("Failed to parse or set cookie") }
            await store.setCookie(cookie)
            return cookieJSON(cookie)
        case "remove":
            let targets = all.filter(matches)
            for cookie in targets { await store.deleteCookie(cookie) }
            return ["url": url?.absoluteString ?? "", "name": details["name"] as? String ?? "", "storeId": "0"]
        default:
            throw RikuganError("Unsupported API: chrome.cookies.\(method)")
        }
    }

    private func cookieJSON(_ c: HTTPCookie) -> [String: Any] {
        var json: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "hostOnly": !c.domain.hasPrefix("."), "path": c.path,
                                   "secure": c.isSecure, "httpOnly": c.isHTTPOnly, "session": c.isSessionOnly, "storeId": "0",
                                   "sameSite": c.sameSitePolicy == .sameSiteStrict ? "strict" : (c.sameSitePolicy == .sameSiteLax ? "lax" : "unspecified")]
        if let expires = c.expiresDate { json["expirationDate"] = expires.timeIntervalSince1970 }
        return json
    }

    // MARK: downloads

    private func downloadsAPI(_ method: String, ext: LoadedExtension, arg0: Any?, caller: Caller) throws -> Any? {
        let manager = AppServices.shared.downloads
        switch method {
        case "download":
            let options = arg0 as? [String: Any] ?? [:]
            guard let raw = options["url"] as? String, let url = URL(string: raw) else { throw RikuganError("Invalid URL") }
            var headers: [String: String] = [:]
            for header in options["headers"] as? [[String: Any]] ?? [] {
                if let name = header["name"] as? String, let value = header["value"] as? String { headers[name] = value }
            }
            let name = (options["filename"] as? String).map { ($0 as NSString).lastPathComponent }
            let item = manager.download(url: url, suggestedName: name, from: caller.tab, headers: headers)
            return item?.numericID ?? -1
        case "search":
            let query = arg0 as? [String: Any] ?? [:]
            return manager.items.filter { item in
                if let id = query["id"] as? Int, item.numericID != id { return false }
                if let state = query["state"] as? String, state != item.chromeState { return false }
                return true
            }.map { $0.chromeJSON }
        case "pause", "resume", "cancel", "erase", "open", "show":
            let ids: [Int] = (arg0 as? Int).map { [$0] } ?? ((arg0 as? [String: Any])?["id"] as? Int).map { [$0] } ?? []
            for id in ids {
                guard let item = manager.items.first(where: { $0.numericID == id }) else { continue }
                switch method {
                case "pause": manager.pause(item)
                case "resume": manager.resume(item)
                case "cancel": manager.cancel(item)
                case "erase": manager.remove(item, deleteFile: false)
                default: manager.open(item)
                }
            }
            return method == "erase" ? ids : nil
        default:
            throw RikuganError("Unsupported API: chrome.downloads.\(method)")
        }
    }

    // MARK: declarativeNetRequest

    private func dnrAPI(_ method: String, ext: LoadedExtension, details: [String: Any]) throws -> Any? {
        switch method {
        case "updateDynamicRules", "updateSessionRules":
            let session = method == "updateSessionRules"
            var rules = session ? ext.sessionRules : ext.dynamicRules
            let remove = Set(details["removeRuleIds"] as? [Int] ?? [])
            rules.removeAll { remove.contains($0["id"] as? Int ?? -1) }
            let add = details["addRules"] as? [[String: Any]] ?? []
            for rule in add {
                let id = rule["id"] as? Int ?? -1
                if rules.contains(where: { ($0["id"] as? Int) == id }) { throw RikuganError("Rule with id \(id) does not have a unique ID.") }
            }
            rules += add
            if session { ext.sessionRules = rules }
            else {
                let json = JSONText.encode(rules)
                runtime.updateRecord(ext.id) { $0.dynamicRulesJSON = json }
            }
            runtime.compileDNR()
            return nil
        case "getDynamicRules":
            let ids = details["ruleIds"] as? [Int]
            return ext.dynamicRules.filter { ids?.contains($0["id"] as? Int ?? -1) ?? true }
        case "getSessionRules":
            let ids = details["ruleIds"] as? [Int]
            return ext.sessionRules.filter { ids?.contains($0["id"] as? Int ?? -1) ?? true }
        case "updateEnabledRulesets":
            var enabled = Set(ext.enabledRulesetIDs)
            enabled.subtract(details["disableRulesetIds"] as? [String] ?? [])
            enabled.formUnion(details["enableRulesetIds"] as? [String] ?? [])
            let valid = Set(ext.manifest.ruleResources.map(\.id))
            if let bad = enabled.first(where: { !valid.contains($0) }) { throw RikuganError("Invalid ruleset id: \(bad).") }
            runtime.updateRecord(ext.id) { $0.enabledRulesets = Array(enabled).sorted() }
            runtime.compileDNR()
            return nil
        case "getEnabledRulesets":
            return ext.enabledRulesetIDs
        case "updateStaticRules":
            throw RikuganError("Unsupported API: chrome.declarativeNetRequest.updateStaticRules")
        case "isRegexSupported":
            let regex = details["regex"] as? String ?? ""
            return ABPPattern.webKitRegex(from: regex) != nil ? ["isSupported": true] : ["isSupported": false, "reason": "syntaxError"]
        default:
            throw RikuganError("Unsupported API: chrome.declarativeNetRequest.\(method)")
        }
    }

    // MARK: alarms

    private func alarmsAPI(_ method: String, ext: LoadedExtension, arg0: Any?, arg1: [String: Any]) -> Any? {
        func json(_ alarm: ExtensionAlarm) -> [String: Any] {
            var j: [String: Any] = ["name": alarm.name, "scheduledTime": alarm.scheduledTime.timeIntervalSince1970 * 1000]
            if let period = alarm.periodInMinutes { j["periodInMinutes"] = period }
            return j
        }
        switch method {
        case "create":
            let name = arg0 as? String ?? ""
            ext.alarms[name]?.timer?.invalidate()
            let now = Date()
            var first: Date
            if let when = arg1["when"] as? Double { first = Date(timeIntervalSince1970: when / 1000) }
            else if let delay = arg1["delayInMinutes"] as? Double { first = now.addingTimeInterval(max(delay, 0.5) * 60) }
            else if let period = arg1["periodInMinutes"] as? Double { first = now.addingTimeInterval(max(period, 0.5) * 60) }
            else { first = now.addingTimeInterval(30) }
            let period = (arg1["periodInMinutes"] as? Double).map { max($0, 0.5) }
            var alarm = ExtensionAlarm(name: name, scheduledTime: first, periodInMinutes: period)
            let timer = Timer(fire: first, interval: (period ?? 0) * 60, repeats: period != nil) { [weak self, weak ext] _ in
                Task { @MainActor in
                    guard let self, let ext, var current = ext.alarms[name] else { return }
                    self.runtime.dispatch(ext, "alarms.onAlarm", [json(current)])
                    if let period = current.periodInMinutes { current.scheduledTime = Date().addingTimeInterval(period * 60); ext.alarms[name] = current }
                    else { ext.alarms.removeValue(forKey: name) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            alarm.timer = timer
            ext.alarms[name] = alarm
            return nil
        case "get":
            return ext.alarms[arg0 as? String ?? ""].map(json)
        case "getAll":
            return ext.alarms.values.map(json)
        case "clear":
            let name = arg0 as? String ?? ""
            let existed = ext.alarms[name] != nil
            ext.alarms.removeValue(forKey: name)?.timer?.invalidate()
            return existed
        case "clearAll":
            for alarm in ext.alarms.values { alarm.timer?.invalidate() }
            let had = !ext.alarms.isEmpty
            ext.alarms.removeAll()
            return had
        default:
            return nil
        }
    }
}
