import XCTest
import Compression
@testable import RikuganCore

/// Builds small ZIP archives in memory for tests.
enum ZipBuilder {
    static func make(_ files: [(String, Data)], deflate: Bool = false) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int) -> Data { u16(v & 0xFFFF) + u16((v >> 16) & 0xFFFF) }
        for (name, content) in files {
            var payload = content
            var method = 0
            if deflate, !content.isEmpty {
                var buffer = [UInt8](repeating: 0, count: content.count + 1024)
                let written = content.withUnsafeBytes { src in
                    compression_encode_buffer(&buffer, buffer.count, src.bindMemory(to: UInt8.self).baseAddress!, content.count, nil, COMPRESSION_ZLIB)
                }
                payload = Data(buffer.prefix(written)); method = 8
            }
            let offset = out.count
            let nameData = Data(name.utf8)
            out += u32(0x04034B50) + u16(20) + u16(0) + u16(method) + u16(0) + u16(0) + u32(0)
            out += u32(payload.count) + u32(content.count) + u16(nameData.count) + u16(0) + nameData + payload
            central += u32(0x02014B50) + u16(20) + u16(20) + u16(0) + u16(method) + u16(0) + u16(0) + u32(0)
            central += u32(payload.count) + u32(content.count) + u16(nameData.count) + u16(0) + u16(0) + u16(0) + u16(0)
            central += u32(0) + u32(offset) + nameData
        }
        let cdOffset = out.count
        out += central
        out += u32(0x06054B50) + u16(0) + u16(0) + u16(files.count) + u16(files.count) + u32(central.count) + u32(cdOffset) + u16(0)
        return out
    }
}

final class ZipAndCRXTests: XCTestCase {
    func testStoredAndDeflated() throws {
        let manifest = Data(#"{"manifest_version":3,"name":"T","version":"1"}"#.utf8)
        for deflate in [false, true] {
            let zip = ZipBuilder.make([("manifest.json", manifest), ("js/a.js", Data(String(repeating: "console.log(1);", count: 50).utf8))], deflate: deflate)
            let archive = try ZipArchive(data: zip)
            XCTAssertEqual(archive.entries.count, 2)
            XCTAssertEqual(try archive.extract(archive.entry("manifest.json")!), manifest)
            XCTAssertEqual(archive.rootPrefix(containing: "manifest.json"), "")
        }
    }

    func testWrappedFolderRoot() throws {
        let zip = ZipBuilder.make([("ext/manifest.json", Data("{}".utf8)), ("ext/a.js", Data("x".utf8))])
        let archive = try ZipArchive(data: zip)
        XCTAssertEqual(archive.rootPrefix(containing: "manifest.json"), "ext/")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try archive.extractAll(to: dir, stripPrefix: "ext/")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.js").path))
    }

    func testRejectsTraversal() {
        let zip = ZipBuilder.make([("../evil.js", Data("x".utf8))])
        XCTAssertThrowsError(try ZipArchive(data: zip))
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip at all, definitely not".utf8)))
    }

    func testCRX3() throws {
        let zip = ZipBuilder.make([("manifest.json", Data("{}".utf8))])
        // Header: field 10000 (signed_header_data) containing field 1 (crx_id, 16 bytes).
        let crxID = Data((0..<16).map { UInt8($0) })
        var signed = Data([0x0A, 0x10]) + crxID
        var header = Data()
        header += Data([0x82, 0xF1, 0x04]) // key (10000 << 3 | 2) as varint
        header += Data([UInt8(signed.count)]) + signed
        signed.removeAll()
        var crx = Data("Cr24".utf8)
        crx += Data([3, 0, 0, 0])
        crx += Data([UInt8(header.count), 0, 0, 0]) + header + zip
        let package = try CRXPackage(data: crx)
        XCTAssertEqual(package.zipData, zip)
        XCTAssertEqual(package.crxID, "aaabacadaeafagahaiajakalamanaoap")
        XCTAssertTrue(ExtensionID.isValid(package.crxID!))
    }

    func testExtensionIDFromKey() {
        // Known vector: key of the Chrome "Google Docs Offline" extension → ghbmnnjooekpmoecnnnilnnbdlolhkhi
        let key = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIZmHlGuBnWd6tWO+pEKrT6RGaV7fiiY8fCsWUx0tEhWtfmMw5ZUvvcdS1MPkrHlBGOQL9Ah4xL8KgaOmKnF+NIzT7dg0/QnHS5rOWVAqV6FlcVL/oLeVFDBoSDDdvStk3J3GNG5LlaAwXXojCIAX3ZezdEFB27ugKCZCIYvS9TwIDAQAB"
        let id = ExtensionID.fromManifestKey(key)
        XCTAssertNotNil(id)
        XCTAssertTrue(ExtensionID.isValid(id!))
        XCTAssertEqual(ExtensionID.fromSeed("a"), ExtensionID.fromSeed("a"))
        XCTAssertNotEqual(ExtensionID.fromSeed("a"), ExtensionID.fromSeed("b"))
    }
}

final class ManifestTests: XCTestCase {
    let json = """
    {
      // comment allowed
      "manifest_version": 3,
      "name": "__MSG_appName__",
      "version": "1.0.2",
      "default_locale": "en",
      "action": {"default_popup": "popup.html", "default_icon": {"16": "i16.png", "48": "i48.png"}},
      "background": {"service_worker": "bg.js", "type": "module"},
      "content_scripts": [{"matches": ["*://*.example.com/*"], "exclude_matches": ["*://example.com/skip*"], "js": ["c.js"], "css": ["c.css"], "run_at": "document_start", "all_frames": true}],
      "permissions": ["storage", "tabs", "declarativeNetRequest"],
      "host_permissions": ["https://api.example.com/*"],
      "optional_permissions": ["downloads"],
      "web_accessible_resources": [{"resources": ["img/*.png"], "matches": ["https://example.com/*"]}],
      "options_ui": {"page": "options.html"},
      "declarative_net_request": {"rule_resources": [{"id": "r1", "enabled": true, "path": "rules.json"}]}
    }
    """

