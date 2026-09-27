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
}

