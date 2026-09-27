import Foundation
import WebKit

/// Userscript world semantics against a real page (spec §8):
/// `@grant none` → page world; granted scripts → isolated (page globals invisible, no leaks);
/// `unsafeWindow` → the real page window (read, write, call); `@inject-into page`;
/// and reload / pushState / iframe / popup navigation.
@MainActor enum PageWorldSuite {
    static let scripts = ["pageworld/none.user.js", "pageworld/isolated.user.js", "pageworld/unsafe.user.js", "pageworld/inject.user.js",
                          "pageworld/privileged-unsafe.user.js"]

    static func run(_ ctx: SelfTestContext) async {
        var installed: [InstalledUserScript] = []
        for path in scripts {
            do {
                let script = try ctx.installScript(path)
                ctx.profile.userscripts.replaceValues([:], for: script.id)
                installed.append(script)
            } catch { ctx.record("安装 \(path)", false, error.localizedDescription) }
        }
        let worlds = Dictionary(installed.map { ($0.metadata.name, $0.usesPageWorld ? "page" : "isolated") }, uniquingKeysWith: { a, _ in a })
        ctx.extras["worlds"] = worlds
        ctx.record("世界选择：@grant none → page", worlds["PW grant none"] == "page", worlds["PW grant none"] ?? "missing")
        ctx.record("世界选择：GM_* 无 unsafeWindow → isolated", worlds["PW isolated (granted)"] == "isolated", worlds["PW isolated (granted)"] ?? "missing")
        ctx.record("世界选择：仅无特权 grant（unsafeWindow + GM_addStyle）→ page", worlds["PW unsafeWindow"] == "page", worlds["PW unsafeWindow"] ?? "missing")
        ctx.record("世界选择：@inject-into page → page", worlds["PW inject-into page"] == "page", worlds["PW inject-into page"] ?? "missing")
        ctx.record("世界选择：特权 GM + unsafeWindow → isolated（安全）", worlds["PW privileged unsafeWindow"] == "isolated", worlds["PW privileged unsafeWindow"] ?? "missing")

        let tab = await ctx.open("/pageworld/index.html")
        ctx.record("测试页面加载", tab.webView?.url?.path == "/pageworld/index.html",
                   "url=\(tab.webView?.url?.absoluteString ?? "nil") loading=\(tab.webView?.isLoading ?? false) lifecycle=\(tab.lifecycle) title=\(tab.webView?.title ?? "nil") requested=\(ctx.server.requested("/pageworld/index.html"))")
        let markers = ["data-none-value", "data-iso-value", "data-unsafe-value", "data-inject-value", "data-pu-value"]
        let allRan = await ctx.waitUntil(10) { let a = await ctx.attrs(tab); return markers.allSatisfy { a[$0] != nil } }
        ctx.record("五个脚本均已注入", allRan, (await ctx.attrs(tab)).keys.filter { $0.hasPrefix("data-") }.sorted().joined(separator: ","))
        await checkDocument(ctx, tab, label: "首次加载", expectRuns: "1")

        // Events: page → scripts (all worlds share the DOM).
        _ = await ctx.eval(tab, "document.dispatchEvent(new CustomEvent('rk-page-event', { detail: 'hello' })); return true;")
        let events = await ctx.waitUntil(5) {
            let a = await ctx.attrs(tab)
            return a["data-none-event"] == "hello" && a["data-iso-event"] == "hello" && a["data-unsafe-event"] == "hello"
        }
        let a = await ctx.attrs(tab)
        ctx.record("页面事件 → 脚本（none / isolated / unsafeWindow）", events,
                   "none=\(a["data-none-event"] ?? "nil") iso=\(a["data-iso-event"] ?? "nil") unsafe=\(a["data-unsafe-event"] ?? "nil")")
        let pageEvents = await ctx.eval(tab, "return window.pageEvents.join(',');") as? String ?? ""
        ctx.record("脚本事件 → 页面监听器", pageEvents.contains("none"), pageEvents)

        // pushState: same document, scripts must not re-run and page-world state must survive.
        _ = await ctx.eval(tab, "history.pushState({}, '', '/pageworld/index.html?pushed=1'); return location.search;")
        let pushed = await ctx.waitUntil(5) { tab.webView?.url?.query == "pushed=1" }
        let afterPush = await ctx.attrs(tab)
        let stillThere = await ctx.eval(tab, "return window.fromUnsafe === 'unsafe' && window.fromGrantNone === 'none';") as? Bool ?? false
        ctx.record("pushState：脚本不重复运行，页面世界状态保留", pushed && afterPush["data-none-runs"] == "1" && stillThere,
                   "url=\(tab.webView?.url?.query ?? "nil") runs=\(afterPush["data-none-runs"] ?? "nil") state=\(stillThere)")
        _ = await ctx.eval(tab, "document.dispatchEvent(new CustomEvent('rk-page-event', { detail: 'after-push' })); return true;")
        let listenerAfterPush = await ctx.waitUntil(5) { await ctx.attr(tab, "data-unsafe-event") == "after-push" }
        ctx.record("pushState 后事件监听仍有效", listenerAfterPush, await ctx.attr(tab, "data-unsafe-event") ?? "nil")

        // iframe (same origin): scripts without @noframes run in the frame with the frame's globals.
        let frame = await ctx.eval(tab, """
            const d = document.getElementById('frame').contentDocument;
            if (!d) return null;
            const r = {}; for (const a of d.documentElement.attributes) r[a.name] = a.value;
            r.fromUnsafe = String(document.getElementById('frame').contentWindow.fromUnsafe);
            return r;
            """) as? [String: String] ?? [:]
        ctx.record("iframe：@grant none 读取 frame 全局", frame["data-none-value"] == "7", frame["data-none-value"] ?? "nil")
        ctx.record("iframe：unsafeWindow 指向 frame 自身窗口", frame["data-unsafe-value"] == "7" && frame["fromUnsafe"] == "unsafe",
                   "value=\(frame["data-unsafe-value"] ?? "nil") write=\(frame["fromUnsafe"] ?? "nil")")
        ctx.record("iframe：隔离脚本在 frame 中仍隔离", frame["data-iso-value"] == "undefined", frame["data-iso-value"] ?? "nil")

        // Reload: everything re-runs, GM storage persists across documents.
        tab.reload()
        _ = await ctx.waitLoaded(tab, path: "/pageworld/index.html")
        _ = await ctx.waitUntil(10) { await ctx.attr(tab, "data-iso-runs") == "2" }
        await checkDocument(ctx, tab, label: "刷新后", expectRuns: "2")

        // Popup / new tab opened by the page.
        let before = Set(ctx.manager.tabs.map(\.id))
        let (_, openError) = await ctx.evalResult(tab, "window.open('/pageworld/index.html?popup=1'); return true;")
        let opened = await ctx.waitUntil(10) { ctx.manager.tabs.contains { !before.contains($0.id) } }
        if opened, let popup = ctx.manager.tabs.first(where: { !before.contains($0.id) }) {
            _ = await ctx.waitLoaded(popup, path: "/pageworld/index.html", query: "popup=1")
            _ = await ctx.waitUntil(10) { await ctx.attr(popup, "data-unsafe-value") != nil }
            await checkDocument(ctx, popup, label: "window.open 新标签页", expectRuns: nil)
            ctx.manager.close(popup)
        } else {
            ctx.record("window.open 新标签页：脚本运行", false,
                       "no new tab (popup blocked or not created)\(openError.map { ": " + $0 } ?? "") blockPopups=\(ctx.services.prefs.blockPopups)")
        }
        for script in installed { ctx.profile.userscripts.delete(script.id) }
    }

