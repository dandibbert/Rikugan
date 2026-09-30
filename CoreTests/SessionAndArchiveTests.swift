import XCTest
@testable import RikuganCore

final class TabLifecyclePolicyTests: XCTestCase {
    func testEvictsLeastRecentlyUsedBeyondLimit() {
        let now = Date()
        var tabs: [TabLifecyclePolicy.Candidate] = []
        for i in 0..<35 {
            tabs.append(.init(id: UUID(), isActive: i == 0, isLive: true, lastActiveAt: now.addingTimeInterval(Double(-i) * 10)))
        }
        let policy = TabLifecyclePolicy(maxLiveBackground: 5)
        let evicted = policy.tabsToSuspend(tabs, memoryPressure: false)
        XCTAssertEqual(evicted.count, 29)
        XCTAssertFalse(evicted.contains(tabs[0].id), "active tab must never be suspended")
        for i in 1...5 { XCTAssertFalse(evicted.contains(tabs[i].id), "most recent background tabs stay live") }
        XCTAssertTrue(evicted.contains(tabs[34].id))
    }

    func testMemoryPressureKeepsOnlyActive() {
        let now = Date()
        let tabs = (0..<8).map { TabLifecyclePolicy.Candidate(id: UUID(), isActive: $0 == 3, isLive: true, lastActiveAt: now, keepAliveHint: $0 == 1) }
        let evicted = TabLifecyclePolicy().tabsToSuspend(tabs, memoryPressure: true)
        XCTAssertEqual(evicted.count, 7)
        XCTAssertFalse(evicted.contains(tabs[3].id))
    }

    func testKeepAliveHintPreferred() {
        let now = Date()
        let old = TabLifecyclePolicy.Candidate(id: UUID(), isActive: false, isLive: true, lastActiveAt: now.addingTimeInterval(-1000), keepAliveHint: true)
        let recent = TabLifecyclePolicy.Candidate(id: UUID(), isActive: false, isLive: true, lastActiveAt: now)
        let evicted = TabLifecyclePolicy(maxLiveBackground: 1).tabsToSuspend([old, recent], memoryPressure: false)
        XCTAssertEqual(evicted, [recent.id])
    }

    func testSuspendedTabsIgnored() {
        let tabs = (0..<10).map { TabLifecyclePolicy.Candidate(id: UUID(), isActive: false, isLive: $0 < 2, lastActiveAt: Date()) }
        XCTAssertTrue(TabLifecyclePolicy(maxLiveBackground: 5).tabsToSuspend(tabs, memoryPressure: false).isEmpty)
    }
}

final class TabGroupModelTests: XCTestCase {
    private func sample() -> (WindowSessionSnapshot, TabGroupSnapshot, TabGroupSnapshot) {
        var s = WindowSessionSnapshot()
        let work = SessionOps.createGroup(&s, name: "Work")
        let play = SessionOps.createGroup(&s, name: "Play")
        s.tabs = [
            TabSnapshot(url: "https://a", title: "a"), TabSnapshot(url: "https://w1", title: "w1", groupID: work.id),
            TabSnapshot(url: "https://b", title: "b"), TabSnapshot(url: "https://w2", title: "w2", groupID: work.id),
            TabSnapshot(url: "https://p1", title: "p1", groupID: play.id),
        ]
        s.selectedGroupID = work.id
        s.selectedTabID = s.tabs[3].id
        return (s, work, play)
    }

