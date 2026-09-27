import SwiftUI

/// Auxiliary iPad windows do not own a second WKWebView stack.
/// Their tabs are `BrowserTab`s on the active `BrowserSession`, so userscripts,
/// content rules, downloads, find, reader, and the page menu run there too.
@MainActor final class WindowRegistry: ObservableObject {
    @Published var selection: [UUID: UUID] = [:]
    private var hidden: Set<UUID> = []

    func select(_ tabID: UUID, in windowID: UUID) { selection[windowID] = tabID }
    func replace(_ tabID: UUID?, in windowID: UUID) {
        if let tabID { selection[windowID] = tabID }
        else { selection.removeValue(forKey: windowID) }
    }
    func markVisible(_ windowID: UUID) { hidden.remove(windowID) }
    func markHidden(_ windowID: UUID) { hidden.insert(windowID) }
    func isHidden(_ windowID: UUID) -> Bool { hidden.contains(windowID) }
    func forget(_ windowID: UUID) {
        selection.removeValue(forKey: windowID)
        hidden.remove(windowID)
    }
}

struct AuxiliaryBrowserView: View {
    @EnvironmentObject private var model: AppModel
    var windowID: UUID?
    @State private var panel: BrowserPanel?

    var body: some View {
        Group {
            if let windowID, let session = model.session {
                AuxiliaryWindowPage(windowID: windowID, session: session, windows: model.windows, panel: $panel)
            } else {
                ContentUnavailableView("这个窗口没有页面", systemImage: "macwindow", description: Text("从主窗口的「新窗口」打开。这个窗口里的页面使用当前身份的标签、脚本、广告过滤和下载。"))
            }
        }
        .sheet(item: $panel) { item in
            if let session = model.session {
                switch item {
                case .addons: AddonsView(session: session)
                case .profiles: ProfilesView()
                case .tabs: TabsView(session: session, windowID: windowID)
                case .library: LibraryView(session: session)
                case .settings: SettingsView(session: session)
                case .commands: CommandsView(session: session)
                }
            }
        }
    }
}

struct AuxiliaryWindowPage: View {
    @EnvironmentObject private var model: AppModel
    let windowID: UUID
    @ObservedObject var session: BrowserSession
    @ObservedObject var windows: WindowRegistry
    @Binding var panel: BrowserPanel?
    @Environment(\.scenePhase) private var scenePhase

    private var tabs: [BrowserTab] { session.tabs.filter { $0.windowID == windowID } }
    private var selected: BrowserTab? { tabs.first { $0.id == windows.selection[windowID] } ?? tabs.first }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs) { tab in
                        HStack(spacing: 4) {
                            Button(tab.pageTitle) { focus(tab) }
                                .font(.subheadline.weight(tab.id == selected?.id ? .bold : .regular))
                                .lineLimit(1)
                            Button { session.close(tab) } label: { Image(systemName: "xmark").font(.caption2) }
                                .accessibilityLabel("关闭标签")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(tab.id == selected?.id ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                    }
                    Button { _ = session.addTab(activate: true, windowID: windowID) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("这个窗口的新标签")
                    Menu {
                        Button("关闭其他") { if let selected { session.closeOthers(keeping: selected) } }
                        Button("关闭全部", role: .destructive) { session.closeAllTabs(in: windowID) }
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("整理这个窗口的标签")
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
            if let selected {
                BrowserPage(tab: selected, session: session, openPanel: { panel = $0 }).id(selected.id)
            } else {
                ContentUnavailableView("没有标签", systemImage: "plus", description: Text("点加号在这个窗口打开新标签。脚本、广告过滤、查找、阅读模式和下载与主窗口相同。"))
            }
        }
        .onAppear {
            model.windows.markVisible(windowID)
            if let selected { focus(selected) }
        }
        .onDisappear {
            let id = windowID
            let leaving = scenePhase != .active
            guard leaving else { return }
            model.windows.markHidden(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard model.windows.isHidden(id), let session = model.session else { return }
                for tab in session.tabs.filter({ $0.windowID == id }) { session.close(tab) }
                model.windows.forget(id)
            }
        }
    }

    private func focus(_ tab: BrowserTab) {
        windows.select(tab.id, in: windowID)
        let previous = session.tabs.first { $0.id == session.selectedID }
        session.activateFromWindow(tab)
    }
}
