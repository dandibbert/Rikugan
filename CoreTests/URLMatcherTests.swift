import XCTest
@testable import RikuganCore

final class URLMatcherTests: XCTestCase {
    private func m(_ pattern: String, _ url: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        do { return try URLMatcher.matchPattern(pattern).matches(URL(string: url)!) }
        catch { XCTFail("pattern failed: \(error)", file: file, line: line); return false }
    }

    func testAllURLs() {
        XCTAssertTrue(m("<all_urls>", "https://example.com/"))
        XCTAssertTrue(m("<all_urls>", "http://a.b/c?d"))
        XCTAssertTrue(m("<all_urls>", "file:///tmp/x.html"))
        XCTAssertFalse(m("<all_urls>", "about:blank"))
        XCTAssertFalse(m("<all_urls>", "chrome-extension://abc/x.html"))
    }

    func testSchemeWildcard() {
        XCTAssertTrue(m("*://example.com/*", "http://example.com/a"))
        XCTAssertTrue(m("*://example.com/*", "https://example.com/"))
        XCTAssertFalse(m("*://example.com/*", "ftp://example.com/"))
        XCTAssertFalse(m("https://example.com/*", "http://example.com/"))
    }

    func testHostWildcard() {
        XCTAssertTrue(m("*://*.example.com/*", "https://example.com/"))
        XCTAssertTrue(m("*://*.example.com/*", "https://a.b.example.com/x"))
        XCTAssertFalse(m("*://*.example.com/*", "https://badexample.com/"))
        XCTAssertFalse(m("*://*.example.com/*", "https://example.com.evil.org/"))
        XCTAssertTrue(m("*://*/*", "https://anything.org/path"))
    }

    func testPathAndQuery() {
        XCTAssertTrue(m("https://example.com/foo*", "https://example.com/foobar"))
        XCTAssertTrue(m("https://example.com/foo*", "https://example.com/foo?x=1"))
        XCTAssertFalse(m("https://example.com/foo", "https://example.com/foo/bar"))
        XCTAssertTrue(m("https://example.com/*/edit", "https://example.com/doc/1/edit"))
        XCTAssertTrue(m("https://example.com/a.b", "https://example.com/a.b"))
        XCTAssertFalse(m("https://example.com/a.b", "https://example.com/aXb"))
    }

    func testFragmentIgnoredAndHostCase() {
        XCTAssertTrue(m("https://example.com/page", "https://EXAMPLE.com/page#section"))
    }

    func testPorts() {
        XCTAssertTrue(m("http://localhost/*", "http://localhost:8080/x"))
        XCTAssertTrue(m("http://127.0.0.1:8765/*", "http://127.0.0.1:8765/index.html"))
        XCTAssertFalse(m("http://127.0.0.1:8765/*", "http://127.0.0.1:9000/index.html"))
    }

    func testInvalidPatterns() {
        XCTAssertThrowsError(try URLMatcher.matchPattern("example.com"))
        XCTAssertThrowsError(try URLMatcher.matchPattern("gopher://example.com/*"))
        XCTAssertFalse(URLMatcher.isValidMatchPattern("https://"))
    }

    func testIncludeGlob() throws {
        let rule = try URLMatcher.includeRule("http*://*.google.com/search*")
        XCTAssertTrue(rule.matches(URL(string: "https://www.google.com/search?q=x")!))
        XCTAssertFalse(rule.matches(URL(string: "https://www.google.com/maps")!))
        let all = try URLMatcher.includeRule("*")
        XCTAssertTrue(all.matches(URL(string: "https://x.y/")!))
    }

    func testIncludeRegex() throws {
        let rule = try URLMatcher.includeRule("/^https:\\/\\/github\\.com\\/.+\\/issues/i")
        XCTAssertTrue(rule.matches(URL(string: "https://GitHub.com/a/b/issues")!))
        XCTAssertFalse(rule.matches(URL(string: "https://github.com/a/b/pulls")!))
        XCTAssertThrowsError(try URLMatcher.includeRule("/[unclosed/"))
    }

    func testTLDMagic() throws {
        let rule = try URLMatcher.includeRule("*://www.google.tld/*")
        XCTAssertTrue(rule.matches(URL(string: "https://www.google.co.jp/x")!))
        XCTAssertTrue(rule.matches(URL(string: "https://www.google.de/")!))
    }

