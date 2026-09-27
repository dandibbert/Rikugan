import Foundation
import WebKit
import UIKit
import UserNotifications

/// Native side of the GM_* API (spec §8 / §9 GMBridge).
@MainActor final class GMBridge {
    unowned let store: UserScriptStore
    private var xhrTasks: [String: URLSessionTask] = [:]
    private var tabValues: [Int: [UUID: Any]] = [:]

    init(store: UserScriptStore) { self.store = store }

    func handle(_ body: [String: Any], message: WKScriptMessage, worldName: String) async throws -> Any? {
        guard let sidText = body["sid"] as? String, let sid = UUID(uuidString: sidText), let script = store.script(sid) else {
            throw RikuganError("Unknown userscript")
        }
        // Authenticate: isolated scripts must come from their own world; page-world scripts need the token.
        let expectedWorld = script.usesPageWorld ? "" : Worlds.userscript(sid).name ?? ""
        if script.usesPageWorld {
            guard body["token"] as? String == store.token(for: sid) else { throw RikuganError("GM bridge authentication failed") }
        } else {
            guard worldName == expectedWorld else { throw RikuganError("GM bridge world mismatch") }
        }
        let op = body["op"] as? String ?? ""
        let args = body["args"] as? [String: Any] ?? [:]
        let tab = message.tab
        let pageURL = message.frameInfo.request.url ?? tab?.webView?.url
        func requireGrant(_ names: String...) throws {
            let grants = Set(script.metadata.grants)
            guard names.contains(where: grants.contains) else {
                throw RikuganError("Missing @grant \(names.first ?? "")")
            }
        }

        switch op {
        case "injected":
            if message.frameInfo.isMainFrame { tab?.injectedScripts.insert(sid) }
            return nil
        case "error":
            tab?.appendConsole(level: "error", text: "[\(script.name)] " + (args["message"] as? String ?? ""))
            return nil
        case "getAll":
            return store.values(for: sid)
        case "setValue":
            guard let key = args["key"] as? String else { return nil }
            let value = args["value"] as? String
            store.setValue(value, key: key, for: sid)
            broadcastValueChange(script: script, key: key, value: value, except: message.webView)
            return nil
        case "deleteValue":
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
            let newTab = manager.newTab(url: url, background: args["background"] as? Bool ?? false, isPrivate: tab?.isPrivate, opener: tab)
            return newTab.numericID
        case "closeTab":
            if let id = args["tabId"] as? Int, let target = TabRegistry.shared.tab(id), target.opener === tab || target === tab {
                target.manager?.close(target)
            } else if args["tabId"] == nil, let tab, script.metadata.grants.contains("window.close") {
                tab.manager?.close(tab)
            }
            return nil
        case "focusTab":
            if let tab { tab.manager?.select(tab) }
            return nil
        case "notification":
            try requireGrant("GM_notification", "GM.notification")
            let title = args["title"] as? String ?? script.name
            let text = args["text"] as? String ?? ""
            let once = OnceFlag()
            let timeout = max(3, (args["timeout"] as? Double ?? 0) / 1000)
            return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                ToastCenter.shared.show("\(title)：\(text)", symbol: "bell", actionTitle: "查看", duration: timeout) {
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
            AppServices.shared.downloads.download(url: url, suggestedName: name, from: tab, headers: args["headers"] as? [String: String] ?? [:])
            return ["url": raw]
        case "menuRegister":
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
            guard let tab else { return [:] }
            return tabValues[tab.numericID]?[sid] ?? [:]
        case "saveTab":
            guard let tab else { return nil }
            tabValues[tab.numericID, default: [:]][sid] = args["value"] ?? [:]
            return nil
        case "getTabs":
            var result: [String: Any] = [:]
            for (tabID, entries) in tabValues { if let v = entries[sid] { result[String(tabID)] = v } }
            return result
        case "xhr":
            try requireGrant("GM_xmlhttpRequest", "GM.xmlHttpRequest", "GM.xmlhttpRequest")
            return try await performXHR(args, script: script, pageURL: pageURL, isPrivate: tab?.isPrivate ?? false, profile: tab?.profile)
        case "xhrAbort":
            if let id = args["id"] as? String { xhrTasks.removeValue(forKey: id)?.cancel() }
            return nil
        default:
            throw RikuganError("Unsupported API: GM op \(op)")
        }
    }

    private func broadcastValueChange(script: InstalledUserScript, key: String, value: String?, except origin: WKWebView?) {
        let fn = "__rikuganGM_" + store.token(for: script.id)
        let payload = JSONText.encode(["type": "valueChanged", "key": key, "value": value.map { $0 as Any } ?? NSNull()])
        let js = "window[\(fn.jsLiteral)] && window[\(fn.jsLiteral)](\(payload))"
        let world = script.usesPageWorld ? WKContentWorld.page : Worlds.userscript(script.id)
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
                            profile: ProfileContext?) async throws -> Any? {
        guard let raw = args["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return ["error": "Invalid URL"]
        }
        guard connectAllowed(url, script: script, pageURL: pageURL) else {
            return ["error": "Blocked by @connect: \(url.host ?? raw) is not declared in the script metadata"]
        }
        let id = args["id"] as? String ?? UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = (args["method"] as? String ?? "GET").uppercased()
        let timeout = args["timeout"] as? Double ?? 0
        request.timeoutInterval = timeout > 0 ? timeout / 1000 : 60
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
        if !anonymous, let profile {
            // Send the browser's cookies for the target URL, like Tampermonkey does by default.
            let store = isPrivate ? profile.privateDataStore() : profile.dataStore
            let cookies = await store.httpCookieStore.allCookies().filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return DomainTools.host(url.host ?? "", isWithin: domain) && url.path.hasPrefix(cookie.path) &&
                    (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate.map { $0 > Date() } ?? true)
            }
            if !cookies.isEmpty, request.value(forHTTPHeaderField: "Cookie") == nil {
                for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(v, forHTTPHeaderField: k) }
            }
        }
        let session = URLSession(configuration: configuration, delegate: RedirectPolicy(follow: (args["redirect"] as? String ?? "follow") != "manual",
                                                                                         check: { [weak self] target in
            guard let self else { return false }
            return await self.connectAllowed(target, script: script, pageURL: pageURL)
        }), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response): (Data, URLResponse) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = session.dataTask(with: request) { data, response, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: (data ?? Data(), response ?? URLResponse())) }
                    }
                    Task { @MainActor in self.xhrTasks[id] = task }
                    task.resume()
                }
            } onCancel: { }
            xhrTasks.removeValue(forKey: id)
            guard data.count <= 64 * 1024 * 1024 else { return ["error": "Response too large"] }
            let http = response as? HTTPURLResponse
            var headers = ""
            for (key, value) in http?.allHeaderFields ?? [:] { headers += "\(String(describing: key).lowercased()): \(value)\r\n" }
            let contentType = (args["overrideMimeType"] as? String) ?? (http?.value(forHTTPHeaderField: "Content-Type") ?? "")
            return [
                "status": http?.statusCode ?? 200,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 200),
                "finalUrl": response.url?.absoluteString ?? raw,
                "responseHeaders": headers,
                "contentType": contentType,
                "base64": data.base64EncodedString(),
                "size": data.count,
            ]
        } catch {
            xhrTasks.removeValue(forKey: id)
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut { return ["error": "timeout"] }
            if nsError.code == NSURLErrorCancelled { return ["error": "abort"] }
            return ["error": error.localizedDescription]
        }
    }

    private var pageUserAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) " + WebViewFactory.safariUserAgentSuffix
    }
}

/// Validates every redirect against @connect.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    let follow: Bool
    let check: (URL) async -> Bool

    init(follow: Bool, check: @escaping (URL) async -> Bool) {
        self.follow = follow
        self.check = check
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard follow, let url = request.url else { completionHandler(nil); return }
        Task {
            let allowed = await check(url)
            completionHandler(allowed ? request : nil)
        }
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
