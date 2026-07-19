//
//  keyboardUITests.swift
//  keyboardUITests
//
//  Created by Meher Deepak on 21/06/26.
//

import XCTest

final class keyboardUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

	@MainActor
	func testPrimarySettingsFlows() throws {
		let app = XCUIApplication()
		app.launch()

		let language = app.buttons["settings.language"]
		XCTAssertTrue(language.waitForExistence(timeout: 5))
		language.tap()
		let english = app.buttons["language.english"]
		XCTAssertTrue(english.waitForExistence(timeout: 3))
		english.tap()

		let appearance = app.buttons["settings.appearance"]
		XCTAssertTrue(appearance.waitForExistence(timeout: 2))
		appearance.tap()
		XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 2))
		add(XCTAttachment(screenshot: app.screenshot()))
		app.navigationBars["Appearance"].buttons.element(boundBy: 0).tap()

		let achievements = app.buttons["achievements.banner"]
		XCTAssertTrue(achievements.waitForExistence(timeout: 2))
		achievements.tap()
		XCTAssertTrue(app.navigationBars["Achievements"].waitForExistence(timeout: 2))
		XCTAssertTrue(app.staticTexts["LAST 14 DAYS"].exists)
		add(XCTAttachment(screenshot: app.screenshot()))
	}

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
