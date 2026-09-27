import XCTest
import WebKit
@testable import Rikugan

final class CoreTests: XCTestCase {
    let source = """
    // ==UserScript==
    // @name Test
    // @match https://*.example.com/*
    // @exclude-match https://example.com/private/*
    // @grant GM_getValue
    // @grant GM.setValue
    // @connect api.example.com
    // @noframes
    // @run-at document-start
    // ==/UserScript==
    console.log('hello');
    """
    func testMetadata() throws {
        let script = try UserScript.parse(source)
        XCTAssertEqual(script.name, "Test"); XCTAssertEqual(script.runAt, "document-start")
        XCTAssertTrue(script.noFrames); XCTAssertTrue(script.isolated)
        XCTAssertTrue(script.permits("getValue")); XCTAssertTrue(script.permits("setValue"))
        XCTAssertFalse(script.permits("xmlHttpRequest"))
    }
    func testURLMatchingAndExclusion() throws {
        let script = try UserScript.parse(source)
        XCTAssertTrue(script.matchesURL(URL(string: "https://example.com/a?query=x")!))
        XCTAssertTrue(script.matchesURL(URL(string: "https://sub.example.com/")!))
        XCTAssertFalse(script.matchesURL(URL(string: "https://example.com.evil.test/")!))
        XCTAssertFalse(script.matchesURL(URL(string: "http://example.com/")!))
        XCTAssertFalse(script.matchesURL(URL(string: "https://example.com/private/account")!))
        XCTAssertFalse(script.matchesURL(URL(string: "file:///etc/passwd")!))
        XCTAssertTrue(URLRules.match("http://127.0.0.1/*", url: URL(string: "http://127.0.0.1:8765/test?q=1#hash")!))
    }
    func testUnsupportedPermissionsFailClosed() {
        XCTAssertThrowsError(try UserScript.parse(source.replacingOccurrences(of: "GM_getValue", with: "unsafeWindow")))
        XCTAssertThrowsError(try UserScript.parse(source.replacingOccurrences(of: "GM_getValue", with: "none")))
        XCTAssertThrowsError(try UserScript.parse("not a userscript"))
    }
    func testCrossOriginPolicy() {
        let origin = URL(string: "https://example.com")!
        XCTAssertTrue(URLRules.connectionAllowed(URL(string: "https://api.example.com/v1")!, origin: origin, rules: ["api.example.com"]))
        XCTAssertFalse(URLRules.connectionAllowed(URL(string: "https://api.example.com.evil.test")!, origin: origin, rules: ["api.example.com"]))
        XCTAssertFalse(URLRules.connectionAllowed(URL(string: "file:///tmp/a")!, origin: origin, rules: ["*"]))
        XCTAssertFalse(URLRules.connectionAllowed(URL(string: "https://user:password@example.com/")!, origin: origin, rules: ["*"]))
        XCTAssertTrue(URLRules.connectionAllowed(origin, origin: origin, rules: ["self"]))
    }
    func testSearchEscapesQuery() {
        let url = URLRules.inputURL("a+b & c", searchEngine: "https://example.com/?q=")!
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a+b & c")
        XCTAssertEqual(URLRules.inputURL("example.com", searchEngine: "")?.absoluteString, "https://example.com")
        XCTAssertNil(URLRules.inputURL("  ", searchEngine: ""))
    }
    func testStateRoundTrip() throws {
        var state = AppState.fresh()
        state.profiles[0].scripts = [try UserScript.parse(source)]
        state.profiles.append(BrowserProfile(name: "工作"))
        let copy = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(copy.profiles, state.profiles)
        XCTAssertNotEqual(copy.profiles[0].id, copy.profiles[1].id)
        XCTAssertTrue(copy.profiles[1].scripts.isEmpty)
    }
    @MainActor func testNamedWebsiteStores() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(WKWebsiteDataStore(forIdentifier: a).identifier, a)
        XCTAssertEqual(WKWebsiteDataStore(forIdentifier: b).identifier, b)
        XCTAssertNotEqual(a, b)
    }
    func testBundledResourcesAndArchive() throws {
        let zip = try XCTUnwrap(Bundle.main.url(forResource: "DemoExtension", withExtension: "zip"))
        XCTAssertNoThrow(try ArchiveValidator.validate(Data(contentsOf: zip)))
        XCTAssertNotNil(Bundle.main.url(forResource: "UserscriptRuntime", withExtension: "js"))
        let script = try XCTUnwrap(Bundle.main.url(forResource: "Demo", withExtension: "user.js"))
        XCTAssertEqual(try UserScript.parse(String(contentsOf: script)).name, "Rikugan Demo Script")
        XCTAssertThrowsError(try ArchiveValidator.validate(Data("not a zip".utf8)))
    }
    func testAdBlockVerdictAndCompile() {
        let blocked = AdBlockEngine.verdict(url: URL(string: "https://ads.doubleclick.net/pagead")!, lines: AdBlockEngine.builtin)
        XCTAssertEqual(blocked, .block)
        let allowed = AdBlockEngine.verdict(url: URL(string: "https://ads.doubleclick.net/pagead")!, lines: ["@@||doubleclick.net^", "||doubleclick.net^"])
        XCTAssertEqual(allowed, .allow)
        XCTAssertEqual(AdBlockEngine.verdict(url: URL(string: "https://example.com/")!, lines: AdBlockEngine.builtin), .none)
        let compiled = AdBlockEngine.compile(lines: ["||doubleclick.net^", "example.com##.ad-banner", "##.adsbygoogle"])
        XCTAssertTrue(compiled.json.contains("css-display-none"))
        XCTAssertTrue(compiled.networkJSON.contains("block"))
        XCTAssertFalse(compiled.networkJSON.contains("css-display-none"))
        XCTAssertTrue(compiled.globalCSS.contains(".adsbygoogle"))
        XCTAssertEqual(compiled.hostSelectors["example.com"], [".ad-banner"])
    }
    func testZipCRXAndCapabilityMatrix() throws {
        let manifest = Data(#"{"manifest_version":3,"name":"T","version":"1.2.3","permissions":["storage"]}"#.utf8)
        let zip = ZipArchive.store([("manifest.json", manifest)])
        XCTAssertNoThrow(try ArchiveValidator.validate(zip))
        let extracted = try XCTUnwrap(ZipArchive.extract(data: zip, path: "manifest.json"))
        let parsed = try ExtensionManifest.parse(extracted)
        XCTAssertEqual(parsed.name, "T")
        XCTAssertEqual(parsed.manifestVersion, 3)
        XCTAssertThrowsError(try ExtensionManifest.parse(Data(#"{"manifest_version":2,"name":"Old","version":"1"}"#.utf8)))
        var crx = Data("Cr24".utf8)
        crx.append(contentsOf: [2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        crx.append(zip)
        XCTAssertNoThrow(try ArchiveValidator.validate(try CRXArchive.zipData(from: crx)))
        var crx3 = Data("Cr24".utf8)
        crx3.append(contentsOf: [3, 0, 0, 0, 0, 0, 0, 0])
        crx3.append(zip)
        XCTAssertEqual(try ZipArchive.extract(data: try CRXArchive.zipData(from: crx3), path: "manifest.json"), manifest)
        XCTAssertEqual(ChromeAPIMatrix.entries.first { $0.api == "debugger" }?.level, "Unsupported")
        XCTAssertEqual(ChromeAPIMatrix.entries.first { $0.api == "nativeMessaging" }?.level, "Unsupported")
        XCTAssertEqual(ChromeAPIMatrix.additions(old: ["storage"], new: ["tabs", "storage"]), ["tabs"])
        XCTAssertEqual(ExtensionCatalog.storeID(from: "abcdefghijklmnopabcdefghijklmnop"), "abcdefghijklmnop")
    }
    func testVersionsOmniboxAndMigration() throws {
        XCTAssertTrue(VersionComparator.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertFalse(VersionComparator.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(VersionComparator.isNewer("2", than: "1.9.9"))
        let keyword = try XCTUnwrap(URLRules.inputURL("g cats", searchEngine: "https://example.com/?q="))
        XCTAssertTrue(keyword.absoluteString.contains("google.com"))
        XCTAssertTrue(keyword.absoluteString.contains("cats"))
        let engine = SearchEngine(name: "C", template: "https://example.com/search?q={query}", keyword: "zz")
        let custom = try XCTUnwrap(URLRules.inputURL("zz a+b", searchEngine: "", customEngines: [engine]))
        XCTAssertEqual(URLComponents(url: custom, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a+b")
        let jump = URLRules.inputURL("gh", searchEngine: "https://example.com/?q=", shortcuts: [URLShortcut(keyword: "gh", url: "https://github.com/")])
        XCTAssertEqual(jump?.absoluteString, "https://github.com/")
        XCTAssertEqual(URLRules.inputURL("chrome://extensions", searchEngine: "")?.scheme, "chrome")
        XCTAssertEqual(InternalPages.kind(URL(string: "edge://extensions")!), "extensions")
        XCTAssertEqual(InternalPages.kind(URL(string: "rikugan://settings")!), "settings")
        let profileID = UUID(), tabID = UUID()
        let legacy: [String: Any] = [
            "schema": 1, "activeProfileID": profileID.uuidString,
            "profiles": [[
                "id": profileID.uuidString, "name": "旧身份", "symbol": "person.crop.circle",
                "tabs": [["id": tabID.uuidString, "url": "https://example.com", "title": "旧", "desktop": false]],
                "selectedTabID": NSNull(), "bookmarks": [], "history": [], "scripts": [], "extensions": [],
                "searchEngine": "https://www.google.com/search?q="
            ]]
        ]
        let migrated = try StateMigration.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated.schema, 2)
        XCTAssertEqual(migrated.profiles[0].name, "旧身份")
        XCTAssertEqual(migrated.profiles[0].tabs.first?.url, "https://example.com")
        XCTAssertTrue(migrated.profiles[0].settings.contentBlocking)
        XCTAssertTrue(migrated.profiles[0].tabGroups.isEmpty)
    }
    func testScriptMetadataAndBackup() throws {
        let meta = """
        // ==UserScript==
        // @name Meta
        // @author Ada
        // @include https://example.com/*
        // @exclude /private/
        // @resource style https://example.com/a.css
        // @run-at document-body
        // @grant GM_getResourceText
        // ==/UserScript==
        console.log('meta');
        """
        let script = try UserScript.parse(meta)
        XCTAssertEqual(script.author, "Ada")
        XCTAssertEqual(script.runAt, "document-body")
        XCTAssertEqual(script.resources.first?.name, "style")
        XCTAssertTrue(script.permits("getResourceText"))
        XCTAssertTrue(script.matchesURL(URL(string: "https://example.com/a")!))
        XCTAssertFalse(script.matchesURL(URL(string: "https://example.com/private")!))
        var backup = PortableBackup()
        backup.tabs = [SavedTab(url: "https://example.com", title: "E")]
        backup.searchHistory = ["cats"]
        backup.settings.customRules = [CustomBlockRule(text: "||example.net^")]
        let copy = try JSONDecoder().decode(PortableBackup.self, from: JSONEncoder().encode(backup))
        XCTAssertEqual(copy.tabs.first?.title, "E")
        XCTAssertEqual(copy.searchHistory, ["cats"])
        XCTAssertEqual(copy.settings.customRules.first?.text, "||example.net^")
    }
    func testAdBlockOptionsCosmeticAndChunks() {
        let compiled = AdBlockEngine.compile(lines: [
            "||tracker.test^$script,third-party",
            "@@||tracker.test^$domain=news.test",
            "example.com#$#body{background:#fff}",
            "example.com#?#div:has(.ad)",
            "example.com#?#div:has-text(Sponsored)",
            "#%#scriptlet",
            "example.com#%#//scriptlet('abort-on-property-read', 'alert')",
            "example.com##+js(set-constant, canRunAds, false)",
            "||ads.test^$redirect=noopjs",
            "||pixel.test^$redirect=1x1",
            "||blank.test^$redirect=empty",
            "||news.example^$removeparam=utm_source",
            "||news.example^$csp=script-src 'none'",
            "||news.example^$replace=/a/b/",
            "##.adsbygoogle",
            "||tracker.test^$xmlhttprequest",
            "example.com#?#:xpath(//div[@class='ad'])",
            "example.com#?#.banner:upward(2)",
            "example.com#?#.banner:matches-css(display, none)",
            "example.com#?#.banner:remove()",
            "example.com#?#.banner:style(color:red)"
        ], limit: 2)
        XCTAssertTrue(compiled.networkJSON.contains("\"script\""))
        XCTAssertTrue(compiled.networkJSON.contains("third-party"))
        XCTAssertTrue(compiled.networkJSON.contains("news.test"))
        XCTAssertTrue(compiled.hostCSS["example.com"]?.contains("background:#fff") == true)
        XCTAssertTrue(compiled.hostCSS["example.com"]?.contains("div:has(.ad)") == true)
        XCTAssertTrue(compiled.proceduralJSON.contains("Sponsored"))
        XCTAssertTrue(compiled.proceduralJSON.contains("has-text"))
        XCTAssertTrue(compiled.proceduralJSON.contains("xpath"))
        XCTAssertTrue(compiled.proceduralJSON.contains("upward"))
        XCTAssertTrue(compiled.proceduralJSON.contains("matches-css"))
        XCTAssertTrue(compiled.proceduralJSON.contains("remove"))
        XCTAssertTrue(compiled.networkJSON.contains("raw"))
        XCTAssertTrue(compiled.proceduralJSON.contains("color:red"))
        XCTAssertTrue(compiled.globalCSS.contains(".adsbygoogle"))
        XCTAssertFalse(compiled.scriptletJSON.contains("\"scriptlet\""))
        XCTAssertTrue(compiled.scriptletJSON.contains("abort-on-property-read"))
        XCTAssertTrue(compiled.scriptletJSON.contains("set-constant"))
        XCTAssertTrue(compiled.scriptletJSON.contains("__rgRedirect.noopjs"))
        XCTAssertTrue(compiled.scriptletJSON.contains("noopFunc"))
        XCTAssertTrue(compiled.scriptletJSON.contains("prevent-fetch"))
        XCTAssertTrue(compiled.scriptletJSON.contains("ads.test"))
        XCTAssertTrue(compiled.scriptletJSON.contains("__rgRedirect.empty"))
        XCTAssertTrue(compiled.scriptletJSON.contains("__rgRedirect.pixel"))
        XCTAssertTrue(compiled.networkJSON.contains("block"))
        XCTAssertFalse(compiled.networkJSON.contains("redirect"))
        XCTAssertEqual(compiled.removeParams.first?.key, "utm_source")
        XCTAssertTrue(compiled.cspJSON.contains("script-src 'none'"))
        XCTAssertTrue(compiled.replaceJSON.contains("\"regex\":\"a\""))
        XCTAssertTrue(compiled.replaceJSON.contains("news.example"))
        let stripped = AdBlockEngine.urlByStripping(URL(string: "https://www.news.example/a?utm_source=x&id=1")!, rules: compiled.removeParams)
        XCTAssertEqual(stripped?.absoluteString, "https://www.news.example/a?id=1")
        XCTAssertNil(AdBlockEngine.urlByStripping(URL(string: "https://other.example/a?utm_source=x")!, rules: compiled.removeParams))
        XCTAssertGreaterThan(compiled.chunks.count, 1)
        XCTAssertEqual(AdBlockEngine.chunkDefault, 50_000)
    }
    func testPlaylistsSuggestionsUpdatesFontsAndPrivateScripts() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720
        hi/index.m3u8
        """
        let variants = PlaylistText.parseM3U8(master, base: URL(string: "https://cdn.example/video/master.m3u8")!)
        XCTAssertEqual(variants.count, 2)
        XCTAssertEqual(variants[0].width, 640)
        XCTAssertEqual(variants[0].bandwidth, 800000)
        XCTAssertTrue(variants[1].url.contains("hi/index.m3u8"))
        let dash = PlaylistText.parseMPD("<MPD><Representation bandwidth=\"900000\" width=\"640\" height=\"360\"><BaseURL>v.mp4</BaseURL></Representation></MPD>", base: URL(string: "https://cdn.example/dash/")!)
        XCTAssertEqual(dash.first?.url, "https://cdn.example/dash/v.mp4")
        XCTAssertEqual(dash.first?.kind, "dash")
        let suggestions = SearchSuggest.parse(Data("[\"cats\",[\"cats food\",\"cats toys\"]]".utf8))
        XCTAssertEqual(suggestions, ["cats food", "cats toys"])
        XCTAssertTrue(SearchSuggest.endpoint(template: "https://www.google.com/search?q=", query: "cats")?.host?.contains("google.com") == true)
        XCTAssertTrue(SearchSuggest.endpoint(template: "https://www.bing.com/search?q=", query: "cats")?.host?.contains("bing.com") == true)
        XCTAssertTrue(SearchSuggest.endpoint(template: "https://search.brave.com/search?q=", query: "cats")?.absoluteString.contains("search.brave.com/api/suggest") == true)
        XCTAssertTrue(SearchSuggest.endpoint(template: "https://search.yahoo.com/search?p=", query: "cats")?.absoluteString.contains("gossip") == true)
        XCTAssertTrue(SearchSuggest.endpoint(template: "https://www.baidu.com/s?wd=", query: "cats")?.absoluteString.contains("sugrec") == true)
        XCTAssertTrue(SearchSuggest.endpoint(template: "https://www.startpage.com/search?q=", query: "cats")?.absoluteString.contains("startpage.com/suggestions") == true)
        XCTAssertTrue(SearchSuggest.endpoint(template: "https://search.naver.com/search.naver?query=", query: "cats")?.host?.contains("naver.com") == true)
        XCTAssertTrue(SearchSuggest.endpoint(template: "https://yandex.com/search/?text=", query: "cats")?.absoluteString.contains("suggest.yandex.com") == true)
        XCTAssertEqual(SearchSuggest.parse(Data("{\"gossip\":{\"results\":[{\"key\":\"cats food\"}]}}".utf8)), ["cats food"])
        XCTAssertEqual(SearchSuggest.parse(Data("{\"g\":[{\"q\":\"baidu cats\"}]}".utf8)), ["baidu cats"])
        XCTAssertEqual(SearchSuggest.parse(Data("{\"items\":[[\"naver cats\"]]}".utf8)), ["naver cats"])
        XCTAssertNil(SearchSuggest.endpoint(template: "https://example.com/?q=", query: "cats"))
        let xml = """
        <gupdate><app appid="abcdefghijklmnop"><updatecheck codebase="https://example.com/ext.crx" version="1.2.3" /></app></gupdate>
        """
        let update = try XCTUnwrap(ExtensionUpdateManifest.package(in: Data(xml.utf8)))
        XCTAssertEqual(update.url.absoluteString, "https://example.com/ext.crx")
        XCTAssertEqual(update.version, "1.2.3")
        XCTAssertNil(ExtensionUpdateManifest.package(in: Data("not xml".utf8)))
        XCTAssertThrowsError(try FontLibrary.rejectUnsupported(Data("wOFF".utf8), ext: "ttf"))
        XCTAssertThrowsError(try FontLibrary.rejectUnsupported(Data([0, 1, 2, 3]), ext: "woff2"))
        XCTAssertNoThrow(try FontLibrary.rejectUnsupported(Data([0, 1, 2, 3]), ext: "otf"))
        XCTAssertFalse(ScriptVault.persists(isPrivate: true))
        XCTAssertTrue(ScriptVault.persists(isPrivate: false))
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.searchSuggestions)
        XCTAssertEqual(settings.homepageURL, "")
        let notifications = try XCTUnwrap(ChromeAPIMatrix.entries.first { $0.api == "notifications" })
        XCTAssertEqual(notifications.level, "Partial")
        XCTAssertTrue(notifications.note.contains("create"))
        XCTAssertTrue(notifications.note.contains("clear"))
        XCTAssertTrue(notifications.note.contains("getAll"))
        XCTAssertTrue(notifications.note.contains("update"))
        XCTAssertTrue(notifications.note.contains("onClicked"))
        XCTAssertFalse(notifications.note.contains("onClicked、按钮和 update 没有"))
        XCTAssertFalse(notifications.note.contains("不会被记成成功"))
        XCTAssertFalse(notifications.note.contains("没有自研 chrome.notifications"))
        let scripting = try XCTUnwrap(ChromeAPIMatrix.entries.first { $0.api == "scripting" })
        XCTAssertEqual(scripting.level, "Partial")
        XCTAssertTrue(scripting.note.contains("insertCSS"))
        XCTAssertTrue(scripting.note.contains("executeScript"))
        XCTAssertTrue(scripting.note.contains("files"))
        XCTAssertFalse(scripting.note.contains("扩展详情调用"))
        XCTAssertEqual(ChromeAPIMatrix.entries.first { $0.api == "debugger" }?.level, "Unsupported")
        let css = try XCTUnwrap(ExtensionScripting.insertCSSExpression("body{color:red}"))
        XCTAssertTrue(css.contains("insertExtensionCSS"))
        XCTAssertTrue(css.contains("color:red"))
        XCTAssertEqual(ExtensionScripting.executeScriptSource("document.title='fixture'"), "document.title='fixture'")
        XCTAssertEqual(AdBlockEngine.verdict(url: URL(string: "https://ads.example/banner.js")!, lines: ["||ads.example^"]), .block)
        XCTAssertEqual(AdBlockEngine.verdict(url: URL(string: "https://news.example/")!, lines: ["||ads.example^"]), .none)
        var memory: [UUID: [String: Any]] = [:]
        let scriptID = UUID()
        XCTAssertNil(ScriptVault.commit(isPrivate: true, scriptID: scriptID, stored: ["secret": "x"], json: "{\"secret\":\"x\"}", memory: &memory))
        XCTAssertEqual(memory[scriptID]?["secret"] as? String, "x")
        var untouched = memory
        XCTAssertEqual(ScriptVault.commit(isPrivate: false, scriptID: scriptID, stored: ["secret": "y"], json: "{\"secret\":\"y\"}", memory: &untouched), "{\"secret\":\"y\"}")
        XCTAssertEqual(untouched[scriptID]?["secret"] as? String, "x")
        let page = URL(string: "https://example.com/a")!
        let same = URL(string: "https://example.com/b")!
        let other = URL(string: "https://cdn.example/b")!
        XCTAssertTrue(ScriptRequestCookies.shouldAttach(page: page, request: same, permitted: true))
        XCTAssertFalse(ScriptRequestCookies.shouldAttach(page: page, request: other, permitted: true))
        XCTAssertFalse(ScriptRequestCookies.shouldAttach(page: page, request: same, permitted: false))
        let card = AutofillItem(kind: "payment", title: "卡", host: "shop.example", username: "", secret: "4242424242424242", paymentLast4: "4242")
        let payload = AutofillVault.fillPayload(card)
        XCTAssertEqual(payload["cardNumber"], "4242424242424242")
        XCTAssertEqual(payload["paymentLast4"], "4242")
        let merged = AutofillVault.merge(local: [card], remote: [AutofillItem(id: card.id, kind: "payment", title: "新卡", host: "shop.example", username: "", secret: "4000000000000002", paymentLast4: "0002")])
        XCTAssertEqual(merged.first?.secret, "4000000000000002")
    }
    func testGrantNonePageWorldAndRequire() throws {
        let page = """
        // ==UserScript==
        // @name Page
        // @match https://example.com/*
        // @require https://example.com/lib.js
        // @grant none
        // ==/UserScript==
        unsafeWindow.document.title = "x";
        """
        let script = try UserScript.parse(page)
        XCTAssertFalse(script.isolated)
        XCTAssertEqual(script.requires, ["https://example.com/lib.js"])
        XCTAssertTrue(script.permits("registerMenuCommand"))
        XCTAssertFalse(BrowserSession.shouldPersistTab(isPrivate: false, windowID: UUID()))
        XCTAssertFalse(BrowserSession.shouldPersistTab(isPrivate: true, windowID: nil))
        XCTAssertTrue(BrowserSession.shouldPersistTab(isPrivate: false, windowID: nil))
        XCTAssertEqual(BrowserSession.faviconKey("News.Example.com"), "news.example.com")
        XCTAssertFalse(BrowserSession.faviconKey("a/b").contains("/"))
    }
    func testExtensionBridgePayloads() throws {
        let css = ExtensionBridge.command(api: "scripting.insertCSS", details: ["css": "body{color:red}", "world": "MAIN", "target": ["tabId": 3]])
        XCTAssertEqual(css.css, "body{color:red}")
        XCTAssertNil(css.error)
        let code = ExtensionBridge.command(api: "scripting.executeScript", details: ["func": "function () { return 1 }", "args": [2]])
        XCTAssertTrue(code.code?.contains("function () { return 1 }") == true)
        XCTAssertTrue(code.code?.contains("[2]") == true)
        XCTAssertTrue(code.isolated)
        XCTAssertNil(code.error)
        let mainWorld = ExtensionBridge.command(api: "scripting.executeScript", details: ["code": "1", "world": "MAIN"])
        XCTAssertFalse(mainWorld.isolated)
        XCTAssertEqual(mainWorld.code, "1")
        let files = ExtensionBridge.command(api: "scripting.executeScript", details: ["files": ["a.js"], "code": "1"])
        XCTAssertNil(files.error)
        XCTAssertEqual(files.files, ["a.js"])
        XCTAssertTrue(files.isolated)
        let cssFiles = ExtensionBridge.command(api: "scripting.insertCSS", details: ["files": ["a.css"], "world": "ISOLATED"])
        XCTAssertNil(cssFiles.error)
        XCTAssertEqual(cssFiles.kind, "css")
        XCTAssertEqual(cssFiles.files, ["a.css"])
        var records: [String: ExtensionNoticeRecord] = [:]
        var delivered: [(String, String)] = []
        let created = ExtensionBridge.apply(api: "notifications.create", details: ["id": "rikugan-demo", "options": ["title": "Rikugan", "message": "通知已创建", "buttons": [["title": "Open"]]]], records: &records) { record in
            delivered.append((record.title, record.message))
        }
        XCTAssertEqual(created.result as? String, "rikugan-demo")
        XCTAssertNil(created.error)
        XCTAssertEqual(records["rikugan-demo"]?.title, "Rikugan")
        XCTAssertEqual(records["rikugan-demo"]?.message, "通知已创建")
        XCTAssertEqual(records["rikugan-demo"]?.buttons, ["Open"])
        XCTAssertEqual(delivered.first?.0, "Rikugan")
        XCTAssertEqual(delivered.first?.1, "通知已创建")
        let updated = ExtensionBridge.apply(api: "notifications.update", details: ["id": "rikugan-demo", "options": ["title": "Updated", "message": "changed"]], records: &records) { record in
            delivered.append((record.title, record.message))
        }
        XCTAssertEqual(updated.result as? Bool, true)
        XCTAssertEqual(records["rikugan-demo"]?.title, "Updated")
        XCTAssertEqual(records["rikugan-demo"]?.message, "changed")
        XCTAssertEqual(records["rikugan-demo"]?.buttons, ["Open"])
        XCTAssertEqual(delivered.last?.0, "Updated")
        let missingUpdate = ExtensionBridge.apply(api: "notifications.update", details: ["id": "missing"], records: &records) { _ in }
        XCTAssertEqual(missingUpdate.result as? Bool, false)
        let listed = ExtensionBridge.apply(api: "notifications.getAll", details: [:], records: &records) { _ in }
        let map = try XCTUnwrap(listed.result as? [String: [String: Any]])
        XCTAssertEqual(map["rikugan-demo"]?["message"] as? String, "changed")
        let cleared = ExtensionBridge.apply(api: "notifications.clear", details: ["id": "rikugan-demo"], records: &records) { _ in }
        XCTAssertEqual(cleared.result as? Bool, true)
        XCTAssertNil(records["rikugan-demo"])
        let bridge = "/* rikugan-extension-bridge */\nfunction installRikuganExtensionBridge(){}"
        XCTAssertEqual(ExtensionBridge.patchWorker(ExtensionBridge.patchWorker("console.log(1)", bridge: bridge), bridge: bridge).components(separatedBy: ExtensionBridge.marker).count, 2)
        let manifest = Data(#"{"manifest_version":3,"name":"T","version":"1","permissions":["scripting","notifications"],"host_permissions":["http://127.0.0.1/*"],"background":{"service_worker":"background.js"},"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"],"run_at":"document_end"}]}"#.utf8)
        let patched = try ExtensionBridge.patchManifest(manifest)
        let text = try XCTUnwrap(String(data: patched, encoding: .utf8))
        XCTAssertTrue(text.contains("rikugan-host-bridge.js"))
        XCTAssertTrue(text.contains("document_start"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        try Data("console.log(1)".utf8).write(to: directory.appendingPathComponent("background.js"))
        try Data("console.log(2)".utf8).write(to: directory.appendingPathComponent("content.js"))
        try ExtensionBridge.install(at: directory, directory: true, source: bridge)
        try ExtensionBridge.install(at: directory, directory: true, source: bridge)
        let worker = try String(contentsOf: directory.appendingPathComponent("background.js"), encoding: .utf8)
        XCTAssertEqual(worker.components(separatedBy: ExtensionBridge.marker).count, 2)
        XCTAssertTrue(worker.contains("console.log(1)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("rikugan-host-bridge.js").path))
        let zip = ZipArchive.store([("manifest.json", manifest), ("background.js", Data("console.log(1)".utf8)), ("content.js", Data("console.log(2)".utf8))])
        let archive = directory.appendingPathComponent("ext.zip")
        try zip.write(to: archive)
        try ExtensionBridge.install(at: archive, directory: false, source: bridge)
        let unpacked = try XCTUnwrap(ZipArchive.unpack(try Data(contentsOf: archive)))
        let packedWorker = try XCTUnwrap(unpacked.first { $0.0 == "background.js" }?.1)
        XCTAssertTrue(String(data: packedWorker, encoding: .utf8)?.contains(ExtensionBridge.marker) == true)
        XCTAssertTrue(unpacked.contains { $0.0 == "rikugan-host-bridge.js" })
        try Data("body{color:red}".utf8).write(to: directory.appendingPathComponent("a.css"))
        try Data("1+1".utf8).write(to: directory.appendingPathComponent("a.js"))
        let loaded = ExtensionBridge.loadSources(["a.js", "a.css"], packages: [(url: directory, directory: true)], strict: true)
        XCTAssertEqual(try loaded.get(), ["1+1", "body{color:red}"])
        let missingFile = ExtensionBridge.loadSources(["missing.js"], packages: [(url: directory, directory: true)], strict: true)
        guard case .failure(let missingMessage) = missingFile else { return XCTFail("missing file should fail") }
        XCTAssertTrue(missingMessage.contains("missing file"))
        let invalidFile = ExtensionBridge.loadSources(["../secret.js"], packages: [(url: directory, directory: true)], strict: true)
        guard case .failure(let invalidMessage) = invalidFile else { return XCTFail("invalid path should fail") }
        XCTAssertTrue(invalidMessage.contains("invalid file"))
        let reply = ExtensionBridge.pageReply(id: "rg1", result: ["rikugan-demo": ["title": "Rikugan", "message": "通知已创建"]], error: nil)
        XCTAssertTrue(reply.contains("通知已创建"))
        XCTAssertTrue(reply.contains("__rgExtHostDone"))
    }
}

