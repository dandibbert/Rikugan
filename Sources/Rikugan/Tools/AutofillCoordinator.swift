import Foundation
import UIKit
import WebKit

/// Autofill flows (spec §40). Secrets live in the Keychain via AutofillStore and are revealed
/// only after device-owner authentication.
@MainActor enum AutofillCoordinator {
    static var store: AutofillStore { AppServices.shared.autofill }

    static func offerToSave(username: String, password: String, host: String, tab: BrowserTab) {
        if store.credentials(for: host).contains(where: { $0.username == username && $0.password == password }) { return }
        let neverKey = "rikugan.autofill.never." + host
        if UserDefaults.standard.bool(forKey: neverKey) { return }
        let existing = store.credentials(for: host).first { $0.username == username }
        let alert = UIAlertController(title: existing == nil ? "保存密码？" : "更新密码？",
                                      message: "\(username.isEmpty ? "（无用户名）" : username) · \(host)\n密码将保存在本机钥匙串中。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "不保存此网站", style: .destructive) { _ in UserDefaults.standard.set(true, forKey: neverKey) })
        alert.addAction(UIAlertAction(title: "以后再说", style: .cancel))
        alert.addAction(UIAlertAction(title: existing == nil ? "保存" : "更新", style: .default) { _ in
            do {
                try store.save(SavedCredential(id: existing?.id ?? UUID(), host: host, username: username, password: password))
                ToastCenter.shared.show("密码已保存", symbol: "key")
            } catch {
                ToastCenter.shared.show("密码未保存：\(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        })
        Presenter.present(alert, from: tab.webView)
    }

    /// Scheme + host + port of the document a fill was requested for. Re-checked after every
    /// suspension point (Face ID, account choice): if the page navigated meanwhile, nothing is filled.
    private struct Origin: Equatable {
        let scheme: String, host: String, port: Int?
        init?(_ url: URL?) {
            guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
            self.scheme = scheme; self.host = host; port = url.port
        }
        /// Secrets are only filled into secure pages (or local development servers).
        var isSecure: Bool { scheme == "https" || host == "localhost" || host == "127.0.0.1" }
    }

    private static func stillOn(_ origin: Origin, _ webView: WKWebView) -> Bool {
        guard Origin(webView.url) == origin else {
            ToastCenter.shared.show("网页已跳转，已取消填充", symbol: "exclamationmark.triangle")
            return false
        }
        return true
    }

    static func fillLogin(_ tab: BrowserTab) {
        guard let webView = tab.webView, let origin = Origin(webView.url) else { return }
        guard origin.isSecure else { ToastCenter.shared.show("只在 HTTPS 网页中填充密码", symbol: "lock.slash"); return }
        let options = store.credentials(for: origin.host)
        guard !options.isEmpty else { ToastCenter.shared.show("没有 \(origin.host) 的已保存密码", symbol: "key"); return }
        Task {
            guard await Keychain.authenticate(reason: "填充 \(origin.host) 的密码"), stillOn(origin, webView) else { return }
            if options.count == 1 { await fill(options[0], webView: webView, origin: origin); return }
            let sheet = UIAlertController(title: "选择账户", message: origin.host, preferredStyle: .actionSheet)
            for credential in options {
                sheet.addAction(UIAlertAction(title: credential.username.isEmpty ? "（无用户名）" : credential.username, style: .default) { _ in
                    Task { await fill(credential, webView: webView, origin: origin) }
                })
            }
            sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
            Presenter.present(sheet, from: webView)
        }
    }

    private static func fill(_ credential: SavedCredential, webView: WKWebView, origin: Origin) async {
        guard stillOn(origin, webView) else { return }
        let ok = await webView.rkTools("fillLogin", [["username": credential.username, "password": credential.password]]) as? Bool ?? false
        if !ok { ToastCenter.shared.show("此页面没有找到登录表单", symbol: "exclamationmark.triangle") }
    }

    static func fillProfile(_ tab: BrowserTab) {
        guard let webView = tab.webView else { return }
        Task {
            let count = await webView.rkTools("fillForm", [store.profile.dictionary]) as? Int ?? 0
            ToastCenter.shared.show(count > 0 ? "已填充 \(count) 个字段" : "没有找到可填充的字段", symbol: "person.text.rectangle")
        }
    }

    static func fillCard(_ tab: BrowserTab, card: PaymentCard) {
        guard let webView = tab.webView, let origin = Origin(webView.url) else { return }
        guard origin.isSecure else { ToastCenter.shared.show("只在 HTTPS 网页中填充支付卡", symbol: "lock.slash"); return }
        Task {
            guard await Keychain.authenticate(reason: "填充支付卡"), stillOn(origin, webView) else { return }
            let count = await webView.rkTools("fillForm", [card.dictionary]) as? Int ?? 0
            ToastCenter.shared.show(count > 0 ? "已填充 \(count) 个字段" : "没有找到支付表单", symbol: "creditcard")
        }
    }
}

