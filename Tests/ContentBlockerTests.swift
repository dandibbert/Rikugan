import XCTest
import WebKit
@testable import Rikugan

final class ContentBlockerTests: XCTestCase {
    @MainActor private func compile(_ source: String, identifier: String) async throws -> WKContentRuleList {
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? RikuganError.message("Rules did not compile")) }
            }
        }
    }

    @MainActor func testBuiltinRulesCompileInRealWebKit() async throws {
        let identifier = "rikugan.tests." + UUID().uuidString
        _ = try await compile(AdBlockEngine.compile(lines: AdBlockEngine.builtin).json, identifier: identifier)
        WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in }
    }

    @MainActor func testRealResourceBlockExceptionAndCosmeticRule() async throws {
        let identifier = "rikugan.tests." + UUID().uuidString
        defer { WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: identifier) { _ in } }
        let compiled = AdBlockEngine.compile(lines: ["||127.0.0.1/blocked", "@@||127.0.0.1/blocked-allowed", "##.ad-banner"])
        let list = try await compile(compiled.json, identifier: identifier)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(list)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        let loaded = expectation(description: "Blocker fixture loaded")
        let delegate = BlockerLoadProbe(loaded)
        view.navigationDelegate = delegate
        view.loadHTMLString("<html><body><div class='ad-banner'>Advertisement</div></body></html>", baseURL: URL(string: "http://127.0.0.1:8765/"))
        await fulfillment(of: [loaded], timeout: 20)
        let result = try await view.callAsyncJavaScript("""
        const blocked = await fetch('/blocked').then(() => false, () => true);
        const allowed = await fetch('/blocked-allowed').then(() => true, () => false);
        return {blocked, allowed, hidden: getComputedStyle(document.querySelector('.ad-banner')).display === 'none'};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool]
        XCTAssertEqual(result?["blocked"], true)
        XCTAssertEqual(result?["allowed"], true)
        XCTAssertEqual(result?["hidden"], true)
        view.navigationDelegate = nil
    }

    func testExceptionOrderModifiersAndUnsupportedRules() throws {
        let compiled = AdBlockEngine.compile(lines: ["@@||example.com/allowed$script", "||example.com^", "~example.com##.important", "||example.net^$websocket"])
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(compiled.networkJSON.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual((rules.last?["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
        XCTAssertEqual((rules.last?["trigger"] as? [String: Any])?["resource-type"] as? [String], ["script"])
        XCTAssertTrue(compiled.hostSelectors.isEmpty)
        let regex = try XCTUnwrap((rules[0]["trigger"] as? [String: Any])?["url-filter"] as? String)
        for url in ["https://example.com/", "http://sub.example.com:8765/a"] {
            XCTAssertNotNil(url.range(of: regex, options: .regularExpression))
        }
        XCTAssertNil("https://example.com.evil.test/".range(of: regex, options: .regularExpression))
        XCTAssertFalse(regex.contains("|"))
    }
}

@MainActor private final class BlockerLoadProbe: NSObject, WKNavigationDelegate {
    let loaded: XCTestExpectation
    init(_ loaded: XCTestExpectation) { self.loaded = loaded }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}
