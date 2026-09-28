import Foundation
import WebKit
import Combine
import UIKit

/// Window-level tab state: tabs, Safari-like tab groups, private tabs and recently closed tabs.
@MainActor final class TabManager: ObservableObject, Identifiable {
    let windowID: UUID
    let numericID: Int
    private(set) var profile: ProfileContext
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var groups: [TabGroupSnapshot] = []
    /// nil = the default "标签页" group.
    @Published var currentGroupID: UUID?
    @Published var isPrivateMode = false
    @Published private(set) var activeTabID: UUID?
    @Published private(set) var recentlyClosed: [TabSnapshot] = []
    private var saveWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    var id: UUID { windowID }

    init(windowID: UUID, profile: ProfileContext) {
        self.windowID = windowID
        numericID = TabRegistry.shared.allocateWindowID()
        self.profile = profile
        TabRegistry.shared.register(self)
        restore()
        NotificationCenter.default.publisher(for: .rikuganProfileDidChange).sink { [weak self] _ in
            Task { @MainActor in self?.profileDidChange() }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification).sink { [weak self] _ in
            Task { @MainActor in
                ErrorLog.shared.record("Memory warning: suspending background tabs", source: "TabManager")
                self?.enforceLifecycle(memoryPressure: true)
            }
        }.store(in: &cancellables)
    }

    private var sessionFile: JSONFile<WindowSessionSnapshot> {
        JSONFile(AppPaths.directory("Sessions", in: profile.directory).appendingPathComponent(windowID.uuidString + ".json"))
    }

    // MARK: Derived state

    var activeTab: BrowserTab? { tabs.first { $0.id == activeTabID } }

    /// Tabs visible in the current space (group or private mode).
    var visibleTabs: [BrowserTab] {
        tabs.filter { isPrivateMode ? $0.isPrivate : (!$0.isPrivate && $0.groupID == currentGroupID) }
    }

    var privateTabs: [BrowserTab] { tabs.filter(\.isPrivate) }

    func tabs(inGroup id: UUID?) -> [BrowserTab] { tabs.filter { !$0.isPrivate && $0.groupID == id } }

    var currentSpaceTitle: String {
        if isPrivateMode { return "无痕浏览" }
        return groups.first { $0.id == currentGroupID }?.name ?? "标签页"
    }

    // MARK: Tab operations

