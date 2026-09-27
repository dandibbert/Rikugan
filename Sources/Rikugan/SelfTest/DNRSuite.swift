import Foundation
import WebKit

/// declarativeNetRequest regression (spec §7). Outcomes are read from the local server's request
/// log: a blocked request never reaches the server, its control twin must. A type whose control
/// request never arrived is reported as inconclusive (failed), not as blocked.
@MainActor enum DNRSuite {
    static func run(_ ctx: SelfTestContext) async {
        let runtime: ExtensionRuntime = ctx.profile.extensions
        let compiles = await ExtensionRuntime.probeDNRCapabilities()
        let capabilities = ExtensionRuntime.executedDNRActions
        ctx.extras["webkitCompiles"] = ["redirect": compiles.redirect, "modifyHeaders": compiles.modifyHeaders]
        ctx.extras["rikuganEnables"] = ["redirect": capabilities.redirect, "modifyHeaders": capabilities.modifyHeaders]
        ctx.record("WebKit 编译探测完成", true, "compiles redirect=\(compiles.redirect) modifyHeaders=\(compiles.modifyHeaders)")

        let started = Date()
        let ext: LoadedExtension
        do { ext = try ctx.installExtension("dnr-ext", seed: "dnr-selftest") } catch {
            ctx.record("安装 DNR 测试扩展", false, error.localizedDescription); return
        }
        let compiled = await ctx.waitForDNRCompile(after: started)
        let status = runtime.dnrStatus
        let skipped = status.skipped[ext.id] ?? []
        ctx.extras["converted"] = status.convertedRules
        ctx.extras["skipped"] = skipped
        ctx.record("规则编译", compiled && status.convertedRules > 0, "converted=\(status.convertedRules) skipped=\(skipped.count)")

        ctx.server.clearLog()
        let tab = await ctx.open("/dnr/index.html")
        let done = await ctx.waitUntil(15) { await ctx.attr(tab, "data-dnr-done") == "1" }
        // Subresources that do not gate `load` (media preload, frames) — wait for their controls.
        let controls = ["/dnr/ok-image.png", "/dnr/ok-style.css", "/dnr/ok-script.js", "/dnr/ok-xhr.json", "/dnr/ok-fetch.json",
                        "/dnr/ok-font.ttf", "/dnr/ok-media.wav", "/dnr/ok-frame.html"]
        _ = await ctx.waitUntil(10) { controls.allSatisfy(ctx.server.requested) }
        ctx.record("测试页面完成全部请求", done, await ctx.attr(tab, "data-dnr-done") ?? "nil")

        let pairs: [(String, String, String)] = [
            ("image", "/dnr/block-image.png", "/dnr/ok-image.png"),
            ("stylesheet", "/dnr/block-style.css", "/dnr/ok-style.css"),
            ("script", "/dnr/block-script.js", "/dnr/ok-script.js"),
            ("xmlhttprequest (XHR)", "/dnr/block-xhr.json", "/dnr/ok-xhr.json"),
            ("xmlhttprequest (fetch)", "/dnr/block-fetch.json", "/dnr/ok-fetch.json"),
            ("font", "/dnr/block-font.ttf", "/dnr/ok-font.ttf"),
            ("media", "/dnr/block-media.wav", "/dnr/ok-media.wav"),
            ("sub_frame", "/dnr/block-frame.html", "/dnr/ok-frame.html"),
        ]
        var matrix: [[String: Any]] = []
        for (type, blocked, control) in pairs {
            let blockedSeen = ctx.server.requested(blocked)
            let controlSeen = ctx.server.requested(control)
            let outcome = !controlSeen ? "inconclusive (control not requested)" : (blockedSeen ? "NOT blocked" : "blocked")
            matrix.append(["type": type, "blockedRequested": blockedSeen, "controlRequested": controlSeen, "outcome": outcome])
            ctx.record("block · \(type)", controlSeen && !blockedSeen, outcome)
        }
        let allowOverride = ctx.server.requested("/dnr/allow-script.js") && !ctx.server.requested("/dnr/allow-other.js")
        ctx.record("allow（高优先级）覆盖 block", allowOverride,
                   "allow-script requested=\(ctx.server.requested("/dnr/allow-script.js")) allow-other requested=\(ctx.server.requested("/dnr/allow-other.js"))")

        // HLS goes through the media stack; whether WebKit content rules see those loads is
        // platform behaviour, so it is reported as an observation rather than asserted.
        ctx.extras["observations"] = [
            "hls": ctx.server.requested("/dnr/block-hls.m3u8") ? "HLS playlist request reached the server (not blockable here)" :
                (ctx.server.requests.contains { $0.path.hasSuffix(".m3u8") } ? "blocked" : "no HLS request observed (video element did not load)"),
            "downloads": "not automated: downloads are started from navigation responses and share the main_frame / sub_frame decision",
        ]

        // Redirect.
        let redirectSkipped = skipped.contains { $0.contains("13") || $0.lowercased().contains("redirect") }
        if capabilities.redirect {
            let ran = await ctx.attr(tab, "data-redirect-dst") == "ran"
            ctx.record("redirect（transform.path）生效", ran && ctx.server.requested("/dnr/redirect-dst.js") && !ctx.server.requested("/dnr/redirect-src.js"),
                       "dst ran=\(ran) src requested=\(ctx.server.requested("/dnr/redirect-src.js"))")
        } else {
            ctx.record("redirect 不受支持时被明确跳过并报告", redirectSkipped && ctx.server.requested("/dnr/redirect-src.js"),
                       "skipped=\(redirectSkipped) — WebKit 不接受 redirect 内容规则")
        }
        // modifyHeaders.
        let echo = (await ctx.attr(tab, "data-echo-body")).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] } ?? [:]
        let control = (await ctx.attr(tab, "data-echo-control-body")).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] } ?? [:]
        let headerSkipped = skipped.contains { $0.contains("14") || $0.lowercased().contains("header") }
        if capabilities.modifyHeaders {
            ctx.record("modifyHeaders（set request header）生效", echo["x-rikugan-dnr"] == "1" && control["x-rikugan-dnr"] == nil,
                       "with=\(echo["x-rikugan-dnr"] ?? "nil") control=\(control["x-rikugan-dnr"] ?? "nil")")
        } else {
            ctx.record("modifyHeaders 不受支持时被明确跳过并报告", headerSkipped && echo["x-rikugan-dnr"] == nil,
                       "skipped=\(headerSkipped) — WebKit 不接受 modify-headers 内容规则")
        }

        // main_frame navigation.
        tab.load(ctx.url("/dnr/block-main.html"))
        _ = await ctx.waitUntil(8) { tab.webView?.isLoading == false }
        tab.load(ctx.url("/dnr/ok-main.html"))
        _ = await ctx.waitUntil(8) { ctx.server.requested("/dnr/ok-main.html") }
        let mainBlocked = !ctx.server.requested("/dnr/block-main.html")
        ctx.record("block · main_frame 导航", mainBlocked && ctx.server.requested("/dnr/ok-main.html"),
                   "blocked requested=\(!mainBlocked) control requested=\(ctx.server.requested("/dnr/ok-main.html"))")
        matrix.append(["type": "main_frame", "blockedRequested": !mainBlocked, "controlRequested": ctx.server.requested("/dnr/ok-main.html"),
                       "outcome": mainBlocked ? "blocked" : "NOT blocked"])
        ctx.extras["matrix"] = matrix

        // Behavioural probe: apply raw redirect / modify-headers content rules straight to a tab
        // and observe what WebKit really does. Rikugan's enabled set must match this.
        await behaviourProbe(ctx, compiles: compiles, enabled: capabilities)

        // Removing the extension removes its rules.
        let removedAt = Date()
        runtime.remove(ext.id)
        _ = await ctx.waitForDNRCompile(after: removedAt)
        ctx.server.clearLog()
        tab.load(ctx.url("/dnr/index.html"))
        _ = await ctx.waitLoaded(tab, path: "/dnr/index.html")
        let unblocked = await ctx.waitUntil(10) { ctx.server.requested("/dnr/block-image.png") }
        ctx.record("卸载扩展后规则移除", unblocked, "block-image requested=\(unblocked)")
        ctx.manager.close(tab)
    }

    static func behaviourProbe(_ ctx: SelfTestContext, compiles: DNRConverter.Capabilities, enabled: DNRConverter.Capabilities) async {
        guard let store = WKContentRuleListStore.default() else { ctx.record("行为探测", false, "no rule list store"); return }
        let redirectRule = #"[{"trigger":{"url-filter":"redirect-probe-src\\.js"},"action":{"type":"redirect","redirect":{"transform":{"path":"/dnr/redirect-probe-dst.js"}}}}]"#
        let headerRule = #"[{"trigger":{"url-filter":"echo-headers\\?probe"},"action":{"type":"modify-headers","request-headers":[{"header":"X-Rikugan-Probe","operation":"set","value":"1"}]}}]"#
        var lists: [WKContentRuleList] = []
        if compiles.redirect, let list = await store.rkCompile("rikugan-behaviour-redirect", redirectRule) { lists.append(list) }
        if compiles.modifyHeaders, let list = await store.rkCompile("rikugan-behaviour-headers", headerRule) { lists.append(list) }
        let tab = ctx.manager.newTab(url: nil, isPrivate: false)
        let webView = tab.ensureWebView()
        for list in lists { webView.configuration.userContentController.add(list) }
        ctx.server.clearLog()
        tab.load(ctx.url("/dnr/probe.html"))
        _ = await ctx.waitLoaded(tab, path: "/dnr/probe.html")
        _ = await ctx.waitUntil(8) { await ctx.attr(tab, "data-probe-echo") != nil }
        let redirectExecutes = compiles.redirect && ctx.server.requested("/dnr/redirect-probe-dst.js") && !ctx.server.requested("/dnr/redirect-probe-src.js")
        let echo = (await ctx.attr(tab, "data-probe-echo")).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] } ?? [:]
        let headersExecute = compiles.modifyHeaders && echo["x-rikugan-probe"] == "1"
        ctx.extras["webkitExecutes"] = ["redirect": redirectExecutes, "modifyHeaders": headersExecute]
        ctx.record("行为：WebKit 是否执行 redirect 与 Rikugan 声明一致", redirectExecutes == enabled.redirect,
                   "compiles=\(compiles.redirect) executes=\(redirectExecutes) enabled=\(enabled.redirect) src requested=\(ctx.server.requested("/dnr/redirect-probe-src.js"))")
        ctx.record("行为：WebKit 是否执行 modify-headers 与 Rikugan 声明一致", headersExecute == enabled.modifyHeaders,
                   "compiles=\(compiles.modifyHeaders) executes=\(headersExecute) enabled=\(enabled.modifyHeaders)")
        for list in lists { webView.configuration.userContentController.remove(list) }
        await store.rkRemove("rikugan-behaviour-redirect")
        await store.rkRemove("rikugan-behaviour-headers")
        ctx.manager.close(tab)
    }
}
