import Foundation
import UIKit
import WebKit

/// Tab lifecycle regression (spec §2): 36 tabs in 3 groups, LRU suspension, fast switching,
/// suspend / restore with history + scroll, close / reopen, WebContent termination handling,
/// group moves and deletion, session persistence, duplicate web views and leaks.
@MainActor enum LifecycleSuite {
    /// Deterministic pseudo-random sequence (no dependence on the system RNG).
    struct LCG { var state: UInt64; mutating func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) } }

    static func invariants(_ ctx: SelfTestContext, _ label: String) async -> Bool {
        let manager = ctx.manager
        let limit = max(0, ctx.services.prefs.maxLiveBackgroundTabs)
        // Suspension is asynchronous (scroll position is read first): wait for it to settle.
        _ = await ctx.waitUntil(10) { manager.tabs.filter { $0.isLive && $0.id != manager.activeTabID && !$0.isLoading }.count <= limit }
        let live = manager.tabs.filter(\.isLive)
        let liveBackground = live.filter { $0.id != manager.activeTabID }
        let webViewIDs = Set(live.compactMap { $0.webView.map(ObjectIdentifier.init) })
        let active = manager.tabs.filter { $0.lifecycle == .active }
        let registered = TabRegistry.shared.liveWebViewCount
        let allWindowsLive = TabRegistry.shared.allWindows.reduce(0) { $0 + $1.tabs.filter(\.isLive).count }
        let ok = liveBackground.filter { !$0.isLoading }.count <= limit && webViewIDs.count == live.count && active.count <= 1 && registered == allWindowsLive
        ctx.record("\(label)：不变量（后台存活 ≤ \(limit)、仅一个 active、无重复 WebView、注册表一致）", ok,
                   "live=\(live.count) liveBackground=\(liveBackground.count) uniqueWebViews=\(webViewIDs.count) active=\(active.count) registered=\(registered)/\(allWindowsLive) webViews=\(RikuganWebView.liveByPurpose)" +
                   (ok ? "" : " " + orphans(manager)))
        return ok
    }

    /// Describes tabs that are registered but not where they should be (for failure details).
    static func orphans(_ manager: TabManager) -> String {
        let inWindows = Set(TabRegistry.shared.allWindows.flatMap { $0.tabs.map(\.id) })
        let odd = TabRegistry.shared.allTabs.filter { !inWindows.contains($0.id) || ($0.lifecycle == .active && $0.id != manager.activeTabID) }
        return "odd=[" + odd.map { "\($0.url?.query ?? "home") inWindow=\(inWindows.contains($0.id)) lifecycle=\($0.lifecycle) live=\($0.isLive) manager=\($0.manager != nil)" }.joined(separator: "; ") + "]"
    }

    static func run(_ ctx: SelfTestContext) async {
        let manager = ctx.manager
        let savedLimit = ctx.services.prefs.maxLiveBackgroundTabs
        ctx.services.prefs.maxLiveBackgroundTabs = 5
        defer { ctx.services.prefs.maxLiveBackgroundTabs = savedLimit }
        let baselineWebViews = RikuganWebView.liveCount
        manager.switchToGroup(nil)
        for tab in manager.tabs where tab.id != manager.activeTabID { manager.close(tab) }

        // 1. 36 tabs across the default group and two named groups.
        let g1 = manager.createGroup(name: "Lifecycle A")
        let g2 = manager.createGroup(name: "Lifecycle B")
        var created: [BrowserTab] = []
        let start = Date()
        for i in 0..<36 {
            let tab = manager.newTab(url: ctx.url("/lifecycle/page.html?n=\(i)"), isPrivate: false)
            let group: UUID? = i % 3 == 0 ? nil : (i % 3 == 1 ? g1.id : g2.id)
            // Explicit for every tab: new tabs open in the *current* group, which follows the
            // active tab when it is moved.
            manager.move(tab, toGroup: group)
            _ = await ctx.waitLoaded(tab, path: "/lifecycle/page.html", seconds: 15)
            created.append(tab)
        }
        let loadedCount = created.filter { $0.url?.query?.hasPrefix("n=") == true }.count
        ctx.record("创建 36 个标签页（3 个组）", loadedCount == 36 && manager.tabs(inGroup: g1.id).count == 12 && manager.tabs(inGroup: g2.id).count == 12,
                   String(format: "loaded=%d groupA=%d groupB=%d in %.1fs", loadedCount, manager.tabs(inGroup: g1.id).count, manager.tabs(inGroup: g2.id).count, Date().timeIntervalSince(start)))
        _ = await invariants(ctx, "36 个标签页后")
        let suspended = created.filter { $0.lifecycle == .suspended }.count
        ctx.record("LRU 挂起旧标签页", suspended >= 36 - 1 - 5, "suspended=\(suspended)")
        ctx.extras["afterCreate"] = ["live": manager.liveTabCount, "suspended": suspended, "rikuganWebViews": RikuganWebView.liveCount]

        // 2. Fast switching without waiting for loads.
        var rng = LCG(state: 42)
        for _ in 0..<80 { manager.select(created[rng.next(created.count)]) }
        let target = created[rng.next(created.count)]
        manager.select(target)
        let restored = await ctx.waitLoaded(target, path: "/lifecycle/page.html", seconds: 15)
        ctx.record("快速切换 80 次后当前标签页恢复", restored && target.lifecycle == .active, "lifecycle=\(target.lifecycle) url=\(target.webView?.url?.query ?? "nil")")
        _ = await invariants(ctx, "快速切换后")

        // 3. Suspend / restore keeps history and scroll position.
        let hist = created[1]
        manager.select(hist)
        _ = await ctx.waitLoaded(hist, path: "/lifecycle/page.html")
        hist.load(ctx.url("/lifecycle/page.html?n=hist2&tall=1"))
        _ = await ctx.waitLoaded(hist, path: "/lifecycle/page.html", query: "n=hist2&tall=1")
        _ = await ctx.eval(hist, "window.scrollTo(0, 1200); return window.scrollY;")
        _ = await ctx.waitUntil(3) { (await ctx.eval(hist, "return window.scrollY;") as? Double ?? 0) >= 1199 }
        // Visit other tabs like a user would (each one is shown and loads), which pushes `hist`
        // out of the live set. A burst of selections restores only the final tab by design.
        for other in created.filter({ $0.id != hist.id && $0.id != manager.activeTabID }).prefix(7) {
            manager.select(other)
            _ = await ctx.waitLoaded(other, path: "/lifecycle/page.html", seconds: 15)
        }
        let wasSuspended = await ctx.waitUntil(10) { hist.lifecycle == .suspended && !hist.isLive }
        ctx.record("标签页被挂起（WebView 释放）", wasSuspended, "lifecycle=\(hist.lifecycle) live=\(hist.isLive) suspendCount=\(hist.suspendCount)")
        let suspendedSnapshot = hist.snapshot
        ctx.record("挂起的标签页快照含网址、历史与滚动位置", suspendedSnapshot.url.contains("hist2") && (suspendedSnapshot.scrollY ?? 0) >= 1150 &&
                   suspendedSnapshot.interactionState != nil,
                   "url=\(URL(string: suspendedSnapshot.url)?.query ?? "nil") scrollY=\(suspendedSnapshot.scrollY ?? -1) history=\(suspendedSnapshot.interactionState?.count ?? 0) bytes")
        let restoresBefore = hist.restoreCount
        manager.select(hist)
        let back = await ctx.waitLoaded(hist, path: "/lifecycle/page.html", query: "n=hist2&tall=1")
        let scrolled = await ctx.waitUntil(5) { (await ctx.eval(hist, "return window.scrollY;") as? Double ?? 0) >= 1150 }
        let restoredY = await ctx.eval(hist, "return window.scrollY;") as? Double ?? -1
        ctx.record("恢复：同一网址 + 滚动位置", back && scrolled && hist.restoreCount == restoresBefore + 1,
                   "url=\(hist.webView?.url?.query ?? "nil") scrollY=\(restoredY) restores=\(hist.restoreCount)")
        let canGoBack = await ctx.waitUntil(3) { hist.webView?.canGoBack == true }
        hist.webView?.goBack()
        let wentBack = await ctx.waitUntil(10) { hist.webView?.url?.query == "n=1" && hist.webView?.isLoading == false }
        ctx.record("恢复：后退历史保留", canGoBack && wentBack, "canGoBack=\(canGoBack) url=\(hist.webView?.url?.query ?? "nil")")

        // 4. Close / reopen.
        let closing = created[4]
        let closingURL = closing.url
        let closingGroup = closing.groupID
        manager.close(closing)
        manager.reopenLastClosed()
        let reopened = manager.activeTab
        _ = await ctx.waitLoaded(reopened ?? closing, path: "/lifecycle/page.html")
        ctx.record("关闭后重新打开", reopened?.url == closingURL && reopened?.groupID == closingGroup && reopened?.id != closing.id,
                   "url=\(reopened?.url?.query ?? "nil") group=\(reopened?.groupID == closingGroup)")
        created.removeAll { $0.id == closing.id }
        if let reopened { created.append(reopened) }

        // 5. WebContent process termination. There is no public API to kill a WebContent process,
        //    so the delegate handler is invoked directly — this exercises Rikugan's recovery path.
        let bgLive = manager.tabs.first { $0.isLive && $0.id != manager.activeTabID }
        if let victim = bgLive {
            victim.contentProcessTerminated()
            ctx.record("后台标签页进程终止 → terminated、释放 WebView（处理函数直接调用）", victim.lifecycle == .terminated && !victim.isLive, "lifecycle=\(victim.lifecycle)")
            manager.select(victim)
            let recovered = await ctx.waitLoaded(victim, path: "/lifecycle/page.html")
            ctx.record("终止的标签页切回后重新加载", recovered && victim.lifecycle == .active, "lifecycle=\(victim.lifecycle)")
        } else {
            ctx.record("后台标签页进程终止", false, "no live background tab to test with")
        }
        if let active = manager.activeTab {
            active.contentProcessTerminated()
            let reloaded = await ctx.waitUntil(10) { active.lifecycle == .active && active.webView?.isLoading == false }
            ctx.record("当前标签页进程终止 → 原地重新加载", reloaded, "lifecycle=\(active.lifecycle)")
        }

        // 6. Group move / reorder / delete.
        let mover = created.first { $0.groupID == g1.id }!
        manager.move(mover, toGroup: g2.id)
        let movedOK = mover.groupID == g2.id && manager.tabs(inGroup: g2.id).last?.id == mover.id
        ctx.record("移动标签页到另一组（追加到末尾）", movedOK, "group=\(mover.groupID == g2.id) last=\(manager.tabs(inGroup: g2.id).last?.id == mover.id)")
        let order = manager.groups.map(\.id)
        manager.reorderGroups(from: IndexSet(integer: order.firstIndex(of: g2.id)!), to: 0)
        ctx.record("调整组顺序", manager.groups.first?.id == g2.id, manager.groups.map(\.name).joined(separator: ","))
        let aCount = manager.tabs(inGroup: g1.id).count
        let defaultBefore = manager.tabs(inGroup: nil).count
        manager.deleteGroup(g1.id, mode: .moveTabsToDefault)
        ctx.record("删除组（标签页移到默认组）", !manager.groups.contains { $0.id == g1.id } && manager.tabs(inGroup: nil).count == defaultBefore + aCount,
                   "moved=\(aCount) default=\(manager.tabs(inGroup: nil).count)")
        let bCount = manager.tabs(inGroup: g2.id).count
        let totalBefore = manager.tabs.count
        manager.deleteGroup(g2.id, mode: .closeTabs)
        ctx.record("删除组（关闭其标签页）", !manager.groups.contains { $0.id == g2.id } && manager.tabs.count <= totalBefore - bCount + 1,
                   "closed=\(bCount) total \(totalBefore)→\(manager.tabs.count)")

        // 7. Persistence: the session snapshot round-trips and validates.
        let g3 = manager.createGroup(name: "Persist")
        if let some = manager.tabs.first(where: { !$0.isPrivate }) { manager.move(some, toGroup: g3.id); manager.select(some) }
        let snapshot = manager.sessionSnapshot
        let decoded = (try? JSONEncoder().encode(snapshot)).flatMap { try? JSONDecoder().decode(WindowSessionSnapshot.self, from: $0) }
        ctx.record("会话快照：顺序 / 分组 / 当前组 / 当前标签页 可往返", decoded?.tabs.map(\.id) == manager.tabs.filter { !$0.isPrivate }.map(\.id) &&
                   decoded?.groups == manager.groups && decoded?.selectedTabID == manager.activeTabID && decoded?.selectedGroupID == g3.id &&
                   decoded.map { SessionOps.validate($0).isEmpty } == true,
                   "tabs=\(decoded?.tabs.count ?? -1) issues=\(decoded.map { SessionOps.validate($0) } ?? [])")

        // 8. Memory warning suspends every background tab.
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let pressure = await ctx.waitUntil(10) { manager.tabs.filter { $0.isLive && $0.id != manager.activeTabID }.isEmpty }
        ctx.record("内存警告：挂起全部后台标签页", pressure, "live=\(manager.liveTabCount)")

        // 9. Leaks: tabs opened and closed here are referenced only weakly by the test, so if
        //    anything in the app retains them (closures, delegates, registries) they stay alive.
        manager.closeAll(inCurrentSpace: false)
        created.removeAll()
        manager.switchToGroup(nil)
        var probes: [WeakBox<BrowserTab>] = []
        for i in 0..<6 {
            let tab = manager.newTab(url: ctx.url("/lifecycle/page.html?n=leak\(i)"), isPrivate: false)
            _ = await ctx.waitLoaded(tab, path: "/lifecycle/page.html")
            probes.append(WeakBox(tab))
        }
        for box in probes { if let tab = box.value { manager.close(tab) } }
        let tabsFreed = await ctx.waitUntil(10) { probes.allSatisfy { $0.value == nil } }
        let webViewsFreed = await ctx.waitUntil(15) { RikuganWebView.liveCount <= baselineWebViews }
        ctx.record("关闭后 BrowserTab 被释放（无循环引用）", tabsFreed, "alive=\(probes.filter { $0.value != nil }.count)/6")
        ctx.record("关闭后 WKWebView 数量回到基线", webViewsFreed,
                   "rikuganWebViews=\(RikuganWebView.liveCount) baseline=\(baselineWebViews) byPurpose=\(RikuganWebView.liveByPurpose) " + orphans(manager))
        manager.deleteGroup(g3.id, mode: .moveTabsToDefault)
        _ = await invariants(ctx, "清理后")
    }
}
