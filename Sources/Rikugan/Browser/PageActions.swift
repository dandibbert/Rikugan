import Foundation
import UIKit
import WebKit
import SwiftUI

/// Page-level actions used by menus, toolbars and quick actions (spec §30).
@MainActor enum PageActions {
    /// Shows Rikugan's find bar (in place of the address bar); see FindBarContent.
    static func findInPage(_ tab: BrowserTab?) {
        guard let tab, !tab.isHome, tab.webView != nil else { return }
        tab.findActive = true
    }

    /// Puts the page back at its normal scale. If pinch-zoom cannot go back below the current
    /// scale (WebKit's minimum is stuck above the page's natural scale, and a reload restores the
    /// stored scale), the page is loaded afresh, which recomputes the scale from its viewport.
    /// The toast shows the scales so a stuck case can be reported with numbers.
    static func resetZoom(_ tab: BrowserTab?) {
        guard let tab, let webView = tab.webView else { return }
        let scrollView = webView.scrollView
        let before = scrollView.zoomScale, minimum = scrollView.minimumZoomScale
        let summary = String(format: "缩放 %.2f×，最小 %.2f×，页面缩放 %.2f", before, minimum, webView.pageZoom)
        webView.pageZoom = 1
        if minimum > 1.01, let url = webView.url {
            webView.load(URLRequest(url: url))
            ToastCenter.shared.show("已重新载入以复位缩放（\(summary)）", symbol: "arrow.up.left.and.arrow.down.right", duration: 5)
        } else {
            scrollView.setZoomScale(minimum, animated: true)
            ToastCenter.shared.show("已复位缩放（\(summary)）", symbol: "arrow.up.left.and.arrow.down.right", duration: 5)
        }
    }

    static func share(_ tab: BrowserTab?) {
        guard let url = tab?.webView?.url ?? tab?.url else { return }
        Presenter.share([url], from: tab?.webView)
    }

    static func print(_ tab: BrowserTab?) {
        guard let webView = tab?.webView else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = tab?.title ?? "Rikugan"
        info.outputType = .general
        controller.printInfo = info
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true)
    }

    static func createPDF(_ tab: BrowserTab?) {
        guard let tab, let webView = tab.webView else { return }
        let configuration = WKPDFConfiguration()
        webView.createPDF(configuration: configuration) { result in
            Task { @MainActor in
                switch result {
                case .success(let data):
                    let name = AppPaths.sanitize(tab.title.isEmpty ? "page" : tab.title) + ".pdf"
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    try? data.write(to: file)
                    Presenter.share([file], from: webView)
                case .failure(let error):
                    ToastCenter.shared.show("生成 PDF 失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    static func addBookmark(_ tab: BrowserTab?, favorites: Bool = false) {
        guard let tab, let url = tab.webView?.url ?? tab.url else { return }
        tab.profile.bookmarks.add(title: tab.title, url: url.absoluteString, parent: favorites ? BookmarkNode.favoritesID : nil)
        ToastCenter.shared.show(favorites ? "已添加到个人收藏" : "已添加书签", symbol: "book")
    }

    static func elementPicker(_ tab: BrowserTab?) {
        guard let webView = tab?.webView else { return }
        Task { _ = await webView.rkTools("startPicker") }
    }

    static func videoAction(_ tab: BrowserTab?, _ action: String) {
        guard let webView = tab?.webView else { return }
        Task {
            let result = await webView.rkTools("videoAction", [action]) as? String
            if result == "no-video" { ToastCenter.shared.show("此页面没有视频", symbol: "video.slash") }
            else if let result, result != "ok" { ToastCenter.shared.show(result, symbol: "exclamationmark.triangle") }
        }
    }

    static func toggleSiteAdBlock(_ tab: BrowserTab?) {
        guard let host = tab?.host else { return }
        let engine = AppServices.shared.adBlock
        engine.setAllowlisted(host, !engine.isAllowlisted(host))
        ToastCenter.shared.show(engine.isAllowlisted(host) ? "已在 \(host) 停用广告拦截" : "已在 \(host) 启用广告拦截", symbol: "shield")
        tab?.markInjected(for: URL(string: "about:invalid")!)
        tab?.reload()
    }

    static func cycleDarkMode(_ tab: BrowserTab?) {
        guard let tab else { return }
        var current = tab.profile.siteSettings.settings(for: tab.host).darkMode ?? AppServices.shared.prefs.pageDarkMode
        // "Automatic" follows the system appearance: toggle relative to what the page shows now.
        if current == .auto { current = UITraitCollection.current.userInterfaceStyle == .dark ? .on : .off }
        let next: TriState = current == .on ? .off : .on
        tab.setPageDarkMode(next)
        ToastCenter.shared.show(next == .on ? "网页深色模式：开" : "网页深色模式：关", symbol: "moon")
    }

    static func translate(_ tab: BrowserTab?) {
        guard let tab else { return }
        switch tab.translation {
        case .translated: TranslationCoordinator.toggleOriginal(tab)
        case .translating: break
        default: TranslationCoordinator.translate(tab)
        }
    }
}
