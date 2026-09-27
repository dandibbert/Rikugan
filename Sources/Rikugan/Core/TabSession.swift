import Foundation

/// Lifecycle of a tab's web content.
///
/// - `active`: the selected tab of a window; always has a live WKWebView.
/// - `liveBackground`: not selected, WKWebView kept alive (recently used).
/// - `suspended`: WKWebView released; URL / title / history state / scroll position / snapshot kept.
/// - `restoring`: a new WKWebView is being created from the saved state.
/// - `terminated`: the WebContent process died; the page must be reloaded (JS heap, WebSockets
///   and unsaved in-page state are lost — this is not hidden from the user).
public enum TabLifecycleState: String, Codable, CaseIterable {
    case active, liveBackground, suspended, restoring, terminated
}

/// Pure eviction policy deciding which background tabs keep a live WKWebView.
public struct TabLifecyclePolicy: Equatable {
    /// Maximum number of live background web views per window under normal conditions.
    public var maxLiveBackground: Int
    /// Maximum under memory pressure.
    public var maxLiveBackgroundUnderPressure: Int

    public init(maxLiveBackground: Int = 5, maxLiveBackgroundUnderPressure: Int = 0) {
        self.maxLiveBackground = maxLiveBackground
        self.maxLiveBackgroundUnderPressure = maxLiveBackgroundUnderPressure
    }

    public struct Candidate: Equatable {
        public let id: UUID
        public let isActive: Bool
        public let isLive: Bool
        public let lastActiveAt: Date
        /// Tabs playing media / with active downloads / pinned are kept live longer.
        public let keepAliveHint: Bool
        public init(id: UUID, isActive: Bool, isLive: Bool, lastActiveAt: Date, keepAliveHint: Bool = false) {
            self.id = id; self.isActive = isActive; self.isLive = isLive; self.lastActiveAt = lastActiveAt; self.keepAliveHint = keepAliveHint
        }
    }

    /// Returns the IDs of live tabs that must be suspended.
    public func tabsToSuspend(_ tabs: [Candidate], memoryPressure: Bool) -> [UUID] {
        let limit = memoryPressure ? maxLiveBackgroundUnderPressure : maxLiveBackground
        let background = tabs.filter { $0.isLive && !$0.isActive }
            .sorted { lhs, rhs in
                if lhs.keepAliveHint != rhs.keepAliveHint && !memoryPressure { return lhs.keepAliveHint }
                return lhs.lastActiveAt > rhs.lastActiveAt
            }
        guard background.count > limit else { return [] }
        return background[limit...].map(\.id)
    }
}

/// Order-preserving operations on a window session (tabs + Safari-style groups). All tab-group
/// manipulation goes through these functions so the app and the unit tests share one model.
public enum SessionOps {
    public enum GroupDeletion: String, Codable { case closeTabs, moveTabsToDefault }

    public static func tabs(_ s: WindowSessionSnapshot, inGroup group: UUID?) -> [TabSnapshot] {
        s.tabs.filter { $0.groupID == group }
    }