    /// World checks on one document.
    private static func checkDocument(_ ctx: SelfTestContext, _ tab: BrowserTab, label: String, expectRuns: String?) async {
        let a = await ctx.attrs(tab)
        let page = await ctx.eval(tab, """
            return { none: String(window.fromGrantNone), unsafe: String(window.fromUnsafe), inject: String(window.fromInjectPage),
                     leak: typeof window.isolatedLeak, nested: String(window.pageObject.nested.n), privileged: typeof window.fromPrivileged };
            """) as? [String: String] ?? [:]
        ctx.record("\(label)：@grant none 读页面变量 / 调用函数 / 读对象",
                   a["data-none-value"] == "41" && a["data-none-fn"] == "pf:a" && a["data-none-obj"] == "2",
                   "value=\(a["data-none-value"] ?? "nil") fn=\(a["data-none-fn"] ?? "nil") obj=\(a["data-none-obj"] ?? "nil")")
        ctx.record("\(label)：@grant none 写入对页面可见", page["none"] == "none", page["none"] ?? "nil")
        ctx.record("\(label)：隔离脚本看不到页面变量", a["data-iso-value"] == "undefined", a["data-iso-value"] ?? "nil")
        ctx.record("\(label)：隔离脚本变量不泄漏到页面", page["leak"] == "undefined", page["leak"] ?? "nil")
        ctx.record("\(label)：隔离脚本 GM API 可用", a["data-iso-gm"] == "ok", a["data-iso-gm"] ?? "nil")
        ctx.record("\(label)：unsafeWindow 读变量 / 调用页面函数", a["data-unsafe-value"] == "41" && a["data-unsafe-fn"] == "pf:b",
                   "value=\(a["data-unsafe-value"] ?? "nil") fn=\(a["data-unsafe-fn"] ?? "nil")")
        ctx.record("\(label)：unsafeWindow 写入对页面可见（全局 + 对象修改）", page["unsafe"] == "unsafe" && page["nested"] == "2",
                   "global=\(page["unsafe"] ?? "nil") nested=\(page["nested"] ?? "nil")")
        ctx.record("\(label)：页面环境脚本 GM_addStyle（无特权）可用", a["data-unsafe-gm"] == "ok", a["data-unsafe-gm"] ?? "nil")
        if let expectRuns {
            ctx.record("\(label)：GM 值跨文档持久（隔离脚本运行次数）", a["data-iso-runs"] == expectRuns, a["data-iso-runs"] ?? "nil")
        }
        ctx.record("\(label)：特权脚本在隔离环境，unsafeWindow 看不到页面变量（Partial，安全）", a["data-pu-value"] == "undefined" && a["data-pu-same"] == "true",
                   "pageValue=\(a["data-pu-value"] ?? "nil") unsafeWindow===window: \(a["data-pu-same"] ?? "nil")")
        ctx.record("\(label)：特权脚本 GM API 可用", a["data-pu-gm"] == "ok", a["data-pu-gm"] ?? "nil")
        ctx.record("\(label)：特权脚本经 unsafeWindow 写入不会泄漏到页面", page["privileged"] == "undefined", page["privileged"] ?? "nil")
        ctx.record("\(label)：@inject-into page 的特权 GM API 被明确拒绝", a["data-inject-gm"] == "denied", a["data-inject-gm"] ?? "nil")
        ctx.record("\(label)：@inject-into page 读页面变量 + GM_info", a["data-inject-value"] == "41" && a["data-inject-info"] == "ok" && page["inject"] == "inject",
                   "value=\(a["data-inject-value"] ?? "nil") info=\(a["data-inject-info"] ?? "nil") write=\(page["inject"] ?? "nil")")
    }
}
