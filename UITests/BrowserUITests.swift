import XCTest

/// Launches Rikugan with `-RikuganSuite <name>`: the app runs that in-app suite against a local
/// fixture server and shows `SELFTEST <suite> PASS|FAIL n/m — failures`. Detailed JSON reports
/// are written to the app's Documents/SelfTestReports (collected by CI via simctl).
///
/// These run in the iOS Simulator. A pass here is a simulator pass — not a device pass.
final class BrowserUITests: XCTestCase {
    /// XCUITest's own accessibility snapshots can time out while the app is busy (the suite runs on
    /// the main actor). That is a harness limitation, not a product assertion: it is logged and
    /// counted, and the test keeps waiting for the suite's real result.
    private var snapshotTimeouts = 0

    override func setUp() {
        continueAfterFailure = true
        snapshotTimeouts = 0
    }

    override func record(_ issue: XCTIssue) {
        if issue.compactDescription.contains("Failed to get matching snapshots") || issue.compactDescription.contains("Timed out while evaluating UI query") {
            snapshotTimeouts += 1
            print("SELFTEST HARNESS: ignored XCUITest snapshot timeout #\(snapshotTimeouts): \(issue.compactDescription)")
            return
        }
        super.record(issue)
    }

    private func runSuite(_ suite: String, timeout: TimeInterval, requirePass: Bool = true, extra: [String] = []) {
        let app = XCUIApplication()
        // Per-invocation nonce: CI passes it (TEST_RUNNER_RIKUGAN_RUN_ID) and later verifies the
        // app's JSON report carries it; locally a fresh one is generated.
        let runID = ProcessInfo.processInfo.environment["RIKUGAN_RUN_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "local-" + UUID().uuidString
        app.launchArguments = ["-RikuganSuite", suite, "-RikuganRunID", runID] + extra
        app.launch()
        let summary = app.staticTexts["selftest-summary"]
        let deadline = Date().addingTimeInterval(timeout)
        var found = false
        while !found && Date() < deadline {
            found = summary.waitForExistence(timeout: 10)
        }
        print("SELFTEST HARNESS: snapshot timeouts ignored while waiting: \(snapshotTimeouts)")
        guard found else {
            XCTFail("Suite \(suite) did not finish within \(Int(timeout)) s")
            return
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "selftest-\(suite)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let label = summary.label
        print("SELFTEST SUMMARY: \(label)")
        // The summary must belong to this invocation (never a stale result).
        XCTAssertTrue(label.contains("SELFTEST \(suite) ") && label.contains("run=\(runID)"), "summary is not from this run: \(label)")
        if requirePass {
            XCTAssertTrue(label.contains(" PASS "), label)
        }
    }

    func testSelfTestSuitePasses() throws { runSuite("core", timeout: 240) }
    func testPageWorldSuite() throws { runSuite("pageworld", timeout: 180) }
    func testSecuritySuite() throws { runSuite("security", timeout: 240) }
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
