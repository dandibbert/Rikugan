import Foundation
import WebKit

/// Real-extension compatibility report (spec §5). CI downloads real packages into
/// `SelfTest/compat/` together with `sources.json` (name, version, source URL, sha256); this suite
/// installs each one in isolation and records, per area, what was actually observed:
/// install, manifest, permissions, background, content scripts, popup, storage, messaging,
/// ports, scripting, tabs, DNR and extension-specific behaviour. Nothing is inferred from the
/// manifest alone: API areas are judged from the calls the extension really made (and whether
/// they failed), behaviour from effects on a real page.
///
/// The suite "passes" when the report was produced; incompatibilities are data, not test failures.
@MainActor enum CompatSuite {
    struct Source: Decodable {
        let key: String
        let name: String
        let version: String?
        let source: String?
        let file: String?
        let sha256: String?
        let downloadError: String?
    }

    typealias Area = [String: String]   // status: ok | fail | partial | n/a | untested ; detail

    static func area(_ status: String, _ detail: String) -> Area { ["status": status, "detail": detail] }

    static func run(_ ctx: SelfTestContext) async {
        let dir = ctx.root.appendingPathComponent("compat")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("sources.json")),
              let sources = try? JSONDecoder().decode([Source].self, from: data) else {
            ctx.record("compat/sources.json", false, "没有真实扩展包（此构建未由 compat CI 任务准备）")
            return
        }
        let savedAdBlock = ctx.services.prefs.adBlockEnabled
        ctx.services.prefs.adBlockEnabled = false   // never attribute Rikugan's own blocking to an extension
        defer { ctx.services.prefs.adBlockEnabled = savedAdBlock }

        // Baseline page state without any extension.
        let baselineTab = await ctx.open("/compat-page/index.html")
        _ = await ctx.waitUntil(15) { let a = await ctx.attrs(baselineTab); return a["data-ad"] != nil && a["data-control"] != nil }
        let baseline = await ctx.attrs(baselineTab)
        ctx.extras["baseline"] = ["ad": baseline["data-ad"] ?? "nil", "control": baseline["data-control"] ?? "nil"]
        ctx.record("基线（无扩展）网络探测", baseline["data-control"] == "loaded", "ad=\(baseline["data-ad"] ?? "nil") control=\(baseline["data-control"] ?? "nil")")
        ctx.manager.close(baselineTab)

