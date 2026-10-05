import SwiftUI

/// Safari-like tab overview with tab groups and private browsing (spec §4).
struct TabSwitcherView: View {
    @EnvironmentObject private var manager: TabManager
    @Environment(\.dismiss) private var dismiss
    @State private var renamingGroup: TabGroupSnapshot?
    @State private var newGroupName = ""
    @State private var showNewGroup = false
    @State private var search = ""
    @State private var showManageGroups = false

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 14)]

    private var filtered: [BrowserTab] {
        let tabs = manager.visibleTabs.sorted { ($0.pinned ? 0 : 1) < ($1.pinned ? 0 : 1) }
        guard !search.isEmpty else { return tabs }
        return tabs.filter { $0.title.localizedCaseInsensitiveContains(search) || ($0.url?.absoluteString ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if filtered.isEmpty {
                        VStack(spacing: 10) {
                            Image(icon: manager.isPrivateMode ? "hand.raised" : "square.on.square").font(.largeTitle).foregroundStyle(.secondary)
                            Text(manager.isPrivateMode ? "无痕浏览：不会记录历史、Cookie 和搜索记录" : "没有标签页").foregroundStyle(.secondary)
                        }
                        .padding(.top, 80)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filtered) { tab in
                            TabCard(tab: tab, active: tab.id == manager.activeTabID) {
                                manager.select(tab)
                                dismiss()
                            } close: {
                                withAnimation { manager.close(tab) }
                            }
                            .id(tab.id)
                            .contextMenu { TabContextMenu(tab: tab) }
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first, let dragged = manager.tabs.first(where: { $0.id.uuidString == raw }) else { return false }
                                withAnimation { manager.move(dragged, before: tab) }
                                return true
                            }
                        }
                    }
                    .padding(14)
                }
                // Open on the tab that was just being viewed instead of the top of the grid.
                // Deferred one run-loop turn so the lazy grid has laid out before scrolling.
                .onAppear { DispatchQueue.main.async { scrollToActive(proxy) } }
                .onChange(of: manager.currentSpaceTitle) { scrollToActive(proxy) }
            }
            .searchable(text: $search, prompt: "搜索标签页")
            .background(manager.isPrivateMode ? Color(.systemGray6).opacity(0.9) : Color(.systemGroupedBackground))
            .navigationTitle(manager.currentSpaceTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if !manager.recentlyClosed.isEmpty {
                            Menu {
                                ForEach(manager.recentlyClosed.prefix(15)) { snapshot in
                                    Button(snapshot.title.isEmpty ? snapshot.url : snapshot.title) { manager.reopen(snapshot); dismiss() }
                                }
                            } label: { Label("最近关闭的标签页", icon: "arrow.uturn.backward") }
                        }
                        Button(role: .destructive) { manager.closeAll() } label: { Label("关闭全部 \(manager.visibleTabs.count) 个标签页", icon: "xmark") }
                        if let active = manager.activeTab {
                            Button { manager.closeOthers(than: active) } label: { Label("关闭其他标签页", icon: "xmark.square") }
                        }
                    } label: { Image(icon: "ellipsis.circle") }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { manager.newTab(); dismiss() } label: { Image(icon: "plus") }
                        .accessibilityIdentifier("switcherNewTab")
                    Spacer()
                    groupMenu
                    Spacer()
                    Button("完成") { dismiss() }.bold()
                }
            }
            .sheet(isPresented: $showManageGroups) { GroupOrderSheet().environmentObject(manager) }
            .alert("新建标签页组", isPresented: $showNewGroup) {
                TextField("名称", text: $newGroupName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let group = manager.createGroup(name: newGroupName)
                    manager.switchToGroup(group.id)
                    newGroupName = ""
                }
            }
            .alert("重命名标签页组", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
                TextField("名称", text: $newGroupName)
                Button("取消", role: .cancel) {}
                Button("好") { if let g = renamingGroup { manager.renameGroup(g.id, to: newGroupName) } }
            }
        }
    }

    private func scrollToActive(_ proxy: ScrollViewProxy) {
        guard search.isEmpty, let id = manager.activeTabID, filtered.contains(where: { $0.id == id }) else { return }
        proxy.scrollTo(id, anchor: .center)
    }

    private var groupMenu: some View {
        Menu {
            Section {
                Button { manager.switchToGroup(nil) } label: {
                    Label("\(manager.tabs(inGroup: nil).count) 个标签页", icon: !manager.isPrivateMode && manager.currentGroupID == nil ? "checkmark" : "square.on.square")
                }
                Button { manager.switchToPrivate() } label: {
                    Label("无痕浏览（\(manager.privateTabs.count)）", icon: manager.isPrivateMode ? "checkmark" : "hand.raised")
                }
            }
            Section("标签页组") {
                // Tapping a group switches to it (like Safari); editing is in its own submenu below.
                ForEach(manager.groups) { group in
                    Button { manager.switchToGroup(group.id) } label: {
                        Label("\(group.name)（\(manager.tabs(inGroup: group.id).count)）",
                              icon: !manager.isPrivateMode && manager.currentGroupID == group.id ? "checkmark" : "square.grid.2x2")
                    }
                }
                Button { showNewGroup = true } label: { Label("新建空白标签页组", icon: "plus") }
            }
            if !manager.groups.isEmpty {
                Section {
                    Menu {
                        ForEach(manager.groups) { group in
                            Menu(group.name) {
                                Button { newGroupName = group.name; renamingGroup = group } label: { Label("重命名", icon: "pencil") }
                                Button(role: .destructive) { manager.deleteGroup(group.id, mode: .moveTabsToDefault) } label: { Label("删除组（标签页移到“标签页”）", icon: "folder.badge.minus") }
                                Button(role: .destructive) { manager.deleteGroup(group.id, mode: .closeTabs) } label: { Label("删除组并关闭其中标签页", icon: "trash") }
                            }
                        }
                        if manager.groups.count > 1 { Button { showManageGroups = true } label: { Label("调整组顺序…", icon: "arrow.up.arrow.down") } }
                    } label: { Label("编辑标签页组", icon: "slider.horizontal.3") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(manager.currentSpaceTitle).font(.headline)
                Image(icon: "chevron.down").font(.caption)
            }
        }
        .accessibilityIdentifier("groupMenu")
    }
}

struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let active: Bool
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = tab.thumbnail, !tab.isHome {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color(.secondarySystemBackground)
                            Image(icon: tab.isHome ? "house" : "globe").font(.largeTitle).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(active ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 3))
                .onTapGesture(perform: open)
                // 28 pt visible badge inside a 44 pt hit area (Apple's minimum touch target).
                Button(action: close) {
                    Image(icon: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.6), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 0.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭标签页")
            }
            HStack(spacing: 5) {
                if tab.pinned { Image(icon: "pin.fill").font(.caption2) }
                if let icon = tab.favicon { Image(uiImage: icon).resizable().frame(width: 14, height: 14) }
                Text(tab.isHome ? "起始页" : tab.title).font(.caption).lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabCard")
    }
}

/// Reorder / rename / delete tab groups.
struct GroupOrderSheet: View {
    @EnvironmentObject private var manager: TabManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.groups) { group in
                    HStack {
                        Label(group.name, icon: "square.grid.2x2")
                        Spacer()
                        Text("\(manager.tabs(inGroup: group.id).count)").foregroundStyle(.secondary)
                    }
                }
                .onMove { manager.reorderGroups(from: $0, to: $1) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("标签页组顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
