import XCTest

/// Launches Rikugan with `-RikuganSuite <name>`: the app runs that in-app suite against a local
/// fixture server and shows `SELFTEST <suite> PASS|FAIL n/m — failures`. Detailed JSON reports
/// are written to the app's Documents/SelfTestReports (collected by CI via simctl).
///
/// These run in the iOS Simulator. A pass here is a simulator pass — not a device pass.
final class BrowserUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func runSuite(_ suite: String, timeout: TimeInterval, requirePass: Bool = true, extra: [String] = []) {
        let app = XCUIApplication()
        app.launchArguments = ["-RikuganSuite", suite] + extra
        app.launch()
        let summary = app.staticTexts["selftest-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: timeout), "Suite \(suite) did not finish within \(Int(timeout)) s")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "selftest-\(suite)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SELFTEST SUMMARY: \(summary.label)")
        if requirePass {
            XCTAssertTrue(summary.label.contains(" PASS "), summary.label)
        }
    }

    func testSelfTestSuitePasses() throws { runSuite("core", timeout: 240) }
    func testPageWorldSuite() throws { runSuite("pageworld", timeout: 180) }
    func testFontSuite() throws { runSuite("fonts", timeout: 240) }
    func testDNRSuite() throws { runSuite("dnr", timeout: 180) }
    func testTabLifecycleSuite() throws { runSuite("lifecycle", timeout: 600) }
    func testBackgroundStressSuite() throws {
        let rounds = ProcessInfo.processInfo.environment["RIKUGAN_STRESS_ROUNDS"] ?? "20"
        runSuite("stress", timeout: 1500, extra: ["-RikuganStressRounds", rounds])
    }
    func testArchiveRoundTripSuite() throws { runSuite("archive", timeout: 240) }
    /// Real third-party extensions: produces a report; incompatibilities are data, not failures.
    func testRealExtensionCompatReport() throws { runSuite("compat", timeout: 900, requirePass: false) }

    func testBasicBrowsingUI() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["pageMenu"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["tabsButton"].exists || app.buttons["newTabButton"].exists)
    }
}
