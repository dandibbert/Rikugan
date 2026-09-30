import Foundation
import WebKit
import UIKit
import CoreLocation
import UserNotifications

/// Central JS ↔ Swift bridge (WKScriptMessageHandlerWithReply). Every injected runtime posts
/// `{ch, ...}` to the "rikugan" handler; the channel is validated against the content world the
/// message came from so page scripts cannot reach privileged userscript / extension APIs.
@MainActor final class ScriptBridge: NSObject, WKScriptMessageHandlerWithReply {
    unowned let profile: ProfileContext

    init(profile: ProfileContext) { self.profile = profile }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let channel = body["ch"] as? String else {
            replyHandler(nil, "Invalid message"); return
        }
        let worldName = message.world.name ?? ""
        Task { @MainActor in
            do {
                let result: Any?
                switch channel {
                case "gm":
                    result = try await profile.userscripts.gm.handle(body, message: message, worldName: worldName)
                case "chrome":
                    result = try await profile.extensions.bridge.handle(body, message: message, worldName: worldName)
                case "tools":
                    guard worldName == Worlds.tools.name else {
                        SecurityLog.shared.record("tools channel rejected from world '\(worldName)'")
                        throw RikuganError("tools channel is only available to the tools world")
                    }
                    result = try await ToolsChannel.handle(body, message: message, profile: profile)
                case "page":
                    result = try await PageChannel.handle(body, message: message, profile: profile)
                default:
                    throw RikuganError("Unknown channel \(channel)")
                }
                replyHandler(Self.sanitize(result), nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    /// Replies must be property-list / JSON compatible.
    static func sanitize(_ value: Any?) -> Any? {
        guard let value else { return nil }
        switch value {
        case is NSNull, is String, is NSNumber, is Bool, is Int, is Double: return value
        case let array as [Any?]: return array.map { sanitize($0) ?? NSNull() }
        case let dict as [String: Any?]: return dict.mapValues { sanitize($0) ?? NSNull() }
        case let date as Date: return date.timeIntervalSince1970 * 1000
        case let url as URL: return url.absoluteString
        case let data as Data: return data.base64EncodedString()
        default: return String(describing: value)
        }
    }
}

extension WKScriptMessage {
    var tab: BrowserTab? { TabRegistry.shared.tab(for: webView) }
}

// MARK: - Tools world (privileged page tools)

@MainActor enum ToolsChannel {
    static func handle(_ body: [String: Any], message: WKScriptMessage, profile: ProfileContext) async throws -> Any? {
        let op = body["op"] as? String ?? ""
        let args = body["args"] as? [String: Any] ?? [:]
        let tab = message.tab
        switch op {
        case "lifecycle":
            if let tab, let url = tab.webView?.url, message.frameInfo.isMainFrame {
                profile.extensions.webNavigation(.domContentLoaded, tab: tab, url: url, frameID: 0)
            }
            return nil
        case "frame":
            tab?.registerFrame(message.frameInfo, token: args["token"] as? String)
            return nil
        case "frameGone":
            if let token = args["token"] as? String { tab?.unregisterFrame(token: token) }
            return nil
        case "pickerDone":
            if let selector = args["selector"] as? String, let host = args["host"] as? String, !selector.isEmpty {
                AppServices.shared.adBlock.addCustomRule("\(host)##\(selector)")
                ToastCenter.shared.show("已隐藏元素，规则已保存到 自定义规则", symbol: "eye.slash")
            }
            return nil
        case "translateMore":
            if let tab, let batches = args["batches"] as? [[[String: Any]]] {
                TranslationCoordinator.translateAdditional(batches, tab: tab)
            }
            return nil
        case "fontData":
            guard let id = args["id"] as? String, let font = AppServices.shared.fonts.imported.first(where: { $0.id == id }),
                  let data = try? Data(contentsOf: font.fileURL) else { return nil }
            return ["base64": data.base64EncodedString(), "mime": MIME.type(forExtension: font.fileURL.pathExtension)]
        case "credentialCaptured":
            guard let tab, !tab.isPrivate, AppServices.shared.prefs.autofillEnabled,
                  let password = args["password"] as? String, !password.isEmpty else { return nil }
            let username = args["username"] as? String ?? ""
            let host = message.frameInfo.securityOrigin.host
            AutofillCoordinator.offerToSave(username: username, password: password, host: host, tab: tab)
            return nil
        default:
            throw RikuganError("Unknown tools op \(op)")
        }
    }
}

// MARK: - Page world (unprivileged hooks)

@MainActor enum PageChannel {
    static let locationProvider = LocationProvider()

    static func handle(_ body: [String: Any], message: WKScriptMessage, profile: ProfileContext) async throws -> Any? {
        let op = body["op"] as? String ?? ""
        let args = body["args"] as? [String: Any] ?? [:]
        guard let tab = message.tab else { return nil }
        let host = message.frameInfo.securityOrigin.host
        switch op {
        case "mediaFound":
            guard let raw = args["url"] as? String, let url = URL(string: raw) else { return nil }
            let contentType = args["contentType"] as? String ?? ""
            var kind = "video"
            if contentType.hasPrefix("audio/") || ["mp3", "m4a", "aac", "ogg", "oga", "opus", "flac", "wav"].contains(url.pathExtension.lowercased()) { kind = "audio" }
            if url.pathExtension.lowercased() == "m3u8" || contentType.contains("mpegurl") { kind = "hls" }
            if url.pathExtension.lowercased() == "mpd" { kind = "dash" }
            tab.addSniffedMedia(MediaItem(url: url, kind: kind, source: args["via"] as? String ?? "network", contentType: contentType))
            return nil
        case "historyStateUpdated":
            // This channel is reachable by page JavaScript. pushState cannot change the origin, so a
            // URL from another origin is forged (it would plant history / webNavigation entries).
            let origin = message.frameInfo.securityOrigin
            if let raw = args["url"] as? String, let url = URL(string: raw), message.frameInfo.isMainFrame,
               url.scheme?.lowercased() == origin.protocol.lowercased(), url.host?.lowercased() == origin.host.lowercased(),
               (url.port ?? 0) == origin.port || (url.port == nil && origin.port == 0) {
                profile.extensions.webNavigation(.historyStateUpdated, tab: tab, url: url, frameID: 0)
                if !tab.isPrivate { profile.history.record(url: url, title: tab.webView?.title ?? "") }
            } else if args["url"] != nil {
                SecurityLog.shared.record("page channel: cross-origin historyStateUpdated rejected (\(origin.host))")
            }
            return nil
        case "console":
            tab.appendConsole(level: args["level"] as? String ?? "log", text: args["text"] as? String ?? "")
            return nil
        case "geolocation":
            let decision = await sitePermission("location", title: "“\(host)” 想要使用你的当前位置", host: host, tab: tab, profile: profile)
            guard decision else { return ["error": true, "code": 1, "message": "User denied Geolocation"] }
            do {
                let location = try await locationProvider.current(highAccuracy: args["highAccuracy"] as? Bool ?? false)
                var position: [String: Any] = [:]
                position["latitude"] = location.coordinate.latitude
                position["longitude"] = location.coordinate.longitude
                position["accuracy"] = location.horizontalAccuracy
                position["altitude"] = location.altitude
                position["altitudeAccuracy"] = location.verticalAccuracy
                position["heading"] = location.course >= 0 ? location.course as Any : NSNull()
                position["speed"] = location.speed >= 0 ? location.speed as Any : NSNull()
                position["timestamp"] = location.timestamp.timeIntervalSince1970 * 1000.0
                return position
            } catch {
                return ["error": true, "code": 2, "message": error.localizedDescription]
            }
        case "notificationPermission":
            let allowed = await sitePermission("notifications", title: "“\(host)” 想要向你发送通知", host: host, tab: tab, profile: profile)
            guard allowed else { return "denied" }
            // The site answer alone is not enough: without system authorization nothing is shown.
            let system = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            return system ? "granted" : "denied"
        case "notify":
            guard currentPermission("notifications", host: host, tab: tab, profile: profile) == true else { return "denied" }
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional || status == .ephemeral else { return "denied" }
            let content = UNMutableNotificationContent()
            content.title = args["title"] as? String ?? host
            content.body = args["body"] as? String ?? ""
            content.subtitle = host
            content.userInfo = ["url": tab.webView?.url?.absoluteString ?? ""]
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            ToastCenter.shared.show("\(content.title)：\(content.body)", symbol: "bell")
            return "shown"
        case "clipboardRead":
            // Decided for the frame that asks (its own origin), not the top-level page. Ask / unset
            // leaves the decision to the system paste prompt.
            return currentPermission("clipboard", host: host, tab: tab, profile: profile) != false
        default:
            throw RikuganError("Unknown page op \(op)")
        }
    }

    /// Stored or session decision, nil when the user has not decided (Ask).
    static func currentPermission(_ key: String, host: String, tab: BrowserTab, profile: ProfileContext) -> Bool? {
        if let session = tab.sessionPermission(key, host: host) { return session }
        switch profile.siteSettings.settings(for: host).permissions[key] {
        case .allow?: return true
        case .block?: return false
        default: return nil
        }
    }

    /// Ask / Allow / Block per domain (spec §48). "Allow once" and every answer in a private tab
    /// are kept for the tab only (never written to site settings).
    static func sitePermission(_ key: String, title: String, host: String, tab: BrowserTab, profile: ProfileContext) async -> Bool {
        if let decided = currentPermission(key, host: host, tab: tab, profile: profile) { return decided }
        guard let answer = await Presenter.permission(title: title, message: nil, from: tab.webView) else { return false }
        let allowed = answer != .block
        if answer == .ask || tab.isPrivate {
            tab.setSessionPermission(key, host: host, allowed)
        } else {
            profile.siteSettings.update(host) { $0.permissions[key] = answer }
        }
        return allowed
    }
}

/// One-shot CoreLocation requests for the geolocation shim.
@MainActor final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    func current(highAccuracy: Bool) async throws -> CLLocation {
        manager.desiredAccuracy = highAccuracy ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: finish(.failure(RikuganError("系统定位权限未开启")))
            default: manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard !self.waiters.isEmpty else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
            case .denied, .restricted: self.finish(.failure(RikuganError("系统定位权限未开启")))
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }
}
