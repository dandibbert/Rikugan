import Foundation
import WebKit
import UIKit
import UserNotifications
import Combine

/// Native side of the GM_* API (spec §8 / §9 GMBridge).
@MainActor final class GMBridge {
    unowned let store: UserScriptStore
    private var xhrTasks: [String: URLSessionTask] = [:]
    private var downloads: [String: DownloadItem] = [:]
    /// GM_saveTab values: tab UUID → script UUID → JSON value. Persisted so they survive an app
    /// restart like the tabs themselves; entries of closed tabs are dropped on the next save.
    private var tabValues: [String: [String: Any]] = [:]
    private var tabValuesLoaded = false
    /// Tabs opened with GM_openInTab, for the handle's `onclose` / `closed`.
    private var openedTabs: [Int: (sid: UUID, webView: WeakBox<WKWebView>, frame: WKFrameInfo?)] = [:]
    private var closeObserver: NSObjectProtocol?

    init(store: UserScriptStore) {
        self.store = store
        closeObserver = NotificationCenter.default.addObserver(forName: .rikuganTabClosed, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["tabId"] as? Int else { return }
            MainActor.assumeIsolated { self?.tabClosed(id) }
        }
    }

    private var tabValuesURL: URL { store.directory.appendingPathComponent("gm-tab-values.json") }

    private func loadTabValues() {
        guard !tabValuesLoaded else { return }
        tabValuesLoaded = true
        if let data = try? Data(contentsOf: tabValuesURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            tabValues = json
        }
    }

    private func saveTabValues() {
        let open = Set(TabRegistry.shared.allTabs.map { $0.id.uuidString })
        tabValues = tabValues.filter { open.contains($0.key) }
        if let data = try? JSONSerialization.data(withJSONObject: tabValues) { try? data.write(to: tabValuesURL, options: .atomic) }
    }

    /// Sends an event to the script's dispatch function in the frame that made the call.
    private func send(_ event: [String: Any], sid: UUID, webView: WKWebView?, frame: WKFrameInfo?) {
        guard let webView else { return }
        let fn = UserScriptStore.dispatchFunctionName(sid)
        webView.rkEval("window[\(fn.jsLiteral)] && window[\(fn.jsLiteral)](\(JSONText.encode(event)))", frame: frame, world: Worlds.userscript(sid))
    }

    private func tabClosed(_ id: Int) {
        guard let opened = openedTabs.removeValue(forKey: id) else { return }
        send(["type": "tabClosed", "tabId": id], sid: opened.sid, webView: opened.webView.value, frame: opened.frame)
    }

