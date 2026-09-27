import XCTest
import WebKit
@testable import Rikugan

@MainActor final class ScriptEventTests: XCTestCase {
    private func eventually(_ tab: BrowserTab, _ expression: String) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if await PageTools.call(expression, in: tab.webView) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RikuganError.message("Timed out: \(expression)")
    }
    func testCrossTabAndIframeValueEventsWithPrivateIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageRoot: root)
        let script = try UserScript.parse("""
        // ==UserScript==
        // @name Event fixture
        // @match http://127.0.0.1/*
        // @grant GM_getValue
        // @grant GM.setValue
        // @grant GM.deleteValue
        // @grant GM_addValueChangeListener
        // @grant GM_removeValueChangeListener
        // ==/UserScript==
        if (!document.querySelector('#gm-write')) {
          let root = document.createElement('section');
          root.innerHTML = '<button id="gm-write">write</button><button id="gm-delete">delete</button><button id="gm-remove">remove</button><span id="gm-value"></span>';
          document.body.appendChild(root);
          let listener = GM_addValueChangeListener('probe', (key, oldValue, value, remote) => {
            document.documentElement.dataset.gmEvent = (value === undefined ? 'deleted' : String(value)) + ':' + remote;
            document.querySelector('#gm-value').textContent = String(GM_getValue('probe', 'missing'));
          });
          document.querySelector('#gm-write').onclick = () => GM.setValue('probe', 42);
          document.querySelector('#gm-delete').onclick = () => GM.deleteValue('probe');
          document.querySelector('#gm-remove').onclick = () => GM_removeValueChangeListener(listener);
        }
        """)
        model.updateProfile(model.profile.id) { $0.scripts = [script] }
        let session = BrowserSession(model: model, profileID: model.profile.id); model.session = session
        defer {
            session.shutdown(); model.session = nil
            try? FileManager.default.removeItem(at: root)
            WKWebsiteDataStore.remove(forIdentifier: session.profileID) { _ in }
        }
        let url = URL(string: "http://127.0.0.1:8765/")!
        let a = session.addTab(url: url), b = session.addTab(url: url), p = session.addTab(url: url, isPrivate: true)
        for tab in [a, b, p] { try await eventually(tab, "!!document.querySelector('#gm-write')") }
        _ = await PageTools.call("(function(){let f=document.createElement('iframe');f.id='child';f.src='/?child=1';document.body.appendChild(f);return true})()", in: b.webView)
        try await eventually(b, "!!document.querySelector('#child')?.contentDocument?.querySelector('#gm-write')")
        _ = await PageTools.call("document.querySelector('#gm-write').click()", in: a.webView)
        try await eventually(a, "document.documentElement.dataset.gmEvent === '42:false'")
        try await eventually(b, "document.documentElement.dataset.gmEvent === '42:true'")
        try await eventually(b, "document.querySelector('#child').contentDocument.documentElement.dataset.gmEvent === '42:true'")
        let privateEvent = await PageTools.call("document.documentElement.dataset.gmEvent || ''", in: p.webView)
        XCTAssertEqual(privateEvent as? String, "")
        _ = await PageTools.call("document.querySelector('#gm-delete').click()", in: b.webView)
        try await eventually(a, "document.documentElement.dataset.gmEvent === 'deleted:true'")
        _ = await PageTools.call("document.querySelector('#gm-remove').click()", in: a.webView)
        _ = await PageTools.call("document.querySelector('#gm-write').click()", in: b.webView)
        try await eventually(b, "document.documentElement.dataset.gmEvent === '42:false'")
        let afterRemoval = await PageTools.call("document.documentElement.dataset.gmEvent", in: a.webView)
        XCTAssertEqual(afterRemoval as? String, "deleted:true")
    }
}
