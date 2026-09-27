import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// Main browser window UI. iPhone: address bar top or bottom + toolbar. iPad: desktop-style tab
/// strip, toolbar with extension buttons and an optional sidebar (spec §4 / §5 / §46).
struct BrowserView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var manager: TabManager
    @EnvironmentObject private var runtime: ExtensionRuntime
    @EnvironmentObject private var scriptInstaller: UserscriptInstallCoordinator
    @EnvironmentObject private var extensionInstaller: ExtensionInstaller
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var sheet: BrowserSheet?
    @State private var showTabs = false
    @State private var editing = false
    @State private var showSidebar = false
    @State private var importKind: ImportKind?
    @State private var showQuickActionPicker = false
    @State private var importPreview: ImportPreview?
    @State private var queuedImportPreview: ImportPreview?

    struct ImportPreview: Identifiable { let id = UUID(); let archive: RikuganArchive; let source: String }

    enum ImportKind: Identifiable { case extensionPackage, extensionFolder, userscript, font, settings
        var id: Int { hashValue }
    }

    private var isRegular: Bool { sizeClass == .regular }
    private var bottomAddress: Bool { !isRegular && services.prefs.toolbarPosition == .bottom }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if isRegular {
                    RegularToolbar(editing: $editing, showSidebar: $showSidebar, showTabs: $showTabs, sheet: $sheet, importKind: $importKind)
                    TabStrip()
                    Divider()
                } else if !bottomAddress {
                    AddressBar(editing: $editing, sheet: $sheet).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.bar)
                }
                HStack(spacing: 0) {
                    if isRegular && showSidebar {
                        SidebarView(sheet: $sheet).frame(width: 300)
                        Divider()
                    }
                    ZStack(alignment: .top) {
                        if let tab = manager.activeTab {
                            // Automated suite runs only: keep web content out of the accessibility
                            // tree so XCUITest snapshots of the native UI stay small and fast.
                            TabContentView(tab: tab).accessibilityHidden(SelfTestRunner.autoRun)
                        } else {
                            Color(.systemBackground)
                        }
                    }
                }
                if !isRegular {
                    VStack(spacing: 0) {
                        Divider()
                        if bottomAddress {
                            AddressBar(editing: $editing, sheet: $sheet).padding(.horizontal, 10).padding(.top, 6)
                        }
                        CompactToolbar(showTabs: $showTabs, sheet: $sheet, importKind: $importKind, showQuickActionPicker: $showQuickActionPicker)
                    }
                    .background(.bar)
                }
            }
            if editing {
                OmniboxOverlay(editing: $editing)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, isRegular ? 24 : 110) }
        .overlay { if let busy = extensionInstaller.busy { BusyOverlay(text: busy) } }
        .overlay { if let url = scriptInstaller.loading { BusyOverlay(text: "正在获取脚本 \(url.lastPathComponent)…") } }
        .sheet(item: $sheet, onDismiss: {
            // A preview requested while another sheet was up is shown once that sheet is gone.
            if let queued = queuedImportPreview { queuedImportPreview = nil; importPreview = queued }
        }) { item in SheetContent(item: item, importKind: $importKind).environmentObjects(services, manager) }
        .sheet(item: $importPreview) { preview in
            ArchiveImportSheet(archive: preview.archive, source: preview.source).environmentObjects(services, manager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rikuganImportPreview)) { note in
            guard (note.object as? TabManager) === manager, let box = note.userInfo?["archive"] as? ArchiveBox else { return }
            let preview = ImportPreview(archive: box.archive, source: note.userInfo?["source"] as? String ?? "")
            if sheet != nil { queuedImportPreview = preview; sheet = nil } else { importPreview = preview }
        }
        .fullScreenCover(isPresented: $showTabs) { TabSwitcherView().environmentObjects(services, manager) }
        .sheet(item: $scriptInstaller.pending) { _ in UserscriptInstallSheet().environmentObject(scriptInstaller) }
        .sheet(item: $extensionInstaller.pending) { pending in ExtensionInstallSheet(pending: pending).environmentObject(extensionInstaller) }
        .sheet(item: $runtime.popup) { request in ExtensionPopupSheet(request: request).environmentObject(runtime) }
        .sheet(item: $runtime.permissionRequest) { prompt in PermissionPromptSheet(prompt: prompt) }
        .sheet(isPresented: $showQuickActionPicker) { QuickActionPicker().environmentObject(services) }
        .fileImporter(isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
                      allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .onReceive(NotificationCenter.default.publisher(for: .rikuganOpenSheet)) { note in
            guard (note.object as? TabManager) === manager, let target = note.userInfo?["sheet"] as? BrowserSheet else { return }
            sheet = target
        }
        .onReceive(NotificationCenter.default.publisher(for: .rikuganShowDownloads)) { _ in
            if TabRegistry.shared.focusedWindow === manager { sheet = .downloads }
        }
        .onReceive(services.$pendingOpen) { items in handlePending(items) }
        .onAppear { if SelfTestRunner.autoRun { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sheet = .selfTest } } }
        .animation(.easeInOut(duration: 0.18), value: editing)
    }

    private var allowedTypes: [UTType] {
        switch importKind {
        case .extensionPackage: return [.zip, UTType(filenameExtension: "crx") ?? .data, .data]
        case .extensionFolder: return [.folder]
        case .userscript: return [UTType(filenameExtension: "js") ?? .plainText, .plainText, .sourceCode, .data]
        case .font: return [.font, UTType(filenameExtension: "ttf") ?? .data, UTType(filenameExtension: "otf") ?? .data, UTType(filenameExtension: "ttc") ?? .data, UTType(filenameExtension: "woff2") ?? .data]
        case .settings: return [.json]
        case nil: return [.data]
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let kind = importKind
        importKind = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch kind {
        case .extensionPackage, .extensionFolder: extensionInstaller.stage(fileURL: url)
        case .userscript: scriptInstaller.importFile(url)
        case .font:
            do { let list = try services.fonts.importFonts(from: url); toasts.show("已导入字体：" + list.map(\.family).joined(separator: "、"), symbol: "textformat") }
            catch { toasts.show(error.localizedDescription, symbol: "exclamationmark.triangle") }
        case .settings: ImportExport.importBundle(from: url, into: manager)
        case nil: break
        }
    }

    private func handlePending(_ items: [AppServices.PendingOpen]) {
        guard let item = items.first, TabRegistry.shared.focusedWindow === manager || TabRegistry.shared.allWindows.count <= 1 else { return }
        services.pendingOpen.removeFirst()
        switch item.kind {
        case .url(let url):
            if url.scheme == "rikugan", let page = url.host, let target = InternalPages.sheet(for: page) { sheet = target; return }
            manager.newTab(url: url, isPrivate: false)
        case .search(let query):
            let tab = manager.newTab(isPrivate: false)
            tab.loadInput(query)
        case .importFile(let url):
            let ext = url.pathExtension.lowercased()
            if url.lastPathComponent.lowercased().hasSuffix(".user.js") || ext == "js" { scriptInstaller.importFile(url) }
            else if ["zip", "crx"].contains(ext) { extensionInstaller.stage(fileURL: url) }
            else if ["ttf", "otf", "woff", "woff2", "ttc"].contains(ext) {
                if let font = try? services.fonts.importFont(from: url) { toasts.show("已导入字体「\(font.family)」", symbol: "textformat") }
            } else if ext == "json" { ImportExport.importBundle(from: url, into: manager) }
            else { manager.newTab(url: url, isPrivate: false) }
        }
    }
}

