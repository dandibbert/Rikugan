import XCTest

final class BrowserUITests: XCTestCase {
    @MainActor func testExtensionUserscriptAndProfileIsolation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.buttons["home.addons"].waitForExistence(timeout: 30))
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "01-Home"; home.lifetime = .keepAlways; add(home)
        app.buttons["home.addons"].tap()
        app.buttons["addons.demo"].tap()
        app.alerts.buttons["安装示例"].tap()
        XCTAssertTrue(app.alerts.buttons["好"].waitForExistence(timeout: 30))
        let installationMessage = app.alerts.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        print("INSTALL_RESULT: " + installationMessage)
        XCTAssertFalse(installationMessage.contains("未能启动"), installationMessage)
        app.alerts.buttons["好"].tap()
        XCTAssertTrue(app.buttons["extension.run.Rikugan Demo"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["extension.run.Rikugan Demo"].isEnabled)
        app.buttons["addons.done"].tap()
        navigate(app)
        XCTAssertTrue(app.webViews.staticTexts["用户脚本运行成功"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.staticTexts["扩展运行成功"].waitForExistence(timeout: 30), app.webViews.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        XCTAssertTrue(app.webViews.staticTexts["GM 存储计数：1"].exists)
        app.webViews.buttons["写入身份标记"].tap()
        XCTAssertTrue(app.webViews.staticTexts["本身份已保存"].exists)
        let runtime = XCTAttachment(screenshot: app.screenshot()); runtime.name = "02-Runtime"; runtime.lifetime = .keepAlways; add(runtime)
        app.buttons["browser.addons"].tap()
        app.buttons["extension.run.Rikugan Demo"].tap()
        XCTAssertTrue(app.webViews.staticTexts["弹窗运行成功"].waitForExistence(timeout: 20))
        let popup = XCTAttachment(screenshot: app.screenshot()); popup.name = "03-Extension-Popup"; popup.lifetime = .keepAlways; add(popup)
        app.navigationBars.buttons["完成"].tap()
        app.buttons["browser.profiles"].tap()
        app.buttons["profiles.add"].tap()
        app.alerts.textFields.firstMatch.tap(); app.alerts.textFields.firstMatch.typeText("工作")
        app.alerts.buttons["创建"].tap()
        XCTAssertTrue(app.buttons["home.addons"].waitForExistence(timeout: 15))
        navigate(app)
        XCTAssertTrue(app.webViews.staticTexts["本身份是空的"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.webViews.staticTexts["用户脚本运行成功"].exists)
        XCTAssertFalse(app.webViews.staticTexts["扩展运行成功"].exists)
        app.buttons["browser.profiles"].tap()
        app.buttons["profile.个人"].tap()
        XCTAssertTrue(app.webViews.staticTexts["本身份已保存"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.staticTexts["扩展运行成功"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.staticTexts["GM 存储计数：2"].waitForExistence(timeout: 20))
    }
    @MainActor private func navigate(_ app: XCUIApplication) {
        let address = app.textFields["browser.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15)); address.tap()
        address.typeText("http://127.0.0.1:8765/\n")
    }
}