    func testCreateRenameReorderGroups() {
        var (s, work, play) = sample()
        SessionOps.renameGroup(&s, work.id, to: "  Office ")
        XCTAssertEqual(s.groups.first?.name, "Office")
        SessionOps.renameGroup(&s, work.id, to: "   ")
        XCTAssertEqual(s.groups.first?.name, "Office", "blank rename ignored")
        SessionOps.reorderGroups(&s, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(s.groups.map(\.id), [play.id, work.id])
        XCTAssertTrue(SessionOps.validate(s).isEmpty)
    }

    func testMoveTabBetweenGroupsAppendsAtEnd() {
        var (s, work, play) = sample()
        let a = s.tabs[0].id
        SessionOps.moveTab(&s, a, toGroup: work.id)
        XCTAssertEqual(SessionOps.tabs(s, inGroup: work.id).map(\.title), ["w1", "w2", "a"])
        SessionOps.moveTab(&s, a, toGroup: play.id)
        XCTAssertEqual(SessionOps.tabs(s, inGroup: play.id).map(\.title), ["p1", "a"])
        SessionOps.moveTab(&s, a, toGroup: UUID())
        XCTAssertEqual(SessionOps.tabs(s, inGroup: play.id).map(\.title), ["p1", "a"], "moving to a missing group is ignored")
    }

    func testReorderWithinGroupKeepsOtherGroups() {
        var (s, work, _) = sample()
        SessionOps.reorderTabs(&s, inGroup: work.id, from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(SessionOps.tabs(s, inGroup: work.id).map(\.title), ["w2", "w1"])
        XCTAssertEqual(SessionOps.tabs(s, inGroup: nil).map(\.title), ["a", "b"])
        XCTAssertEqual(s.tabs.map(\.title), ["a", "w2", "b", "w1", "p1"])
    }

    func testDeleteGroupModes() {
        var (s, work, _) = sample()
        var moved = s
        let closed = SessionOps.deleteGroup(&s, work.id, mode: .closeTabs)
        XCTAssertEqual(closed.count, 2)
        XCTAssertNil(s.selectedGroupID)
        XCTAssertNotNil(s.selectedTabID, "selection falls back to a remaining tab")
        XCTAssertTrue(SessionOps.validate(s).isEmpty)
        SessionOps.deleteGroup(&moved, work.id, mode: .moveTabsToDefault)
        XCTAssertEqual(SessionOps.tabs(moved, inGroup: nil).count, 4)
        XCTAssertTrue(SessionOps.validate(moved).isEmpty)
    }

    func testRepairFixesDanglingReferences() {
        var (s, _, _) = sample()
        s.groups.removeAll()
        XCTAssertFalse(SessionOps.validate(s).isEmpty)
        SessionOps.repair(&s)
        XCTAssertTrue(SessionOps.validate(s).isEmpty)
        XCTAssertTrue(s.tabs.allSatisfy { $0.groupID == nil })
    }

    func testArrayMoveMatchesSwiftUISemantics() {
        var a = [0, 1, 2, 3, 4]
        a.rkMove(fromOffsets: IndexSet([1, 3]), toOffset: 5)
        XCTAssertEqual(a, [0, 2, 4, 1, 3])
        var b = [0, 1, 2, 3]
        b.rkMove(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(b, [3, 0, 1, 2])
    }
}

final class ArchiveTests: XCTestCase {
    private func makeArchive() -> RikuganArchive {
        var window = WindowSessionSnapshot()
        let g = SessionOps.createGroup(&window, name: "Research")
        window.tabs = [TabSnapshot(url: "https://a.com", title: "A"), TabSnapshot(url: "https://b.com", title: "B", groupID: g.id, interactionState: Data([9, 8]), scrollY: 420)]
        window.selectedGroupID = g.id
        window.selectedTabID = window.tabs[1].id
        var site = SiteSettings(host: "github.com")
        site.fontBody = "Font B"
        site.darkMode = .on
        let folder = BookmarkNode(title: "Dev", url: nil, parentID: nil, isFolder: true)
        let profile = ProfileArchive(id: UUID(), name: "Work", symbol: "briefcase", isDefault: false, siteSettings: [site],
                                     bookmarks: [folder, BookmarkNode(title: "Swift", url: "https://swift.org", parentID: folder.id)],
                                     windows: [window],
                                     userscripts: [ArchivedUserscript(name: "S", namespace: "n", version: "1", enabled: true, sourceURL: nil,
                                                                      source: "// ==UserScript==\n// @name S\n// @namespace n\n// ==/UserScript==", values: ["k": "1"])],
                                     extensions: [ExtensionMetadata(id: "abcdefghijklmnopabcdefghijklmnop", name: "X", version: "1", enabled: true, source: "file", storeURL: nil)])
        var prefs = Preferences()
        prefs.searchEngineID = "bing"
        prefs.customEngines = [SearchEngine(id: "c", name: "C", searchTemplate: "https://c/?q={query}")]
        return RikuganArchive(appVersion: "1.0 (1)", settings: prefs, activeProfileID: profile.id, profiles: [profile],
                              fonts: [FontMetadata(family: "Font B", fileName: "b.ttf")],
                              contentBlocking: ContentBlockingArchive(enabled: true, customRules: "example.com##.ad", subscriptions: FilterSubscription.defaults, allowlist: ["ok.com"]))
    }

    func testExportResetImportRoundTrip() throws {
        let archive = makeArchive()
        let data = try ArchiveCodec.encode(archive)
        let decoded = try ArchiveCodec.decode(data)
        XCTAssertEqual(decoded.formatVersion, RikuganArchive.currentFormatVersion)
        XCTAssertEqual(decoded.excluded, RikuganArchive.excludedAlways)
        // reset → import (replace) → equivalent state
        // Serialisation is lossless apart from sub-millisecond date precision: a second
        // export of the imported archive is byte-identical to the first export.
        XCTAssertEqual(try ArchiveCodec.encode(decoded), data)
        let restored = ArchiveCodec.apply(decoded.profiles[0], to: ProfileData(), mode: .replace)
        XCTAssertEqual(restored, decoded.profiles[0].data)
        XCTAssertEqual(restored.windows[0].tabs.map(\.url), archive.profiles[0].windows[0].tabs.map(\.url))
        XCTAssertEqual(restored.windows[0].tabs.map(\.id), archive.profiles[0].windows[0].tabs.map(\.id))
        XCTAssertEqual(restored.windows[0].groups.map(\.name), ["Research"])
        XCTAssertEqual(restored.windows[0].selectedTabID, archive.profiles[0].windows[0].selectedTabID)
        XCTAssertEqual(restored.windows[0].tabs[1].scrollY, 420)
        XCTAssertEqual(decoded.settings.searchEngineID, "bing")
        XCTAssertEqual(decoded.settings.customEngines.count, 1)
        XCTAssertEqual(decoded.summary.tabs, 2)
        XCTAssertEqual(decoded.summary.groups, 1)
    }

    /// Secrets are not part of the settings JSON at all: an archive never contains the translation
    /// key field, and an old archive carrying one does not bring it back on import.
    func testArchiveContainsNoTranslationKey() throws {
        let text = String(decoding: try ArchiveCodec.encode(makeArchive()), as: UTF8.self)
        XCTAssertFalse(text.contains(Preferences.translationKeyAccount))
        let legacy = Data(#"{"searchEngineID":"bing","translationAPIKey":"SENTINEL-SECRET-123"}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertEqual(decoded.searchEngineID, "bing")
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(reencoded.contains("SENTINEL-SECRET-123"))
    }

    func testMergeDoesNotDuplicateAndRemapsIDs() throws {
        let archive = makeArchive()
        let once = ArchiveCodec.apply(archive.profiles[0], to: ProfileData(), mode: .merge)
        let twice = ArchiveCodec.apply(archive.profiles[0], to: once, mode: .merge)
        XCTAssertEqual(twice.bookmarks.filter { !$0.isFolder }.count, 1, "bookmarks deduplicated by URL")
        XCTAssertEqual(twice.bookmarks.filter(\.isFolder).count, 1)
        XCTAssertEqual(twice.windows.count, 2, "windows appended")
        XCTAssertNotEqual(twice.windows[0].tabs[0].id, twice.windows[1].tabs[0].id, "tab IDs regenerated")
        XCTAssertTrue(twice.windows.allSatisfy { SessionOps.validate($0).isEmpty })
        XCTAssertEqual(twice.userscripts.count, 1, "userscripts replaced by name + namespace")
        XCTAssertEqual(twice.siteSettings.count, 1)
    }

    /// Structural problems are rejected instead of being imported "successfully".
    func testArchiveValidationRejectsBrokenData() throws {
        func mutate(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var json = try JSONSerialization.jsonObject(with: ArchiveCodec.encode(makeArchive())) as! [String: Any]
            change(&json)
            return try JSONSerialization.data(withJSONObject: json)
        }
        XCTAssertThrowsError(try ArchiveCodec.decode(mutate { $0["formatVersion"] = -1 }), "negative version")
        XCTAssertThrowsError(try ArchiveCodec.decode(mutate { $0["formatVersion"] = 0 }), "version 0")
        XCTAssertThrowsError(try ArchiveCodec.decode(mutate { json in
            var settings = json["settings"] as! [String: Any]
            settings["adBlockEnabled"] = "yes"
            json["settings"] = settings
        }), "wrong type for a known setting")
        XCTAssertThrowsError(try ArchiveCodec.decode(mutate { $0["activeProfileID"] = UUID().uuidString }), "unknown active profile")
        // Bookmark folders A → B → A.
        var archive = makeArchive()
        let a = BookmarkNode(id: UUID(), title: "A", url: nil, parentID: nil, isFolder: true)
        var b = BookmarkNode(id: UUID(), title: "B", url: nil, parentID: a.id, isFolder: true)
        var cyclicA = a
        cyclicA.parentID = b.id
        b.parentID = cyclicA.id
        archive.profiles[0].bookmarks = [cyclicA, b]
        XCTAssertThrowsError(try ArchiveCodec.decode(ArchiveCodec.encode(archive)), "bookmark cycle")
    }

    func testBookmarkTreeRules() {
        let root = BookmarkNode(title: "R", url: nil, parentID: nil, isFolder: true)
        let child = BookmarkNode(title: "C", url: nil, parentID: root.id, isFolder: true)
        let leaf = BookmarkNode(title: "L", url: "https://x", parentID: child.id)
        let nodes = [root, child, leaf]
        XCTAssertTrue(BookmarkTree.problems(nodes).isEmpty)
        XCTAssertTrue(BookmarkTree.isDescendant(child.id, of: root.id, in: nodes))
        XCTAssertTrue(BookmarkTree.isDescendant(root.id, of: root.id, in: nodes))
        XCTAssertFalse(BookmarkTree.isDescendant(root.id, of: child.id, in: nodes))
        let underLeaf = BookmarkNode(title: "X", url: "https://y", parentID: leaf.id)
        XCTAssertFalse(BookmarkTree.problems(nodes + [underLeaf]).isEmpty, "a bookmark cannot be a parent")
    }

    /// Child folders listed before their parents still land under the right (merged) parent.
    func testMergeFoldersParentFirst() {
        let existingTop = BookmarkNode(title: "Top", url: nil, parentID: nil, isFolder: true)
        var current = ProfileData()
        current.bookmarks = [existingTop]
        let top = BookmarkNode(title: "Top", url: nil, parentID: nil, isFolder: true)      // merges into existingTop
        let mid = BookmarkNode(title: "Mid", url: nil, parentID: top.id, isFolder: true)
        let deep = BookmarkNode(title: "Deep", url: nil, parentID: mid.id, isFolder: true)
        let leaf = BookmarkNode(title: "Leaf", url: "https://leaf", parentID: deep.id)
        let incoming = ProfileArchive(id: UUID(), name: "P", symbol: "person", isDefault: false, siteSettings: [],
                                      bookmarks: [leaf, deep, mid, top], windows: [], userscripts: [], extensions: [])
        let merged = ArchiveCodec.apply(incoming, to: current, mode: .merge).bookmarks
        XCTAssertTrue(BookmarkTree.problems(merged).isEmpty, "\(BookmarkTree.problems(merged))")
        let midMerged = merged.first { $0.title == "Mid" }
        XCTAssertEqual(midMerged?.parentID, existingTop.id)
        XCTAssertEqual(merged.first { $0.title == "Deep" }?.parentID, midMerged?.id)
    }

    func testUnknownFieldsIgnoredAndFutureVersionRejected() throws {
        var json = try JSONSerialization.jsonObject(with: ArchiveCodec.encode(makeArchive())) as! [String: Any]
        json["someFutureField"] = ["x": 1]
        var profiles = json["profiles"] as! [[String: Any]]
        profiles[0]["futureProfileField"] = true
        json["profiles"] = profiles
        XCTAssertNoThrow(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: json)))
        json["formatVersion"] = RikuganArchive.currentFormatVersion + 1
        XCTAssertThrowsError(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func testCorruptFilesRejected() throws {
        XCTAssertThrowsError(try ArchiveCodec.decode(Data("{not json".utf8)))
        XCTAssertThrowsError(try ArchiveCodec.decode(Data(#"{"format":"something-else"}"#.utf8)))
        XCTAssertThrowsError(try ArchiveCodec.decode(Data(#"{"format":"rikugan-archive","formatVersion":2}"#.utf8)))
        var archive = makeArchive()
        archive.profiles[0].windows[0].tabs[0].groupID = UUID() // dangling group
        XCTAssertThrowsError(try ArchiveCodec.decode(ArchiveCodec.encode(archive)))
    }

    func testV1Migration() throws {
        let group = TabGroupSnapshot(name: "Old")
        var session = WindowSessionSnapshot()
        session.groups = [group]
        session.tabs = [TabSnapshot(url: "https://x.com", title: "X", groupID: group.id)]
        let v1 = ExportBundle(preferences: Preferences(), sessions: [session], siteSettings: [SiteSettings(host: "x.com")], bookmarks: [],
                              adBlockCustomRules: "x.com##.y", adBlockSubscriptions: [], adBlockAllowlist: [],
                              userscripts: [ExportedUserscript(source: "// ==UserScript==\n// @name Legacy\n// ==/UserScript==", enabled: false, values: [:])])
        let archive = try ArchiveCodec.decode(ExportBundle.encoder().encode(v1))
        XCTAssertEqual(archive.formatVersion, 2)
        XCTAssertEqual(archive.profiles.count, 1)
        XCTAssertEqual(archive.profiles[0].windows[0].tabs[0].groupID, group.id)
        XCTAssertEqual(archive.profiles[0].userscripts.first?.name, "Legacy")
        XCTAssertEqual(archive.contentBlocking.customRules, "x.com##.y")
    }

    /// The checked-in v1 file (also used by the in-app archive suite) migrates losslessly.
    func testV1FixtureFileMigrates() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Rikugan/Resources/SelfTest/archive/v1-export.json")
        let archive = try ArchiveCodec.decode(Data(contentsOf: file))
        XCTAssertEqual(archive.formatVersion, RikuganArchive.currentFormatVersion)
        let profile = try XCTUnwrap(archive.profiles.first)
        XCTAssertEqual(profile.windows.first?.tabs.map(\.title), ["v1 A", "v1 B"])
        XCTAssertEqual(profile.windows.first?.groups.map(\.name), ["V1 Group"])
        XCTAssertEqual(profile.windows.first?.selectedTabID, UUID(uuidString: "8D1C63F4-0000-4000-8000-000000000002"))
        XCTAssertEqual(profile.bookmarks.map(\.title), ["V1 Bookmark"])
        XCTAssertEqual(profile.siteSettings.map(\.host), ["v1.example"])
        XCTAssertEqual(profile.userscripts.first?.name, "V1 Script")
        XCTAssertNotNil(profile.userscripts.first?.source)
        XCTAssertEqual(archive.settings.searchEngineID, "duckduckgo")
        XCTAssertEqual(archive.contentBlocking.allowlist, ["v1-allowed.example"])
        XCTAssertEqual(archive.excluded, RikuganArchive.excludedAlways)
    }

    func testSiteSettingsTolerantDecoding() throws {
        let site = try JSONDecoder().decode(SiteSettings.self, from: Data(#"{"host":"A.com","darkMode":"on","unknown":1}"#.utf8))
        XCTAssertEqual(site.host, "a.com")
        XCTAssertEqual(site.darkMode, .on)
        XCTAssertTrue(site.permissions.isEmpty)
    }
}

final class FontTests: XCTestCase {
    func testResolveGlobalAndPerSite() {
        var prefs = Preferences()
        prefs.webFontEnabled = true
        prefs.webFontFamily = "Font A"
        prefs.webFontMono = "Mono A"
        var github = SiteSettings(host: "github.com")
        github.fontBody = "Font B"
        var example = SiteSettings(host: "example.com")
        example.webFont = false
        XCTAssertEqual(FontPlan.resolve(prefs: prefs, site: SiteSettings(host: "a.org"), host: "a.org"), FontPlan(body: "Font A", heading: nil, mono: "Mono A"))
        XCTAssertEqual(FontPlan.resolve(prefs: prefs, site: github, host: "github.com")?.body, "Font B")
        XCTAssertEqual(FontPlan.resolve(prefs: prefs, site: github, host: "github.com")?.mono, "Mono A")
        XCTAssertNil(FontPlan.resolve(prefs: prefs, site: example, host: "example.com"))
        prefs.webFontEnabled = false
        XCTAssertNil(FontPlan.resolve(prefs: prefs, site: SiteSettings(host: "a.org"), host: "a.org"))
        XCTAssertEqual(FontPlan.resolve(prefs: prefs, site: github, host: "github.com")?.body, "Font B", "site override works without global")
    }

    func testIconFontPattern() throws {
        let re = try NSRegularExpression(pattern: FontPlan.iconFontPattern, options: [.caseInsensitive])
        func hit(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        for name in ["Material Icons", "Material Symbols Outlined", "Font Awesome 6 Free", "FontAwesome", "icomoon", "iconfont", "Octicons", "dashicons", "bootstrap-icons"] {
            XCTAssertTrue(hit(name), name)
        }
        for name in ["Helvetica", "Roboto", "PingFang SC", "Noto Sans"] { XCTAssertFalse(hit(name), name) }
    }

    /// Builds a TTC with two tiny faces and checks every face is extracted as a standalone sfnt.
    func testTTCSplit() throws {
        func sfnt(tag: String, payload: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 16, 0, 0, 0, 0]
            out += Array(tag.utf8) + [0, 0, 0, 0] + [0, 0, 0, 28] + [0, 0, 0, UInt8(payload.count)]
            return out + payload
        }
        let faceA = sfnt(tag: "abcd", payload: [1, 2, 3, 4])
        let faceB = sfnt(tag: "wxyz", payload: [5, 6, 7, 8, 9, 10, 11, 12])
        // TTC: header (12) + 2 offsets (8) = 20; directories at 20 and 48; table data at 76 and 80.
        var ttc: [UInt8] = Array("ttcf".utf8) + [0, 1, 0, 0, 0, 0, 0, 2] + [0, 0, 0, 20] + [0, 0, 0, 48]
        var a = faceA, b = faceB
        a[20..<24] = [0, 0, 0, 76]            // table data offset absolute in TTC
        b[20..<24] = [0, 0, 0, 80]
        ttc += a.prefix(28) + b.prefix(28)
        ttc += faceA.suffix(4) + faceB.suffix(8)
        let fonts = try FontCollection.split(Data(ttc))
        XCTAssertEqual(fonts.count, 2)
        XCTAssertEqual(Array(fonts[0].suffix(4)), [1, 2, 3, 4])
        XCTAssertEqual(Array(fonts[1].suffix(8)), [5, 6, 7, 8, 9, 10, 11, 12])
        XCTAssertEqual(Array(fonts[1][20..<24]), [0, 0, 0, 28], "offsets rebased for the standalone font")
        XCTAssertThrowsError(try FontCollection.split(Data("nope".utf8)))
    }
}

final class DNRAdvancedTests: XCTestCase {
    func testRedirectAndHeadersRespectCapabilities() {
        let rules: [[String: Any]] = [
            ["id": 1, "action": ["type": "redirect", "redirect": ["url": "https://example.com/new.js"]], "condition": ["urlFilter": "/old.js"]],
            ["id": 2, "action": ["type": "redirect", "redirect": ["regexSubstitution": "\\1"]], "condition": ["regexFilter": "(a)"]],
            ["id": 3, "action": ["type": "modifyHeaders", "requestHeaders": [["header": "X-Test", "operation": "set", "value": "1"]]], "condition": ["urlFilter": "api"]],
            ["id": 4, "action": ["type": "redirect", "redirect": ["transform": ["scheme": "https", "queryTransform": ["removeParams": ["utm_source"]]]]], "condition": ["urlFilter": "track"]],
        ]
        let none = DNRConverter.convert(rules)
        XCTAssertEqual(Set(none.skipped.map(\.id)), [1, 2, 3, 4])
        let full = DNRConverter.convert(rules, capabilities: .init(redirect: true, modifyHeaders: true), baseURL: "chrome-extension://x/")
        XCTAssertEqual(full.skipped.map(\.id), [2], "regexSubstitution is not expressible")
        let redirect = full.rules.first { $0.action == .redirect }!.webKitJSON()
        let action = redirect["action"] as! [String: Any]
        XCTAssertEqual(action["type"] as? String, "redirect")
        XCTAssertEqual((action["redirect"] as? [String: Any])?["url"] as? String, "https://example.com/new.js")
        let headers = full.rules.first { $0.action == .modifyHeaders }!.webKitJSON()["action"] as! [String: Any]
        XCTAssertEqual(headers["type"] as? String, "modify-headers")
        XCTAssertEqual((headers["request-headers"] as? [[String: Any]])?.first?["header"] as? String, "X-Test")
        let transform = full.rules.filter { $0.action == .redirect }[1].webKitJSON()["action"] as! [String: Any]
        let t = (transform["redirect"] as? [String: Any])?["transform"] as? [String: Any]
        XCTAssertEqual(t?["scheme"] as? String, "https")
        XCTAssertEqual((t?["query-transform"] as? [String: Any])?["remove-parameters"] as? [String], ["utm_source"])
    }
}

final class MatrixTests: XCTestCase {
    override func setUp() {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Rikugan/Resources/JS/chrome-api-matrix.json")
        ChromeAPIMatrix.jsonOverride = try? Data(contentsOf: url)
        ChromeAPIMatrix.reload()
    }

    func testMatrixLoadsPerMethodLevels() {
        XCTAssertEqual(ChromeAPIMatrix.method("tabs", "query")?.level, .supported)
        XCTAssertEqual(ChromeAPIMatrix.method("tabs", "update")?.level, .partial)
        XCTAssertEqual(ChromeAPIMatrix.method("tabs", "move")?.level, .partial)
        XCTAssertEqual(ChromeAPIMatrix.method("tabs", "group")?.level, .unsupported)
        XCTAssertEqual(ChromeAPIMatrix.level(of: "webRequest"), .unsupported)
        XCTAssertEqual(ChromeAPIMatrix.method("declarativeNetRequest", "getMatchedRules")?.level, .unsupported)
        XCTAssertFalse(ChromeAPIMatrix.entries.first { $0.namespace == "tabs" }!.missing.isEmpty)
        for namespace in ["runtime", "storage", "scripting", "tabs", "permissions", "action", "contextMenus", "cookies", "downloads", "webNavigation", "declarativeNetRequest", "webRequest"] {
            let entry = ChromeAPIMatrix.entries.first { $0.namespace == namespace }
            XCTAssertNotNil(entry, namespace)
            XCTAssertFalse(entry!.methods.isEmpty, "\(namespace) must list methods")
            if entry!.level != .supported { XCTAssertFalse(entry!.reason.isEmpty, "\(namespace) needs a reason") }
        }
    }
}
