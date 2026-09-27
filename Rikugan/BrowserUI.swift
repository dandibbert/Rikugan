import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if let session = model.session { BrowserShell(session: session).id(session.profileID) }
            else { ProgressView("正在打开 Rikugan") }
        }
        .tint(.indigo)
        .sheet(item: $model.scriptDraft, onDismiss: model.scriptEditorDidDismiss) { ScriptEditor(draft: $0) }
        .sheet(item: $model.preparedExtension) { ExtensionInstaller(prepared: $0) }
        .onChange(of: model.message) { _, value in
            guard let value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                BrowserPresentation.alert(title: "Rikugan", message: value) { if model.message == value { model.message = nil } }
            }
        }
        .overlay(alignment: .top) {
            if model.working { HStack(spacing: 10) { ProgressView(); Text("正在处理导入…").font(.subheadline) }.padding().background(.regularMaterial, in: Capsule()).padding(.top) }
        }
    }
}

enum BrowserPanel: String, Identifiable { case addons, profiles, tabs, library, settings, commands; var id: String { rawValue } }

struct BrowserShell: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var session: BrowserSession
    @State private var panel: BrowserPanel?
    var body: some View {
        Group {
            if sizeClass == .regular { iPad } else { phone }
        }
        .overlay { if !session.ready { ZStack { Color(uiColor: .systemBackground).opacity(0.93); ProgressView("正在载入身份与扩展…") } } }
        .onChange(of: session.requestedPanel) { _, value in
            guard let value else { return }
            panel = value == "settings" ? .settings : .addons
            session.requestedPanel = nil
        }
        .onChange(of: session.ready) { _, ready in if ready { model.applyPendingShare() } }
        .sheet(item: $panel) { item in
            switch item {
            case .addons: AddonsView(session: session)
            case .profiles: ProfilesView()
            case .tabs: TabsView(session: session)
            case .library: LibraryView(session: session)
            case .settings: SettingsView(session: session)
            case .commands: CommandsView(session: session)
            }
        }
    }
    private var phone: some View {
        Group { if let tab = session.activeTab { BrowserPage(tab: tab, session: session, openPanel: { panel = $0 }).id(tab.id) } else { ProgressView() } }
    }
    private var iPad: some View {
        NavigationSplitView {
            List {
                Section {
                    ForEach(session.profile.tabGroups) { group in
                        Text(group.name).font(.headline)
                        ForEach(session.tabs.filter { $0.groupID == group.id }) { row($0) }
                    }
                    Text("未分组").font(.headline)
                    ForEach(session.tabs.filter { $0.groupID == nil && !$0.isPrivate }) { row($0) }
                    if session.tabs.contains(where: \.isPrivate) {
                        Text("无痕").font(.headline)
                        ForEach(session.tabs.filter(\.isPrivate)) { row($0) }
                    }
                }
            }.navigationTitle("标签")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("新标签", systemImage: "plus") { session.addTab() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("新窗口", systemImage: "macwindow.badge.plus") { let tab = session.addTab(activate: false); openWindow(value: tab.id) } }
                }
        } detail: {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(session.tabs) { tab in
                            Button(tab.pageTitle) { session.select(tab) }
                                .font(.subheadline.weight(tab.id == session.selectedID ? .bold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(tab.id == session.selectedID ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                        }
                    }.padding(.horizontal, 8)
                }.frame(height: 40)
                phone
            }
        }
    }
    private func row(_ tab: BrowserTab) -> some View {
        Button { session.select(tab) } label: { HStack { Image(systemName: tab.isPrivate ? "eyeglasses" : "globe"); Text(tab.pageTitle).lineLimit(1) } }
    }
}

