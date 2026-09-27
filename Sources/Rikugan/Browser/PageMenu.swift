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
        Menu {
            Section {
                Button { manager.newTab() } label: { Label("新标签页", systemImage: "plus.square.on.square") }
                Button { manager.newTab(isPrivate: true) } label: { Label("无痕标签页", systemImage: "hand.raised") }
                if tab.isLoading {
                    Button { tab.stop() } label: { Label("停止", systemImage: "xmark") }
                } else {
                    Button { tab.reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                }
            }
            if !tab.isHome {
                Section {
                    Button { tab.toggleDesktopMode() } label: {
                        Label(tab.desktopMode ? "请求移动版网站" : "请求桌面版网站", systemImage: tab.desktopMode ? "iphone" : "desktopcomputer")
                    }
                    Button { PageActions.findInPage(tab) } label: { Label("页内查找", systemImage: "doc.text.magnifyingglass") }
                    Button { PageActions.translate(tab) } label: { Label(translateTitle, systemImage: "character.bubble") }
                    Button { sheet = .reader } label: { Label("阅读模式", systemImage: "doc.plaintext") }
                    Menu {
                        Picker("本网站", selection: Binding(get: { siteDark ?? .auto }, set: { tab.setPageDarkMode($0 == .auto ? nil : $0) })) {
                            Text("跟随全局设置").tag(TriState.auto)
                            Text("开").tag(TriState.on)
                            Text("关").tag(TriState.off)
                        }
                        Picker("全局", selection: Binding(get: { services.prefs.pageDarkMode }, set: { services.prefs.pageDarkMode = $0 })) {
                            Text("自动（跟随系统）").tag(TriState.auto)
                            Text("开").tag(TriState.on)
                            Text("关").tag(TriState.off)
                        }
                    } label: { Label("网页深色模式", systemImage: "moon") }
                    Menu {
                        ForEach([0, 5, 10, 30, 60, 300], id: \.self) { seconds in
                            Button {
                                tab.autoRefreshInterval = seconds == 0 ? nil : TimeInterval(seconds)
                            } label: {
                                if Int(tab.autoRefreshInterval ?? 0) == seconds { Label(refreshTitle(seconds), systemImage: "checkmark") }
                                else { Text(refreshTitle(seconds)) }
                            }
                        }
                        Button("自定义…") { askCustomRefresh() }
                    } label: { Label(tab.autoRefreshInterval == nil ? "定时刷新" : "定时刷新（\(Int(tab.autoRefreshInterval ?? 0)) 秒）", systemImage: "timer") }
                }
            }
            Section {
                Menu {
                    if tab.menuCommands.isEmpty {
                        Text("此页面没有脚本命令")
                    } else {
                        ForEach(tab.menuCommands) { command in
                            Button("\(command.title)  ·  \(command.scriptName)") { tab.runMenuCommand(command) }
                        }
                    }
                    Divider()
                    Button { sheet = .userscripts } label: { Label("管理用户脚本", systemImage: "gearshape") }
                } label: { Label("用户脚本" + (tab.injectedScripts.isEmpty ? "" : "（\(tab.injectedScripts.count) 个运行中）"), systemImage: "curlybraces") }
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
                    Button { sheet = .extensions } label: { Label("管理扩展", systemImage: "gearshape") }
                } label: { Label("扩展", systemImage: "puzzlepiece.extension") }
                Menu {
                    if let host = tab.host {
                        Button { PageActions.toggleSiteAdBlock(tab) } label: {
                            Label(adBlock.isAllowlisted(host) ? "在此网站启用拦截" : "在此网站停用拦截", systemImage: "shield.slash")
                        }
                    }
                    Button { PageActions.elementPicker(tab) } label: { Label("隐藏网页元素", systemImage: "eye.slash") }
                    Button { sheet = .adblock } label: { Label("内容拦截设置", systemImage: "gearshape") }
                } label: { Label("广告拦截", systemImage: "shield.lefthalf.filled") }
            }
            Section {
                Button { sheet = .media } label: { Label("媒体资源" + (tab.sniffedMedia.isEmpty ? "" : "（\(tab.sniffedMedia.count)）"), systemImage: "play.rectangle.on.rectangle") }
                Button { sheet = .images } label: { Label("查看图片", systemImage: "photo.on.rectangle") }
                Menu {
                    Button { PageActions.videoAction(tab, "pip") } label: { Label("画中画", systemImage: "pip.enter") }
                    Button { PageActions.videoAction(tab, "fullscreen") } label: { Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Button { PageActions.videoAction(tab, "play") } label: { Label("播放 / 暂停", systemImage: "playpause") }
                } label: { Label("视频", systemImage: "video") }
                Button { sheet = .downloads } label: { Label("下载", systemImage: "arrow.down.circle") }
            }
            Section {
                Button { PageActions.share(tab) } label: { Label("分享", systemImage: "square.and.arrow.up") }
                Button { PageActions.addBookmark(tab) } label: { Label("添加书签", systemImage: "book") }
                Button { PageActions.addBookmark(tab, favorites: true) } label: { Label("添加到个人收藏", systemImage: "star") }
                Button { PageActions.print(tab) } label: { Label("打印", systemImage: "printer") }
                Button { PageActions.createPDF(tab) } label: { Label("创建 PDF", systemImage: "doc.richtext") }
                Menu {
                    if let url = tab.url { Button { sheet = .qrCode(url.absoluteString) } label: { Label("当前网址二维码", systemImage: "qrcode") } }
                    Button { sheet = .qrScanner } label: { Label("扫描二维码", systemImage: "qrcode.viewfinder") }
                } label: { Label("二维码", systemImage: "qrcode") }
            }
            Section {
                Menu {
                    Button { AutofillCoordinator.fillLogin(tab) } label: { Label("填充密码", systemImage: "key") }
                    Button { AutofillCoordinator.fillProfile(tab) } label: { Label("填充个人信息", systemImage: "person.text.rectangle") }
                    ForEach(autofill.cards) { card in
                        Button { AutofillCoordinator.fillCard(tab, card: card) } label: { Label("填充 \(card.nickname.isEmpty ? card.masked : card.nickname)", systemImage: "creditcard") }
                    }
                } label: { Label("自动填充", systemImage: "rectangle.and.pencil.and.ellipsis") }
                Button { sheet = .siteSettings } label: { Label("网站设置", systemImage: "slider.horizontal.3") }
                Button { sheet = .console } label: { Label("网页检查器", systemImage: "ladybug") }
                Button { sheet = .bookmarks } label: { Label("书签与历史", systemImage: "clock") }
                Button { sheet = .settings } label: { Label("设置", systemImage: "gearshape") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("pageMenu")
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

