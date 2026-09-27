import XCTest
@testable import Rikugan

final class ScriptUpdateTests: XCTestCase {
    private func source(version: String, body: String = "globalThis.updated = true;") -> String {
        """
        // ==UserScript==
        // @name Update fixture
        // @version \(version)
        // @match https://example.com/*
        // @grant none
        // @updateURL https://example.com/update.meta.js
        // @downloadURL https://example.com/update.user.js
        // ==/UserScript==
        \(body)
        """
    }

    func testMetadataIsFollowedByFullDownload() async throws {
        let installed = try UserScript.parse(source(version: "1"))
        var paths: [String] = []
        let update = try await ScriptUpdateResolver.source(for: installed) { url in
            paths.append(url.path)
            return self.source(version: "2", body: url.path.hasSuffix(".meta.js") ? "" : "globalThis.updated = true;")
        }
        XCTAssertEqual(paths, ["/update.meta.js", "/update.user.js"])
        XCTAssertTrue(update?.contains("globalThis.updated") == true)
    }

    func testMetadataOnlyDownloadNeverReplacesProgram() async throws {
        let installed = try UserScript.parse(source(version: "1"))
        do {
            _ = try await ScriptUpdateResolver.source(for: installed) { _ in self.source(version: "2", body: "") }
            XCTFail("Metadata-only source was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("元数据")) }
    }

    func testCurrentVersionDoesNotDownloadAgainAndReinstallDoes() async throws {
        let installed = try UserScript.parse(source(version: "2"))
        var requests = 0
        let update = try await ScriptUpdateResolver.source(for: installed) { _ in requests += 1; return self.source(version: "2") }
        XCTAssertNil(update); XCTAssertEqual(requests, 1)
        let reinstall = try await ScriptUpdateResolver.source(for: installed, checkVersion: false) { url in
            XCTAssertEqual(url.path, "/update.user.js")
            return self.source(version: "2")
        }
        XCTAssertNotNil(reinstall)
    }

    @MainActor func testReinstallKeepsLatestIdentityToggleAndStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageRoot: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var installed = try UserScript.parse(source(version: "1"))
        installed.enabled = false; installed.storageJSON = "{\"count\":42}"
        let owner = model.profile.id
        model.updateProfile(owner) { $0.scripts = [installed] }
        let prepared = try UserScript.parse(source(version: "2"))
        try model.commitScript(prepared, profileID: owner, replacing: installed.id)
        XCTAssertEqual(model.profile.scripts.count, 1)
        XCTAssertEqual(model.profile.scripts[0].id, installed.id)
        XCTAssertEqual(model.profile.scripts[0].storageJSON, installed.storageJSON)
        XCTAssertFalse(model.profile.scripts[0].enabled)
        model.updateProfile(owner) { $0.scripts.removeAll() }
        XCTAssertThrowsError(try model.commitScript(prepared, profileID: owner, replacing: installed.id))
        XCTAssertTrue(model.profile.scripts.isEmpty)
    }
}