struct WebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tab: BrowserTab
    @ObservedObject var session: BrowserSession
    var openPanel: (BrowserPanel) -> Void
    @State private var input = ""
    @State private var showFind = false
    @State private var findText = ""
    @State private var findIndex = 0
    @State private var findTotal = 0
    @State private var suggestions: [OmniboxSuggestion] = []
    @State private var tool: ToolSheet?
    @FocusState private var addressFocused: Bool
    private var barOnTop: Bool { model.profile.settings.addressBar == "top" }

    var body: some View {
        VStack(spacing: 0) {
            if barOnTop { chrome }
            ZStack(alignment: .bottom) {
                ZStack {
                    if tab.isHome { HomeView(session: session, openPanel: openPanel) }
                    else { WebSurface(webView: tab.webView) }
                    if let error = tab.pageError {
                        VStack(spacing: 16) {
                            Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                            Text("页面未能载入").font(.headline)
                            Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("重新载入") { tab.pageError = nil; tab.webView.reload() }.buttonStyle(.borderedProminent)
                        }.padding(28).frame(maxWidth: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24)).padding()
                    }
                }
                if addressFocused && !suggestions.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(suggestions) { item in
                                Button { tab.loadInput(item.target); addressFocused = false } label: {
                                    VStack(alignment: .leading, spacing: 2) { Text(item.title).lineLimit(1); Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 220).background(.regularMaterial)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if showFind {
                HStack {
                    TextField("在页面中查找", text: $findText).onSubmit { Task { await runFind(1) } }.submitLabel(.search)
                    Text(findTotal == 0 ? "0" : "\(findIndex) / \(findTotal)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { Task { await runFind(-1) } } label: { Image(systemName: "chevron.up") }
                    Button { Task { await runFind(1) } } label: { Image(systemName: "chevron.down") }
                    Button { showFind = false; tab.clearFind() } label: { Image(systemName: "xmark.circle.fill") }
                }.padding().background(.bar)
            }
            if tab.isLoading { ProgressView(value: tab.progress).progressViewStyle(.linear) }
            if !barOnTop { chrome }
        }
        .onAppear { input = tab.isHome ? "" : tab.address; tab.visiblePageCount += 1; tab.lastActiveAt = Date(); tab.restoreIfNeeded() }
        .onDisappear { tab.visiblePageCount = max(0, tab.visiblePageCount - 1) }
        .onChange(of: tab.address) { _, value in if !addressFocused { input = value } }
        .onChange(of: addressFocused) { _, value in if value { input = tab.isHome ? "" : tab.address }; refreshSuggestions() }
        .onChange(of: input) { _, _ in refreshSuggestions() }
        .sheet(item: $tool) { item in
            switch item {
            case .reader: ReaderSheet(tab: tab)
            case .media: MediaSheet(tab: tab)
            case .images: ImageSheet(tab: tab)
            case .qr: QRSheet(address: tab.webView.url?.absoluteString ?? tab.address)
            case .translate: TranslateSheet(tab: tab)
            case .site: SiteSettingsSheet(tab: tab)
            case .console: ConsoleSheet(tab: tab)
            case .autofill: AutofillSheet(tab: tab)
            case .refresh: RefreshSheet(tab: tab)
            case .blocking: NavigationStack { ContentBlockingView() }
            case .fonts: NavigationStack { FontSettingsView() }
            case .matrix: NavigationStack { CapabilityView() }
            }
        }
    }
    private var chrome: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { openPanel(.addons) } label: { Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 20)) }
                    .accessibilityLabel("扩展与脚本").accessibilityIdentifier("browser.addons")
                TextField("搜索或输入网址", text: $input)
                    .font(.system(size: 15)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.webSearch).submitLabel(.go).focused($addressFocused)
                    .accessibilityIdentifier("browser.address")
                    .onSubmit { tab.loadInput(input); addressFocused = false }
                if addressFocused {
                    Button { input = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清空地址")
                } else if !tab.isHome {
                    Button { if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() } } label: { Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise") }
                        .accessibilityLabel(tab.isLoading ? "停止" : "刷新")
                }
            }.padding(.horizontal, 14).frame(height: 46).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            HStack {
                Button { tab.webView.goBack() } label: { Image(systemName: "chevron.left").frame(width: 32, height: 30) }.disabled(!tab.canGoBack).accessibilityLabel("后退")
                Button { tab.webView.goForward() } label: { Image(systemName: "chevron.right").frame(width: 32, height: 30) }.disabled(!tab.canGoForward).accessibilityLabel("前进")
                ForEach(model.profile.settings.shortcuts, id: \.self) { id in
                    Button { shortcut(id) } label: { Image(systemName: ShortcutCatalog.symbol(id)).frame(width: 30, height: 30) }.accessibilityLabel(ShortcutCatalog.title(id))
                }
                Spacer(minLength: 8)
                Button { openPanel(.profiles) } label: { Image(systemName: model.profile.symbol).frame(width: 36, height: 30) }.accessibilityLabel("身份空间").accessibilityIdentifier("browser.profiles")
                Spacer(minLength: 8)
                Button { share() } label: { Image(systemName: "square.and.arrow.up").frame(width: 32, height: 30) }.disabled(tab.isHome).accessibilityLabel("分享")
                Button { openPanel(.tabs) } label: { ZStack { Image(systemName: "square.on.square"); Text("\(session.tabs.count)").font(.system(size: 9, weight: .bold)).offset(x: -2, y: 2) }.frame(width: 36, height: 30) }.accessibilityLabel("标签页").accessibilityIdentifier("browser.tabs")
                pageMenu
            }.font(.system(size: 19))
        }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6).background(.bar)
    }
    private var pageMenu: some View {
        Menu {
            Button("新标签页", systemImage: "plus") { session.addTab() }
            Button("无痕标签页", systemImage: "eyeglasses") { session.addTab(isPrivate: true) }
            Button("书签与历史", systemImage: "book") { openPanel(.library) }
            Button("添加书签", systemImage: "bookmark") { session.addBookmark() }.disabled(tab.isHome)
            Divider()
            Button(tab.desktop ? "手机版" : "桌面版", systemImage: "desktopcomputer") { tab.toggleDesktop() }.disabled(tab.isHome)
            Button("页内查找", systemImage: "doc.text.magnifyingglass") { showFind.toggle() }.disabled(tab.isHome)
            Button("翻译网页", systemImage: "character.book.closed") { tool = .translate }.disabled(tab.isHome)
            Button("阅读模式", systemImage: "text.alignleft") { tool = .reader }.disabled(tab.isHome)
            Button("暗黑模式", systemImage: "moon") { cycleDark() }.disabled(tab.isHome)
            Button("用户脚本", systemImage: "curlybraces") { openPanel(.addons) }
            Button("扩展", systemImage: "puzzlepiece.extension") { openPanel(.addons) }
            Button("内容拦截", systemImage: "hand.raised") { tool = .blocking }
            Button("隐藏元素", systemImage: "eye.slash") { tab.beginElementPicker() }.disabled(tab.isHome)
            Button("媒体", systemImage: "play.rectangle") { tool = .media }.disabled(tab.isHome)
            Button("图片", systemImage: "photo") { tool = .images }.disabled(tab.isHome)
            Button("画中画", systemImage: "pip") { tab.video("pip") }.disabled(tab.isHome)
            Button("下载", systemImage: "arrow.down.circle") { openPanel(.settings) }
            Divider()
            Button("分享", systemImage: "square.and.arrow.up") { share() }
            Button("打印", systemImage: "printer") { tab.printPage() }.disabled(tab.isHome)
            Button("创建 PDF", systemImage: "doc.richtext") { Task { if let url = await tab.makePDF() { BrowserPresentation.share([url]) } } }.disabled(tab.isHome)
            Button("定时刷新", systemImage: "timer") { tool = .refresh }
            Button("脚本菜单", systemImage: "terminal") { openPanel(.commands) }
            Button("此网站", systemImage: "slider.horizontal.3") { tool = .site }
            Button("二维码", systemImage: "qrcode") { tool = .qr }.disabled(tab.isHome)
            Button("自动填充", systemImage: "person.crop.rectangle") { tool = .autofill }
            Button("实验控制台", systemImage: "terminal.fill") { tool = .console }.disabled(tab.isHome)
            Divider()
            Button("设置与下载", systemImage: "gearshape") { openPanel(.settings) }
        } label: { Image(systemName: "ellipsis.circle").frame(width: 32, height: 30) }
        .accessibilityLabel("更多")
        .contextMenu { ForEach(ShortcutCatalog.all, id: \.id) { item in Button(item.title) { shortcut(item.id) } } }
    }
    private func shortcut(_ id: String) {
        switch id {
        case "newTab": session.addTab()
        case "closeTab": session.close(tab)
        case "dark": cycleDark()
        case "translate": tool = .translate
        case "userscripts": openPanel(.addons)
        case "media": tool = .media
        case "reload": tab.webView.reload()
        case "desktop": tab.toggleDesktop()
        case "reader": tool = .reader
        case "find": showFind = true
        default: break
        }
    }
    private func cycleDark() {
        let order = ["off", "auto", "on"]
        let index = order.firstIndex(of: model.profile.settings.darkMode) ?? -1
        let next = order[(index + 1) % order.count]
        model.updateProfile(session.profileID) { $0.settings.darkMode = next }
        tab.applyDecorations()
    }
    private func refreshSuggestions() { suggestions = addressFocused ? Omnibox.suggestions(input: input, profile: model.profile) : [] }
    private func runFind(_ direction: Int) async {
        let found = await tab.findInPage(findText, direction: direction)
        findIndex = found.0; findTotal = found.1
    }
    private func share() {
        guard let url = tab.webView.url else { return }
        BrowserPresentation.share([url])
    }
}