extension View {
    func environmentObjects(_ services: AppServices, _ manager: TabManager) -> some View {
        self.environmentObject(services)
            .environmentObject(manager)
            .environmentObject(services.profile)
            .environmentObject(services.profile.extensions)
            .environmentObject(services.profile.userscripts)
            .environmentObject(services.downloads)
            .environmentObject(services.adBlock)
            .environmentObject(services.fonts)
            .environmentObject(services.autofill)
            .environmentObject(ToastCenter.shared)
            .environmentObject(UserscriptInstallCoordinator.shared)
            .environmentObject(ExtensionInstaller.shared)
    }
}

// MARK: - Tab content

struct TabContentView: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var services: AppServices

    var body: some View {
        ZStack(alignment: .top) {
            if tab.isHome {
                HomeView(tab: tab)
            } else {
                WebViewContainer(webView: tab.ensureWebView())
            }
            VStack(spacing: 0) {
                if tab.isLoading && !tab.isHome {
                    ProgressView(value: max(0.05, tab.progress)).progressViewStyle(.linear).tint(.accentColor).frame(height: 2)
                }
                if let item = tab.storeInstallCandidate {
                    StoreInstallBanner(item: item)
                }
                TranslationBanner(tab: tab)
                Spacer()
            }
            if let error = tab.loadError {
                LoadErrorView(message: error) { tab.reload() }
            }
        }
        .onAppear { tab.activate() }
    }
}

