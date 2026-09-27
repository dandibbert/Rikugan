import XCTest

final class BrowserUITests: XCTestCase {
    @MainActor func testExtensionUserscriptAndProfileIsolation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.buttons["home.addons"].waitForExistence(timeout: 30))
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "01-Home"; home.lifetime = .keepAlways; add(home)
        app.buttons["home.addons"].tap()
        let demo = app.buttons["addons.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 20))
        var nudges = 0
        while demo.frame.midY > app.windows.element(boundBy: 0).frame.maxY - 12 && nudges < 4 {
            app.swipeUp(); nudges += 1
        }
        demo.tap()
        tap(app, "安装示例")
        tap(app, "好", timeout: 30)
        XCTAssertTrue(app.buttons["extension.run.Rikugan Demo"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["extension.run.Rikugan Demo"].isEnabled)
        app.buttons["addons.done"].tap()
        navigate(app)
        XCTAssertTrue(app.webViews.staticTexts["用户脚本运行成功"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.staticTexts["脚本标记已写入"].exists)
        XCTAssertTrue(app.webViews.staticTexts["扩展运行成功"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.staticTexts["脚本注入成功"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.staticTexts["通知已创建"].waitForExistence(timeout: 30))
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
        let nameField = app.textFields["profiles.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 15))
        nameField.tap(); nameField.typeText("工作")
        tap(app, "创建")
        XCTAssertTrue(app.buttons["home.addons"].waitForExistence(timeout: 15))
        navigate(app)
        XCTAssertTrue(app.webViews.staticTexts["本身份是空的"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.webViews.staticTexts["用户脚本运行成功"].exists)
        XCTAssertFalse(app.webViews.staticTexts["扩展运行成功"].exists)
        XCTAssertFalse(app.webViews.staticTexts["脚本注入成功"].exists)
        XCTAssertFalse(app.webViews.staticTexts["通知已创建"].exists)
        app.buttons["browser.profiles"].tap()
        app.buttons["profile.个人"].tap()
        XCTAssertTrue(app.webViews.staticTexts["本身份已保存"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.staticTexts["扩展运行成功"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.staticTexts["脚本注入成功"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.staticTexts["通知已创建"].exists)
        XCTAssertTrue(app.webViews.staticTexts["GM 存储计数：2"].waitForExistence(timeout: 20))
    }
    @MainActor private func tap(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 20) {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: timeout))
        let window = app.windows.element(boundBy: 0).frame
        var nudges = 0
        while button.exists && button.frame.midY > window.maxY - 12 && nudges < 4 {
            app.swipeUp(); nudges += 1
        }
        button.tap()
    }
    @MainActor private func navigate(_ app: XCUIApplication) {
        let address = app.textFields["browser.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 15)); address.tap()
        address.typeText("http://127.0.0.1:8765/\n")
    }
}
