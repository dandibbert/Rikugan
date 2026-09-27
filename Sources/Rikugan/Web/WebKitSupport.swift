import Foundation
import WebKit
import UIKit

/// Bundled JavaScript resources.
enum JSResource {
    private static var cache: [String: String] = [:]

    static func load(_ name: String) -> String {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Missing JS resource \(name)")
            return ""
        }
        cache[name] = text
        return text
    }

    /// Replaces a `/*__MARKER__*/null` placeholder with a JSON config.
    static func fill(_ name: String, marker: String, config: Any) -> String {
        load(name).replacingOccurrences(of: "/*\(marker)*/null", with: JSONText.encode(config))
    }
}

enum Worlds {
    static let tools = WKContentWorld.world(name: "rikugan-tools")
    static func userscript(_ id: UUID) -> WKContentWorld { .world(name: "us-" + id.uuidString) }
    static func extensionWorld(_ id: String) -> WKContentWorld { .world(name: "ext-" + id) }
    static let messageHandlerName = "rikugan"
}

extension WKWebView {
    /// Runs an async function body (`return ...`) and awaits its (promise) result.
    @discardableResult
    func rkCall(_ body: String, arguments: [String: Any] = [:], frame: WKFrameInfo? = nil,
                world: WKContentWorld = .page) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            callAsyncJavaScript(body, arguments: arguments, in: frame, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value is NSNull ? nil : value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fire-and-forget evaluation.
    func rkEval(_ script: String, frame: WKFrameInfo? = nil, world: WKContentWorld = .page) {
        evaluateJavaScript(script, in: frame, in: world) { _ in }
    }

    /// Calls `window.__rikuganTools.<name>(...args)` in the tools world.
    func rkTools(_ name: String, _ args: [Any] = [], frame: WKFrameInfo? = nil) async -> Any? {
        let body = "const t = window.__rikuganTools; if (!t) return null; const r = await t[\(name.jsLiteral)](...args); return r === undefined ? null : r;"
        return try? await rkCall(body, arguments: ["args": args], frame: frame, world: Worlds.tools)
    }
}

extension WKFrameInfo {
    var rkURL: URL? { request.url }
}

/// MIME type lookup for extension resources and downloads.
enum MIME {
    static func type(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "txt": return "text/plain"
        case "xml": return "application/xml"
        case "wasm": return "application/wasm"
        case "mp3": return "audio/mpeg"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Presentation helpers

@MainActor enum Presenter {
    static var keyWindow: UIWindow? {
        let scenes: [UIWindowScene] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active: [UIWindowScene] = scenes.filter { $0.activationState == .foregroundActive }
        let ordered: [UIWindowScene] = active + scenes.filter { $0.activationState != .foregroundActive }
        let windows: [UIWindow] = ordered.flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    static func topController(from view: UIView? = nil) -> UIViewController? {
        var controller = (view?.window ?? keyWindow)?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed { controller = presented }
        return controller
    }

    static func present(_ controller: UIViewController, from view: UIView? = nil) {
        guard let top = topController(from: view) else { return }
        if let pop = controller.popoverPresentationController, pop.sourceView == nil {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 60, width: 1, height: 1)
        }
        top.present(controller, animated: true)
    }

    static func alert(title: String?, message: String?, from view: UIView? = nil, actions: [UIAlertAction]) {
        let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
        actions.forEach(controller.addAction)
        present(controller, from: view)
    }

    static func confirm(title: String, message: String?, confirm: String = "允许", cancel: String = "取消",
                        destructive: Bool = false, from view: UIView? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = OnceFlag()
            let finish: (Bool) -> Void = { value in if once.fire() { continuation.resume(returning: value) } }
            let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: cancel, style: .cancel) { _ in finish(false) })
            controller.addAction(UIAlertAction(title: confirm, style: destructive ? .destructive : .default) { _ in finish(true) })
            guard let top = topController(from: view) else { finish(false); return }
            top.present(controller, animated: true)
        }
    }

    /// Three-way permission prompt: allow once / always / deny.
    static func permission(title: String, message: String?, from view: UIView? = nil) async -> PermissionDecision? {
        await withCheckedContinuation { continuation in
            let once = OnceFlag()
            let finish: (PermissionDecision?) -> Void = { value in if once.fire() { continuation.resume(returning: value) } }
            let controller = UIAlertController(title: title, message: message, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: "允许", style: .default) { _ in finish(.allow) })
            controller.addAction(UIAlertAction(title: "仅本次允许", style: .default) { _ in finish(.ask) })
            controller.addAction(UIAlertAction(title: "拒绝", style: .cancel) { _ in finish(.block) })
            guard let top = topController(from: view) else { finish(nil); return }
            top.present(controller, animated: true)
        }
    }

    static func share(_ items: [Any], from view: UIView? = nil) {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        present(controller, from: view)
    }
}

/// Lightweight toast / banner messages.
@MainActor final class ToastCenter: ObservableObject {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let symbol: String
        var actionTitle: String?
        var action: (() -> Void)?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }
    static let shared = ToastCenter()
    @Published var current: Toast?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, symbol: String = "info.circle", actionTitle: String? = nil, duration: Double = 2.6, action: (() -> Void)? = nil) {
        current = Toast(text: text, symbol: symbol, actionTitle: actionTitle, action: action)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled { self?.current = nil }
        }
    }
}