    func testParse() throws {
        let m = try ExtensionManifest(data: Data(json.utf8))
        XCTAssertEqual(m.version, "1.0.2")
        XCTAssertEqual(m.actionPopup, "popup.html")
        XCTAssertEqual(m.serviceWorker, "bg.js")
        XCTAssertEqual(m.backgroundType, "module")
        XCTAssertEqual(m.contentScripts.count, 1)
        XCTAssertEqual(m.contentScripts[0].runAt, "document_start")
        XCTAssertTrue(m.contentScripts[0].allFrames)
        XCTAssertEqual(m.ruleResources.first?.path, "rules.json")
        XCTAssertEqual(m.optionsPage, "options.html")
        XCTAssertEqual(Set(m.requestedHostPatterns), ["https://api.example.com/*", "*://*.example.com/*"])
        XCTAssertEqual(m.bestIcon(prefer: 32), "i48.png")
        XCTAssertTrue(m.isWebAccessible("img/a.png", from: URL(string: "https://example.com/x")))
        XCTAssertFalse(m.isWebAccessible("img/a.png", from: URL(string: "https://other.com/x")))
        XCTAssertFalse(m.isWebAccessible("secret.js", from: nil))
    }

    func testContentScriptMatching() throws {
        let m = try ExtensionManifest(data: Data(json.utf8))
        let cs = m.contentScripts[0]
        XCTAssertTrue(cs.matches(URL(string: "https://www.example.com/")!))
        XCTAssertFalse(cs.matches(URL(string: "https://example.com/skip/1")!))
        XCTAssertFalse(cs.matches(URL(string: "https://other.com/")!))
    }