    func handle(_ body: [String: Any], message: WKScriptMessage, worldName: String) async throws -> Any? {
        guard let sidText = body["sid"] as? String, let sid = UUID(uuidString: sidText), let script = store.script(sid) else {
            SecurityLog.shared.record("GM call rejected: unknown userscript id from world '\(worldName)'")
            throw RikuganError("Unknown userscript")
        }
        // Authenticate by content world only. WebKit reports the world a message came from; page
        // JavaScript (world "") and other scripts' worlds cannot produce "us-<this script's id>".
        // Page-world scripts never get the bridge, so there is no page-world credential to steal.
        guard !script.usesPageWorld, let expectedWorld = Worlds.userscript(sid).name, worldName == expectedWorld else {
            SecurityLog.shared.record("GM call rejected: world '\(worldName)' for script \(script.name)")
            throw RikuganError("GM bridge world mismatch")
        }
        guard script.enabled else { throw RikuganError("Userscript is disabled") }
        let op = body["op"] as? String ?? ""
        let args = body["args"] as? [String: Any] ?? [:]
        let tab = message.tab
        let pageURL = message.frameInfo.request.url ?? tab?.webView?.url
        func requireGrant(_ names: String...) throws { try requireGrant(names) }
        func requireGrant(_ names: [String]) throws {
            let grants = Set(script.metadata.grants)
            guard names.contains(where: grants.contains) else {
                SecurityLog.shared.record("GM op '\(op)' rejected for \(script.name): missing @grant \(names.first ?? "")")
                throw RikuganError("Missing @grant \(names.first ?? "")")
            }
        }
        let storageRead = ["GM_getValue", "GM.getValue", "GM_listValues", "GM.listValues", "GM_getValues", "GM.getValues",
                           "GM_addValueChangeListener", "GM.addValueChangeListener", "GM_setValue", "GM.setValue",
                           "GM_deleteValue", "GM.deleteValue", "GM_setValues", "GM.setValues", "GM_deleteValues", "GM.deleteValues"]
        let storageWrite = ["GM_setValue", "GM.setValue", "GM_deleteValue", "GM.deleteValue", "GM_setValues", "GM.setValues",
                            "GM_deleteValues", "GM.deleteValues"]
        let tabGrants = ["GM_getTab", "GM.getTab", "GM_saveTab", "GM.saveTab", "GM_getTabs", "GM.getTabs"]

        switch op {
        case "injected":
            if message.frameInfo.isMainFrame { tab?.injectedScripts.insert(sid) }
            return nil
        case "error":
            tab?.appendConsole(level: "error", text: "[\(script.name)] " + (args["message"] as? String ?? ""))
            return nil
        case "getAll":
            try requireGrant(storageRead)
            return store.values(for: sid)
        case "setValue":
            try requireGrant(storageWrite)
            guard let key = args["key"] as? String else { return nil }
            let value = args["value"] as? String
            store.setValue(value, key: key, for: sid)
            broadcastValueChange(script: script, key: key, value: value, except: message.webView)
            return nil
        case "deleteValue":
            try requireGrant(storageWrite)
            guard let key = args["key"] as? String else { return nil }
            store.setValue(nil, key: key, for: sid)
            broadcastValueChange(script: script, key: key, value: nil, except: message.webView)
            return nil
        case "clipboard":
            try requireGrant("GM_setClipboard", "GM.setClipboard")
            let text = args["text"] as? String ?? ""
            let type = (args["type"] as? String ?? "text").lowercased()
            if type.contains("html") { UIPasteboard.general.setValue(text, forPasteboardType: "public.html") }
            else { UIPasteboard.general.string = text }
            return true
        case "openInTab":
            try requireGrant("GM_openInTab", "GM.openInTab")
            guard let raw = args["url"] as? String, let url = URL(string: raw), let manager = tab?.manager else { return nil }
            let incognito = (args["incognito"] as? Bool ?? false) || (tab?.isPrivate ?? false)
            let newTab = manager.newTab(url: url, background: args["background"] as? Bool ?? false, isPrivate: incognito, opener: tab,
                                        insertAfterOpener: args["insert"] as? Bool ?? true)
            if let webView = message.webView {
                openedTabs[newTab.numericID] = (sid, WeakBox(webView), message.frameInfo)
            }
            return newTab.numericID
        case "closeTab":
            if let id = args["tabId"] as? Int, let target = TabRegistry.shared.tab(id), target.opener === tab || target === tab {
                target.manager?.close(target)
            } else if args["tabId"] == nil, let tab, script.metadata.grants.contains("window.close") {
                tab.manager?.close(tab)
            }
            return nil
        case "focusTab":
            try requireGrant(["window.focus"])
            if let tab { tab.manager?.select(tab) }
            return nil
        case "notification":
            try requireGrant("GM_notification", "GM.notification")
            let title = args["title"] as? String ?? script.name
            let text = args["text"] as? String ?? ""
            let highlight = args["highlight"] as? Bool ?? false
            let clickURL = (args["url"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            // `highlight` brings the script's tab to the front; with no text that is all it does.
            if highlight, let tab { tab.manager?.select(tab) }
            if text.isEmpty, highlight { return "done" }
            let once = OnceFlag()
            let timeout = max(3, (args["timeout"] as? Double ?? 0) / 1000)
            return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                ToastCenter.shared.show("\(title)：\(text)", symbol: "bell", actionTitle: "查看", duration: timeout) {
                    if let tab { tab.manager?.select(tab) }
                    if let clickURL, let manager = tab?.manager { manager.newTab(url: clickURL, isPrivate: tab?.isPrivate, opener: tab) }
                    if once.fire() { continuation.resume(returning: "clicked") }
                }
                Task { @MainActor in
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = text
                    if UIApplication.shared.applicationState != .active {
                        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                    }
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if once.fire() { continuation.resume(returning: "done") }
                }
            }
        case "download":
            try requireGrant("GM_download", "GM.download")
            guard let raw = args["url"] as? String, let url = URL(string: raw) else { throw RikuganError("Invalid URL") }
            let name = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let item = AppServices.shared.downloads.download(url: url, suggestedName: name, from: tab,
                                                                   headers: args["headers"] as? [String: String] ?? [:]) else {
                return ["error": "download_failed", "details": "The download could not be started"]
            }
            if args["saveAs"] as? Bool == true { item.exportToFiles = true }
            let key = sid.uuidString + "|" + (args["id"] as? String ?? UUID().uuidString)
            downloads[key] = item
            defer { downloads.removeValue(forKey: key) }
            let webView = message.webView, frame = message.frameInfo, jsID = args["id"] as? String ?? ""
            let timeout = (args["timeout"] as? Double).map { $0 / 1000 } ?? 0
            let state = await awaitDownload(item, timeout: timeout) { [weak self] loaded, total in
                self?.send(["type": "download", "id": jsID, "loaded": loaded, "total": total], sid: sid, webView: webView, frame: frame)
            }
            switch state {
            case .completed: return ["url": raw, "name": item.fileName]
            case .cancelled: return ["error": timeout > 0 && item.received < item.total ? "timeout" : "aborted"]
            case .failed(let message): return ["error": "download_failed", "details": message]
            default: return ["error": "download_failed"]
            }
        case "downloadAbort":
            if let id = args["id"] as? String, let item = downloads[sid.uuidString + "|" + id] { AppServices.shared.downloads.cancel(item) }
            return nil
        case "menuRegister":
            try requireGrant(["GM_registerMenuCommand", "GM.registerMenuCommand"])
            guard let tab, message.frameInfo.isMainFrame else { return nil }
            let id = args["id"] as? String ?? UUID().uuidString
            let command = ScriptMenuCommand(scriptID: sid, commandID: id, scriptName: script.name, title: args["name"] as? String ?? id)
            tab.menuCommands.removeAll { $0.id == command.id }
            tab.menuCommands.append(command)
            return id
        case "menuUnregister":
            let id = args["id"] as? String ?? ""
            tab?.menuCommands.removeAll { $0.scriptID == sid && $0.commandID == id }
            return nil
        case "getTab":
            try requireGrant(tabGrants)
            loadTabValues()
            guard let tab else { return [:] }
            return tabValues[tab.id.uuidString]?[sid.uuidString] ?? [:]
        case "saveTab":
            try requireGrant(tabGrants)
            loadTabValues()
            guard let tab, !tab.isPrivate else { return nil }
            let value = args["value"] ?? [:]
            guard JSONSerialization.isValidJSONObject([value]) else { throw RikuganError("GM_saveTab: value is not serialisable") }
            tabValues[tab.id.uuidString, default: [:]][sid.uuidString] = value
            saveTabValues()
            return nil
        case "getTabs":
            try requireGrant(tabGrants)
            loadTabValues()
            var result: [String: Any] = [:]
            for tab in TabRegistry.shared.allTabs where !tab.isPrivate {
                if let value = tabValues[tab.id.uuidString]?[sid.uuidString] { result[String(tab.numericID)] = value }
            }
            return result
        case "xhr":
            try requireGrant("GM_xmlhttpRequest", "GM.xmlHttpRequest", "GM.xmlhttpRequest")
            let webView = message.webView, frame = message.frameInfo
            return try await performXHR(args, script: script, pageURL: pageURL, isPrivate: tab?.isPrivate ?? false, profile: tab?.profile) { [weak self] event in
                self?.send(event, sid: sid, webView: webView, frame: frame)
            }
        case "xhrAbort":
            if let id = args["id"] as? String { xhrTasks.removeValue(forKey: sid.uuidString + "|" + id)?.cancel() }
            return nil
        case "cookieList", "cookieSet", "cookieDelete":
            try requireGrant("GM_cookie", "GM.cookie")
            return try await cookieOp(op, args, script: script, pageURL: pageURL, tab: tab)
        case "audioSetMute":
            try requireGrant("GM_audio", "GM.audio")
            guard let tab else { throw RikuganError("No tab") }
            tab.audioMuted = args["isMuted"] as? Bool ?? false
            tab.invalidateInjection()
            if let webView = tab.webView {
                _ = await webView.rkTools("setMuted", [tab.audioMuted])
                for record in tab.frameRecords where !record.frame.isMainFrame { _ = await webView.rkTools("setMuted", [tab.audioMuted], frame: record.frame) }
            }
            return nil
        case "audioGetState":
            try requireGrant("GM_audio", "GM.audio")
            guard let tab else { throw RikuganError("No tab") }
            var audible = false
            if let webView = tab.webView {
                audible = await webView.rkTools("audible") as? Bool ?? false
                for record in tab.frameRecords where !audible && !record.frame.isMainFrame {
                    audible = await webView.rkTools("audible", frame: record.frame) as? Bool ?? false
                }
            }
            return ["isMuted": tab.audioMuted, "muteReason": tab.audioMuted ? "user" as Any : NSNull(), "isAudible": audible]
        default:
            throw RikuganError("Unsupported API: GM op \(op)")
        }
    }

    private func broadcastValueChange(script: InstalledUserScript, key: String, value: String?, except origin: WKWebView?) {
        guard !script.usesPageWorld else { return }
        let fn = UserScriptStore.dispatchFunctionName(script.id)
        let payload = JSONText.encode(["type": "valueChanged", "key": key, "value": value.map { $0 as Any } ?? NSNull()])
        let js = "window[\(fn.jsLiteral)] && window[\(fn.jsLiteral)](\(payload))"
        let world = Worlds.userscript(script.id)
        for tab in TabRegistry.shared.allTabs {
            guard let webView = tab.webView, webView !== origin, tab.injectedScripts.contains(script.id) else { continue }
            webView.rkEval(js, world: world)
        }
    }

    // MARK: GM_xmlhttpRequest

    private func connectAllowed(_ url: URL, script: InstalledUserScript, pageURL: URL?) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let pageHost = pageURL?.host?.lowercased(), DomainTools.host(host, isWithin: pageHost) || host == pageHost { return true }
        let connects = script.metadata.connects.map { $0.lowercased() }
        if connects.isEmpty {
            // Tampermonkey asks the user when no @connect is declared; Rikugan allows hosts of the script's
            // own @match / @include rules and otherwise requires an explicit @connect.
            return script.metadata.includeRules().contains { $0.matches(url) }
        }
        return connects.contains { rule in
            rule == "*" || (rule == "self" && host == pageURL?.host?.lowercased()) ||
                (rule == "localhost" && (host == "localhost" || host == "127.0.0.1")) ||
                DomainTools.host(host, isWithin: rule) || host == rule
        }
    }

