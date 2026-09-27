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
}