    @discardableResult
    public static func createGroup(_ s: inout WindowSessionSnapshot, name: String) -> TabGroupSnapshot {
        let group = TabGroupSnapshot(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名组" : name)
        s.groups.append(group)
        return group
    }

    public static func renameGroup(_ s: inout WindowSessionSnapshot, _ id: UUID, to name: String) {
        guard let i = s.groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        s.groups[i].name = trimmed.isEmpty ? s.groups[i].name : trimmed
    }

    public static func reorderGroups(_ s: inout WindowSessionSnapshot, from source: IndexSet, to destination: Int) {
        s.groups.rkMove(fromOffsets: source, toOffset: destination)
    }

    /// Deletes a group. Returns the IDs of tabs that were closed (empty when moved).
    @discardableResult
    public static func deleteGroup(_ s: inout WindowSessionSnapshot, _ id: UUID, mode: GroupDeletion) -> [UUID] {
        guard s.groups.contains(where: { $0.id == id }) else { return [] }
        var closed: [UUID] = []
        switch mode {
        case .closeTabs:
            closed = s.tabs.filter { $0.groupID == id }.map(\.id)
            s.tabs.removeAll { $0.groupID == id }
        case .moveTabsToDefault:
            for i in s.tabs.indices where s.tabs[i].groupID == id { s.tabs[i].groupID = nil }
        }
        s.groups.removeAll { $0.id == id }
        if s.selectedGroupID == id { s.selectedGroupID = nil }
        if let selected = s.selectedTabID, closed.contains(selected) {
            s.selectedTabID = s.tabs.filter { $0.groupID == nil }.max { $0.lastActiveAt < $1.lastActiveAt }?.id
        }
        return closed
    }

    /// Moves a tab to another group, appending it at the end of that group.
    public static func moveTab(_ s: inout WindowSessionSnapshot, _ tabID: UUID, toGroup group: UUID?) {
        guard let i = s.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if let group, !s.groups.contains(where: { $0.id == group }) { return }
        var tab = s.tabs.remove(at: i)
        tab.groupID = group
        if let last = s.tabs.lastIndex(where: { $0.groupID == group }) { s.tabs.insert(tab, at: last + 1) } else { s.tabs.append(tab) }
    }

    /// Reorders tabs *within* one group; positions of tabs in other groups are unchanged.
    public static func reorderTabs(_ s: inout WindowSessionSnapshot, inGroup group: UUID?, from source: IndexSet, to destination: Int) {
        let positions = s.tabs.indices.filter { s.tabs[$0].groupID == group }
        var members = positions.map { s.tabs[$0] }
        members.rkMove(fromOffsets: source, toOffset: destination)
        for (slot, tab) in zip(positions, members) { s.tabs[slot] = tab }
    }

    /// Validates invariants: unique tab IDs, every groupID refers to an existing group, selection valid.
    public static func validate(_ s: WindowSessionSnapshot) -> [String] {
        var problems: [String] = []
        let groupIDs = Set(s.groups.map(\.id))
        if Set(s.tabs.map(\.id)).count != s.tabs.count { problems.append("duplicate tab id") }
        if Set(s.groups.map(\.id)).count != s.groups.count { problems.append("duplicate group id") }
        for tab in s.tabs { if let g = tab.groupID, !groupIDs.contains(g) { problems.append("tab \(tab.id) references missing group") } }
        if let g = s.selectedGroupID, !groupIDs.contains(g) { problems.append("selected group missing") }
        if let t = s.selectedTabID, !s.tabs.contains(where: { $0.id == t }) { problems.append("selected tab missing") }
        return problems
    }

    /// Repairs an invalid snapshot (used after import / corrupted state).
    public static func repair(_ s: inout WindowSessionSnapshot) {
        var seenGroups = Set<UUID>()
        s.groups = s.groups.filter { seenGroups.insert($0.id).inserted }
        var seenTabs = Set<UUID>()
        s.tabs = s.tabs.filter { seenTabs.insert($0.id).inserted }
        for i in s.tabs.indices { if let g = s.tabs[i].groupID, !seenGroups.contains(g) { s.tabs[i].groupID = nil } }
        if let g = s.selectedGroupID, !seenGroups.contains(g) { s.selectedGroupID = nil }
        if let t = s.selectedTabID, !seenTabs.contains(t) { s.selectedTabID = nil }
    }
}

public extension Array {
    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`, without depending on SwiftUI.
    mutating func rkMove(fromOffsets source: IndexSet, toOffset destination: Int) {
        let valid = source.filter { $0 >= 0 && $0 < count }
        guard !valid.isEmpty else { return }
        let moving = valid.map { self[$0] }
        let adjusted = destination - valid.filter { $0 < destination }.count
        for index in valid.sorted(by: >) { remove(at: index) }
        insert(contentsOf: moving, at: Swift.max(0, Swift.min(adjusted, count)))
    }
}