    private func performXHR(_ args: [String: Any], script: InstalledUserScript, pageURL: URL?, isPrivate: Bool,
                            profile: ProfileContext?, onEvent: @escaping @MainActor ([String: Any]) -> Void) async throws -> Any? {
        guard let raw = args["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return ["error": "Invalid URL"]
        }
        guard connectAllowed(url, script: script, pageURL: pageURL) else {
            return ["error": "Blocked by @connect: \(url.host ?? raw) is not declared in the script metadata"]
        }
        // Task keys are namespaced by script so one script cannot abort another's request.
        let jsID = args["id"] as? String ?? UUID().uuidString
        let id = script.id.uuidString + "|" + jsID
        var request = URLRequest(url: url)
        request.httpMethod = (args["method"] as? String ?? "GET").uppercased()
        let timeout = args["timeout"] as? Double ?? 0
        request.timeoutInterval = timeout > 0 ? timeout / 1000 : 60
        if args["nocache"] as? Bool == true { request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData }
        else if args["revalidate"] as? Bool == true { request.cachePolicy = .reloadRevalidatingCacheData }
        for (key, value) in args["headers"] as? [String: Any] ?? [:] {
            request.setValue(String(describing: value), forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(pageUserAgent, forHTTPHeaderField: "User-Agent")
        }
        if let base64 = args["bodyBase64"] as? String, let data = Data(base64Encoded: base64) { request.httpBody = data }
        else if let text = args["body"] as? String { request.httpBody = Data(text.utf8) }
        if let user = args["user"] as? String, let password = args["password"] as? String {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        let anonymous = args["anonymous"] as? Bool ?? false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        var cookieHeader: [String] = []
        if !anonymous, let profile {
            // Send the browser's cookies for the target URL, like Tampermonkey does by default.
            let store = isPrivate ? profile.privateDataStore() : profile.dataStore
            let cookies = await store.httpCookieStore.allCookies().filter { Self.cookie($0, appliesTo: url) }
            if !cookies.isEmpty, request.value(forHTTPHeaderField: "Cookie") == nil, let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
                cookieHeader.append(header)
            }
        }
        // Tampermonkey's `cookie` option adds cookies to the request.
        if let extra = args["cookie"] as? String, !extra.isEmpty { cookieHeader.append(extra) }
        if !cookieHeader.isEmpty, request.value(forHTTPHeaderField: "Cookie") == nil {
            request.setValue(cookieHeader.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        let stream = args["stream"] as? Bool ?? false
        let delegate = XHRDelegate(follow: (args["redirect"] as? String ?? "follow") != "manual", stream: stream,
                                   check: { [weak self] target in
            guard let self else { return false }
            return await self.connectAllowed(target, script: script, pageURL: pageURL)
        }, event: { event in
            var event = event
            event["type"] = "xhr"
            event["id"] = jsID
            Task { @MainActor in onEvent(event) }
        })
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
                delegate.completion = { result in continuation.resume(with: result) }
                let task = session.dataTask(with: request)
                xhrTasks[id] = task
                task.resume()
            }
            xhrTasks.removeValue(forKey: id)
            guard data.count <= 64 * 1024 * 1024 else { return ["error": "Response too large"] }
            let http = response as? HTTPURLResponse
            let contentType = (args["overrideMimeType"] as? String) ?? (http?.value(forHTTPHeaderField: "Content-Type") ?? "")
            return [
                "status": http?.statusCode ?? 200,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 200),
                "finalUrl": response.url?.absoluteString ?? raw,
                "responseHeaders": XHRDelegate.headerText(http),
                "contentType": contentType,
                "base64": stream ? "" : data.base64EncodedString(),
                "size": delegate.received,
                "streamed": stream,
            ]
        } catch {
            xhrTasks.removeValue(forKey: id)
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut { return ["error": "timeout"] }
            if nsError.code == NSURLErrorCancelled { return ["error": "abort"] }
            return ["error": error.localizedDescription]
        }
    }