struct LoadErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("无法打开页面").font(.title3.bold())
            Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("重新加载", action: retry).buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

struct StoreInstallBanner: View {
    let item: WebStoreItem
    @EnvironmentObject private var installer: ExtensionInstaller
    var body: some View {
        HStack {
            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.tint)
            Text("在 Rikugan 中安装此扩展").font(.subheadline)
            Spacer()
            Button("添加") { installer.stage(store: item) }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial)
    }
}

struct TranslationBanner: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        switch tab.translation {
        case .idle: EmptyView()
        case .translating(let progress):
            HStack {
                ProgressView(value: progress).frame(width: 80)
                Text("正在翻译…").font(.footnote)
                Spacer()
                Button("停止") { TranslationCoordinator.stop(tab) }.font(.footnote)
            }
            .padding(8).background(.regularMaterial)
        case .translated(let showingOriginal):
            HStack {
                Image(systemName: "character.bubble")
                Text(showingOriginal ? "正在显示原文" : "已翻译为\(TranslationLanguage.name(for: AppServices.shared.prefs.translationTargetLanguage))").font(.footnote)
                Spacer()
                Button(showingOriginal ? "显示译文" : "显示原文") { TranslationCoordinator.toggleOriginal(tab) }.font(.footnote)
                Button { TranslationCoordinator.stop(tab) } label: { Image(systemName: "xmark") }.font(.footnote)
            }
            .padding(8).background(.regularMaterial)
        case .failed(let message):
            HStack {
                Image(systemName: "exclamationmark.triangle")
                Text(message).font(.footnote).lineLimit(2)
                Spacer()
                Button { tab.translation = .idle } label: { Image(systemName: "xmark") }.font(.footnote)
            }
            .padding(8).background(.regularMaterial)
        }
    }
}

