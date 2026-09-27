import XCTest
import UniformTypeIdentifiers
@testable import Rikugan

final class ShareInboxTests: XCTestCase {
    private let script = "// ==UserScript==\n// @name Shared probe\n// @match https://example.com/*\n// @grant none\n// ==/UserScript==\nthrow new Error('must not execute on import');"

    func testOrderedDurableBatchesAndIdempotentTransfer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ShareInbox(container: root.appendingPathComponent("group")), destination = ShareInbox(container: root.appendingPathComponent("app"))
        let first = SharedItem(kind: .script, value: script, name: "probe.user.js")
        let batch = SharedBatch(createdAt: Date(timeIntervalSince1970: 1), items: [first, SharedItem(kind: .open, value: "https://example.com")])
        try source.enqueue(batch); try source.enqueue(batch)
        try source.enqueue(SharedBatch(createdAt: Date(timeIntervalSince1970: 2), items: [SharedItem(kind: .search, value: "another share")]))
        try destination.enqueue(batch) // Emulate interruption after persisting, before acknowledging.
        try source.transfer(to: destination)
        XCTAssertEqual(try destination.items().count, 3)
        XCTAssertEqual(try destination.items().first?.id, first.id)
        XCTAssertTrue(try source.items().isEmpty)
        try destination.acknowledge(first.id)
        XCTAssertEqual(try ShareInbox(container: root.appendingPathComponent("app")).items().count, 2)
        XCTAssertEqual(try destination.items().last?.value, "another share")
    }

    func testInvalidBatchesAndURLsNeverEnterQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = ShareInbox(container: root)
        for item in [SharedItem(kind: .open, value: "javascript:alert(1)"), SharedItem(kind: .open, value: "https://user:pass@example.com"), SharedItem(kind: .script, value: "alert(1)"), SharedItem(kind: .search, value: String(repeating: "a", count: 16001))] {
            XCTAssertThrowsError(try inbox.enqueue(SharedBatch(items: [item])))
        }
        let item = SharedItem(kind: .script, value: script)
        XCTAssertThrowsError(try inbox.enqueue(SharedBatch(items: [item, item])))
        XCTAssertTrue(try inbox.items().isEmpty)
    }

    func testItemProviderFileBytesSurviveTemporaryURLLifetime() async throws {
        let provider = NSItemProvider()
        provider.suggestedName = "sample.user.js"
        let bytes = Data(script.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.javaScript.identifier, visibility: .all) { completion in
            completion(bytes, nil); return nil
        }
        let items = try await ShareInputReader.read([provider])
        XCTAssertEqual(items.first?.kind, .script)
        XCTAssertEqual(items.first?.value, script)
        XCTAssertEqual(items.first?.name, "sample.user.js")
    }

    @MainActor func testShareOnlyPreviewsAndWaitsForDismissal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageRoot: root)
        let session = BrowserSession(model: model, profileID: model.profile.id)
        model.session = session; session.ready = true
        defer { session.shutdown(); try? FileManager.default.removeItem(at: root) }
        try model.shareInbox.enqueue(SharedBatch(items: [SharedItem(kind: .script, value: script), SharedItem(kind: .script, value: script)]))
        model.applyPendingShare()
        XCTAssertNotNil(model.scriptDraft)
        XCTAssertTrue(model.profile.scripts.isEmpty)
        XCTAssertEqual(try model.shareInbox.items().count, 2)
        let draftID = model.scriptDraft?.id
        model.applyPendingShare()
        XCTAssertEqual(model.scriptDraft?.id, draftID)
        model.scriptDraft = nil
        model.scriptEditorDidDismiss()
        XCTAssertEqual(try model.shareInbox.items().count, 1)
    }
}