    static func cookie(_ cookie: HTTPCookie, appliesTo url: URL) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        let host = url.host?.lowercased() ?? ""
        let domainOK = cookie.domain.hasPrefix(".") ? DomainTools.host(host, isWithin: domain.lowercased()) || host == domain.lowercased() : host == domain.lowercased()
        let path = url.path.isEmpty ? "/" : url.path
        return domainOK && path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate.map { $0 > Date() } ?? true)
    }

    // MARK: GM_download

    private func awaitDownload(_ item: DownloadItem, timeout: TimeInterval,
                               progress: @escaping @MainActor (Int64, Int64) -> Void) async -> DownloadItem.State {
        func isFinal(_ state: DownloadItem.State) -> Bool {
            switch state { case .completed, .failed, .cancelled: return true; default: return false }
        }
        if isFinal(item.state) { return item.state }
        var cancellables = Set<AnyCancellable>()
        if timeout > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !isFinal(item.state) { AppServices.shared.downloads.cancel(item) }
            }
        }
        let state: DownloadItem.State = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            item.$state.sink { state in
                if isFinal(state), once.fire() { continuation.resume(returning: state) }
            }.store(in: &cancellables)
            item.$received.throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true).sink { received in
                MainActor.assumeIsolated { progress(received, item.total) }
            }.store(in: &cancellables)
        }
        cancellables.removeAll()
        return state
    }

    // MARK: GM_cookie

    /// Cookies are reachable for the page's own site and for hosts the script may connect to
    /// (its @match / @include / @connect rules), like GM_xmlhttpRequest.
    private func cookieOp(_ op: String, _ details: [String: Any], script: InstalledUserScript, pageURL: URL?, tab: BrowserTab?) async throws -> Any? {
        guard let profile = tab?.profile else { throw RikuganError("No tab") }
        let domainArg = (details["domain"] as? String)?.lowercased()
        let target: URL? = (details["url"] as? String).flatMap(URL.init(string:))
            ?? domainArg.flatMap { URL(string: "https://" + ($0.hasPrefix(".") ? String($0.dropFirst()) : $0) + "/") }
            ?? pageURL
        guard let url = target, url.host != nil else { throw RikuganError("GM_cookie: a url or domain is required") }
        guard connectAllowed(url, script: script, pageURL: pageURL) else {
            throw RikuganError("GM_cookie: \(url.host ?? "") is outside the page and the script's @match / @connect rules")
        }
        let store = (tab?.isPrivate ?? false) ? profile.privateDataStore().httpCookieStore : profile.dataStore.httpCookieStore
        let all = await store.allCookies()
        func matches(_ c: HTTPCookie) -> Bool {
            if let domainArg, details["url"] == nil {
                let d = domainArg.hasPrefix(".") ? String(domainArg.dropFirst()) : domainArg
                let cd = (c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain).lowercased()
                guard cd == d || DomainTools.host(cd, isWithin: d) else { return false }
            } else if !Self.cookie(c, appliesTo: url) { return false }
            if let name = details["name"] as? String, c.name != name { return false }
            if let path = details["path"] as? String, c.path != path { return false }
            return true
        }
        switch op {
        case "cookieList":
            return all.filter(matches).map { c -> [String: Any] in
                var json: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "hostOnly": !c.domain.hasPrefix("."),
                                           "path": c.path, "secure": c.isSecure, "httpOnly": c.isHTTPOnly, "session": c.isSessionOnly,
                                           "sameSite": c.sameSitePolicy == .sameSiteStrict ? "strict" : (c.sameSitePolicy == .sameSiteLax ? "lax" : "unspecified"),
                                           "firstPartyDomain": ""]
                if let expires = c.expiresDate { json["expirationDate"] = expires.timeIntervalSince1970 }
                return json
            }
        case "cookieSet":
            guard let name = details["name"] as? String, !name.isEmpty else { throw RikuganError("GM_cookie.set: name is required") }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: details["value"] as? String ?? "", .path: details["path"] as? String ?? "/",
                .domain: domainArg ?? url.host ?? "",
            ]
            if details["secure"] as? Bool == true { properties[.secure] = "TRUE" }
            if details["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let expires = details["expirationDate"] as? Double { properties[.expires] = Date(timeIntervalSince1970: expires) }
            if let sameSite = details["sameSite"] as? String, sameSite != "unspecified", sameSite != "no_restriction" {
                properties[.sameSitePolicy] = sameSite == "strict" ? HTTPCookieStringPolicy.sameSiteStrict : HTTPCookieStringPolicy.sameSiteLax
            }
            guard let cookie = HTTPCookie(properties: properties) else { throw RikuganError("GM_cookie.set: invalid cookie") }
            await store.setCookie(cookie)
            return nil
        default:
            guard details["name"] is String else { throw RikuganError("GM_cookie.delete: name is required") }
            for cookie in all where matches(cookie) { await store.deleteCookie(cookie) }
            return nil
        }
    }

    private var pageUserAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " + WebViewFactory.safariUserAgentSuffix
    }
}

