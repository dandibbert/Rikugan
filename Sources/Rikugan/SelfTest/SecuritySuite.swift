import Foundation
import WebKit

/// Adversarial security suite. A hostile page and a hostile extension actively try to reach
/// privileged native operations they were never granted:
///
/// - page JS: enumerate globals and message handlers, capture page-world bridge traffic, forge GM
///   calls for a known userscript id (with and without a guessed token), forge XHR / tab / menu /
///   notification requests, dispatch relay-like DOM events, call the per-script dispatch function,
///   impersonate extension content scripts / pages / background, use the tools channel, and plant a
///   cross-origin history entry;
/// - extension B (its own content world): act as extension A, read A's storage, message as A,
///   post into / disconnect A's port (its id deliberately leaked to B), call GM as a userscript.
///
/// The assertions are about effects, verified natively: every forged call is rejected, and no
/// value, tab, menu command, rule, history entry, storage item or port message appears.
@MainActor enum SecuritySuite {
    static func run(_ ctx: SelfTestContext) async {
        let profile = ctx.profile
        let runtime: ExtensionRuntime = ctx.profile.extensions
        let rejectedBefore = SecurityLog.shared.totalRejected

        // Victims and attacker.
        let victim: InstalledUserScript
        let pageScript: InstalledUserScript
        let extA: LoadedExtension
        let extB: LoadedExtension
        do {
            victim = try ctx.installScript("sec/victim.user.js")
            profile.userscripts.replaceValues([:], for: victim.id)
            pageScript = try ctx.installScript("sec/victim-page.user.js")
            extA = try ctx.installExtension("sec-ext-a", seed: "sec-a")
            extB = try ctx.installExtension("sec-ext-b", seed: "sec-b")
        } catch { ctx.record("安装受害者 / 攻击者夹具", false, error.localizedDescription); return }
        ctx.record("世界：受害脚本（特权）在隔离环境", !victim.usesPageWorld)
        ctx.record("世界：@inject-into page 脚本在页面环境且无特权", pageScript.usesPageWorld && pageScript.metadata.unavailableInPageWorld == ["GM_setValue"])
        _ = await ctx.waitUntil(20) { extA.background?.isReady == true && extB.background?.isReady == true }

        let tabsBefore = ctx.manager.tabs.count
        let rulesBefore = ctx.services.adBlock.customRules
        let tab = await ctx.open("/sec/index.html")
        let ready = await ctx.waitUntil(15) {
            let a = await ctx.attrs(tab)
            return a["data-victim-ready"] == "ok" && a["data-a-ready"] == "1" && a["data-b-ready"] == "1" && !(a["data-a-port"] ?? "").isEmpty && a["data-victim-page"] != nil
        }
        let attrs = await ctx.attrs(tab)
        ctx.record("夹具就绪（受害脚本、A、B 内容脚本）", ready, attrs.filter { $0.key.hasPrefix("data-") }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        ctx.record("@inject-into page 脚本调用特权 GM 被拒绝", attrs["data-victim-page"] == "denied", attrs["data-victim-page"] ?? "nil")
        let aPort = attrs["data-a-port"] ?? ""
        let valuesBefore = profile.userscripts.values(for: victim.id)
        let menusBefore = tab.menuCommands.map(\.title)
        let historyBefore = profile.history.entries.count
        let aStorageBefore = runtime.storage(extA, area: "local")

        // --- Hostile page attacks ------------------------------------------------------------------
        let params: [String: Any] = ["sid": victim.id.uuidString, "pageSid": pageScript.id.uuidString, "extA": extA.id, "extB": extB.id, "aPort": aPort]
        let (pageRaw, pageError) = await ctx.evalResult(tab, "return await window.__attack(p);", world: .page, arguments: ["p": params])
        let page = (pageRaw as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        ctx.extras["pageAttack"] = page
        ctx.record("恶意页面攻击脚本执行完成", pageError == nil && !page.isEmpty, pageError ?? "\(page.count) results")
        let mustReject = ["gmGetAll", "gmGetAllGuessToken", "gmSetValue", "gmXhr", "gmXhrAbortForgedId", "gmOpenTab", "gmMenu", "gmNotify",
                          "gmImpersonatePageScript", "gmUnknownScript", "chromeAsContentA", "chromeAsPageA", "chromeAsBackgroundA",
                          "chromeScriptingA", "chromeRuntimeA", "chromePortA", "toolsPicker", "toolsCredential"]
        for key in mustReject {
            let outcome = page[key] ?? "missing"
            ctx.record("页面伪造 \(key) 被拒绝", outcome.hasPrefix("rejected:"), String(outcome.prefix(160)))
        }
        let globals = page["suspiciousGlobals"] ?? ""
        // Dispatch functions or anything credential-like; native interfaces (DOMTokenList) excluded.
        let nativeInterfaces: Set<String> = ["DOMTokenList"]
        let leakedGlobals = globals.split(separator: ",").map(String.init).filter {
            !nativeInterfaces.contains($0) && $0.range(of: "__rikuganGM|token|secret|credential", options: [.regularExpression, .caseInsensitive]) != nil
        }
        ctx.record("页面全局中没有 GM 分发函数或凭据", leakedGlobals.isEmpty, "leaked=\(leakedGlobals) all=\(globals.isEmpty ? "none" : globals)")
        let markers = page["runMarkers"] ?? "missing"
        ctx.record("页面可见的脚本运行标记只含 true（不含凭据 / 值）",
                   markers == "none" || markers.split(separator: ",").allSatisfy { $0 == "boolean:true" }, markers)
        ctx.record("页面拦截到的 GM 桥消息数为 0（页面环境脚本不发任何特权消息）", page["capturedGM"] == "0", page["capturedGM"] ?? "nil")
        ctx.record("页面 HTML 中不含脚本存储值", page["htmlHasSecret"] == "false", page["htmlHasSecret"] ?? "nil")
        ctx.record("页面拿不到受害脚本的分发函数", page["dispatchFunction"] == "undefined", page["dispatchFunction"] ?? "nil")
        ctx.extras["pageVisibleHandlers"] = page["handlers"] ?? ""

        // --- Hostile extension B attacks -------------------------------------------------------------
        let (bRaw, bError) = await ctx.evalResult(tab, "return await globalThis.__attackB(p);", world: Worlds.extensionWorld(extB.id), arguments: ["p": params])
        let b = (bRaw as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        ctx.extras["extensionBAttack"] = b
        ctx.record("扩展 B 攻击脚本执行完成", bError == nil && !b.isEmpty, bError ?? "\(b.count) results")
        for key in ["storageAsAContent", "storageAsAPage", "messageAsA", "tabsAsABackground", "portPostClaimingA", "gmAsVictim"] {
            let outcome = b[key] ?? "missing"
            ctx.record("扩展 B 冒充 A / 脚本：\(key) 被拒绝", outcome.hasPrefix("rejected:"), String(outcome.prefix(160)))
        }
        ctx.record("扩展 B 自己的存储中没有 A 的数据", (b["ownStorage"] ?? "").hasPrefix("resolved:") && !(b["ownStorage"] ?? "").contains("a-secret"),
                   String((b["ownStorage"] ?? "missing").prefix(120)))

        // --- Effects (verified natively) --------------------------------------------------------------
        // Let any (wrongly) accepted asynchronous effect land before checking — condition-based wait
        // for A's port to answer, which also proves the port survived the attacks.
        let (echo, echoError) = await ctx.evalResult(tab, "return await globalThis.__aEcho('after-attacks');", world: Worlds.extensionWorld(extA.id))
        ctx.record("A 的端口在攻击后仍正常工作（未被劫持 / 断开）", echo as? String == "after-attacks", echoError ?? String(describing: echo))
        _ = await ctx.waitUntil(5) { (runtime.storage(extA, area: "local")["portLog"] ?? "").contains("after-attacks") }
        let aStorage = runtime.storage(extA, area: "local")
        let portLog = aStorage["portLog"] ?? ""
        ctx.record("A 的端口没有收到伪造消息", !portLog.contains("evil"), portLog)
        ctx.record("A 的存储未被篡改（秘密仍在、无 evil 标记）", aStorage["aSecret"] == aStorageBefore["aSecret"] && aStorage["evilMessage"] == nil,
                   "keys=\(aStorage.keys.sorted())")
        let valuesAfter = profile.userscripts.values(for: victim.id)
        ctx.record("受害脚本的 GM 存储未被篡改", valuesAfter == valuesBefore && valuesAfter["attacker"] == nil, "keys=\(valuesAfter.keys.sorted())")
        ctx.record("没有打开新标签页", ctx.manager.tabs.count == tabsBefore + 1 && !ctx.manager.tabs.contains { $0.url?.host == "evil.example" },
                   "tabs \(tabsBefore)+1 → \(ctx.manager.tabs.count)")
        ctx.record("没有注册伪造的菜单命令", tab.menuCommands.map(\.title) == menusBefore && !tab.menuCommands.contains { $0.title == "Evil" },
                   tab.menuCommands.map(\.title).joined(separator: ","))
        ctx.record("没有写入伪造的拦截规则", ctx.services.adBlock.customRules == rulesBefore)
        ctx.record("没有写入跨源的伪造历史记录", !profile.history.entries.contains { $0.url.contains("forged.example") },
                   "history \(historyBefore) → \(profile.history.entries.count)")
        let rejected = SecurityLog.shared.totalRejected - rejectedBefore
        ctx.record("拒绝均有记录（SecurityLog）", rejected >= mustReject.count, "\(rejected) rejections logged")
        ctx.extras["securityLog"] = SecurityLog.shared.entries.suffix(40).map(\.message)

        // Diagnostics export privacy: the bug-report file carries the rejection count but none of the
        // secrets, stored values or full URLs present in this run.
        ErrorLog.shared.record("probe https://user:pw@private.example/path/secret-page?token=abc", source: "security-suite")
        let exported = (try? DiagnosticsReport.collect().json()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let leaks = ["victim-secret", "a-secret", "secret-page", "token=abc", "user:pw", "/sec/index.html"].filter { exported.contains($0) }
        ctx.record("诊断导出不含存储值 / 秘密 / 完整网址", !exported.isEmpty && leaks.isEmpty, leaks.isEmpty ? "\(exported.count) bytes" : "leaked: \(leaks)")
        let required = ["\"backgroundRuntime\"", "\"security\"", "\"featureFlags\"", "\"compatibilityMatrixVersion\"", "\"manualTests\"", "\"gitCommit\"", "\"privacy\"", "not CI results"]
        let missing = required.filter { !exported.contains($0) }
        ctx.record("诊断导出包含必需字段（后台、安全、开关、矩阵版本、人工清单、commit、隐私声明）", missing.isEmpty, missing.isEmpty ? "ok" : "missing: \(missing)")
        ctx.record("诊断导出中的安全拒绝计数与日志一致", exported.contains("\"rejectedPrivilegedCalls\" : \(SecurityLog.shared.totalRejected)"))
        ctx.record("诊断导出中的网址只保留域名", exported.contains("https://private.example/…"))

        // Legitimate paths still work (the fixes did not break the victims).
        if let command = tab.menuCommands.first(where: { $0.title == "Victim command" }) {
            tab.runMenuCommand(command)
            _ = await ctx.waitUntil(5) { await ctx.attr(tab, "data-victim-menu") == "ran" }
        }
        ctx.record("合法路径：受害脚本自己的菜单命令仍可用", await ctx.attr(tab, "data-victim-menu") == "ran")

        ctx.manager.close(tab)
        runtime.remove(extA.id)
        runtime.remove(extB.id)
        profile.userscripts.delete(victim.id)
        profile.userscripts.delete(pageScript.id)
    }
}
