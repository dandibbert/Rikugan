import SwiftUI
import WebKit

/// Page menu (spec §30) with page tools, userscript commands, extensions, AdBlock, media and sharing.
struct PageMenuButton: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var manager: TabManager
    @EnvironmentObject private var runtime: ExtensionRuntime
    @EnvironmentObject private var adBlock: AdBlockEngine
    @EnvironmentObject private var autofill: AutofillStore
    @Binding var sheet: BrowserSheet?
    @Binding var importKind: BrowserView.ImportKind?

    private var siteDark: TriState? { tab.profile.siteSettings.settings(for: tab.host).darkMode }

    var body: some View {
        // Short top level; page tools, add-ons, media / files and settings each live in their own
        // submenu so the common actions are one tap away.
        Menu {
            Section {
                Button { manager.newTab() } label: { Label("新标签页", icon: "plus.square.on.square") }
                Button { manager.newTab(isPrivate: true) } label: { Label("无痕标签页", icon: "hand.raised") }
                if !tab.isHome {
                    Button { PageActions.share(tab) } label: { Label("分享", icon: "square.and.arrow.up") }
                    Button { PageActions.addBookmark(tab) } label: { Label("添加书签", icon: "book") }
                }
            }
            if !tab.isHome {
                Section {
                    Menu { pageTools } label: { Label("网页工具", icon: "wrench.and.screwdriver") }
                    Menu { addOns } label: {
                        Label("脚本 / 扩展 / 拦截" + (tab.injectedScripts.isEmpty ? "" : "（\(tab.injectedScripts.count) 个脚本运行中）"), icon: "puzzlepiece.extension")
                    }
                    Menu { mediaAndFiles } label: {
                        Label("媒体与文件" + (tab.sniffedMedia.isEmpty ? "" : "（\(tab.sniffedMedia.count)）"), icon: "play.rectangle.on.rectangle")
                    }
                }
            }
            Section {
                Button { sheet = .bookmarks } label: { Label("书签与历史", icon: "clock") }
                Button { sheet = .downloads } label: { Label("下载", icon: "arrow.down.circle") }
                if !tab.isHome { Button { sheet = .siteSettings } label: { Label("网站设置", icon: "slider.horizontal.3") } }
                Button { sheet = .settings } label: { Label("设置", icon: "gearshape") }
            }
        } label: {
            Image(icon: "ellipsis.circle")
        }
        .accessibilityIdentifier("pageMenu")
    }

    // MARK: Submenus

    @ViewBuilder private var pageTools: some View {
        Section {
            Button { PageActions.findInPage(tab) } label: { Label("页内查找", icon: "doc.text.magnifyingglass") }
            Button { PageActions.translate(tab) } label: { Label(translateTitle, icon: "character.bubble") }
            Button { sheet = .reader } label: { Label("阅读模式", icon: "doc.plaintext") }
            Menu {
                Picker("本网站", selection: Binding(get: { siteDark ?? .auto }, set: { tab.setPageDarkMode($0 == .auto ? nil : $0) })) {
                    Text("跟随全局设置").tag(TriState.auto)
                    Text("本网站始终开启").tag(TriState.on)
                    Text("本网站始终关闭").tag(TriState.off)
                }
            } label: { Label("网页深色模式：" + darkModeSummary, icon: "moon") }
            Button { tab.toggleDesktopMode() } label: {
                Label(tab.desktopMode ? "请求移动版网站" : "请求桌面版网站", icon: tab.desktopMode ? "iphone" : "desktopcomputer")
            }
            Button { PageActions.resetZoom(tab) } label: { Label("复位页面缩放", icon: "arrow.up.left.and.arrow.down.right") }
        }
        Section {
            Menu {
                ForEach([0, 5, 10, 30, 60, 300], id: \.self) { seconds in
                    Button {
                        tab.autoRefreshInterval = seconds == 0 ? nil : TimeInterval(seconds)
                    } label: {
                        if Int(tab.autoRefreshInterval ?? 0) == seconds { Label(refreshTitle(seconds), icon: "checkmark") }
                        else { Text(refreshTitle(seconds)) }
                    }
                }
                Button("自定义…") { askCustomRefresh() }
            } label: { Label(tab.autoRefreshInterval == nil ? "定时刷新" : "定时刷新（\(Int(tab.autoRefreshInterval ?? 0)) 秒）", icon: "timer") }
            Menu {
                Button { AutofillCoordinator.fillLogin(tab) } label: { Label("填充密码", icon: "key") }
                Button { AutofillCoordinator.fillProfile(tab) } label: { Label("填充个人信息", icon: "person.text.rectangle") }
                ForEach(autofill.cards) { card in
                    Button { AutofillCoordinator.fillCard(tab, card: card) } label: { Label("填充 \(card.nickname.isEmpty ? card.masked : card.nickname)", icon: "creditcard") }
                }
            } label: { Label("自动填充", icon: "rectangle.and.pencil.and.ellipsis") }
            Button { PageActions.print(tab) } label: { Label("打印", icon: "printer") }
            Button { PageActions.createPDF(tab) } label: { Label("创建 PDF", icon: "doc.richtext") }
            Menu {
                if let url = tab.url { Button { sheet = .qrCode(url.absoluteString) } label: { Label("当前网址二维码", icon: "qrcode") } }
                Button { sheet = .qrScanner } label: { Label("扫描二维码", icon: "qrcode.viewfinder") }
            } label: { Label("二维码", icon: "qrcode") }
            Button { PageActions.addBookmark(tab, favorites: true) } label: { Label("添加到个人收藏", icon: "star") }
            Button { sheet = .console } label: { Label("网页检查器", icon: "ladybug") }
        }
    }

    @ViewBuilder private var addOns: some View {
        Menu {
            if tab.menuCommands.isEmpty {
                Text("此页面没有脚本命令")
            } else {
                ForEach(tab.menuCommands) { command in
                    Button("\(command.title)  ·  \(command.scriptName)") { tab.runMenuCommand(command) }
                }
            }
            Divider()
            Button { sheet = .userscripts } label: { Label("管理用户脚本", icon: "gearshape") }
        } label: { Label("用户脚本" + (tab.injectedScripts.isEmpty ? "" : "（\(tab.injectedScripts.count) 个运行中）"), icon: "curlybraces") }
        Menu {
            ForEach(runtime.toolbarExtensions) { ext in
                Button { runtime.performAction(ext, tab: tab) } label: { Label(ext.displayName, uiImage: ext.actionState(for: tab.numericID).icon ?? ext.icon) }
            }
            let entries = runtime.contextMenuEntries(for: ["page", "all", "frame"], tab: tab, linkURL: nil)
            if !entries.isEmpty {
                Divider()
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    Button { entry.run() } label: { Label(entry.title, uiImage: entry.image) }.disabled(!entry.enabled)
                }
            }
            Divider()
            Button { sheet = .extensions } label: { Label("管理扩展", icon: "gearshape") }
        } label: { Label("扩展", icon: "puzzlepiece.extension") }
        Menu {
            if let host = tab.host {
                Button { PageActions.toggleSiteAdBlock(tab) } label: {
                    Label(adBlock.isAllowlisted(host) ? "在此网站启用拦截" : "在此网站停用拦截", icon: "shield.slash")
                }
            }
            Button { PageActions.elementPicker(tab) } label: { Label("隐藏网页元素", icon: "eye.slash") }
            Button { sheet = .adblock } label: { Label("内容拦截设置", icon: "gearshape") }
        } label: { Label("广告拦截", icon: "shield.lefthalf.filled") }
    }

    @ViewBuilder private var mediaAndFiles: some View {
        Button { sheet = .media } label: { Label("媒体资源" + (tab.sniffedMedia.isEmpty ? "" : "（\(tab.sniffedMedia.count)）"), icon: "play.rectangle.on.rectangle") }
        Button { sheet = .images } label: { Label("查看图片", icon: "photo.on.rectangle") }
        Menu {
            Button { PageActions.videoAction(tab, "pip") } label: { Label("画中画", icon: "pip.enter") }
            Button { PageActions.videoAction(tab, "fullscreen") } label: { Label("全屏", icon: "arrow.up.left.and.arrow.down.right") }
            Button { PageActions.videoAction(tab, "play") } label: { Label("播放 / 暂停", icon: "playpause") }
        } label: { Label("视频", icon: "video") }
    }

    private var darkModeSummary: String {
        switch siteDark {
        case .on?: return "本网站开"
        case .off?: return "本网站关"
        default:
            switch services.prefs.pageDarkMode {
            case .on: return "全局开"
            case .off: return "全局关"
            case .auto: return "跟随系统"
            }
        }
    }

    private var translateTitle: String {
        switch tab.translation {
        case .translated(let original): return original ? "显示译文" : "显示原文"
        case .translating: return "正在翻译…"
        default: return "翻译网页"
        }
    }

    private func refreshTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "关闭"
        case 60: return "1 分钟"
        case 300: return "5 分钟"
        default: return "\(seconds) 秒"
        }
    }

    private func askCustomRefresh() {
        let alert = UIAlertController(title: "定时刷新", message: "刷新间隔（秒）。仅在应用处于前台时生效。", preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad; $0.placeholder = "例如 15" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "开始", style: .default) { _ in
            if let value = Double(alert.textFields?.first?.text ?? ""), value >= 1 { tab.autoRefreshInterval = value }
        })
        Presenter.present(alert, from: tab.webView)
    }
}

