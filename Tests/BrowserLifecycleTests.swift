import XCTest
import WebKit
@testable import Rikugan

@MainActor final class BrowserLifecycleTests: XCTestCase {
    private func makeSession(tabs: [SavedTab]) -> (AppModel, BrowserSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageRoot: root)
        model.updateProfile(model.profile.id) { $0.tabs = tabs; $0.selectedTabID = tabs.first?.id }
        let session = BrowserSession(model: model, profileID: model.profile.id)
        model.session = session
        return (model, session)
    }
    private func clean(_ model: AppModel, _ session: BrowserSession) {
        model.downloadCenter.removeProfile(session.profileID)
        session.shutdown(); model.session = nil
        try? FileManager.default.removeItem(at: model.root)
        WKWebsiteDataStore.remove(forIdentifier: session.profileID) { _ in }
    }
    private func waitUntil(_ description: String, timeout: TimeInterval = 30,
                           condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail(description)
        throw RikuganError.message(description)
    }
    private func loaded(_ tab: BrowserTab, query: String? = nil) async throws {
        try await waitUntil("Fixture did not finish loading: \(tab.address)") {
            guard let view = tab.existingWebView, !view.isLoading, view.url?.host == "127.0.0.1",
                  query == nil || view.url?.query == query else { return false }
            return await PageTools.call("document.readyState", in: view) as? String == "complete"
        }
    }

    func testRestoringManyTabsAndRefreshingSettingsDoesNotAllocateWebViews() async throws {
        let saved = (0..<200).map { SavedTab(url: "http://127.0.0.1:8765/?tab=\($0)") }
        let (model, session) = makeSession(tabs: saved)
        defer { clean(model, session) }
        XCTAssertEqual(session.tabs.count, 200)
        XCTAssertTrue(session.tabs.allSatisfy { $0.existingWebView == nil })
        session.refreshScripts()
        for tab in session.tabs { tab.applyDecorations(); tab.syncContentRules() }
        XCTAssertTrue(session.tabs.allSatisfy { $0.existingWebView == nil })
        session.select(session.tabs[0])
        XCTAssertEqual(session.tabs.filter { $0.existingWebView != nil }.count, 1)
    }

    func testOrdinarySwitchPreservesJSAndSuspensionRestoresHistory() async throws {
        let (model, session) = makeSession(tabs: [SavedTab(), SavedTab()])
        defer { clean(model, session) }
        let first = session.tabs[0], second = session.tabs[1]
        first.navigate(URL(string: "http://127.0.0.1:8765/?step=one")!)
        try await loaded(first, query: "step=one")
        first.navigate(URL(string: "http://127.0.0.1:8765/?step=two")!)
        try await loaded(first, query: "step=two")
        let original = first.webView
        _ = await PageTools.call("(globalThis.lifecycleToken = 41)", in: original)
        session.select(second); session.select(first)
        XCTAssertTrue(first.webView === original)
        let token = await PageTools.call("globalThis.lifecycleToken", in: first.webView)
        XCTAssertEqual((token as? NSNumber)?.intValue, 41)
        XCTAssertFalse(first.suspend(), "The active tab must never be evicted")
        session.select(second)
        first.visiblePageCount = 1
        XCTAssertFalse(first.suspend(), "A tab visible in another iPad window must not be evicted")
        first.visiblePageCount = 0
        XCTAssertTrue(first.suspend())
        XCTAssertNil(first.existingWebView)
        XCTAssertTrue(first.isSuspended)
        session.refreshScripts()
        XCTAssertNil(first.existingWebView)
        session.select(first)
        XCTAssertFalse(first.webView === original)
        try await loaded(first, query: "step=two")
        XCTAssertTrue(first.webView.canGoBack)
        first.webView.goBack()
        try await loaded(first, query: "step=one")
    }

    func testPrivateGMStorageNeverChangesNormalStorageOrBackup() async throws {
        let (model, session) = makeSession(tabs: [SavedTab()])
        defer { clean(model, session) }
        var script = try UserScript.parse("""
        // ==UserScript==
        // @name Private storage probe
        // @version 1
        // @match http://127.0.0.1/*
        // @grant GM_getValue
        // @grant GM_setValue
        // ==/UserScript==
        const n = GM_getValue('count', 0) + 1;
        GM_setValue('count', n);
        document.documentElement.setAttribute('data-private-gm', String(n));
        """)
        script.storageJSON = "{\"count\":7}"
        model.updateProfile(session.profileID) { $0.scripts = [script] }
        let tab = session.addTab(url: URL(string: "http://127.0.0.1:8765/?private=secret")!, isPrivate: true)
        try await loaded(tab)
        try await waitUntil("Private script did not execute") {
            await PageTools.call("document.documentElement.getAttribute('data-private-gm')", in: tab.webView) as? String == "1"
        }
        XCTAssertFalse(tab.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(model.profile.scripts[0].storageJSON, "{\"count\":7}")
        try await waitUntil("Private value was not stored") { session.privateScriptStorage[script.id] != nil }
        session.persistTabs()
        XCTAssertFalse(model.profile.tabs.contains { $0.url.contains("private=secret") })
        let backup = try Data(contentsOf: model.exportBackup())
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("private=secret"))
        session.close(tab)
        XCTAssertTrue(session.privateScriptStorage.isEmpty)
    }

    func testNativeDownloadCookiesPauseResumeAndProfileOwnership() async throws {
        let (model, session) = makeSession(tabs: [SavedTab()])
        defer { clean(model, session) }
        let tab = session.tabs[0]
        tab.navigate(URL(string: "http://127.0.0.1:8765/")!)
        try await loaded(tab)
        _ = await PageTools.call("(document.cookie = 'download-auth=yes; path=/')", in: tab.webView)
        model.downloadCenter.start(url: URL(string: "http://127.0.0.1:8765/__download.bin")!)
        try await waitUntil("Native download did not receive authenticated data") {
            model.profile.downloads.first.map { (model.downloadCenter.live[$0.id]?.received ?? 0) > 0 } ?? false
        }
        let id = try XCTUnwrap(model.profile.downloads.first?.id)
        model.downloadCenter.pause(id)
        try await waitUntil("Download did not pause") { model.profile.downloads.first?.state == "paused" }
        XCTAssertTrue(model.profile.downloads[0].resumable)
        model.downloadCenter.resume(id)
        try await waitUntil("Resumed download did not finish") { model.profile.downloads.first?.state == "finished" }
        let record = try XCTUnwrap(model.profile.downloads.first)
        let data = try Data(contentsOf: model.downloadCenter.fileURL(record, profile: session.profileID))
        XCTAssertEqual(data.count, 4 * 1024 * 1024)
        XCTAssertEqual(data.prefix(8), Data(repeating: 0x52, count: 8))
        XCTAssertEqual(record.received, Int64(data.count))
        model.downloadCenter.start(url: URL(string: "http://127.0.0.1:8765/__download.bin")!)
        try await waitUntil("Second download not registered") { model.profile.downloads.count == 2 }
        let cancelled = model.profile.downloads[0].id
        model.downloadCenter.cancel(cancelled)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.profile.downloads[0].state, "cancelled", "Late callbacks must not resurrect downloads")
    }
}