/// URLSession delegate for GM_xmlhttpRequest: checks every redirect against @connect, reports the
/// headers and real download progress, and forwards body chunks for `responseType: "stream"`.
final class XHRDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let follow: Bool
    let stream: Bool
    let check: (URL) async -> Bool
    let event: ([String: Any]) -> Void
    var completion: ((Result<(Data, URLResponse), Error>) -> Void)?
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private(set) var received = 0
    private var expected: Int64 = -1
    private var lastProgress = Date.distantPast

    init(follow: Bool, stream: Bool, check: @escaping (URL) async -> Bool, event: @escaping ([String: Any]) -> Void) {
        self.follow = follow
        self.stream = stream
        self.check = check
        self.event = event
    }

    static func headerText(_ http: HTTPURLResponse?) -> String {
        var headers = ""
        for (key, value) in http?.allHeaderFields ?? [:] { headers += "\(String(describing: key).lowercased()): \(value)\r\n" }
        return headers
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard follow, let url = request.url else { completionHandler(nil); return }
        Task {
            let allowed = await check(url)
            completionHandler(allowed ? request : nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); self.response = response; expected = response.expectedContentLength; lock.unlock()
        let http = response as? HTTPURLResponse
        event(["phase": "headers", "status": http?.statusCode ?? 200,
               "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 200),
               "finalUrl": response.url?.absoluteString ?? "", "responseHeaders": Self.headerText(http),
               "total": max(0, response.expectedContentLength)])
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        received += chunk.count
        if !stream { data.append(chunk) }
        let loaded = received, total = max(0, expected)
        let due = Date().timeIntervalSince(lastProgress) >= 0.1
        if due { lastProgress = Date() }
        lock.unlock()
        if stream { event(["phase": "chunk", "base64": chunk.base64EncodedString()]) }
        if due { event(["phase": "progress", "loaded": loaded, "total": total]) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = data, response = self.response ?? task.response ?? URLResponse()
        let done = completion
        completion = nil
        lock.unlock()
        if let error { done?(.failure(error)) } else { done?(.success((body, response))) }
    }
}

/// Thread-safe "only once" flag for continuations resumed from several callbacks.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