    func testJSExpressionIsValidEcmascript() throws {
        let rule = try URLMatcher.matchPattern("*://*.example.com/a/*")
        XCTAssertTrue(rule.jsExpression.hasPrefix("new RegExp(\""))
    }

    func testDomainTools() {
        XCTAssertTrue(DomainTools.host("a.example.com", isWithin: "example.com"))
        XCTAssertFalse(DomainTools.host("badexample.com", isWithin: "example.com"))
        XCTAssertEqual(DomainTools.suffixes(of: "a.b.c"), ["a.b.c", "b.c", "c"])
        XCTAssertEqual(DomainTools.registrableDomain("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(DomainTools.registrableDomain("a.b.example.com"), "example.com")
    }

    func testPatternCovers() {
        XCTAssertTrue(URLMatcher.pattern("<all_urls>", covers: "https://a.com/*"))
        XCTAssertTrue(URLMatcher.pattern("*://*.a.com/*", covers: "https://b.a.com/*"))
        XCTAssertFalse(URLMatcher.pattern("*://a.com/*", covers: "*://b.com/*"))
    }
}

final class MetadataParserTests: XCTestCase {
    let sample = """
    // ==UserScript==
    // @name         Sample
    // @namespace    https://example.com
    // @version      1.2.3
    // @description  Test script
    // @author       Me
    // @match        https://example.com/*
    // @include      /^https:\\/\\/news\\./
    // @exclude      https://example.com/private*
    // @exclude-match https://example.com/admin/*
    // @run-at       document-start
    // @grant        GM_getValue
    // @grant        GM_setValue
    // @grant        GM_xmlhttpRequest
    // @connect      api.example.com
    // @require      https://cdn.example.com/lib.js
    // @resource     css https://cdn.example.com/style.css
    // @icon         https://example.com/icon.png
    // @downloadURL  https://example.com/s.user.js
    // @updateURL    https://example.com/s.meta.js
    // @noframes
    // ==/UserScript==
    console.log(1)
    """

    func testParsesAllFields() {
        let result = MetadataParser.parse(sample)
        XCTAssertFalse(result.hasErrors, "\(result.issues)")
        let m = result.metadata
        XCTAssertEqual(m.name, "Sample")
        XCTAssertEqual(m.namespace, "https://example.com")
        XCTAssertEqual(m.version, "1.2.3")
        XCTAssertEqual(m.description, "Test script")
        XCTAssertEqual(m.author, "Me")
        XCTAssertEqual(m.matches, ["https://example.com/*"])
        XCTAssertEqual(m.includes.count, 1)
        XCTAssertEqual(m.excludes, ["https://example.com/private*"])
        XCTAssertEqual(m.excludeMatches, ["https://example.com/admin/*"])
        XCTAssertEqual(m.runAt, .documentStart)
        XCTAssertEqual(m.grants, ["GM_getValue", "GM_setValue", "GM_xmlhttpRequest"])
        XCTAssertEqual(m.connects, ["api.example.com"])
        XCTAssertEqual(m.requires, ["https://cdn.example.com/lib.js"])
        XCTAssertEqual(m.resources, [UserScriptResourceRef(name: "css", url: "https://cdn.example.com/style.css")])
        XCTAssertEqual(m.icon, "https://example.com/icon.png")
        XCTAssertEqual(m.downloadURL, "https://example.com/s.user.js")
        XCTAssertEqual(m.updateURL, "https://example.com/s.meta.js")
        XCTAssertTrue(m.noframes)
        XCTAssertFalse(m.runsInPageWorld)
    }

    func testMatchingIncludeExclude() {
        let m = MetadataParser.parse(sample).metadata
        XCTAssertTrue(m.matches(URL(string: "https://example.com/page")!))
        XCTAssertTrue(m.matches(URL(string: "https://news.site.org/")!))
        XCTAssertFalse(m.matches(URL(string: "https://example.com/private/x")!))
        XCTAssertFalse(m.matches(URL(string: "https://example.com/admin/users")!))
        XCTAssertFalse(m.matches(URL(string: "https://other.com/")!))
    }

    func testRunAtValues() {
        for value in ["document-start", "document-body", "document-end", "document-idle"] {
            let src = "// ==UserScript==\n// @name x\n// @match *://*/*\n// @run-at \(value)\n// ==/UserScript==\n"
            XCTAssertEqual(MetadataParser.parse(src).metadata.runAt.rawValue, value)
        }
        let defaultSrc = "// ==UserScript==\n// @name x\n// @match *://*/*\n// ==/UserScript==\n"
        XCTAssertEqual(MetadataParser.parse(defaultSrc).metadata.runAt, .documentIdle)
    }

    func testGrantNoneRunsInPage() {
        let src = "// ==UserScript==\n// @name x\n// @match *://*/*\n// @grant none\n// ==/UserScript==\n"
        let m = MetadataParser.parse(src).metadata
        XCTAssertTrue(m.grantsNone)
        XCTAssertTrue(m.runsInPageWorld)
        let unsafe = "// ==UserScript==\n// @name x\n// @match *://*/*\n// @grant unsafeWindow\n// @grant GM_setValue\n// ==/UserScript==\n"
        XCTAssertTrue(MetadataParser.parse(unsafe).metadata.runsInPageWorld)
    }

    func testErrorsReported() {
        XCTAssertTrue(MetadataParser.parse("console.log(1)").hasErrors)
        let bad = "// ==UserScript==\n// @name x\n// @match not-a-pattern\n// ==/UserScript==\n"
        let result = MetadataParser.parse(bad)
        XCTAssertTrue(result.hasErrors)
        XCTAssertEqual(result.issues.first { $0.severity == .error }?.line, 3)
        let unknownGrant = "// ==UserScript==\n// @name x\n// @match *://*/*\n// @grant GM_cookie\n// ==/UserScript==\n"
        let r2 = MetadataParser.parse(unknownGrant)
        XCTAssertFalse(r2.hasErrors)
        XCTAssertTrue(r2.issues.contains { $0.message.contains("GM_cookie") })
    }

    func testVersionCompare() {
        XCTAssertEqual(MetadataParser.compareVersions("1.2.10", "1.2.9"), .orderedDescending)
        XCTAssertEqual(MetadataParser.compareVersions("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(MetadataParser.compareVersions("2", "10"), .orderedAscending)
    }
}

final class OmniboxTests: XCTestCase {
    func testURLs() {
        XCTAssertEqual(Omnibox.classify("github.com"), .url(URL(string: "https://github.com")!))
        XCTAssertEqual(Omnibox.classify("https://example.com/x"), .url(URL(string: "https://example.com/x")!))
        XCTAssertEqual(Omnibox.classify("localhost:3000"), .url(URL(string: "http://localhost:3000")!))
        XCTAssertEqual(Omnibox.classify("192.168.1.1"), .url(URL(string: "http://192.168.1.1")!))
        XCTAssertEqual(Omnibox.classify("example.com/path?q=1"), .url(URL(string: "https://example.com/path?q=1")!))
        XCTAssertEqual(Omnibox.classify("about:blank"), .url(URL(string: "about:blank")!))
    }

    func testSearches() {
        XCTAssertEqual(Omnibox.classify("WKWebView extensions"), .search("WKWebView extensions"))
        XCTAssertEqual(Omnibox.classify("swift"), .search("swift"))
        XCTAssertEqual(Omnibox.classify("node.js"), .search("node.js"))
        XCTAssertEqual(Omnibox.classify("1.5"), .search("1.5"))
    }

    func testInternalPages() {
        XCTAssertEqual(Omnibox.classify("chrome://extensions"), .internalPage("extensions"))
        XCTAssertEqual(Omnibox.classify("rikugan://settings"), .internalPage("settings"))
    }

    func testShortcuts() {
        let shortcuts = [URLShortcut(keyword: "gh", template: "https://github.com/search?q={query}")]
        XCTAssertEqual(Omnibox.classify("gh swift ui", shortcuts: shortcuts), .url(URL(string: "https://github.com/search?q=swift%20ui")!))
    }

    func testSearchTemplate() {
        let engine = SearchEngine(id: "x", name: "x", searchTemplate: "https://www.google.com/search?q={query}")
        XCTAssertEqual(engine.searchURL(for: "a&b c")?.absoluteString, "https://www.google.com/search?q=a%26b%20c")
        XCTAssertTrue(SearchEngine.isValidTemplate("https://s.com/?q=%s"))
        XCTAssertFalse(SearchEngine.isValidTemplate("https://s.com/"))
    }

    func testSuggestionParsing() {
        XCTAssertEqual(SearchEngine.parseSuggestions(Data(#"["sw",["swift","swiftui"]]"#.utf8)), ["swift", "swiftui"])
        XCTAssertEqual(SearchEngine.parseSuggestions(Data(#"{"g":[{"q":"百度"}]}"#.utf8)), ["百度"])
    }
}
