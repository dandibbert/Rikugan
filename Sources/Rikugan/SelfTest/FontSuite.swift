import Foundation
import WebKit

/// Font module regression (spec §9). Uses purpose-built fonts whose metrics make application
/// measurable: in RikuganTestSans / RikuganTestPairA / RikuganTestPairB the glyph "x" is 2 em wide,
/// so "xxxx" at 20 px is exactly 160 px; the page's icon font draws U+E001 3 em (60 px) wide.
@MainActor enum FontSuite {
    struct Probe {
        let width: Double
        let family: String
        let tag: String
    }

    static let ids = ["body", "heading", "mono", "emoji", "icon-class", "icon-pua", "icon-ligature", "custom", "late"]

    static func measure(_ ctx: SelfTestContext, _ tab: BrowserTab) async -> [String: Probe] {
        let raw = await ctx.eval(tab, """
            const out = {};
            for (const id of ids) {
              const el = document.getElementById(id);
              if (!el) continue;
              out[id] = { w: el.getBoundingClientRect().width, f: getComputedStyle(el).fontFamily,
                          t: el.getAttribute('data-rk-font') || ('skip:' + (el.getAttribute('data-rk-font-skip') || 'none')) };
            }
            return out;
            """, arguments: ["ids": ids]) as? [String: [String: Any]] ?? [:]
        return raw.mapValues { Probe(width: ($0["w"] as? NSNumber)?.doubleValue ?? -1, family: $0["f"] as? String ?? "", tag: $0["t"] as? String ?? "") }
    }