        var reports: [[String: Any]] = []
        for source in sources {
            var report: [String: Any] = ["key": source.key, "name": source.name, "version": source.version ?? "unknown",
                                         "source": source.source ?? "", "sha256": source.sha256 ?? ""]
            var areas: [String: Area] = [:]
            defer {
                report["areas"] = areas
                reports.append(report)
                let failed = areas.filter { $0.value["status"] == "fail" }.keys.sorted()
                ctx.record("\(source.name) \(source.version ?? "")", failed.isEmpty,
                           failed.isEmpty ? "all observed areas ok" : "fail: " + failed.joined(separator: ", "))
            }
            guard let file = source.file, let package = try? Data(contentsOf: dir.appendingPathComponent(file)) else {
                areas["install"] = area("untested", "download failed: \(source.downloadError ?? "file missing")")
                continue
            }
            // Install.
            let pending: PendingExtensionInstall
            do {
                pending = try ExtensionInstaller.shared.preparePackage(package, source: .file, storeURL: source.source, seed: source.key)
            } catch {
                areas["install"] = area("fail", error.localizedDescription)
                areas["manifest"] = area("fail", error.localizedDescription)
                continue
            }
            let manifest = pending.manifest
            report["manifestVersion"] = manifest.manifestVersion
            areas["manifest"] = area("ok", "MV\(manifest.manifestVersion) \(manifest.version) background=\(manifest.backgroundKind) content_scripts=\(manifest.contentScripts.count) popup=\(manifest.actionPopup ?? "none")")
            let perms = manifest.apiPermissions
            let unsupportedPerms = perms.filter { ChromeAPIMatrix.permissionLevel($0) == .unsupported }
            let partialPerms = perms.filter { ChromeAPIMatrix.permissionLevel($0) == .partial }
            // Requesting an unsupported permission is not itself a failure; what breaks shows up in the
            // API / behaviour areas (from observed calls), so this area is at worst "partial".
            areas["permissions"] = area(unsupportedPerms.isEmpty && partialPerms.isEmpty ? "ok" : "partial",
                                        "requested=\(perms.joined(separator: ",")) unsupported=\(unsupportedPerms.joined(separator: ",")) partial=\(partialPerms.joined(separator: ","))")
            let started = Date()
            do { try ctx.profile.extensions.install(pending) } catch {
                areas["install"] = area("fail", error.localizedDescription); continue
            }
            guard let ext = ctx.profile.extensions.loaded[pending.extensionID] else {
                areas["install"] = area("fail", "installed but not loaded"); continue
            }
            areas["install"] = area("ok", ext.id)
            let runtime: ExtensionRuntime = ctx.profile.extensions

            // Background.
            if let bg = ext.background {
                let ready = await ctx.waitUntil(20) { bg.isReady || bg.state == .failed }
                areas["background"] = area(bg.isReady ? "ok" : "fail", ready ? bg.diagnostics : "not ready after 20 s: \(bg.diagnostics)")
            } else {
                areas["background"] = area("n/a", "no background")
            }
            // Real rulesets (uBOL ships ~100k rules) take a while to convert and compile; wait for the
            // compile to actually finish and record how long it took.
            let dnrDone = await ctx.waitForDNRCompile(after: started, seconds: 120)
            report["dnrCompile"] = ["finished": dnrDone, "seconds": runtime.dnrStatus.lastDuration, "compiles": runtime.dnrStatus.compileCount,
                                    "converted": runtime.dnrStatus.convertedRules, "lists": runtime.dnrStatus.lists]

            // Page with content scripts.
            let tab = await ctx.open("/compat-page/index.html")
            _ = await ctx.waitUntil(15) { let a = await ctx.attrs(tab); return a["data-ad"] != nil && a["data-control"] != nil }
            let injected = tab.webView.flatMap { $0.url }.map { runtime.contentScripts(for: $0, tab: tab).filter { $0.world.name == Worlds.extensionWorld(ext.id).name }.count } ?? 0
            if manifest.contentScripts.isEmpty {
                areas["content_scripts"] = area("n/a", "none declared")
            } else {
                let csErrors = ext.record.lastErrors.filter { $0.hasPrefix("[content]") }
                areas["content_scripts"] = area(injected > 0 && csErrors.isEmpty ? "ok" : "fail",
                                                "declared=\(manifest.contentScripts.count) injected=\(injected) errors=\(csErrors.prefix(3).joined(separator: " | "))")
            }

            // Behaviour on the page.
            areas["behavior"] = await behavior(source.key, ctx: ctx, tab: tab, ext: ext, baseline: baseline)

            // Popup.
            if let popupPath = manifest.actionPopup, let url = URL(string: ext.baseURL + popupPath) {
                let errorsBefore = ext.record.lastErrors.count
                let holder = PopupHolder()
                holder.load(ExtensionRuntime.PopupRequest(extID: ext.id, url: url, tabID: tab.numericID, title: source.name), runtime: runtime)
                if let webView = holder.webView { BackgroundHostContainer.shared.attach(webView) }
                let loaded = await ctx.waitUntil(15) { holder.webView?.isLoading == false && holder.webView?.url != nil }
                let bodyText = (try? await holder.webView?.rkCall("return document.body ? document.body.innerText.length : -1;")) as? Int ?? -1
                let newErrors = ext.record.lastErrors.dropFirst(errorsBefore).filter { !$0.hasPrefix("[content]") }
                areas["popup"] = area(loaded && bodyText > 0 && newErrors.isEmpty ? "ok" : "fail",
                                      "loaded=\(loaded) textLength=\(bodyText) errors=\(newErrors.prefix(3).joined(separator: " | "))")
                holder.webView?.removeFromSuperview()
                holder.close(runtime: runtime)
            } else {
                areas["popup"] = area("n/a", "no action popup")
            }

            // API areas from observed traffic.
            let stats = runtime.apiStats[ext.id] ?? [:]
            func judge(_ name: String, _ match: (String) -> Bool) {
                let relevant = stats.filter { match($0.key) }
                let calls = relevant.values.reduce(0) { $0 + $1.calls }
                let errors = relevant.values.reduce(0) { $0 + $1.errors }
                let failing = relevant.filter { $0.value.errors > 0 }.map { "\($0.key): \($0.value.lastError ?? "")" }.sorted()
                if calls == 0 { areas[name] = area("untested", "no calls observed"); return }
                areas[name] = area(errors == 0 ? "ok" : (errors < calls ? "partial" : "fail"),
                                   "calls=\(calls) errors=\(errors) " + failing.prefix(3).joined(separator: " | "))
            }
            judge("storage") { $0.hasPrefix("storage.") }
            judge("messaging") { $0 == "runtime.sendMessage" || $0 == "tabs.sendMessage" }
            judge("ports") { $0 == "runtime.connect" || $0.hasPrefix("port.") || $0 == "tabs.connect" }
            judge("scripting") { $0.hasPrefix("scripting.") }
            judge("tabs") { $0.hasPrefix("tabs.") && $0 != "tabs.sendMessage" && $0 != "tabs.connect" }
            let dnrSkipped = runtime.dnrStatus.skipped[ext.id] ?? []
            if manifest.ruleResources.isEmpty && stats.keys.allSatisfy({ !$0.hasPrefix("declarativeNetRequest.") }) {
                areas["dnr"] = area("n/a", "no rulesets, no DNR calls")
            } else {
                judge("dnr") { $0.hasPrefix("declarativeNetRequest.") }
                let base = areas["dnr"]?["detail"] ?? ""
                let enabledSets = ext.enabledRulesetIDs.count
                let converted = runtime.dnrStatus.convertedRules
                let status = converted == 0 && enabledSets > 0 ? "fail" : (dnrSkipped.isEmpty ? (areas["dnr"]?["status"] == "fail" ? "fail" : "ok") : "partial")
                areas["dnr"] = area(status,
                                    "rulesets=\(manifest.ruleResources.count) enabled=\(enabledSets) converted=\(converted) lists=\(runtime.dnrStatus.lists) compile=\(String(format: "%.1f", runtime.dnrStatus.lastDuration))s skipped=\(dnrSkipped.count) \(dnrSkipped.prefix(3).joined(separator: " | ")) \(base)")
            }
            let unsupported = runtime.unsupportedCalls[ext.id] ?? [:]
            report["unsupportedCalls"] = unsupported
            report["apiCalls"] = stats.mapValues { ["calls": $0.calls, "errors": $0.errors, "lastError": $0.lastError ?? ""] }
            report["runtimeErrors"] = Array(ext.record.lastErrors.suffix(10))
            areas["unsupported_apis"] = area(unsupported.isEmpty ? "ok" : "partial",
                                             unsupported.isEmpty ? "none called" : unsupported.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))