    @discardableResult
    func newTab(url: URL? = nil, background: Bool = false, isPrivate: Bool? = nil, opener: BrowserTab? = nil,
                configuration: WKWebViewConfiguration? = nil, insertAfterOpener: Bool = true) -> BrowserTab {
        let privateTab = isPrivate ?? isPrivateMode
        let snapshot = TabSnapshot(url: "", title: "新标签页", groupID: privateTab ? nil : currentGroupID)
        let tab = BrowserTab(snapshot: snapshot, profile: profile, isPrivate: privateTab, configuration: configuration)
        tab.manager = self
        tab.opener = opener
        if let opener, insertAfterOpener, let index = tabs.firstIndex(where: { $0.id == opener.id }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if let url { tab.load(url) }
        if !background {
            if privateTab != isPrivateMode { isPrivateMode = privateTab }
            select(tab)
        }
        profile.extensions.tabCreated(tab)
        scheduleSave()
        return tab
    }

    func select(_ tab: BrowserTab) {
        let previous = activeTab
        guard previous?.id != tab.id else { tab.activate(); return }
        previous?.captureThumbnail()
        previous?.deactivate()
        activeTabID = tab.id
        if !tab.isPrivate { currentGroupID = tab.groupID }
        isPrivateMode = tab.isPrivate
        tab.activate()
        TabRegistry.shared.focus(self)
        profile.extensions.tabActivated(tab, previous: previous)
        enforceLifecycle(memoryPressure: false)
        scheduleSave()
    }

    // MARK: Lifecycle (live / suspended web views)

    var lifecyclePolicy: TabLifecyclePolicy {
        TabLifecyclePolicy(maxLiveBackground: max(0, AppServices.shared.prefs.maxLiveBackgroundTabs), maxLiveBackgroundUnderPressure: 0)
    }

    /// Suspends least-recently-used background web views beyond the policy limit.
    func enforceLifecycle(memoryPressure: Bool) {
        let candidates = tabs.map {
            TabLifecyclePolicy.Candidate(id: $0.id, isActive: $0.id == activeTabID, isLive: $0.isLive, lastActiveAt: $0.lastActiveAt,
                                         keepAliveHint: $0.pinned || $0.isLoading)
        }
        let victims = lifecyclePolicy.tabsToSuspend(candidates, memoryPressure: memoryPressure)
        guard !victims.isEmpty else { return }
        for tab in tabs where victims.contains(tab.id) {
            Task { await tab.suspend() }
        }
    }

    var liveTabCount: Int { tabs.filter(\.isLive).count }
    var suspendedTabCount: Int { tabs.filter { !$0.isLive && ($0.url != nil) }.count }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if !tab.isPrivate, !(tab.url == nil && tab.webView == nil) {
            recentlyClosed.insert(tab.snapshot, at: 0)
            recentlyClosed = Array(recentlyClosed.prefix(30))
            profile.extensions.sessionsChanged()
        }
        let wasActive = tab.id == activeTabID
        let space = tabs.filter { $0.isPrivate == tab.isPrivate && (tab.isPrivate || $0.groupID == tab.groupID) }
        tabs.remove(at: index)
        TabThumbnailStore.remove(tab.id)
        profile.extensions.tabRemoved(tab)
        tab.teardown()
        if tab.isPrivate { profile.releasePrivateStoreIfUnused() }
        if wasActive {
            let remaining = space.filter { $0.id != tab.id }
            if let opener = tab.opener, remaining.contains(where: { $0.id == opener.id }) {
                select(opener)
            } else if let next = remaining.sorted(by: { $0.lastActiveAt > $1.lastActiveAt }).first {
                select(next)
            } else if tab.isPrivate {
                isPrivateMode = false
                if let other = visibleTabs.max(by: { $0.lastActiveAt < $1.lastActiveAt }) { select(other) } else { newTab(isPrivate: false) }
            } else {
                newTab(isPrivate: false)
            }
        }
        scheduleSave()
    }

    func closeAll(inCurrentSpace: Bool = true) {
        for tab in (inCurrentSpace ? visibleTabs : tabs) { close(tab) }
    }

    func closeOthers(than keep: BrowserTab) {
        for tab in visibleTabs where tab.id != keep.id && !tab.pinned { close(tab) }
    }

    func reopenLastClosed() {
        guard !recentlyClosed.isEmpty else { return }
        let snapshot = recentlyClosed.removeFirst()
        reopen(snapshot)
    }

    func reopen(_ snapshot: TabSnapshot) {
        recentlyClosed.removeAll { $0.id == snapshot.id }
        var copy = snapshot
        copy.id = UUID()
        if let group = copy.groupID, !groups.contains(where: { $0.id == group }) { copy.groupID = nil }
        let tab = BrowserTab(snapshot: copy, profile: profile, isPrivate: false)
        tab.manager = self
        tabs.append(tab)
        select(tab)
        scheduleSave()
        profile.extensions.sessionsChanged()
    }

