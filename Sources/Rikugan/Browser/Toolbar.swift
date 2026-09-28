import SwiftUI
import WebKit

/// Everything an action needs to run: the tab, its window and the window's UI state.
struct ToolbarActionContext {
    let tab: BrowserTab
    let manager: TabManager
    let sheet: Binding<BrowserSheet?>
    let showTabs: Binding<Bool>
    let showCustomize: Binding<Bool>
}

/// Actions for toolbar buttons, long presses and gestures (spec §46).
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
        case .back: return "后退"
        case .forward: return "前进"
        case .tabSwitcher: return "标签页概览"
        case .pageMenu: return "菜单"
        case .home: return "起始页"
        case .downloads: return "下载"
        case .history: return "历史记录"
        case .settings: return "设置"
        case .addBookmark: return "添加书签"
        case .scrollToTop: return "回到顶部"
        case .reopenClosedTab: return "恢复关闭的标签页"
        case .nextTab: return "下一个标签页"
        case .previousTab: return "上一个标签页"
        case .none: return "无"
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
        case .back: return "chevron.backward"
        case .forward: return "chevron.forward"
        case .tabSwitcher: return "square.on.square"
        case .pageMenu: return "ellipsis.circle"
        case .home: return "house"
        case .downloads: return "arrow.down.circle"
        case .history: return "clock"
        case .settings: return "gearshape"
        case .addBookmark: return "bookmark"
        case .scrollToTop: return "arrow.up.to.line"
        case .reopenClosedTab: return "arrow.uturn.backward"
        case .nextTab: return "arrow.right.square"
        case .previousTab: return "arrow.left.square"
        case .none: return "circle.slash"
        }
    }

    static func perform(_ action: ToolbarAction, _ c: ToolbarActionContext) {
        let tab = c.tab, manager = c.manager
        switch action {
        case .newTab: manager.newTab()
        case .closeTab: manager.close(tab)
        case .reload: tab.reload()
        case .darkMode: PageActions.cycleDarkMode(tab)
        case .translate: PageActions.translate(tab)
        case .userscripts: c.sheet.wrappedValue = .userscripts
        case .media: c.sheet.wrappedValue = .media
        case .desktopSite: tab.toggleDesktopMode()
        case .readerMode: c.sheet.wrappedValue = .reader
        case .findInPage: PageActions.findInPage(tab)
        case .share: PageActions.share(tab)
        case .bookmarks: c.sheet.wrappedValue = .bookmarks
        case .privateTab: manager.newTab(isPrivate: true)
        case .images: c.sheet.wrappedValue = .images
        case .extensions: c.sheet.wrappedValue = .extensions
        case .elementPicker: PageActions.elementPicker(tab)
        case .back: tab.goBack()
        case .forward: tab.goForward()
        case .tabSwitcher: tab.captureThumbnail(); c.showTabs.wrappedValue = true
        case .pageMenu: c.showCustomize.wrappedValue = true
        case .home: tab.goHome()
        case .downloads: c.sheet.wrappedValue = .downloads
        case .history: c.sheet.wrappedValue = .history
        case .settings: c.sheet.wrappedValue = .settings
        case .addBookmark: PageActions.addBookmark(tab)
        case .scrollToTop:
            if let scroll = tab.webView?.scrollView { scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: true) }
        case .reopenClosedTab: manager.reopenLastClosed()
        case .nextTab: switchTab(manager, by: 1)
        case .previousTab: switchTab(manager, by: -1)
        case .none: break
        }
    }

    static func switchTab(_ manager: TabManager, by offset: Int) {
        let tabs = manager.visibleTabs
        guard tabs.count > 1, let current = manager.activeTab, let index = tabs.firstIndex(where: { $0 === current }) else { return }
        let next = tabs[(index + offset + tabs.count) % tabs.count]
        current.captureThumbnail()
        manager.select(next)
    }
}

// MARK: - Compact (iPhone) toolbar

struct CompactToolbarContent: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var manager: TabManager
    @Binding var showTabs: Bool
    @Binding var sheet: BrowserSheet?
    @Binding var importKind: BrowserView.ImportKind?
    @Binding var showQuickActionPicker: Bool

    private var context: ToolbarActionContext {
        ToolbarActionContext(tab: tab, manager: manager, sheet: $sheet, showTabs: $showTabs, showCustomize: $showQuickActionPicker)
    }

    var body: some View {
        let layout = services.prefs.toolbarLayout.normalized
        HStack {
            ForEach(0..<ToolbarLayout.slotCount, id: \.self) { index in
                if index > 0 { Spacer() }
                slot(layout.buttons[index], longPress: layout.longPress[index])
            }
        }
        .font(.system(size: 19))
        .padding(.horizontal, 22)
        .frame(height: 46)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            let action = services.prefs.swipeUpToolbarAction
            guard action != .none, value.translation.height < -40, abs(value.translation.width) < abs(value.translation.height) else { return }
            QuickActions.perform(action, context)
        })
    }

    @ViewBuilder
    private func slot(_ action: ToolbarAction, longPress: ToolbarAction) -> some View {
        switch action {
        case .pageMenu:
            PageMenuButton(tab: tab, sheet: $sheet, importKind: $importKind)
        case .back where longPress == .none:
            BackForwardButton(tab: tab, forward: false)
        case .forward where longPress == .none:
            BackForwardButton(tab: tab, forward: true)
        case .tabSwitcher where longPress == .none:
            TabsButton(showTabs: $showTabs)
        default:
            ToolbarSlotButton(action: action, tab: tab) {
                QuickActions.perform(action, context)
            } onLongPress: {
                // No long-press action assigned: long press opens the toolbar customisation.
                if longPress == .none { showQuickActionPicker = true } else { QuickActions.perform(longPress, context) }
            }
        }
    }
}

