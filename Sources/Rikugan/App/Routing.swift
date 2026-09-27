import Foundation
import SwiftUI

/// Sheets / pages that can be shown in a browser window. Internal URLs such as
/// `rikugan://extensions` and `chrome://extensions` map onto these (spec §18).
enum BrowserSheet: Identifiable, Equatable {
    case settings, extensions, userscripts, bookmarks, history, downloads, adblock, tabs, media, images, reader, console,
         siteSettings, qrScanner, qrCode(String), pageTools, translate, profiles, selfTest
    var id: String {
        switch self {
        case .qrCode(let s): return "qr:" + s
        default: return String(describing: self)
        }
    }
}

@MainActor enum InternalPages {
    static func sheet(for page: String) -> BrowserSheet? {
        switch page.lowercased() {
        case "extensions", "extension": return .extensions
        case "userscripts", "scripts": return .userscripts
        case "settings", "preferences": return .settings
        case "bookmarks": return .bookmarks
        case "history": return .history
        case "downloads": return .downloads
        case "adblock", "content-blocking": return .adblock
        case "selftest": return .selftest
        case "profiles": return .profiles
        default: return nil
        }
    }

    static func open(_ page: String, from tab: BrowserTab) {
        guard let sheet = sheet(for: page) else {
            ToastCenter.shared.show("未知的内部页面：\(page)", symbol: "questionmark.circle")
            return
        }
        NotificationCenter.default.post(name: .rikuganOpenSheet, object: tab.manager, userInfo: ["sheet": sheet])
    }
}

extension BrowserSheet {
    static let selftest = BrowserSheet.selfTest
}

extension Notification.Name {
    static let rikuganOpenSheet = Notification.Name("rikugan.openSheet")
}