    func duplicate(_ tab: BrowserTab) {
        var snapshot = tab.snapshot
        snapshot.id = UUID()
        let copy = BrowserTab(snapshot: snapshot, profile: profile, isPrivate: tab.isPrivate)
        copy.manager = self
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) { tabs.insert(copy, at: index + 1) } else { tabs.append(copy) }
        select(copy)
    }

    /// Reorders tabs inside the current group / private space.
    func move(from source: IndexSet, to destination: Int) {
        if isPrivateMode {
            var visible = privateTabs
            visible.rkMove(fromOffsets: source, toOffset: destination)
            tabs = tabs.filter { !$0.isPrivate } + visible
            scheduleSave()
            return
        }
        let group = currentGroupID
        applySessionOp { SessionOps.reorderTabs(&$0, inGroup: group, from: source, to: destination) }
    }

    /// chrome.tabs.move: places a (non-private) tab at `index` among the window's non-private tabs
    /// (-1 = end). Returns the final index.
    @discardableResult
    func moveTab(_ tab: BrowserTab, toIndex index: Int) -> Int {
        guard !tab.isPrivate, let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return 0 }
        var list = tabs
        list.remove(at: from)
        let normal = list.filter { !$0.isPrivate }
        let target = index < 0 || index >= normal.count ? normal.count : index
        let insertAt = target < normal.count ? (list.firstIndex { $0.id == normal[target].id } ?? list.count) : list.count
        list.insert(tab, at: insertAt)
        tabs = list
        scheduleSave()
        return tabs.filter { !$0.isPrivate }.firstIndex { $0.id == tab.id } ?? target
    }

    /// Drag & drop reorder: place `tab` before `target` (same group / space).
    func move(_ tab: BrowserTab, before target: BrowserTab) {
        let space = isPrivateMode ? privateTabs : tabs(inGroup: currentGroupID)
        guard let from = space.firstIndex(where: { $0.id == tab.id }), let to = space.firstIndex(where: { $0.id == target.id }), from != to else { return }
        move(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }

    func togglePin(_ tab: BrowserTab) {
        tab.pinned.toggle()
        scheduleSave()
    }

    // MARK: Groups (Safari-like) — all mutations go through SessionOps (unit-tested model)

    /// Applies a SessionOps mutation to the live tab list, preserving private tabs separately.
    private func applySessionOp(_ op: (inout WindowSessionSnapshot) -> Void) {
        var snapshot = WindowSessionSnapshot()
        let normal = tabs.filter { !$0.isPrivate }
        snapshot.tabs = normal.map { TabSnapshot(id: $0.id, url: "", title: "", groupID: $0.groupID, lastActiveAt: $0.lastActiveAt) }
        snapshot.groups = groups
        snapshot.selectedGroupID = currentGroupID
        snapshot.selectedTabID = activeTab?.isPrivate == true ? nil : activeTabID
        op(&snapshot)
        let remaining = Set(snapshot.tabs.map(\.id))
        let closed = normal.filter { !remaining.contains($0.id) }
        groups = snapshot.groups
        let byID = Dictionary(uniqueKeysWithValues: normal.map { ($0.id, $0) })
        var ordered: [BrowserTab] = []
        for entry in snapshot.tabs {
            guard let tab = byID[entry.id] else { continue }
            if tab.groupID != entry.groupID { tab.groupID = entry.groupID }
            ordered.append(tab)
        }
        // Keep removed tabs in the list until `close` runs: it needs to find them to tear them down,
        // record them as recently closed and notify extensions (otherwise their web views leak).
        tabs = ordered + closed + tabs.filter(\.isPrivate)
        for tab in closed { close(tab) }
        if let group = currentGroupID, !groups.contains(where: { $0.id == group }) { switchToGroup(nil) }
        objectWillChange.send()
        scheduleSave()
    }

    @discardableResult
    func createGroup(name: String, moving tab: BrowserTab? = nil) -> TabGroupSnapshot {
        var created = TabGroupSnapshot(name: name)
        applySessionOp { created = SessionOps.createGroup(&$0, name: name) }
        if let tab { move(tab, toGroup: created.id) }
        return created
    }

    func renameGroup(_ id: UUID, to name: String) {
        applySessionOp { SessionOps.renameGroup(&$0, id, to: name) }
    }

    func reorderGroups(from source: IndexSet, to destination: Int) {
        applySessionOp { SessionOps.reorderGroups(&$0, from: source, to: destination) }
    }

    /// Deletes a group; its tabs are either closed or moved to the default group (never silently lost).
    func deleteGroup(_ id: UUID, mode: SessionOps.GroupDeletion = .closeTabs) {
        let wasCurrent = currentGroupID == id
        applySessionOp { SessionOps.deleteGroup(&$0, id, mode: mode) }
        if wasCurrent { switchToGroup(nil) }
    }

    func move(_ tab: BrowserTab, toGroup id: UUID?) {
        guard !tab.isPrivate else { return }
        let wasActive = tab.id == activeTabID
        applySessionOp { SessionOps.moveTab(&$0, tab.id, toGroup: id) }
        if wasActive, tab.groupID != currentGroupID {
            // Keep the moved tab focused and follow it into its new group.
            currentGroupID = tab.groupID
        }
    }

    func switchToGroup(_ id: UUID?) {
        isPrivateMode = false
        currentGroupID = id
        if let last = tabs(inGroup: id).max(by: { $0.lastActiveAt < $1.lastActiveAt }) { select(last) }
        else { newTab(isPrivate: false) }
    }

    func switchToPrivate() {
        isPrivateMode = true
        if let last = privateTabs.max(by: { $0.lastActiveAt < $1.lastActiveAt }) { select(last) }
        else { newTab(isPrivate: true) }
    }

    // MARK: Persistence

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    var sessionSnapshot: WindowSessionSnapshot {
        var snapshot = WindowSessionSnapshot()
        snapshot.tabs = tabs.filter { !$0.isPrivate }.map(\.snapshot)
        snapshot.groups = groups
        snapshot.selectedTabID = activeTab?.isPrivate == true ? nil : activeTabID
        snapshot.selectedGroupID = currentGroupID
        return snapshot
    }

    func save() {
        guard AppServices.shared.prefs.restoreTabs else { sessionFile.save(WindowSessionSnapshot()); return }
        sessionFile.save(sessionSnapshot)
    }

    private func restore() {
        let snapshot = AppServices.shared.prefs.restoreTabs ? (sessionFile.load() ?? Self.adoptOrphanSession(profile: profile)) : nil
        apply(snapshot ?? WindowSessionSnapshot())
    }

    /// A new window of a freshly-launched app adopts the most recent orphaned session file.
    private static func adoptOrphanSession(profile: ProfileContext) -> WindowSessionSnapshot? {
        let dir = AppPaths.directory("Sessions", in: profile.directory)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let openIDs = Set(TabRegistry.shared.allWindows.map { $0.windowID.uuidString + ".json" })
        let candidates = files.filter { !openIDs.contains($0.lastPathComponent) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                      ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let file = candidates.first, let snapshot = JSONFile<WindowSessionSnapshot>(file).load() else { return nil }
        try? FileManager.default.removeItem(at: file)
        return snapshot
    }

    func apply(_ original: WindowSessionSnapshot) {
        var snapshot = original
        SessionOps.repair(&snapshot)
        for tab in tabs { tab.teardown() }
        groups = snapshot.groups
        tabs = snapshot.tabs.map { saved in
            let tab = BrowserTab(snapshot: saved, profile: profile, isPrivate: false)
            tab.manager = self
            return tab
        }
        currentGroupID = snapshot.selectedGroupID.flatMap { id in groups.contains { $0.id == id } ? id : nil }
        isPrivateMode = false
        if let selected = tabs.first(where: { $0.id == snapshot.selectedTabID }) ?? tabs(inGroup: currentGroupID).last {
            select(selected)
        } else {
            newTab(isPrivate: false)
        }
    }

    /// Imported tabs & groups are appended (spec §39).
    func importSession(_ snapshot: WindowSessionSnapshot) {
        var groupMap: [UUID: UUID] = [:]
        for group in snapshot.groups {
            if let existing = groups.first(where: { $0.name == group.name }) { groupMap[group.id] = existing.id }
            else { let g = TabGroupSnapshot(name: group.name); groups.append(g); groupMap[group.id] = g.id }
        }
        for saved in snapshot.tabs where !saved.url.isEmpty {
            var copy = saved
            copy.id = UUID()
            copy.groupID = saved.groupID.flatMap { groupMap[$0] }
            let tab = BrowserTab(snapshot: copy, profile: profile, isPrivate: false)
            tab.manager = self
            tabs.append(tab)
        }
        scheduleSave()
    }

    private func profileDidChange() {
        save()
        for tab in tabs { profile.extensions.tabRemoved(tab); tab.teardown() }
        tabs.removeAll()
        profile = AppServices.shared.profile
        recentlyClosed.removeAll()
        restore()
    }

    func windowWillClose() {
        save()
        for tab in tabs { profile.extensions.tabRemoved(tab); tab.teardown() }
        TabRegistry.shared.unregister(self)
    }
}