/// A toolbar button with a separate long-press action.
struct ToolbarSlotButton: View {
    let action: ToolbarAction
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var manager: TabManager
    let onTap: () -> Void
    let onLongPress: () -> Void

    private var disabled: Bool {
        switch action {
        case .back: return !tab.canGoBack
        case .forward: return !tab.canGoForward
        default: return false
        }
    }

    var body: some View {
        Group {
            if action == .tabSwitcher {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.6).frame(width: 22, height: 22)
                    Text("\(min(manager.visibleTabs.count, 99))").font(.system(size: 11, weight: .semibold))
                }
            } else {
                Image(systemName: QuickActions.symbol(action))
            }
        }
        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.accentColor)
        .frame(minWidth: 36, minHeight: 36)
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { onTap() } }
        .onLongPressGesture(minimumDuration: 0.45) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress()
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(QuickActions.title(action))
        .accessibilityIdentifier(action == .tabSwitcher ? "tabsButton" : "toolbar-\(action.rawValue)")
    }
}

// MARK: - Customisation

struct ToolbarCustomizeView: View {
    @EnvironmentObject private var services: AppServices

    private var layout: ToolbarLayout { services.prefs.toolbarLayout.normalized }

    var body: some View {
        Form {
            Section {
                ForEach(0..<ToolbarLayout.slotCount, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(selection: Binding(get: { layout.buttons[index] }, set: { setButton(index, $0) })) {
                            ForEach(ToolbarAction.allCases.filter { $0 != .none }) { action in
                                Label(QuickActions.title(action), systemImage: QuickActions.symbol(action)).tag(action)
                            }
                        } label: {
                            Text("按钮 \(index + 1)")
                        }
                        if layout.buttons[index] != .pageMenu {
                            Picker(selection: Binding(get: { layout.longPress[index] }, set: { setLongPress(index, $0) })) {
                                Text(defaultLongPressTitle(layout.buttons[index])).tag(ToolbarAction.none)
                                ForEach(ToolbarAction.assignable) { action in
                                    Label(QuickActions.title(action), systemImage: QuickActions.symbol(action)).tag(action)
                                }
                            } label: {
                                Text("长按").foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
                Button("恢复默认布局") { services.prefs.toolbarLayout = .default }
            } header: {
                Text("底部工具栏（iPhone）")
            } footer: {
                Text("从左到右 5 个按钮。菜单按钮必须保留（设置从这里进入），如果被替换，最后一个按钮会自动变回菜单。")
            }
            Section {
                Toggle("左右滑动地址栏切换标签页", isOn: $services.prefs.swipeAddressBarSwitchesTabs)
                Picker("在工具栏上向上滑", selection: $services.prefs.swipeUpToolbarAction) {
                    Text("无").tag(ToolbarAction.none)
                    ForEach(ToolbarAction.assignable) { Text(QuickActions.title($0)).tag($0) }
                }
                Picker("双击地址栏", selection: $services.prefs.doubleTapAddressBarAction) {
                    Text("无").tag(ToolbarAction.none)
                    ForEach(ToolbarAction.assignable) { Text(QuickActions.title($0)).tag($0) }
                }
            } header: {
                Text("手势")
            } footer: {
                Text("设置了双击动作后，单击地址栏进入编辑会有很短的延迟。")
            }
        }
        .navigationTitle("工具栏与手势")
    }

    private func defaultLongPressTitle(_ button: ToolbarAction) -> String {
        switch button {
        case .back, .forward: return "默认（历史列表）"
        case .tabSwitcher: return "默认（标签页菜单）"
        default: return "默认（打开此设置）"
        }
    }

    private func setButton(_ index: Int, _ action: ToolbarAction) {
        var l = layout
        l.buttons[index] = action
        services.prefs.toolbarLayout = l.normalized
        if index == 2 { services.prefs.quickActions = [action] }
    }

    private func setLongPress(_ index: Int, _ action: ToolbarAction) {
        var l = layout
        l.longPress[index] = action
        services.prefs.toolbarLayout = l.normalized
    }
}

/// Sheet wrapper (long press on a toolbar button without an assigned long-press action).
struct QuickActionPicker: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ToolbarCustomizeView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
