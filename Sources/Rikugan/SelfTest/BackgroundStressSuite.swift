import Foundation
import WebKit

/// Background runtime stress (spec §4). Repeats, N times:
///   cold start (message) → cold start (port) → message while starting → multiple ports →
///   storage → idle suspension → wake (new runtime) → ports keep it alive → port across tab close →
///   popup during start-up → shutdown.
/// Every step has its own deadline and is never retried; any failed step fails its round, and
/// any failed round fails the suite.
@MainActor enum BackgroundStressSuite {
    static var rounds: Int {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-RikuganStressRounds"), i + 1 < args.count, let n = Int(args[i + 1]) { return max(1, n) }
        return 20
    }

    static func run(_ ctx: SelfTestContext) async {
        let runtime: ExtensionRuntime = ctx.profile.extensions
        let savedIdle = ctx.services.prefs.backgroundIdleSeconds
        ctx.services.prefs.backgroundIdleSeconds = 2
        defer { ctx.services.prefs.backgroundIdleSeconds = savedIdle }

        let ext: LoadedExtension
        do { ext = try ctx.installExtension("stress-ext", seed: "stress-selftest") } catch {
            ctx.record("安装压力测试扩展", false, error.localizedDescription); return
        }
        guard let bg = ext.background else { ctx.record("后台宿主", false, "no background host"); return }
        let world = Worlds.extensionWorld(ext.id)
        let tab = await ctx.open("/stress/index.html")
        let csReady = await ctx.waitUntil(10) { await ctx.attr(tab, "data-stress-cs") == "ready" }
        if !csReady {
            let url = tab.webView?.url
            let planned = url.map { runtime.contentScripts(for: $0, tab: tab).filter { $0.world.name == world.name }.count } ?? -1
            let state = await ctx.eval(tab, "return document.readyState + ' attrs=' + [...document.documentElement.attributes].map(a => a.name).join(',');") as? String ?? "nil"
            ctx.record("压力测试页面 + 内容脚本就绪", false,
                       "url=\(url?.absoluteString ?? "nil") loading=\(tab.webView?.isLoading ?? false) state=\(state) plannedScripts=\(planned) injectedFor=\(tab.lastInjectedURL?.absoluteString ?? "nil") extErrors=\(ext.record.lastErrors.suffix(3)) log=\(ErrorLog.shared.entries.suffix(3).map(\.message))")
            return
        }
        ctx.record("压力测试页面 + 内容脚本就绪", true)

        func call(_ js: String, _ args: [String: Any] = [:], in target: BrowserTab? = nil) async -> (Any?, String?) {
            await ctx.evalResult(target ?? tab, js, world: world, arguments: args)
        }
        func stored(_ key: String) -> Any? {
            guard let text = runtime.storage(ext, area: "local")[key] else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        }

        let total = rounds
        let watch = SelfTestContext.MainThreadWatch()
        watch.start()
        defer { watch.stop() }
        var failedRounds = 0
        var log: [[String: Any]] = []
        let suiteStart = Date()
        for round in 0..<total {
            var failures: [String] = []
            var timings: [String: Double] = [:]
            func step(_ name: String, _ body: () async -> String?) async {
                let t = Date()
                watch.reset()
                if let failure = await body() {
                    failures.append("\(name): \(failure) [mainThreadMaxGap=\(String(format: "%.2f", watch.maxGap))s webViews=\(RikuganWebView.liveByPurpose) bgTimeline=\(bg.timeline.suffix(6).joined(separator: "; "))]")
                }
                timings[name] = (Date().timeIntervalSince(t) * 1000).rounded() / 1000
                timings["mainThreadMaxGap " + name] = (watch.maxGap * 1000).rounded() / 1000
            }

            var firstWake = ""
            await step("cold start → sendMessage") {
                bg.stop()
                guard bg.state == .notStarted else { return "state after stop = \(bg.state.rawValue)" }
                let (value, error) = await call("return await __stress.ping(n, 15000);", ["n": round])
                let reply = value as? [String: Any]
                guard (reply?["pong"] as? Int) == round else { return "reply=\(String(describing: value)) error=\(error ?? "nil") bg=\(bg.diagnostics)" }
                firstWake = reply?["wake"] as? String ?? ""
                return bg.isReady ? nil : "state after reply = \(bg.state.rawValue)"
            }
            await step("cold start → connect + postMessage") {
                bg.stop()
                let (value, error) = await call("const r = await __stress.openAndEcho('cold', 'hi' + n, 15000); __stress.close('cold'); return r.echo;", ["n": round])
                return value as? String == "hi\(round)" ? nil : "echo=\(String(describing: value)) error=\(error ?? "nil") bg=\(bg.diagnostics)"
            }
            await step("message while starting (queued)") {
                bg.stop()
                bg.start()
                guard bg.state == .starting else { return "state after start = \(bg.state.rawValue)" }
                let (value, error) = await call("return await __stress.ping(n, 15000);", ["n": round])
                return ((value as? [String: Any])?["pong"] as? Int) == round ? nil : "reply=\(String(describing: value)) error=\(error ?? "nil")"
            }
            await step("3 concurrent ports") {
                let (value, error) = await call("""
                    const names = ['a', 'b', 'c'].map((x) => x + n);
                    const replies = await Promise.all(names.map((name) => __stress.openAndEcho(name, 'm-' + name, 10000)));
                    __stress.closeAll();
                    return replies.map((r) => r.echo + '@' + r.name).join(',');
                    """, ["n": round])
                let expected = ["a", "b", "c"].map { "m-\($0)\(round)@\($0)\(round)" }.joined(separator: ",")
                return value as? String == expected ? nil : "got=\(String(describing: value)) error=\(error ?? "nil")"
            }
            await step("storage round-trip") {
                let (value, error) = await call("return await __stress.storage(n, 10000);", ["n": round])
                return ((value as? [String: Any])?["value"] as? Int) == round ? nil : "reply=\(String(describing: value)) error=\(error ?? "nil")"
            }
            await step("idle → suspended") {
                let suspended = await ctx.waitUntil(8) { bg.state == .suspended }
                return suspended && bg.webView == nil ? nil : "state=\(bg.state.rawValue) webView=\(bg.webView != nil)"
            }
            await step("wake from suspended") {
                let (value, error) = await call("return await __stress.ping(n, 15000);", ["n": round])
                let reply = value as? [String: Any]
                guard (reply?["pong"] as? Int) == round else { return "reply=\(String(describing: value)) error=\(error ?? "nil") bg=\(bg.diagnostics)" }
                let wake = reply?["wake"] as? String ?? ""
                return wake != firstWake && bg.isReady ? nil : "wake id unchanged (\(wake)) or state=\(bg.state.rawValue)"
            }
            if round % 5 == 0 {
                await step("open port prevents idle suspension") {
                    let (value, error) = await call("return (await __stress.openAndEcho('keep', 'k', 10000)).echo;")
                    guard value as? String == "k" else { return "echo=\(String(describing: value)) error=\(error ?? "nil")" }
                    // Two full idle limits with an open port: suspension here is a failure.
                    let suspendedWhileOpen = await ctx.waitUntil(4.5) { bg.state == .suspended }
                    _ = await call("return __stress.close('keep');")
                    return suspendedWhileOpen ? "suspended while a port was open" : nil
                }
            }
            await step("port disconnect on tab close") {
                let before = stored("disconnects") as? Int ?? 0
                let other = await ctx.open("/stress/index.html?t=\(round)", background: true)
                guard await ctx.waitUntil(10, { await ctx.attr(other, "data-stress-cs") == "ready" }) else { ctx.manager.close(other); return "second tab content script not ready" }
                let (value, error) = await call("return (await __stress.openAndEcho('closing', 'c', 10000)).echo;", in: other)
                guard value as? String == "c" else { ctx.manager.close(other); return "echo=\(String(describing: value)) error=\(error ?? "nil")" }
                ctx.manager.close(other)
                let counted = await ctx.waitUntil(10) { (stored("disconnects") as? Int ?? 0) == before + 1 }
                let open = runtime.bridge.openPortCount
                return counted && open == 0 ? nil : "disconnects \(before)→\(stored("disconnects") as? Int ?? -1) openPorts=\(open)"
            }
            if round % 5 == 0 {
                await step("popup sends while background starts") {
                    _ = await call("return await __stress.set({ popupPong: 'pending' }, 10000);")
                    bg.stop()
                    let holder = PopupHolder()
                    guard let url = URL(string: ext.baseURL + "popup.html") else { return "bad popup url" }
                    holder.load(ExtensionRuntime.PopupRequest(extID: ext.id, url: url, tabID: tab.numericID, title: "stress"), runtime: runtime)
                    if let webView = holder.webView { BackgroundHostContainer.shared.attach(webView) }
                    let ok = await ctx.waitUntil(15) { stored("popupPong") as? String == "ok" }
                    holder.webView?.removeFromSuperview()
                    holder.close(runtime: runtime)
                    return ok ? nil : "popupPong=\(String(describing: stored("popupPong"))) bg=\(bg.diagnostics)"
                }
            }
            await step("shutdown") {
                bg.stop()
                return bg.state == .notStarted && bg.webView == nil && !runtime.bridge.hasOpenPorts(extID: ext.id) ? nil
                    : "state=\(bg.state.rawValue) webView=\(bg.webView != nil) ports=\(runtime.bridge.openPortCount)"
            }
            if !failures.isEmpty { failedRounds += 1 }
            log.append(["round": round, "failures": failures, "timings": timings])
            ctx.record("第 \(round + 1)/\(total) 轮", failures.isEmpty, failures.joined(separator: " | "))
            // Partial report after every round: evidence survives even if the app is killed.
            ctx.extras["rounds"] = log
            ctx.writeReport(summary: "SELFTEST stress IN PROGRESS \(round + 1)/\(total)")
        }
        ctx.extras["rounds"] = log
        ctx.extras["webViewsAtEnd"] = RikuganWebView.liveByPurpose
        ctx.extras["stuckStartRecoveries"] = bg.stuckStartRecoveries
        // Informational (always recorded, visible in the summary): how often WebKit never started a
        // background navigation and a fresh web view had to be used.
        ctx.record("（记录）后台导航未启动→更换 WebView 的次数", true, "\(bg.stuckStartRecoveries) of \(bg.startCount) starts")
        ctx.extras["failedRounds"] = failedRounds
        ctx.extras["seconds"] = Date().timeIntervalSince(suiteStart)
        ctx.record("压力测试总计", failedRounds == 0, String(format: "%d/%d rounds passed in %.1fs", total - failedRounds, total, Date().timeIntervalSince(suiteStart)))
        bg.start()
        ctx.manager.close(tab)
        runtime.remove(ext.id)
    }
}
