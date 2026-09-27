import Foundation
import UIKit
import WebKit
import SwiftUI

/// Page-level actions used by menus, toolbars and quick actions (spec §30).
@MainActor enum PageActions {
    static func findInPage(_ tab: BrowserTab?) {
        guard let webView = tab?.webView else { return }
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
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
        let current = tab.profile.siteSettings.settings(for: tab.host).darkMode ?? AppServices.shared.prefs.pageDarkMode
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