    func testRejectsMV2() {
        XCTAssertThrowsError(try ExtensionManifest(data: Data(#"{"manifest_version":2,"name":"x","version":"1"}"#.utf8)))
    }

    func testLocalization() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let en = dir.appendingPathComponent("_locales/en"), zh = dir.appendingPathComponent("_locales/zh_CN")
        try FileManager.default.createDirectory(at: en, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zh, withIntermediateDirectories: true)
        try Data(#"{"appName":{"message":"Hello"},"greet":{"message":"Hi $name$! $1","placeholders":{"name":{"content":"$1"}}},"only":{"message":"EN only"}}"#.utf8)
            .write(to: en.appendingPathComponent("messages.json"))
        try Data(#"{"appName":{"message":"你好"}}"#.utf8).write(to: zh.appendingPathComponent("messages.json"))
        let zhLoc = ExtensionLocalization.load(from: dir, defaultLocale: "en", preferred: ["zh-Hans-CN"])
        XCTAssertEqual(zhLoc.message("appName"), "你好")
        XCTAssertEqual(zhLoc.message("only"), "EN only")
        XCTAssertEqual(zhLoc.localize("__MSG_appName__ app"), "你好 app")
        let enLoc = ExtensionLocalization.load(from: dir, defaultLocale: "en", preferred: ["fr"])
        XCTAssertEqual(enLoc.message("greet", substitutions: ["Bob"]), "Hi Bob! Bob")
        XCTAssertEqual(enLoc.message("@@extension_id", extensionID: "abc"), "abc")
    }

    func testPermissionDescriptions() {
        let lines = PermissionDescriber.describe(apiPermissions: ["downloads", "storage"], hostPatterns: ["<all_urls>"])
        XCTAssertEqual(lines.map(\.text).first, "读取和修改所有网站的数据")
        XCTAssertTrue(lines.contains { $0.text.hasPrefix("管理下载") })
        XCTAssertTrue(lines.contains { $0.text == "保存本地数据" })
    }

    func testAPIMatrix() {
        XCTAssertEqual(ChromeAPIMatrix.level(of: "runtime"), .supported)
        XCTAssertEqual(ChromeAPIMatrix.level(of: "debugger"), .unsupported)
        XCTAssertTrue(ChromeAPIMatrix.unsupportedNamespaces.contains("webRequest"))
    }
}

final class FilterTests: XCTestCase {
    func testABPPattern() throws {
        let regex = try XCTUnwrap(ABPPattern.regex("||ads.example.com^"))
        let re = try NSRegularExpression(pattern: regex)
        func hit(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        XCTAssertTrue(hit("https://ads.example.com/banner.js"))
        XCTAssertTrue(hit("https://sub.ads.example.com/x"))
        XCTAssertFalse(hit("https://notads.example.com/x"))
        XCTAssertFalse(hit("https://example.com/ads.example.com"))
        XCTAssertEqual(ABPPattern.regex("|https://x.com/a*b|"), "^https://x\\.com/a.*b$")
        XCTAssertNil(ABPPattern.webKitRegex(from: "a|b"))
        XCTAssertEqual(ABPPattern.webKitRegex(from: "ad\\d+"), "ad[0-9]+")
    }

    func testParseList() {
        let list = """
        ! comment
        [Adblock Plus 2.0]
        ||doubleclick.net^
        ||ads.com^$third-party,script
        @@||ads.com/allowed.js
        @@||goodsite.com^$document
        ##.ad-banner
        example.com##.promo
        ~safe.com##.generic-ad
        example.com#@#.ad-banner
        example.com#$#body { overflow: auto !important; }
        example.com##div:has-text(Sponsored)
        ||tracker.com^$redirect=noop.js
        0.0.0.0 hosts-ad.com
        @@||nohide.com^$elemhide
        """
        let result = FilterListParser.parse(list)
        XCTAssertEqual(result.comments, 2)
        XCTAssertEqual(result.network.filter { $0.action == .block }.count, 3)
        XCTAssertTrue(result.network.contains { $0.action == .allowDocument && $0.ifDomains == ["goodsite.com"] })
        let third = result.network.first { $0.thirdParty == true }
        XCTAssertEqual(third?.resourceTypes, [.script])
        XCTAssertEqual(result.unsupported, 2)
        let onExample = result.cosmetic.rules(forHost: "www.example.com")
        XCTAssertTrue(onExample.selectors.contains(".promo"))
        XCTAssertFalse(onExample.selectors.contains(".ad-banner"))
        XCTAssertEqual(onExample.css.count, 1)
        let elsewhere = result.cosmetic.rules(forHost: "news.org")
        XCTAssertTrue(elsewhere.selectors.contains(".ad-banner"))
        XCTAssertTrue(elsewhere.selectors.contains(".generic-ad"))
        XCTAssertFalse(result.cosmetic.rules(forHost: "safe.com").selectors.contains(".generic-ad"))
        XCTAssertTrue(result.cosmetic.rules(forHost: "nohide.com").selectors.isEmpty)
    }

    func testCompilerProducesValidJSON() throws {
        let result = FilterListParser.parse("||a.com^\n@@||a.com/ok\n")
        let docs = ContentBlockerCompiler.compile(result.network, allowlistedHosts: ["trusted.org"])
        XCTAssertEqual(docs.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(docs[0].utf8)) as? [[String: Any]])
        XCTAssertEqual(json.count, 3)
        XCTAssertEqual((json.last?["action"] as? [String: Any])?["type"] as? String, "ignore-previous-rules")
        let empty = ContentBlockerCompiler.compile([], allowlistedHosts: [])
        XCTAssertEqual(empty.count, 1)
    }

    func testDNR() {
        let rules: [[String: Any]] = [
            ["id": 1, "priority": 1, "action": ["type": "block"], "condition": ["urlFilter": "||blocked.test^", "resourceTypes": ["script"]]],
            ["id": 2, "priority": 2, "action": ["type": "allow"], "condition": ["urlFilter": "||blocked.test/ok.js"]],
            ["id": 3, "action": ["type": "redirect", "redirect": ["url": "https://x"]], "condition": ["urlFilter": "x"]],
            ["id": 4, "action": ["type": "block"], "condition": ["requestDomains": ["a.com", "b.com"]]],
            ["id": 5, "action": ["type": "upgradeScheme"], "condition": ["urlFilter": "|http://insecure.test/"]],
        ]
        let out = DNRConverter.convert(rules)
        XCTAssertEqual(out.skipped.map(\.id), [3])
        XCTAssertEqual(out.rules.filter { $0.action == .block }.count, 3)
        XCTAssertEqual(out.rules.last?.action, .allow)
        XCTAssertEqual(out.rules.first { $0.resourceTypes == [.script] }?.urlRegex, ABPPattern.regex("||blocked.test^"))
        XCTAssertTrue(out.rules.contains { $0.action == .upgradeScheme })
    }
}

final class MiscCoreTests: XCTestCase {
    func testM3U8() {
        let base = URL(string: "https://cdn.test/v/master.m3u8")!
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=\"1280x720\"\nhigh/index.m3u8\n"
        XCTAssertTrue(M3U8.isMaster(master))
        let variants = M3U8.variants(master, base: base)
        XCTAssertEqual(variants.first?.url.absoluteString, "https://cdn.test/v/high/index.m3u8")
        XCTAssertEqual(variants.first?.resolution, "1280x720")
        let media = "#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:4.0,\nseg0.ts\n#EXTINF:3.5,\nhttps://other/seg1.ts\n#EXT-X-ENDLIST\n"
        let playlist = M3U8.media(media, base: base)
        XCTAssertEqual(playlist.segments.count, 2)
        XCTAssertEqual(playlist.totalDuration, 7.5, accuracy: 0.001)
        XCTAssertNil(playlist.encryption)
        XCTAssertEqual(M3U8.media("#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:1,\na.ts", base: base).encryption, "SAMPLE-AES")
    }

    func testPreferencesTolerantDecoding() throws {
        let data = Data(#"{"searchEngineID":"bing","unknownKey":1,"pageDarkMode":"on"}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(prefs.searchEngineID, "bing")
        XCTAssertEqual(prefs.pageDarkMode, .on)
        XCTAssertEqual(prefs.toolbarPosition, .bottom)
    }

    func testExportRoundTrip() throws {
        var prefs = Preferences()
        prefs.searchEngineID = "duckduckgo"
        let group = TabGroupSnapshot(name: "Work")
        var session = WindowSessionSnapshot()
        session.groups = [group]
        session.tabs = [TabSnapshot(url: "https://a.com", title: "A", groupID: group.id, interactionState: Data([1, 2, 3]))]
        var site = SiteSettings(host: "Example.com")
        site.darkMode = .on
        let bundle = ExportBundle(preferences: prefs, sessions: [session], siteSettings: [site], bookmarks: [],
                                  adBlockCustomRules: "example.com##.x", adBlockSubscriptions: FilterSubscription.defaults,
                                  adBlockAllowlist: ["ok.com"], userscripts: [ExportedUserscript(source: "// x", enabled: true, values: ["k": "1"])])
        let data = try ExportBundle.encoder().encode(bundle)
        let decoded = try ExportBundle.decode(data)
        XCTAssertEqual(decoded.preferences.searchEngineID, "duckduckgo")
        XCTAssertEqual(decoded.sessions.first?.tabs.first?.groupID, group.id)
        XCTAssertEqual(decoded.sessions.first?.tabs.first?.interactionState, Data([1, 2, 3]))
        XCTAssertEqual(decoded.siteSettings.first?.host, "example.com")
        XCTAssertThrowsError(try ExportBundle.decode(Data(#"{"format":"x"}"#.utf8)))
    }

    func testJSLiteral() {
        XCTAssertEqual("a\"b\n".jsLiteral, "\"a\\\"b\\n\"")
        XCTAssertEqual(JSONText.encode(["a": 1]), "{\"a\":1}")
    }
}
