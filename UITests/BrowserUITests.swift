import XCTest

/// Launches Rikugan with `-RikuganSelfTest`, which opens a local fixture page and verifies the
/// Chrome MV3 runtime, userscript engine and AdBlock end-to-end (spec §50 / §51 / §54).
final class BrowserUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testSelfTestSuitePasses() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-RikuganSelfTest"]
        app.launch()
        let summary = app.staticTexts["selftest-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 240), "Self-test did not finish")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
        // Scroll through results for the log.
        for cell in app.cells.allElementsBoundByIndex { print("SELFTEST ROW: \(cell.label)") }
        XCTAssertTrue(summary.label.contains("PASS"), summary.label)
    }

    func testBasicBrowsingUI() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["pageMenu"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["tabsButton"].exists || app.buttons["newTabButton"].exists)
    }
}