struct BusyOverlay: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.footnote).multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ToastView: View {
    @EnvironmentObject private var toasts: ToastCenter
    var body: some View {
        if let toast = toasts.current {
            HStack(spacing: 10) {
                Image(systemName: toast.symbol)
                Text(toast.text).font(.subheadline).lineLimit(3)
                if let title = toast.actionTitle {
                    Button(title) { toast.action?(); toasts.current = nil }.font(.subheadline.bold())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8, y: 2)
            .padding(.horizontal, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
            .accessibilityIdentifier("toast")
        }
    }
}

// MARK: - Address bar

struct AddressBar: View {
    @EnvironmentObject private var manager: TabManager
    @EnvironmentObject private var runtime: ExtensionRuntime
    @Binding var editing: Bool
    @Binding var sheet: BrowserSheet?

    var body: some View {
        if let tab = manager.activeTab {
            AddressBarContent(tab: tab, editing: $editing, sheet: $sheet)
        }
    }
}

struct AddressBarContent: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var runtime: ExtensionRuntime
    @Binding var editing: Bool
    @Binding var sheet: BrowserSheet?

    var body: some View {
        HStack(spacing: 6) {
            if tab.isPrivate { Image(systemName: "hand.raised.fill").foregroundStyle(.purple).font(.caption) }
            Button { editing = true } label: {
                HStack(spacing: 6) {
                    if let url = tab.url, url.scheme == "https", !tab.isHome {
                        Image(systemName: tab.hasSecureContent ? "lock.fill" : "lock.open").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(tab.isHome ? "搜索或输入网址" : Omnibox.displayText(for: tab.url))
                        .lineLimit(1)
                        .foregroundStyle(tab.isHome ? .secondary : .primary)
                        .font(.body)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addressBar")
            if !runtime.toolbarExtensions.isEmpty {
                ExtensionToolbarMenu(tab: tab)
            }
            if tab.isLoading {
                Button { tab.stop() } label: { Image(systemName: "xmark") }.accessibilityLabel("停止")
            } else if !tab.isHome {
                Button { tab.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Extension buttons (spec §17). iPhone: compact menu; iPad: individual buttons in the toolbar.
struct ExtensionToolbarMenu: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var runtime: ExtensionRuntime

    var body: some View {
        Menu {
            ForEach(runtime.toolbarExtensions) { ext in
                Button {
                    runtime.performAction(ext, tab: tab)
                } label: {
                    let state = ext.actionState(for: tab.numericID)
                    Label(ext.displayName + (state.badgeText.isEmpty ? "" : "  [\(state.badgeText)]"),
                          uiImage: state.icon ?? ext.icon)
                }
            }
            Divider()
            Button { NotificationCenter.default.post(name: .rikuganOpenSheet, object: tab.manager, userInfo: ["sheet": BrowserSheet.extensions]) } label: {
                Label("管理扩展", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "puzzlepiece.extension")
        }
        .accessibilityIdentifier("extensionsMenu")
    }
}

struct ExtensionActionButton: View {
    @ObservedObject var ext: LoadedExtension
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var runtime: ExtensionRuntime

    var body: some View {
        let state = ext.actionState(for: tab.numericID)
        Button { runtime.performAction(ext, tab: tab) } label: {
            ZStack(alignment: .topTrailing) {
                if let image = state.icon ?? ext.icon {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                }
                if !state.badgeText.isEmpty {
                    Text(state.badgeText).font(.system(size: 9, weight: .bold)).foregroundStyle(Color(state.badgeTextColor))
                        .padding(.horizontal, 3).background(Color(state.badgeColor), in: Capsule()).offset(x: 8, y: -6)
                }
            }
        }
        .opacity(state.enabled ? 1 : 0.4)
        .accessibilityLabel(state.title ?? ext.displayName)
        .contextMenu {
            Button("选项") { runtime.openOptions(ext, from: tab) }
            if ext.record.hostAccess == .onClick { Button("在此网站运行") { runtime.runOnCurrentSite(ext, tab: tab) } }
        }
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, uiImage: UIImage?) {
        if let uiImage {
            self.init { Text(title) } icon: { Image(uiImage: uiImage.preparingThumbnail(of: CGSize(width: 22, height: 22)) ?? uiImage) }
        } else {
            self.init { Text(title) } icon: { Image(systemName: "puzzlepiece.extension") }
        }
    }
}

// MARK: - Compact (iPhone) toolbar

struct CompactToolbar: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var manager: TabManager
    @Binding var showTabs: Bool
    @Binding var sheet: BrowserSheet?
    @Binding var importKind: BrowserView.ImportKind?
    @Binding var showQuickActionPicker: Bool

    var body: some View {
        if let tab = manager.activeTab {
            CompactToolbarContent(tab: tab, showTabs: $showTabs, sheet: $sheet, importKind: $importKind, showQuickActionPicker: $showQuickActionPicker)
        }
    }
}

struct CompactToolbarContent: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var manager: TabManager
    @Binding var showTabs: Bool
    @Binding var sheet: BrowserSheet?
    @Binding var importKind: BrowserView.ImportKind?
    @Binding var showQuickActionPicker: Bool

    var body: some View {
        HStack {
            BackForwardButton(tab: tab, forward: false)
            Spacer()
            BackForwardButton(tab: tab, forward: true)
            Spacer()
            QuickActionButton(tab: tab, sheet: $sheet, showPicker: $showQuickActionPicker)
            Spacer()
            TabsButton(showTabs: $showTabs)
            Spacer()
            PageMenuButton(tab: tab, sheet: $sheet, importKind: $importKind)
        }
        .font(.system(size: 19))
        .padding(.horizontal, 22)
        .frame(height: 46)
    }
}

struct BackForwardButton: View {
    @ObservedObject var tab: BrowserTab
    let forward: Bool

    private var historyItems: [WKBackForwardListItem] {
        guard let list = tab.webView?.backForwardList else { return [] }
        return forward ? list.forwardList : Array(list.backList.reversed())
    }

    var body: some View {
        Menu {
            ForEach(Array(historyItems.prefix(15).enumerated()), id: \.offset) { _, item in
                Button(item.title?.isEmpty == false ? item.title! : item.url.absoluteString) { tab.webView?.go(to: item) }
            }
        } label: {
            Image(systemName: forward ? "chevron.forward" : "chevron.backward")
        } primaryAction: {
            forward ? tab.goForward() : tab.goBack()
        }
        .disabled(forward ? !tab.canGoForward : !tab.canGoBack)
        .accessibilityIdentifier(forward ? "forward" : "back")
    }
}

struct TabsButton: View {
    @EnvironmentObject private var manager: TabManager
    @Binding var showTabs: Bool

    var body: some View {
        Menu {
            Button { manager.newTab() } label: { Label("新标签页", systemImage: "plus") }
            Button { manager.newTab(isPrivate: true) } label: { Label("新无痕标签页", systemImage: "hand.raised") }
            if let tab = manager.activeTab {
                Button(role: .destructive) { manager.close(tab) } label: { Label("关闭此标签页", systemImage: "xmark") }
            }
            if !manager.recentlyClosed.isEmpty {
                Button { manager.reopenLastClosed() } label: { Label("恢复关闭的标签页", systemImage: "arrow.uturn.backward") }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.6).frame(width: 22, height: 22)
                Text("\(min(manager.visibleTabs.count, 99))").font(.system(size: 11, weight: .semibold))
            }
        } primaryAction: {
            manager.activeTab?.captureThumbnail()
            showTabs = true
        }
        .accessibilityIdentifier("tabsButton")
    }
}

/// Long-press customisable quick action slot (spec §46).
struct QuickActionButton: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var manager: TabManager
    @Binding var sheet: BrowserSheet?
    @Binding var showPicker: Bool

    var body: some View {
        let action = services.prefs.quickActions.first ?? .darkMode
        Button { QuickActions.perform(action, tab: tab, manager: manager, sheet: $sheet) } label: {
            Image(systemName: QuickActions.symbol(action))
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in showPicker = true })
        .accessibilityLabel(QuickActions.title(action))
    }
}

@MainActor enum QuickActions {
    static func title(_ action: ToolbarAction) -> String {
        switch action {
        case .newTab: return "新标签页"
        case .closeTab: return "关闭标签页"
        case .reload: return "刷新"
        case .darkMode: return "网页深色模式"
        case .translate: return "翻译"
        case .userscripts: return "用户脚本"
        case .media: return "媒体嗅探"
        case .desktopSite: return "桌面版网站"
        case .readerMode: return "阅读模式"
        case .findInPage: return "页内查找"
        case .share: return "分享"
        case .bookmarks: return "书签"
        case .privateTab: return "无痕标签页"
        case .images: return "查看图片"
        case .extensions: return "扩展"
        case .elementPicker: return "隐藏网页元素"
        }
    }

    static func symbol(_ action: ToolbarAction) -> String {
        switch action {
        case .newTab: return "plus.square.on.square"
        case .closeTab: return "xmark.square"
        case .reload: return "arrow.clockwise"
        case .darkMode: return "moon"
        case .translate: return "character.bubble"
        case .userscripts: return "curlybraces"
        case .media: return "play.rectangle.on.rectangle"
        case .desktopSite: return "desktopcomputer"
        case .readerMode: return "doc.plaintext"
        case .findInPage: return "doc.text.magnifyingglass"
        case .share: return "square.and.arrow.up"
        case .bookmarks: return "book"
        case .privateTab: return "hand.raised"
        case .images: return "photo.on.rectangle"
        case .extensions: return "puzzlepiece.extension"
        case .elementPicker: return "eye.slash"
        }
    }

    static func perform(_ action: ToolbarAction, tab: BrowserTab, manager: TabManager, sheet: Binding<BrowserSheet?>) {
        switch action {
        case .newTab: manager.newTab()
        case .closeTab: manager.close(tab)
        case .reload: tab.reload()
        case .darkMode: PageActions.cycleDarkMode(tab)
        case .translate: PageActions.translate(tab)
        case .userscripts: sheet.wrappedValue = .userscripts
        case .media: sheet.wrappedValue = .media
        case .desktopSite: tab.toggleDesktopMode()
        case .readerMode: sheet.wrappedValue = .reader
        case .findInPage: PageActions.findInPage(tab)
        case .share: PageActions.share(tab)
        case .bookmarks: sheet.wrappedValue = .bookmarks
        case .privateTab: manager.newTab(isPrivate: true)
        case .images: sheet.wrappedValue = .images
        case .extensions: sheet.wrappedValue = .extensions
        case .elementPicker: PageActions.elementPicker(tab)
        }
    }
}

struct QuickActionPicker: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(ToolbarAction.allCases) { action in
                Button {
                    services.prefs.quickActions = [action]
                    dismiss()
                } label: {
                    HStack {
                        Label(QuickActions.title(action), systemImage: QuickActions.symbol(action))
                        Spacer()
                        if services.prefs.quickActions.first == action { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("自定义快捷按钮")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Regular (iPad) toolbar + tab strip

struct RegularToolbar: View {
    @EnvironmentObject private var manager: TabManager
    @EnvironmentObject private var runtime: ExtensionRuntime
    @Binding var editing: Bool
    @Binding var showSidebar: Bool
    @Binding var showTabs: Bool
    @Binding var sheet: BrowserSheet?
    @Binding var importKind: BrowserView.ImportKind?

    var body: some View {
        if let tab = manager.activeTab {
            RegularToolbarContent(tab: tab, editing: $editing, showSidebar: $showSidebar, showTabs: $showTabs, sheet: $sheet, importKind: $importKind)
        }
    }
}

struct RegularToolbarContent: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var manager: TabManager
    @EnvironmentObject private var runtime: ExtensionRuntime
    @Environment(\.openWindow) private var openWindow
    @Binding var editing: Bool
    @Binding var showSidebar: Bool
    @Binding var showTabs: Bool
    @Binding var sheet: BrowserSheet?
    @Binding var importKind: BrowserView.ImportKind?

    var body: some View {
        HStack(spacing: 18) {
            Button { withAnimation { showSidebar.toggle() } } label: { Image(systemName: "sidebar.left") }
            BackForwardButton(tab: tab, forward: false)
            BackForwardButton(tab: tab, forward: true)
            AddressBarContent(tab: tab, editing: $editing, sheet: $sheet).frame(maxWidth: 720)
            ForEach(runtime.toolbarExtensions.prefix(6)) { ext in ExtensionActionButton(ext: ext, tab: tab) }
            Button { PageActions.share(tab) } label: { Image(systemName: "square.and.arrow.up") }
            Button { manager.newTab() } label: { Image(systemName: "plus") }.accessibilityIdentifier("newTabButton")
            Button { tab.captureThumbnail(); showTabs = true } label: { Image(systemName: "square.on.square") }
            PageMenuButton(tab: tab, sheet: $sheet, importKind: $importKind)
        }
        .font(.system(size: 18))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct TabStrip: View {
    @EnvironmentObject private var manager: TabManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(manager.visibleTabs) { tab in
                        TabStripItem(tab: tab, active: tab.id == manager.activeTabID)
                            .id(tab.id)
                            .onTapGesture { manager.select(tab) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: manager.activeTabID) { _, id in withAnimation { proxy.scrollTo(id) } }
        }
        .background(.bar)
    }
}

struct TabStripItem: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var manager: TabManager
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let icon = tab.favicon { Image(uiImage: icon).resizable().frame(width: 14, height: 14) }
            else { Image(systemName: tab.isPrivate ? "hand.raised" : "globe").font(.caption) }
            Text(tab.isHome ? "起始页" : tab.title).font(.footnote).lineLimit(1)
            Spacer(minLength: 0)
            Button { manager.close(tab) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(width: 190, height: 30)
        .background(active ? Color(.systemBackground) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu { TabContextMenu(tab: tab) }
    }
}

struct TabContextMenu: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var manager: TabManager

    var body: some View {
        Button { manager.duplicate(tab) } label: { Label("复制标签页", systemImage: "plus.square.on.square") }
        Button { manager.togglePin(tab) } label: { Label(tab.pinned ? "取消固定" : "固定标签页", systemImage: "pin") }
        if !tab.isPrivate {
            Menu {
                Button("标签页") { manager.move(tab, toGroup: nil) }
                ForEach(manager.groups) { group in Button(group.name) { manager.move(tab, toGroup: group.id) } }
                Button("新建标签页组…") { manager.createGroup(name: "新组 \(manager.groups.count + 1)", moving: tab) }
            } label: { Label("移到标签页组", systemImage: "square.grid.2x2") }
        }
        if let url = tab.url {
            Button { UIPasteboard.general.url = url } label: { Label("拷贝链接", systemImage: "doc.on.doc") }
        }
        Button { manager.closeOthers(than: tab) } label: { Label("关闭其他标签页", systemImage: "xmark.square") }
        Button(role: .destructive) { manager.close(tab) } label: { Label("关闭标签页", systemImage: "xmark") }
    }
}

// MARK: - Sidebar (iPad)

struct SidebarView: View {
    @EnvironmentObject private var manager: TabManager
    @EnvironmentObject private var profile: ProfileContext
    @Binding var sheet: BrowserSheet?

    var body: some View {
        List {
            Section("标签页组") {
                SidebarRow(title: "标签页", symbol: "square.on.square", count: manager.tabs(inGroup: nil).count,
                           selected: !manager.isPrivateMode && manager.currentGroupID == nil) { manager.switchToGroup(nil) }
                ForEach(manager.groups) { group in
                    SidebarRow(title: group.name, symbol: "square.grid.2x2", count: manager.tabs(inGroup: group.id).count,
                               selected: !manager.isPrivateMode && manager.currentGroupID == group.id) { manager.switchToGroup(group.id) }
                }
                SidebarRow(title: "无痕浏览", symbol: "hand.raised", count: manager.privateTabs.count, selected: manager.isPrivateMode) {
                    manager.switchToPrivate()
                }
                Button { manager.createGroup(name: "新组 \(manager.groups.count + 1)") } label: { Label("新建标签页组", systemImage: "plus") }
            }
            Section("个人收藏") {
                ForEach(profile.bookmarks.favorites) { node in
                    Button { if let url = node.url.flatMap(URL.init(string:)) { manager.activeTab?.load(url) } } label: {
                        Label(node.title, systemImage: "star")
                    }
                }
            }
            Section {
                Button { sheet = .bookmarks } label: { Label("书签", systemImage: "book") }
                Button { sheet = .history } label: { Label("历史记录", systemImage: "clock") }
                Button { sheet = .downloads } label: { Label("下载", systemImage: "arrow.down.circle") }
                Button { sheet = .extensions } label: { Label("扩展", systemImage: "puzzlepiece.extension") }
                Button { sheet = .userscripts } label: { Label("用户脚本", systemImage: "curlybraces") }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).font(.footnote)
            }
        }
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : nil)
    }
}