    /// First family of a computed `font-family` value, without quotes.
    static func primary(_ p: Probe?) -> String {
        (p?.family.split(separator: ",").first.map(String.init) ?? "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func near(_ value: Double?, _ target: Double) -> Bool { value.map { abs($0 - target) < 1.5 } ?? false }

    static func describe(_ p: Probe?) -> String {
        guard let p else { return "missing" }
        return String(format: "w=%.1f tag=%@ family=%@", p.width, p.tag, String(p.family.prefix(60)))
    }

    static func run(_ ctx: SelfTestContext) async {
        let fonts = ctx.services.fonts
        let host = "127.0.0.1"
        let savedPrefs = ctx.services.prefs
        defer {
            ctx.services.prefs = savedPrefs
            ctx.profile.siteSettings.remove(host)
        }
        ctx.profile.siteSettings.remove(host)

        // 1. Import .ttf and .ttc (collection split into standalone faces).
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rk-font-test", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var families: [String] = []
        for name in ["RikuganTestSans.ttf", "RikuganTestPair.ttc"] {
            let copy = tmp.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: ctx.root.appendingPathComponent("fonts/" + name), to: copy)
                let imported = try fonts.importFonts(from: copy)
                families += imported.map(\.family)
                ctx.record("导入 \(name)", !imported.isEmpty, imported.map { "\($0.family) ← \($0.fileURL.lastPathComponent)" }.joined(separator: ", "))
            } catch { ctx.record("导入 \(name)", false, error.localizedDescription) }
        }
        ctx.record("TTC 拆分为两个字体", families.contains("RikuganTestPairA") && families.contains("RikuganTestPairB"), families.joined(separator: ", "))

        // 2. Baseline without override: proves the page's icon font loads at all.
        ctx.services.prefs.webFontEnabled = false
        let tab = await ctx.open("/fonts-page/index.html")
        _ = await ctx.waitUntil(10) { near((await measure(ctx, tab))["icon-class"]?.width, 60) }
        let base = await measure(ctx, tab)
        ctx.record("基线：页面图标字体已加载（U+E001 = 60px）", near(base["icon-class"]?.width, 60), describe(base["icon-class"]))
        ctx.record("基线：正文未被替换", !near(base["body"]?.width, 160) && base["body"]?.tag == "skip:none", describe(base["body"]))
        ctx.extras["baseline"] = base.mapValues { ["width": $0.width, "family": $0.family, "tag": $0.tag] }

        // 3. Global plan: body = TestSans, heading = PairB, mono = keep page font.
        var prefs = ctx.services.prefs
        prefs.webFontEnabled = true
        prefs.webFontFamily = "RikuganTestSans"
        prefs.webFontHeading = "RikuganTestPairB"
        prefs.webFontMono = ""
        prefs.webFontExcludedHosts.removeAll { $0 == host }
        ctx.services.prefs = prefs
        tab.reload()
        _ = await ctx.waitLoaded(tab, path: "/fonts-page/index.html")
        _ = await ctx.waitUntil(15) {
            let m = await measure(ctx, tab)
            return near(m["body"]?.width, 160) && near(m["heading"]?.width, 160) && near(m["late"]?.width, 160)
        }
        let global = await measure(ctx, tab)
        ctx.extras["global"] = global.mapValues { ["width": $0.width, "family": $0.family, "tag": $0.tag] }
        ctx.record("正文 → 导入字体（宽度证明已渲染）", near(global["body"]?.width, 160) && primary(global["body"]) == "RikuganTestSans", describe(global["body"]))
        ctx.record("标题 → TTC 中的 PairB", near(global["heading"]?.width, 160) && primary(global["heading"]) == "RikuganTestPairB", describe(global["heading"]))
        ctx.record("等宽（保持页面字体）不被替换", global["mono"]?.tag == "skip:mono" && global["mono"]?.family.contains("RikuganTest") == false, describe(global["mono"]))
        ctx.record("Emoji 保留彩色 emoji 回退", global["emoji"]?.family.contains("Apple Color Emoji") == true && (global["emoji"]?.width ?? 0) > 20, describe(global["emoji"]))
        ctx.record("图标字体（class=fa）未被替换", near(global["icon-class"]?.width, 60) && global["icon-class"]?.tag == "skip:icon", describe(global["icon-class"]))
        ctx.record("图标字体（私有区字符）未被替换", near(global["icon-pua"]?.width, 60) && global["icon-pua"]?.tag == "skip:icon", describe(global["icon-pua"]))
        ctx.record("连字图标（material-icons）未被替换", global["icon-ligature"]?.tag == "skip:icon" && primary(global["icon-ligature"]) == "PageIcons", describe(global["icon-ligature"]))
        ctx.record("页面自定义 @font-face 正文被替换", near(global["custom"]?.width, 160), describe(global["custom"]))
        ctx.record("动态插入的文字被替换（MutationObserver）", near(global["late"]?.width, 160), describe(global["late"]))

        // 4. Live update without reload.
        ctx.services.prefs.webFontFamily = "RikuganTestPairA"
        let live = await ctx.waitUntil(10) { (await measure(ctx, tab))["body"]?.family.contains("RikuganTestPairA") == true }
        ctx.record("修改全局字体后实时生效（无需刷新）", live, describe((await measure(ctx, tab))["body"]))
        ctx.services.prefs.webFontFamily = "RikuganTestSans"

        // 5. Per-site override: this host uses PairA for body, heading stays global.
        ctx.profile.siteSettings.update(host) { $0.fontBody = "RikuganTestPairA" }
        tab.reload()
        _ = await ctx.waitLoaded(tab, path: "/fonts-page/index.html")
        _ = await ctx.waitUntil(15) { (await measure(ctx, tab))["body"]?.family.contains("RikuganTestPairA") == true }
        let site = await measure(ctx, tab)
        ctx.record("网站覆盖：正文使用站点字体", site["body"]?.family.contains("RikuganTestPairA") == true && near(site["body"]?.width, 160), describe(site["body"]))
        ctx.record("网站覆盖：未覆盖的标题沿用全局", site["heading"]?.family.contains("RikuganTestPairB") == true, describe(site["heading"]))

        // 6. Per-site disable.
        ctx.profile.siteSettings.update(host) { $0.fontBody = nil; $0.webFont = false }
        tab.reload()
        _ = await ctx.waitLoaded(tab, path: "/fonts-page/index.html")
        _ = await ctx.waitUntil(10) { near((await measure(ctx, tab))["icon-class"]?.width, 60) }
        let disabled = await measure(ctx, tab)
        let taggedCount = await ctx.eval(tab, "return document.querySelectorAll('[data-rk-font]').length;") as? Int ?? -1
        ctx.record("网站禁用：不替换任何元素", !near(disabled["body"]?.width, 160) && taggedCount == 0, "\(describe(disabled["body"])) tagged=\(taggedCount)")

        // 7. Global exclusion list.
        ctx.profile.siteSettings.remove(host)
        ctx.services.prefs.webFontExcludedHosts.append(host)
        tab.reload()
        _ = await ctx.waitLoaded(tab, path: "/fonts-page/index.html")
        _ = await ctx.waitUntil(10) { near((await measure(ctx, tab))["icon-class"]?.width, 60) }
        let excluded = await measure(ctx, tab)
        ctx.record("排除列表中的网站不替换", !near(excluded["body"]?.width, 160) && excluded["body"]?.tag == "skip:none", describe(excluded["body"]))
        ctx.manager.close(tab)
    }
}
