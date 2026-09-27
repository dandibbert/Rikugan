import XCTest
import WebKit
@testable import Rikugan

final class StaticDNRTests: XCTestCase {
    private func compiled(_ rules: [[String: Any]]) throws -> StaticDNR.Compiled {
        let data = try JSONSerialization.data(withJSONObject: rules)
        return try StaticDNR.compile(rulesets: [["id": "test", "path": "rules.json", "enabled": true]]) { _ in data }
    }
    private func rule(_ id: Int, _ action: String, _ filter: String, priority: Int = 1) -> [String: Any] {
        ["id": id, "priority": priority, "action": ["type": action], "condition": ["urlFilter": filter, "resourceTypes": ["xmlhttprequest"]]]
    }
    func testURLAnchorsAndSeparatorsDoNotWidenDomains() throws {
        for (pattern, good, bad) in [
            ("||example.com^", ["https://example.com/", "http://sub.example.com:80/x", "https://example.com"], ["https://example.com.evil/", "https://notexample.com/", "https://evil.test/?example.com/"]),
            ("|https://example.com/ads*|", ["https://example.com/ads", "https://example.com/ads-1"], ["http://example.com/ads", "https://evil.test/https://example.com/ads"]),
            ("example^ads", ["https://host.test/example/ads"], ["https://host.test/exampleads"])
        ] {
            let expressions = try StaticDNR.urlPatterns(pattern)
            for url in good { XCTAssertTrue(expressions.contains { url.range(of: $0, options: .regularExpression) != nil }, url) }
            for url in bad { XCTAssertFalse(expressions.contains { url.range(of: $0, options: .regularExpression) != nil }, url) }
        }
    }
    func testUnsupportedConditionsAndDuplicateIDsFailClosed() throws {
        var item = rule(1, "block", "blocked")
        item["condition"] = ["urlFilter": "blocked", "initiatorDomains": ["specific.test"]]
        XCTAssertThrowsError(try compiled([item]))
        item = rule(1, "redirect", "blocked")
        XCTAssertThrowsError(try compiled([item]))
        item = rule(1, "block", "blocked"); item["id"] = true
        XCTAssertThrowsError(try compiled([item]))
        XCTAssertThrowsError(try compiled([rule(1, "block", "a"), rule(1, "allow", "b")]))
        XCTAssertThrowsError(try StaticDNR.compile(rulesets: [["id": "test", "path": "../rules.json", "enabled": true]]) { _ in Data() })
        let disabled = try StaticDNR.compile(rulesets: [["id": "test", "path": "rules.json", "enabled": false]]) { _ in XCTFail("Disabled resource was read"); return Data() }
        XCTAssertEqual(disabled.count, 0)
    }
    @MainActor func testActualBlockingAllowPriorityAndUnmount() async throws {
        let compiled = try compiled([rule(1, "block", "/dnr-test"), rule(2, "allow", "/dnr-test-allow", priority: 2), rule(3, "block", "/dnr-test-allow-block", priority: 3)])
        let name = "rikugan.dnr.test." + UUID().uuidString
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        defer { store.removeContentRuleList(forIdentifier: name) { _ in } }
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: compiled.json) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? RikuganError.message("No compiled rules")) }
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageRoot: root), id = UUID()
        let session = BrowserSession(model: model, profileID: model.profile.id); model.session = session
        defer {
            session.shutdown(); model.session = nil; try? FileManager.default.removeItem(at: root)
            WKWebsiteDataStore.remove(forIdentifier: session.profileID) { _ in }
        }
        session.extensionDNRLists[id] = list
        let tab = session.addTab(url: URL(string: "http://127.0.0.1:8765/")!)
        let deadline = Date().addingTimeInterval(25)
        while tab.existingWebView?.url?.host != "127.0.0.1" || tab.existingWebView?.isLoading != false {
            guard Date() < deadline else { throw RikuganError.message("Fixture load timed out") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let result = try await tab.webView.callAsyncJavaScript("""
        const blocked = await fetch('/dnr-test').then(() => false, () => true);
        const allowed = await fetch('/dnr-test-allow').then(() => true, () => false);
        const overridden = await fetch('/dnr-test-allow-block').then(() => false, () => true);
        return {blocked, allowed, overridden};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool]
        XCTAssertEqual(result, ["blocked": true, "allowed": true, "overridden": true])
        let privateTab = session.addTab(isPrivate: true)
        _ = privateTab.webView
        XCTAssertTrue(privateTab.appliedExtensionDNR.isEmpty)
        session.removeStaticDNR(id)
        XCTAssertTrue(tab.appliedExtensionDNR.isEmpty)
        let permitted = try await tab.webView.callAsyncJavaScript("return await fetch('/dnr-test').then(() => true, () => false)", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(permitted as? Bool, true)
    }
}