struct RefreshSheet: View {
    @ObservedObject var tab: BrowserTab
    @Environment(\.dismiss) private var dismiss
    @State private var custom = 15
    private let presets = [0, 5, 10, 30, 60, 300]
    var body: some View {
        NavigationStack {
            Form {
                Picker("间隔", selection: Binding(get: { presets.contains(tab.autoRefreshSeconds) ? tab.autoRefreshSeconds : -1 }, set: { tab.setAutoRefresh($0) })) {
                    Text("关闭").tag(0); Text("5 秒").tag(5); Text("10 秒").tag(10); Text("30 秒").tag(30); Text("1 分钟").tag(60); Text("5 分钟").tag(300)
                }
                Stepper("自定义 \(custom) 秒", value: $custom, in: 2...3600)
                Button("使用自定义间隔") { tab.setAutoRefresh(custom); dismiss() }
                Text("只有你打开定时刷新后才会执行。App 进入后台时，iOS 不保证计时继续。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("定时刷新")
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: BrowserSession
    var openPanel: (BrowserPanel) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RIKUGAN").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(3).foregroundStyle(.secondary)
                        Text("你的浏览，自有主张。").font(.system(size: 28, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Image(systemName: "eye.fill").font(.system(size: 32)).foregroundStyle(.white).frame(width: 66, height: 66)
                        .background(LinearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
                }.padding(.top, 26)
                HStack(spacing: 12) {
                    Image(systemName: model.profile.symbol).font(.title2).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 3) { Text(model.profile.name).font(.headline); Text("独立登录状态 · 独立扩展与脚本").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("切换") { openPanel(.profiles) }.font(.subheadline.weight(.semibold))
                }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
                HStack(spacing: 14) {
                    homeCard("扩展与脚本", subtitle: "为网页添加能力", icon: "puzzlepiece.extension.fill") { openPanel(.addons) }.accessibilityIdentifier("home.addons")
                    homeCard("身份空间", subtitle: "把不同生活分开", icon: "person.2.crop.square.stack.fill") { openPanel(.profiles) }.accessibilityIdentifier("home.profiles")
                }
                if !frequent.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("经常访问").font(.headline)
                        ForEach(frequent, id: \.host) { item in
                            Button { if let url = URL(string: "https://\(item.host)") { session.activeTab?.navigate(url) } } label: {
                                HStack { Text(item.host).lineLimit(1); Spacer(); Text("\(item.count)").font(.caption).foregroundStyle(.secondary) }
                                    .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("收藏").font(.headline); Spacer(); Button("全部书签") { openPanel(.library) }.font(.subheadline) }
                    let pages = model.profile.bookmarks.isEmpty ? [PageRecord(title: "Google", url: "https://www.google.com"), PageRecord(title: "GitHub", url: "https://github.com"), PageRecord(title: "扩展自检页", url: "https://example.com")] : Array(model.profile.bookmarks.prefix(8))
                    ForEach(pages) { page in
                        Button { session.activeTab?.navigate(URL(string: page.url)!) } label: {
                            HStack { Image(systemName: "globe").foregroundStyle(.indigo); Text(page.title).lineLimit(1); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary) }
                                .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                }
                Text("没有会员墙，也不需要安装多份 App。\n从底部地址栏开始，或先导入你常用的扩展。").font(.footnote).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22).frame(maxWidth: 760)
        }.frame(maxWidth: .infinity).background {
            if let image = wallpaper {
                Image(uiImage: image).resizable().scaledToFill().overlay(model.profile.settings.immersiveWallpaper ? Color.black.opacity(0.25) : Color.clear)
            } else { Color(uiColor: .systemGroupedBackground) }
        }
    }
    private var frequent: [(host: String, count: Int)] {
        var counts: [String: Int] = [:]
        for page in model.profile.history { if let host = URL(string: page.url)?.host { counts[host, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }.prefix(6).map { (host: $0.0, count: $0.1) }
    }
    private var wallpaper: UIImage? {
        let name = model.profile.settings.wallpaperFile
        guard !name.isEmpty else { return nil }
        let url = model.directory(model.profile.id).appendingPathComponent(name)
        return UIImage(contentsOfFile: url.path)
    }
    private func homeCard(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain)
    }
}

struct TabsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: BrowserSession
    @State private var naming = false
    @State private var groupName = ""
    var body: some View {
        NavigationStack {
            List {
                if !model.profile.closedTabs.isEmpty {
                    Button("恢复最近关闭 · \(model.profile.closedTabs[0].title)", systemImage: "arrow.uturn.backward") { session.reopenClosed() }
                }
                if !session.tabs.filter(\.isPrivate).isEmpty {
                    Section("无痕") { ForEach(session.tabs.filter(\.isPrivate)) { row($0) } }
                }
                ForEach(model.profile.tabGroups) { group in
                    Section(group.name) {
                        ForEach(session.tabs.filter { $0.groupID == group.id && !$0.isPrivate }) { row($0) }
                    }
                }
                Section("标签页") { ForEach(session.tabs.filter { $0.groupID == nil && !$0.isPrivate }) { row($0) } }
            }.navigationTitle("标签页")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("新建", systemImage: "plus") { session.addTab(); dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .bottomBar) {
                        Menu("整理") {
                            Button("无痕标签") { session.addTab(isPrivate: true); dismiss() }
                            Button("新建标签组") { naming = true }
                            Button("关闭全部") { session.closeAllTabs() }
                            if let current = session.activeTab { Button("关闭其他") { session.closeOthers(keeping: current) } }
                        }
                    }
                }
                .alert("新建标签组", isPresented: $naming) {
                    TextField("名称", text: $groupName)
                    Button("创建") { session.addGroup(named: groupName); groupName = "" }
                    Button("取消", role: .cancel) {}
                }
        }
    }
    private func row(_ tab: BrowserTab) -> some View {
        Button { session.select(tab); dismiss() } label: {
            HStack(spacing: 12) {
                if let image = session.thumbnails[tab.id] { Image(uiImage: image).resizable().scaledToFill().frame(width: 54, height: 40).clipped().cornerRadius(6) }
                else if let icon = session.favicons[tab.id] { Image(uiImage: icon).resizable().frame(width: 22, height: 22) }
                else { Image(systemName: tab.isHome ? "house" : (tab.isPrivate ? "eyeglasses" : "globe")) }
                VStack(alignment: .leading) { Text(tab.pageTitle).lineLimit(1); Text(tab.isHome ? "新标签页" : tab.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if tab.isSuspended { Image(systemName: "moon.zzz").accessibilityLabel("已休眠，打开时恢复") }
                if tab.id == session.selectedID { Image(systemName: "checkmark.circle.fill") }
            }
        }
        .contextMenu {
            Button("关闭") { session.close(tab) }
            Button("关闭其他") { session.closeOthers(keeping: tab) }
            Button("复制链接") { UIPasteboard.general.string = tab.address }
            Menu("移到标签组") {
                Button("未分组") { session.move(tab, to: nil) }
                ForEach(model.profile.tabGroups) { group in Button(group.name) { session.move(tab, to: group.id) } }
            }
        }
        .swipeActions { Button("关闭", role: .destructive) { session.close(tab) } }
    }
}

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var adding = false
    @State private var deleting: BrowserProfile?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.state.profiles) { profile in
                        Button { model.activate(profile.id); dismiss() } label: {
                            HStack(spacing: 14) { Image(systemName: profile.symbol).font(.title2); VStack(alignment: .leading, spacing: 4) { Text(profile.name).font(.headline); Text("\(profile.extensions.count) 个扩展 · \(profile.scripts.count) 个脚本").font(.caption).foregroundStyle(.secondary) }; Spacer(); if profile.id == model.state.activeProfileID { Image(systemName: "checkmark.circle.fill") } }
                        }.accessibilityIdentifier("profile.\(profile.name)")
                            .swipeActions { Button("删除", role: .destructive) { deleting = profile }; Button("重命名") { BrowserPresentation.input(title: "重命名身份", message: "", initial: profile.name) { name in if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { model.updateProfile(profile.id) { $0.name = String(name.prefix(40)) } } } }.tint(.indigo) }
                    }
                } footer: { Text("Cookie、网站存储、标签页、书签、浏览记录、扩展设置和脚本数据按身份分开。切换身份会重新载入标签页；网页内未提交的表单不会保存。") }
                Button("新建身份空间", systemImage: "plus") { adding = true }.accessibilityIdentifier("profiles.add")
            }.navigationTitle("身份空间")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .alert("新建身份空间", isPresented: $adding) { TextField("例如：工作、小号", text: $newName); Button("取消", role: .cancel) {}; Button("创建") { model.addProfile(newName); newName = ""; dismiss() } }
                .confirmationDialog("删除「\(deleting?.name ?? "")」及其本地数据？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    Button("删除身份", role: .destructive) { if let deleting { model.deleteProfile(deleting.id) }; deleting = nil }
                }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: BrowserSession
    @State private var selection = 0
    @State private var query = ""
    @State private var folderName = ""
    @State private var addingFolder = false
    @State private var folder: UUID?
    var body: some View {
        NavigationStack {
            List {
                Picker("资料", selection: $selection) { Text("书签").tag(0); Text("历史").tag(1) }.pickerStyle(.segmented)
                TextField("搜索", text: $query)
                if selection == 0 {
                    if model.profile.bookmarkFolders.isEmpty == false && folder == nil {
                        ForEach(model.profile.bookmarkFolders) { item in Button(item.name, systemImage: "folder") { folder = item.id } }
                    }
                    if filteredBookmarks.isEmpty { ContentUnavailableView("还没有书签", systemImage: "book") }
                    ForEach(filteredBookmarks) { page in
                        Button { open(page.url) } label: { VStack(alignment: .leading) { Text(page.title).lineLimit(1); Text(page.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                            .swipeActions {
                                Button("删除", role: .destructive) { model.updateProfile(session.profileID) { $0.bookmarks.removeAll { $0.id == page.id } } }
                                Button("编辑") { BrowserPresentation.input(title: "编辑书签", message: page.url, initial: page.title) { title in
                                    guard let title else { return }
                                    model.updateProfile(session.profileID) { if let index = $0.bookmarks.firstIndex(where: { $0.id == page.id }) { $0.bookmarks[index].title = title } }
                                } }
                            }
                            .contextMenu {
                                Menu("移动到") {
                                    Button("顶层") { model.updateProfile(session.profileID) { if let index = $0.bookmarks.firstIndex(where: { $0.id == page.id }) { $0.bookmarks[index].folderID = nil } } }
                                    ForEach(model.profile.bookmarkFolders) { item in
                                        Button(item.name) { model.updateProfile(session.profileID) { if let index = $0.bookmarks.firstIndex(where: { $0.id == page.id }) { $0.bookmarks[index].folderID = item.id } } }
                                    }
                                }
                            }
                    }
                } else {
                    if filteredHistory.isEmpty { ContentUnavailableView("还没有浏览记录", systemImage: "clock") }
                    ForEach(historyDays, id: \.title) { day in
                        Section(day.title) {
                            ForEach(day.pages) { page in
                                Button { open(page.url) } label: { VStack(alignment: .leading) { Text(page.title).lineLimit(1); Text(page.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                                    .swipeActions { Button("删除", role: .destructive) { model.updateProfile(session.profileID) { $0.history.removeAll { $0.id == page.id } } } }
                            }
                            Button("删除这一天", role: .destructive) {
                                let ids = Set(day.pages.map(\.id))
                                model.updateProfile(session.profileID) { $0.history.removeAll { ids.contains($0.id) } }
                            }
                        }
                    }
                    Button("清除全部历史", role: .destructive) { model.updateProfile(session.profileID) { $0.history.removeAll() } }
                }
            }.navigationTitle("书签与历史")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { if selection == 0 { Button("文件夹", systemImage: "folder.badge.plus") { addingFolder = true } } }
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
                }
                .alert("新建文件夹", isPresented: $addingFolder) {
                    TextField("名称", text: $folderName)
                    Button("创建") { model.updateProfile(session.profileID) { $0.bookmarkFolders.append(BookmarkFolder(name: String(folderName.prefix(40)))) }; folderName = "" }
                    Button("取消", role: .cancel) {}
                }
        }
    }
    private var filteredBookmarks: [PageRecord] {
        model.profile.bookmarks.filter { page in
            (folder == nil || page.folderID == folder) && (query.isEmpty || page.title.localizedCaseInsensitiveContains(query) || page.url.localizedCaseInsensitiveContains(query))
        }
    }
    private var filteredHistory: [PageRecord] {
        model.profile.history.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
    }
    private var historyDays: [(title: String, pages: [PageRecord])] {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .none
        var buckets: [(String, [PageRecord])] = []
        for page in filteredHistory {
            let title = formatter.string(from: page.date)
            if let index = buckets.firstIndex(where: { $0.0 == title }) { buckets[index].1.append(page) }
            else { buckets.append((title, [page])) }
        }
        return buckets.map { (title: $0.0, pages: $0.1) }
    }
    private func open(_ raw: String) { if let url = URL(string: raw) { session.activeTab?.navigate(url) }; dismiss() }
}

struct CommandsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: BrowserSession
    var body: some View {
        NavigationStack {
            List {
                let commands = session.commands.filter { $0.tabID == session.activeTab?.id }
                if commands.isEmpty { ContentUnavailableView("当前页面没有脚本菜单", systemImage: "terminal", description: Text("支持 GM_registerMenuCommand 的脚本运行后会出现在这里。")) }
                ForEach(commands) { command in Button(command.title) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { session.runCommand(command) } } }
            }.navigationTitle("脚本菜单").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: BrowserSession
    @State private var clearing = false
    @State private var importing = false
    @State private var wallpaper = false
    @State private var backupPreview: BackupPreview?
    var body: some View {
        NavigationStack {
            Form {
                Section("当前身份：" + model.profile.name) {
                    Picker("搜索引擎", selection: Binding(get: { model.profile.searchEngine }, set: { engine in model.updateProfile(session.profileID) { $0.searchEngine = engine } })) {
                        let current = model.profile.searchEngine
                        let known = SearchEngines.builtins.map(\.template) + model.profile.settings.customEngines.map(\.template)
                        if !known.contains(current) { Text("当前").tag(current) }
                        ForEach(SearchEngines.builtins, id: \.template) { Text($0.name).tag($0.template) }
                        ForEach(model.profile.settings.customEngines) { Text($0.name).tag($0.template) }
                    }
                    Button("自定义搜索引擎") { BrowserPresentation.input(title: "搜索模板", message: "使用 {query}，例如 https://example.com/search?q={query}", initial: "https://example.com/search?q={query}") { template in
                        guard let template, template.contains("{query}"), let url = URL(string: template.replacingOccurrences(of: "{query}", with: "test")) else { return }
                        _ = url
                        model.updateProfile(session.profileID) { profile in
                            profile.settings.customEngines.append(SearchEngine(name: "自定义", template: template, keyword: "c\(profile.settings.customEngines.count)"))
                            profile.searchEngine = template
                        }
                    } }
                    Picker("地址栏", selection: Binding(get: { model.profile.settings.addressBar }, set: { value in model.updateProfile(session.profileID) { $0.settings.addressBar = value } })) {
                        Text("底部").tag("bottom"); Text("顶部").tag("top")
                    }
                    Picker("网页暗黑", selection: Binding(get: { model.profile.settings.darkMode }, set: { value in model.updateProfile(session.profileID) { $0.settings.darkMode = value }; session.tabs.forEach { $0.applyDecorations() } })) {
                        Text("关闭").tag("off"); Text("自动").tag("auto"); Text("始终").tag("on")
                    }
                    Picker("首页", selection: Binding(get: { model.profile.settings.homepage }, set: { value in model.updateProfile(session.profileID) { $0.settings.homepage = value } })) {
                        Text("收藏").tag("favorites"); Text("空白").tag("blank"); Text("自定义网址").tag("custom")
                    }
                    Toggle("首页沉浸壁纸", isOn: Binding(get: { model.profile.settings.immersiveWallpaper }, set: { value in model.updateProfile(session.profileID) { $0.settings.immersiveWallpaper = value } }))
                    Button(model.profile.settings.wallpaperFile.isEmpty ? "选择首页壁纸" : "更换首页壁纸") { wallpaper = true }
                    if !model.profile.settings.wallpaperFile.isEmpty { Button("清除首页壁纸", role: .destructive) { model.clearWallpaper() } }
                    Toggle("拦截 App Store 跳转", isOn: Binding(get: { model.profile.settings.preventAppStoreRedirect }, set: { value in model.updateProfile(session.profileID) { $0.settings.preventAppStoreRedirect = value } }))
                    Toggle("拦截外部 App 跳转", isOn: Binding(get: { model.profile.settings.preventExternalAppRedirect }, set: { value in model.updateProfile(session.profileID) { $0.settings.preventExternalAppRedirect = value } }))
                    Toggle("允许 Safari 检查网页", isOn: Binding(get: { model.profile.settings.inspectable }, set: { value in model.updateProfile(session.profileID) { $0.settings.inspectable = value }; session.tabs.forEach { $0.existingWebView?.isInspectable = value } }))
                    NavigationLink("内容拦截") { ContentBlockingView() }
                    NavigationLink("网页字体") { FontSettingsView() }
                    NavigationLink("扩展 API 兼容性") { CapabilityView() }
                    NavigationLink("自动填充") { AutofillSheet(tab: nil) }
                    Button("清除网站数据与历史记录", role: .destructive) { clearing = true }
                }
                Section("工具栏快捷动作") {
                    ForEach(ShortcutCatalog.all, id: \.id) { item in
                        Toggle(item.title, isOn: Binding(get: { model.profile.settings.shortcuts.contains(item.id) }, set: { on in
                            model.updateProfile(session.profileID) { profile in
                                profile.settings.shortcuts.removeAll { $0 == item.id }
                                if on { profile.settings.shortcuts.append(item.id) }
                            }
                        }))
                    }
                }
                Section("备份") {
                    NavigationLink("待处理分享（\(model.pendingShareCount)）") { ShareQueueView() }
                    Button("导出标签页和设置") { if let url = try? model.exportBackup() { BrowserPresentation.share([url]) } }
                    Button("导入备份") { importing = true }
                }
                Section("本身份的下载") { DownloadList(center: model.downloadCenter) }
                Section("关于 Rikugan") {
                    LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") + ")")
                    Text("扩展运行时使用 iOS 18.4 的 WKWebExtension，而不是一套假装完整的自研 chrome.*。未实现的 API 会标明 Unsupported，不会静默当成成功。").font(.footnote).foregroundStyle(.secondary)
                    Text("未签名 IPA 没有默认浏览器 entitlement。重签时如果描述文件不含该权限，Rikugan 不会出现在系统默认浏览器列表里，这里也不会假装可以。分享扩展需要同一个 App Group：\(AppGroupID.suite)。").font(.footnote).foregroundStyle(.secondary)
                    Link("源代码与问题反馈", destination: URL(string: "https://github.com/dandibbert/Rikugan")!)
                }
            }.navigationTitle("设置与下载").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .confirmationDialog("会退出当前身份中的网站登录，不影响其他身份、书签或脚本。", isPresented: $clearing, titleVisibility: .visible) { Button("清除", role: .destructive) { Task { await session.clearWebsiteData() } } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size <= 8_000_000 else { throw RikuganError.message("备份超过 8 MB。") }
                            backupPreview = BackupPreview(backup: try BackupImporter.decode(Data(contentsOf: url)), fileName: url.lastPathComponent)
                        } catch { model.message = "未导入备份：\(error.localizedDescription)" }
                    }
                }
                .sheet(item: $backupPreview) { BackupPreviewSheet(preview: $0) }
                .fileImporter(isPresented: $wallpaper, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        do { try model.importWallpaper(url) } catch { model.message = error.localizedDescription }
                    }
                }
        }
    }
}
