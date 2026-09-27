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
        .sheet(item: $model.scriptDraft) { ScriptEditor(draft: $0) }
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
    @ObservedObject var session: BrowserSession
    @State private var panel: BrowserPanel?
    var body: some View {
        Group {
            if let tab = session.activeTab { BrowserPage(tab: tab, session: session, openPanel: { panel = $0 }).id(tab.id) }
            else { ProgressView() }
        }
        .overlay { if !session.ready { ZStack { Color(uiColor: .systemBackground).opacity(0.93); ProgressView("正在载入身份与扩展…") } } }
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
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if showFind {
                HStack {
                    TextField("在页面中查找", text: $findText).onSubmit { find() }.submitLabel(.search)
                    Button(action: { find() }) { Image(systemName: "chevron.down") }
                    Button(action: { showFind = false }) { Image(systemName: "xmark.circle.fill") }
                }.padding().background(.bar)
            }
            if tab.isLoading { ProgressView(value: tab.progress).progressViewStyle(.linear) }
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
                    Spacer(minLength: 12)
                    Button { openPanel(.profiles) } label: { Image(systemName: model.profile.symbol).frame(width: 36, height: 30) }.accessibilityLabel("身份空间").accessibilityIdentifier("browser.profiles")
                    Spacer(minLength: 12)
                    Button { share() } label: { Image(systemName: "square.and.arrow.up").frame(width: 32, height: 30) }.disabled(tab.isHome).accessibilityLabel("分享")
                    Button { openPanel(.tabs) } label: { ZStack { Image(systemName: "square.on.square"); Text("\(session.tabs.count)").font(.system(size: 9, weight: .bold)).offset(x: -2, y: 2) }.frame(width: 36, height: 30) }.accessibilityLabel("标签页").accessibilityIdentifier("browser.tabs")
                    Menu {
                        Button("新标签页", systemImage: "plus") { session.addTab() }
                        Button("书签与历史", systemImage: "book") { openPanel(.library) }
                        Button("添加书签", systemImage: "bookmark") { session.addBookmark() }.disabled(tab.isHome)
                        Button("脚本菜单命令", systemImage: "terminal") { openPanel(.commands) }
                        Button("在页面中查找", systemImage: "doc.text.magnifyingglass") { showFind.toggle() }.disabled(tab.isHome)
                        Button(tab.desktop ? "切换移动版" : "请求桌面版", systemImage: "desktopcomputer") { tab.toggleDesktop() }.disabled(tab.isHome)
                        Divider()
                        Button("设置与下载", systemImage: "gearshape") { openPanel(.settings) }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 32, height: 30) }.accessibilityLabel("更多")
                }.font(.system(size: 19))
            }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6).background(.bar)
        }
        .onAppear { input = tab.isHome ? "" : tab.address }
        .onChange(of: tab.address) { _, value in if !addressFocused { input = value } }
        .onChange(of: addressFocused) { _, value in if value { input = tab.isHome ? "" : tab.address } }
    }
    private func find() { tab.webView.find(findText, configuration: WKFindConfiguration()) { _ in } }
    private func share() {
        guard let url = tab.webView.url, let presenter = BrowserPresentation.presenter else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 60, width: 1, height: 1)
        presenter.present(sheet, animated: true)
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
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("常用网站").font(.headline); Spacer(); Button("全部书签") { openPanel(.library) }.font(.subheadline) }
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
        }.frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground))
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
    @ObservedObject var session: BrowserSession
    var body: some View {
        NavigationStack {
            List {
                ForEach(session.tabs) { tab in
                    Button { session.select(tab); dismiss() } label: {
                        HStack { Image(systemName: tab.isHome ? "house" : "globe"); VStack(alignment: .leading) { Text(tab.pageTitle).lineLimit(1); Text(tab.isHome ? "新标签页" : tab.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if tab.id == session.selectedID { Image(systemName: "checkmark.circle.fill") } }
                    }.swipeActions { Button("关闭", role: .destructive) { session.close(tab) } }
                }
            }.navigationTitle("标签页")
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("新建", systemImage: "plus") { session.addTab(); dismiss() } }; ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
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
    var body: some View {
        NavigationStack {
            List {
                Picker("资料", selection: $selection) { Text("书签").tag(0); Text("历史").tag(1) }.pickerStyle(.segmented)
                let pages = selection == 0 ? model.profile.bookmarks : model.profile.history
                if pages.isEmpty { ContentUnavailableView(selection == 0 ? "还没有书签" : "还没有浏览记录", systemImage: "book") }
                ForEach(pages) { page in
                    Button { if let url = URL(string: page.url) { session.activeTab?.navigate(url) }; dismiss() } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(page.title).lineLimit(1); Text(page.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.swipeActions { Button("删除", role: .destructive) { model.updateProfile(session.profileID) { if selection == 0 { $0.bookmarks.removeAll { $0.id == page.id } } else { $0.history.removeAll { $0.id == page.id } } } } }
                }
            }.navigationTitle("书签与历史").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
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
    @State private var downloads: [URL] = []
    var body: some View {
        NavigationStack {
            Form {
                Section("当前身份：" + model.profile.name) {
                    Picker("搜索引擎", selection: Binding(get: { model.profile.searchEngine }, set: { engine in model.updateProfile(session.profileID) { $0.searchEngine = engine } })) {
                        Text("Google").tag("https://www.google.com/search?q="); Text("Bing").tag("https://www.bing.com/search?q="); Text("DuckDuckGo").tag("https://duckduckgo.com/?q="); Text("百度").tag("https://www.baidu.com/s?wd=")
                    }
                    Button("清除网站数据与历史记录", role: .destructive) { clearing = true }
                }
                Section("本身份的下载") {
                    if downloads.isEmpty { Text("还没有下载文件").foregroundStyle(.secondary) }
                    ForEach(downloads, id: \.self) { file in
                        HStack { Text(file.lastPathComponent).font(.subheadline).lineLimit(2); Spacer(); ShareLink(item: file) { Image(systemName: "square.and.arrow.up") } }
                    }
                }
                Section("关于 Rikugan") {
                    LabeledContent("版本", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") + ")")
                    Text("使用 WebKit 官方扩展运行时。扩展兼容范围由 iOS/WebKit 决定，不等同于完整桌面 Chrome。").font(.footnote).foregroundStyle(.secondary)
                    Text("此版没有云同步、推送、默认浏览器特权，也不需要额外 App Group 授权。支持 iOS 18.4 及以上。").font(.footnote).foregroundStyle(.secondary)
                    Link("源代码与问题反馈", destination: URL(string: "https://github.com/dandibbert/Rikugan")!)
                }
            }.navigationTitle("设置与下载").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
                .confirmationDialog("会退出当前身份中的网站登录，不影响其他身份、书签或脚本。", isPresented: $clearing, titleVisibility: .visible) { Button("清除", role: .destructive) { Task { await session.clearWebsiteData() } } }
                .onAppear {
                    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads").appendingPathComponent(session.profileID.uuidString)
                    downloads = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
                }
        }
    }
}
