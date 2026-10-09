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
            "downloads": "see the download / HLS phase (downloadPhase) — run with the rules active",
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

        // Downloads and media with the rules active.
        await downloadPhase(ctx, tab: tab, extID: ext.id, capabilities: capabilities)

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

    /// Downloads and media sniffing while DNR rules are active. WebKit boundary: content rules
    /// apply only to loads made by WebKit (navigations → WKDownload, page fetch / XHR). Rikugan's
    /// own URLSession downloads (direct links, media sniffer, HLS segments, GM_download) are not
    /// seen by content rules at all — they can never be blocked *or* corrupted by DNR.
    static func downloadPhase(_ ctx: SelfTestContext, tab: BrowserTab, extID: String, capabilities: DNRConverter.Capabilities) async {
        let downloads = ctx.services.downloads
        func fixture(_ path: String) -> Data { (try? Data(contentsOf: ctx.root.appendingPathComponent(String(path.dropFirst())))) ?? Data() }
        func item(for path: String) -> DownloadItem? { downloads.items.first { $0.sourceURL?.path == path } }
        func finished(_ path: String) async -> DownloadItem? {
            _ = await ctx.waitUntil(20) {
                guard let item = item(for: path) else { return false }
                if case .downloading = item.state { return false }
                return true
            }
            return item(for: path)
        }
        func bytes(_ item: DownloadItem?) -> Data { item?.fileURL.flatMap { try? Data(contentsOf: $0) } ?? Data() }
        func describe(_ item: DownloadItem?) -> String {
            guard let item else { return "no download item" }
            return "state=\(item.state) name=\(item.fileName) bytes=\(bytes(item).count)"
        }
        var created: [DownloadItem] = []
        var report: [String: String] = [:]

        // 1. A download blocked by a main_frame rule never reaches the server and creates no item.
        ctx.server.clearLog()
        tab.load(ctx.url("/dnr/dl/block-download.bin"))
        _ = await ctx.waitUntil(8) { tab.webView?.isLoading == false }
        let blockedItem = item(for: "/dnr/dl/block-download.bin")
        ctx.record("下载 · 被 block 规则拦截的下载不发出请求、不产生下载项", !ctx.server.requested("/dnr/dl/block-download.bin") && blockedItem == nil,
                   "requested=\(ctx.server.requested("/dnr/dl/block-download.bin")) item=\(blockedItem != nil)")

        // 2. An ordinary (navigation → WKDownload) download works with DNR on and its bytes are
        //    untouched, although its body contains the blocked URL strings.
        tab.load(ctx.url("/dnr/dl/file.bin"))
        let navItem = await finished("/dnr/dl/file.bin")
        if let navItem { created.append(navItem) }
        let expected = fixture("/dnr/dl/file.bin")
        ctx.record("下载 · 普通下载（WKDownload）在 DNR 开启时完成且字节一致", navItem?.state == .completed && bytes(navItem) == expected && !expected.isEmpty,
                   describe(navItem) + " expected=\(expected.count)")

        // 2b. A tab opened only to download a file (new tab whose first load is the file) closes
        //     when the download ends and the opener is shown again.
        let tabsBefore = ctx.manager.tabs.count
        let downloadTab = ctx.manager.newTab(url: ctx.url("/dnr/dl/file.bin?newtab=1"), background: false, opener: tab)
        let closed = await ctx.waitUntil(20) { !ctx.manager.tabs.contains { $0 === downloadTab } }
        if let tabItem = downloads.items.first(where: { $0.sourceURL?.query == "newtab=1" }) { created.append(tabItem) }
        ctx.record("下载 · 只为下载打开的新标签页在下载结束后自动关闭并回到原标签页",
                   closed && ctx.manager.activeTab === tab && ctx.manager.tabs.count == tabsBefore,
                   "closed=\(closed) activeIsOpener=\(ctx.manager.activeTab === tab) tabs=\(tabsBefore)→\(ctx.manager.tabs.count) shownPage=\(downloadTab.hasShownPage)")

        // 3. Direct (URLSession) download of the same file: not subject to content rules.
        let directURL = ctx.url("/dnr/dl/file.bin?direct=1")
        let direct = downloads.download(url: directURL, suggestedName: "direct.bin", from: tab)
        if let direct { created.append(direct) }
        _ = await ctx.waitUntil(20) { if let direct, case .downloading = direct.state { return false }; return true }
        ctx.record("下载 · 直接下载（URLSession）在 DNR 开启时完成且字节一致", direct?.state == .completed && bytes(direct) == expected, describe(direct))

        // 4. Skipped redirect rule: the original resource is downloaded, unmodified, under its own
        //    name — not reported as redirected / blocked.
        ctx.server.clearLog()
        tab.load(ctx.url("/dnr/dl/redirect-dl.bin"))
        if capabilities.redirect {
            _ = await ctx.waitUntil(20) { downloads.items.contains { $0.fileName.hasPrefix("other") && $0.state == .completed } }
            ctx.record("下载 · redirect 规则生效（WebKit 执行）", ctx.server.requested("/dnr/dl/other.bin") && !ctx.server.requested("/dnr/dl/redirect-dl.bin"))
        } else {
            let redirected = await finished("/dnr/dl/redirect-dl.bin")
            if let redirected { created.append(redirected) }
            ctx.record("下载 · 被跳过的 redirect 规则：下载原始资源、内容未被改写、未被报告为拦截",
                       redirected?.state == .completed && bytes(redirected) == fixture("/dnr/dl/redirect-dl.bin")
                           && ctx.server.requested("/dnr/dl/redirect-dl.bin") && !ctx.server.requested("/dnr/dl/other.bin")
                           && redirected?.fileName.hasPrefix("redirect-dl") == true,
                       describe(redirected) + " other.bin requested=\(ctx.server.requested("/dnr/dl/other.bin"))")
        }

        // 5. Skipped modifyHeaders rule: the request goes out without the header, the download is
        //    intact and not reported as modified.
        ctx.server.clearLog()
        tab.load(ctx.url("/dnr/dl/headers-dl.bin"))
        let headersItem = await finished("/dnr/dl/headers-dl.bin")
        if let headersItem { created.append(headersItem) }
        let sentHeader = ctx.server.requests.first { $0.path == "/dnr/dl/headers-dl.bin" }?.headers["x-rikugan-dnr"]
        if capabilities.modifyHeaders {
            ctx.record("下载 · modifyHeaders 规则生效（WebKit 执行）", sentHeader == "dl", "header=\(sentHeader ?? "nil")")
        } else {
            ctx.record("下载 · 被跳过的 modifyHeaders 规则：请求未带该头、下载完整",
                       sentHeader == nil && headersItem?.state == .completed && bytes(headersItem) == fixture("/dnr/dl/headers-dl.bin"),
                       describe(headersItem) + " header=\(sentHeader ?? "nil")")
        }
        let skipped = ctx.profile.extensions.dnrStatus.skipped[extID] ?? []
        report["skippedRules"] = skipped.joined(separator: " | ")
        if !capabilities.redirect || !capabilities.modifyHeaders {
            ctx.record("下载 · 被跳过的规则在诊断中标为“跳过”（未应用）", skipped.contains { $0.contains("16") } || skipped.contains { $0.contains("17") } || capabilities.redirect,
                       "skipped=\(skipped.count)")
        }

        // 6. Media sniffer with rules active: allowed HLS / MP4 responses are listed; the
        //    DNR-blocked playlist is not (it never produced a response).
        ctx.server.clearLog()
        tab.load(ctx.url("/dnr/dl/media.html"))
        _ = await ctx.waitUntil(15) { await ctx.attr(tab, "data-media-done") == "1" }
        let mediaResult = await ctx.attr(tab, "data-media-result") ?? "nil"
        _ = await ctx.waitUntil(5) { tab.sniffedMedia.contains { $0.url.path == "/dnr/dl/stream.m3u8" } && tab.sniffedMedia.contains { $0.url.path == "/dnr/dl/clip.mp4" } }
        let sniffed = tab.sniffedMedia.map { "\($0.kind):\($0.url.path)" }
        report["sniffed"] = sniffed.joined(separator: ", ")
        report["mediaPage"] = mediaResult
        ctx.record("媒体嗅探 · DNR 开启时仍检测到 HLS 与 MP4", tab.sniffedMedia.contains { $0.url.path == "/dnr/dl/stream.m3u8" && $0.kind == "hls" }
                       && tab.sniffedMedia.contains { $0.url.path == "/dnr/dl/clip.mp4" }, "\(sniffed) page=\(mediaResult)")
        ctx.record("媒体嗅探 · 被 DNR 拦截的媒体请求未被列为可下载", mediaResult.contains("\"blocked\":\"blocked\"")
                       && !ctx.server.requested("/dnr/block-hls.m3u8") && !tab.sniffedMedia.contains { $0.url.path == "/dnr/block-hls.m3u8" },
                   "page=\(mediaResult) sniffed=\(sniffed)")

        // 7. HLS download (URLSession) of the sniffed playlist with rules active: segments joined in order.
        let hls = downloads.download(url: ctx.url("/dnr/dl/stream.m3u8"), suggestedName: "dnr-hls.ts", from: tab)
        if let hls { created.append(hls) }
        _ = await ctx.waitUntil(20) { if let hls, case .downloading = hls.state { return false }; return true }
        let joined = fixture("/dnr/dl/seg0.ts") + fixture("/dnr/dl/seg1.ts")
        ctx.record("HLS · DNR 开启时下载完成且分段按序拼接", hls?.state == .completed && bytes(hls) == joined, describe(hls) + " expected=\(joined.count)")

        ctx.extras["downloads"] = report
        for item in created { downloads.remove(item, deleteFile: true) }
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