            ctx.manager.close(tab)
            runtime.remove(ext.id)
        }
        ctx.extras["extensions"] = reports
    }

    /// Extension-specific, observable effects on the compatibility page.
    static func behavior(_ key: String, ctx: SelfTestContext, tab: BrowserTab, ext: LoadedExtension, baseline: [String: String]) async -> Area {
        switch key {
        case "darkreader":
            let dark = await ctx.waitUntil(15) {
                (await ctx.eval(tab, "return !!document.querySelector('style.darkreader, style[class*=darkreader]') || [...document.documentElement.attributes].some(a => a.name.startsWith('data-darkreader'));") as? Bool) == true
            }
            let bg = await ctx.eval(tab, "return getComputedStyle(document.body).backgroundColor;") as? String ?? ""
            return area(dark && bg != "rgb(255, 255, 255)" ? "ok" : "fail", "darkreader styles injected=\(dark) body background=\(bg)")
        case "ubol":
            let a = await ctx.attrs(tab)
            guard baseline["data-ad"] == "loaded" else {
                return area("untested", "baseline ad request did not load without the extension (\(baseline["data-ad"] ?? "nil")) — network unavailable, cannot attribute blocking")
            }
            let hidden = await ctx.eval(tab, "return getComputedStyle(document.getElementById('ad-slot')).display;") as? String ?? ""
            return area(a["data-ad"] == "error" && a["data-control"] == "loaded" ? "ok" : "fail",
                        "ad script=\(a["data-ad"] ?? "nil") (baseline loaded) control=\(a["data-control"] ?? "nil") ad slot display=\(hidden)")
        case "immersive-translate":
            let found = await ctx.waitUntil(15) {
                (await ctx.eval(tab, "return document.querySelectorAll('[class*=immersive-translate],[id*=immersive-translate],[data-immersive-translate-walked]').length;") as? Int ?? 0) > 0
            }
            let count = await ctx.eval(tab, "return document.querySelectorAll('[class*=immersive-translate],[id*=immersive-translate],[data-immersive-translate-walked]').length;") as? Int ?? 0
            return area(found ? "ok" : "fail", "immersive-translate elements injected=\(count) (translation itself needs the service; only UI injection is checked)")
        case "violentmonkey", "tampermonkey":
            // A userscript manager's core job: its dashboard / popup and background must work.
            let bgOK = ext.background?.isReady == true
            let unsupported = ctx.profile.extensions.unsupportedCalls[ext.id] ?? [:]
            let userScriptsAPI = unsupported.keys.filter { $0.hasPrefix("userScripts") }
            return area(bgOK && userScriptsAPI.isEmpty ? "partial" : "fail",
                        "background ready=\(bgOK); chrome.userScripts calls=\(userScriptsAPI.joined(separator: ",")) — script injection itself is not verified by this suite")
        default:
            return area("untested", "no behaviour probe for \(key)")
        }
    }
}
