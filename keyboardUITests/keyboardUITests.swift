//
//  keyboardUITests.swift
//  keyboardUITests
//
//  Created by Meher Deepak on 21/06/26.
//

import XCTest

final class keyboardUITests: XCTestCase {
	private struct ReferenceKey: Codable {
		let label: String
		let identifier: String
		let x: Double
		let y: Double
		let width: Double
		let height: Double
	}

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
		app.launchArguments = ["-ui-testing-used-keyboard"]
		app.launch()

		let language = app.buttons["settings.language"]
		for _ in 0..<4 {
			if language.isHittable { break }
			app.swipeUp()
		}
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

		let progress = app.buttons["progress.banner"]
		for _ in 0..<3 {
			if progress.isHittable { break }
			app.swipeDown()
		}
		XCTAssertTrue(progress.waitForExistence(timeout: 2))
		progress.tap()
		XCTAssertTrue(app.navigationBars["Progress"].waitForExistence(timeout: 2))
		XCTAssertTrue(app.staticTexts["Words entered"].exists)
		add(XCTAttachment(screenshot: app.screenshot()))
	}

	@MainActor
	func testInstalledExtensionTypesInEveryLanguageMode() throws {
		try selectLanguage(identifier: "language.english", title: "English")
		var host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
			throw XCTSkip("Glyph is not the active software keyboard on this simulator")
		}
		XCTAssertTrue(host.keys["Q"].waitForExistence(timeout: 2))
		host.keys["Q"].tap()
		XCTAssertEqual(host.textFields["runtime.text"].value as? String, "Q")
		host.terminate()

		try selectLanguage(identifier: "language.tenglish", title: "Tenglish to Telugu")
		host = launchRuntimeHost()
		tapLetter("N", in: host)
		tapLetter("e", in: host)
		tapLetter("n", in: host)
		tapLetter("u", in: host)
		host.keys["Space"].tap()
		let tEnglishField = host.textFields["runtime.text"]
		let converted = NSPredicate(format: "value BEGINSWITH %@", "నేను")
		expectation(for: converted, evaluatedWith: tEnglishField)
		waitForExpectations(timeout: 3)
		host.terminate()

		try selectLanguage(identifier: "language.roman_telugu", title: "Tenglish (Roman)")
		host = launchRuntimeHost()
		for letter in ["i", "d", "h", "i"] { tapLetter(letter, in: host) }
		host.keys["Space"].tap()
		let romanOutput = host.textFields["runtime.text"].value as? String
		XCTAssertEqual(romanOutput?.lowercased(), "idhi ",
			"Roman Telugu must preserve Latin script while sentence casing remains active")
		host.terminate()

		try selectLanguage(identifier: "language.telugu", title: "Telugu (Native)")
		host = launchRuntimeHost()
		let ka = host.keys["Telugu ka"]
		XCTAssertTrue(ka.waitForExistence(timeout: 4))
		ka.tap()
		let aa = host.keys["Telugu aa"]
		XCTAssertTrue(aa.waitForExistence(timeout: 2))
		aa.tap()
		XCTAssertEqual(host.textFields["runtime.text"].value as? String, "కా")
	}

	/// Explicit research capture only. Apple Telugu is a system input mode, not an
	/// asset the project downloads or redistributes. Screenshots and accessibility
	/// geometry remain XCTest attachments in the immutable xcresult.
	@MainActor
	func testCaptureAppleTeluguReference() throws {
		let explicitlyEnabled = ProcessInfo.processInfo.environment["CAPTURE_APPLE_TELUGU"] == "1"
			|| UserDefaults.standard.bool(forKey: "KeyboardCaptureAppleTeluguReference")
		guard explicitlyEnabled else {
			throw XCTSkip("Set CAPTURE_APPLE_TELUGU=1 for a reference capture")
		}
		let app = launchRuntimeHost()
		defer { app.terminate() }

		let ka = app.keys["క"]
		for _ in 0..<8 where !ka.exists {
			let switcher = inputModeSwitch(in: app)
			guard switcher.waitForExistence(timeout: 1) else {
				throw XCTSkip("No input-mode switch key is exposed by the active keyboard")
			}
			switcher.tap()
		}
		guard ka.waitForExistence(timeout: 2) else {
			throw XCTSkip("Apple Telugu is not enabled in this simulator")
		}

		captureReference(app, state: "alphabetic")
		ka.press(forDuration: 0.8)
		captureReference(app, state: "ka-long-press")
		app.textFields["runtime.text"].tap()

		ka.tap()
		let aa = app.keys["ఆ"]
		if aa.waitForExistence(timeout: 1) { aa.tap() }
		captureReference(app, state: "composition-ka-aa")

		let appleMore = app.keys["more"]
		let conventionalNumbers = app.keys["123"]
		let numbers = appleMore.waitForExistence(timeout: 1)
			? appleMore : conventionalNumbers
		XCTAssertTrue(numbers.waitForExistence(timeout: 1),
			"Apple Telugu did not expose its numeric-page control")
		numbers.tap()
		XCTAssertTrue(app.keys["1"].waitForExistence(timeout: 1),
			"Apple Telugu did not transition to its numeric page")
		captureReference(app, state: "numbers")
		if let shift = app.keys.allElementsBoundByIndex.first(where: {
			$0.label.localizedCaseInsensitiveContains("shift")
		}) {
			shift.tap()
			captureReference(app, state: "shift")
		}
	}

	@MainActor
	private func selectLanguage(identifier: String, title: String) throws {
		let app = XCUIApplication()
		app.launchArguments = []
		app.launch()
		let picker = app.buttons["settings.language"]
		for _ in 0..<4 {
			if picker.isHittable { break }
			app.swipeUp()
		}
		XCTAssertTrue(picker.waitForExistence(timeout: 5))
		picker.tap()
		let identified = app.descendants(matching: .any)[identifier]
		let option = identified.waitForExistence(timeout: 2) ? identified : app.buttons[title]
		XCTAssertTrue(option.waitForExistence(timeout: 2))
		option.tap()
		app.terminate()
	}

	@MainActor
	private func launchRuntimeHost() -> XCUIApplication {
		let app = XCUIApplication()
		app.launchArguments = ["-keyboard-runtime-host"]
		app.launch()
		let field = app.textFields["runtime.text"]
		XCTAssertTrue(field.waitForExistence(timeout: 5))
		field.tap()
		return app
	}

	@MainActor
	private func tapLetter(_ preferredLabel: String, in app: XCUIApplication) {
		let preferred = app.keys[preferredLabel]
		if preferred.waitForExistence(timeout: 1) {
			preferred.tap()
			return
		}
		let alternateLabel = preferredLabel == preferredLabel.lowercased()
			? preferredLabel.uppercased() : preferredLabel.lowercased()
		let alternate = app.keys[alternateLabel]
		XCTAssertTrue(alternate.waitForExistence(timeout: 2))
		alternate.tap()
	}

	@MainActor
	private func inputModeSwitch(in app: XCUIApplication) -> XCUIElement {
		let keys = app.keys.allElementsBoundByIndex
		if let key = keys.first(where: {
			$0.label.localizedCaseInsensitiveContains("next keyboard")
				|| $0.label.localizedCaseInsensitiveContains("globe")
		}) { return key }
		return app.buttons["Next Keyboard"]
	}

	@MainActor
	private func captureReference(_ app: XCUIApplication, state: String) {
		let keys = app.keys.allElementsBoundByIndex.filter(\.exists).map { key in
			ReferenceKey(label: key.label, identifier: key.identifier,
				x: key.frame.minX, y: key.frame.minY,
				width: key.frame.width, height: key.frame.height)
		}
		let payload: [String: Any] = [
			"schemaVersion": 1,
			"state": state,
			"capturedAt": ISO8601DateFormatter().string(from: Date()),
			"keys": keys.map {
				["label": $0.label, "identifier": $0.identifier, "x": $0.x,
				 "y": $0.y, "width": $0.width, "height": $0.height]
			},
		]
		if let data = try? JSONSerialization.data(withJSONObject: payload,
			options: [.prettyPrinted, .sortedKeys]) {
			let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
			attachment.name = "apple-telugu-\(state).json"
			attachment.lifetime = .keepAlways
			add(attachment)
		}
		let screenshot = XCTAttachment(screenshot: app.screenshot())
		screenshot.name = "apple-telugu-\(state)"
		screenshot.lifetime = .keepAlways
		add(screenshot)
	}

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

	/// The re-added clipboard icon sits in the suggestion strip and is tappable — proving
	/// SuggestionBar exposes it and the tap target is valid on a real device. The panel
	/// it opens is an extension overlay whose accessibility subtree XCUITest does not
	/// reliably snapshot, so its rendering is covered by the `renderClipboardPanel` unit
	/// test instead; here we only assert the entry point and that the tap does not crash
	/// the keyboard (the strip is still queryable afterward).
	@MainActor
	func testClipboardIconIsPresentAndTappable() throws {
		try selectLanguage(identifier: "language.english", title: "English")
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
			throw XCTSkip("Glyph is not the active software keyboard on this simulator")
		}
		let clip = host.descendants(matching: .any)["suggestion.clipboard"]
		XCTAssertTrue(clip.waitForExistence(timeout: 3), "Clipboard icon missing from suggestion strip")
		XCTAssertTrue(clip.isHittable, "Clipboard icon is not hittable")
		clip.tap()
		// The keyboard survived opening the panel: the deck is still there to type on.
		XCTAssertTrue(host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 3),
			"Keyboard disappeared after opening the clipboard panel")
	}

	/// Probes the emoji page end-to-end: opens the palette, taps specific cells (early
	/// section, then a far section reached via a category tab), and verifies the exact
	/// tapped emoji landed in the host field — hunting the "emoji selection bug" noted
	/// in commit c9ff326. Reports what was inserted via NSLog EMOJI-PROBE lines.
	@MainActor
	func testEmojiSelectionProbe() throws {
		try selectLanguage(identifier: "language.english", title: "English")
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
			throw XCTSkip("Glyph is not the active software keyboard on this simulator")
		}
		let field = host.textFields["runtime.text"]
		let emojiKey = host.buttons["Emoji"].exists ? host.buttons["Emoji"] : host.keys["Emoji"]
		XCTAssertTrue(emojiKey.waitForExistence(timeout: 3), "Emoji key missing on letters page")
		emojiKey.tap()

		let grid = host.collectionViews.firstMatch
		XCTAssertTrue(grid.waitForExistence(timeout: 3), "Emoji grid did not appear")
		var previous = (field.value as? String) ?? ""

		func tapCellAndVerify(_ index: Int, label note: String) {
			let cell = grid.cells.element(boundBy: index)
			guard cell.exists, cell.isHittable else {
				NSLog("EMOJI-PROBE %@ cell %d not hittable", note, index)
				return
			}
			let expected = cell.label
			cell.tap()
			let text = (field.value as? String) ?? ""
			let inserted = String(text.dropFirst(previous.count))
			previous = text
			NSLog("EMOJI-PROBE %@ tapped=%@ inserted=%@ %@", note, expected, inserted,
				  inserted == expected ? "OK" : "MISMATCH")
			XCTAssertEqual(inserted, expected, "\(note): tapped \(expected) got \(inserted)")
		}

		tapCellAndVerify(0, label: "first-cell")
		tapCellAndVerify(5, label: "sixth-cell")

		// Jump to a later category via its bottom-bar tab, then pick a visible cell.
		let tab = host.descendants(matching: .any)["emoji.category.4"]
		if tab.waitForExistence(timeout: 2) {
			tab.tap()
			if let visible = grid.cells.allElementsBoundByIndex.first(where: { $0.isHittable }) {
				let expected = visible.label
				visible.tap()
				let text = (field.value as? String) ?? ""
				let inserted = String(text.dropFirst(previous.count))
				previous = text
				NSLog("EMOJI-PROBE after-tab-jump tapped=%@ inserted=%@ %@", expected, inserted,
					  inserted == expected ? "OK" : "MISMATCH")
				XCTAssertEqual(inserted, expected, "after-tab-jump: tapped \(expected) got \(inserted)")
			}
		}

		// Scroll the grid and pick again (scroll-tracking selection interplay).
		grid.swipeUp()
		if let visible = grid.cells.allElementsBoundByIndex.first(where: { $0.isHittable }) {
			let expected = visible.label
			visible.tap()
			let text = (field.value as? String) ?? ""
			let inserted = String(text.dropFirst(previous.count))
			previous = text
			NSLog("EMOJI-PROBE after-scroll tapped=%@ inserted=%@ %@", expected, inserted,
				  inserted == expected ? "OK" : "MISMATCH")
			XCTAssertEqual(inserted, expected, "after-scroll: tapped \(expected) got \(inserted)")
		}
	}

	/// End-to-end autocorrect battery: types spatially-plausible QWERTY slips on the
	/// REAL extension key-by-key, reads the suggestion strip before each space, and the
	/// committed text after. Words flow as sentences so context scoring is exercised.
	/// The test never fails on a miss — it reports measured quality via attachment
	/// and NSLog lines prefixed TYPO-BATTERY so the host log can be grepped.
	@MainActor
	func testTypoCorrectionBattery() throws {
		try selectLanguage(identifier: "language.english", title: "English")
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
			throw XCTSkip("Glyph is not the active software keyboard on this simulator")
		}

		// (typed, intended). intended == typed means "must NOT be falsely corrected".
		let cases: [(typed: String, intended: String)] = [
			("i", "I"), ("am", "am"), ("goinf", "going"), ("to", "to"), ("the", "the"), ("store", "store"),
			("can", "can"), ("you", "you"), ("sebd", "send"), ("me", "me"), ("thw", "the"), ("file", "file"),
			("see", "see"), ("you", "you"), ("tomirrow", "tomorrow"),
			("whst", "what"), ("time", "time"), ("is", "is"), ("it", "it"),
			("i", "I"), ("dont", "don't"), ("know", "know"),
			("hiw", "how"), ("are", "are"), ("yiu", "you"), ("doing", "doing"),
			("plesse", "please"), ("call", "call"), ("me", "me"),
			("teh", "the"), ("meeting", "meeting"), ("was", "was"), ("awesomr", "awesome"),
			("rhis", "this"), ("wprk", "work"), ("runnjng", "running"),
			("coudl", "could"), ("definately", "definitely"), ("recieve", "receive"),
			("coeevitjkn", "correction"),
		]

		var lines: [String] = []
		var correctedHits = 0, typoTotal = 0, falseCorrections = 0, cleanTotal = 0
		var suggestionHits = 0
		var previousText = ""
		let field = host.textFields["runtime.text"]

		for c in cases {
			for ch in c.typed { tapLetter(String(ch), in: host) }
			let sugg = ["suggestion.left", "suggestion.primary", "suggestion.right"].map { id -> String in
				let el = host.descendants(matching: .any)[id]
				return el.exists ? el.label : ""
			}
			host.keys["Space"].tap()
			let text = (field.value as? String) ?? ""
			let committed = String(text.dropFirst(previousText.count))
				.trimmingCharacters(in: .whitespaces)
			previousText = text

			let isTypo = c.typed.lowercased() != c.intended.lowercased()
			let ok = committed.lowercased() == c.intended.lowercased()
			if isTypo {
				typoTotal += 1
				if ok { correctedHits += 1 }
				if sugg.contains(where: { $0.lowercased() == c.intended.lowercased() }) { suggestionHits += 1 }
			} else {
				cleanTotal += 1
				if !ok { falseCorrections += 1 }
			}
			lines.append("\(c.typed) -> \(committed) [want \(c.intended)] \(ok ? "OK" : "MISS") sugg=[\(sugg.joined(separator: "|"))]")
		}

		let summary = "SUMMARY corrected=\(correctedHits)/\(typoTotal) inSuggestions=\(suggestionHits)/\(typoTotal) falseCorrections=\(falseCorrections)/\(cleanTotal)"
		lines.append(summary)
		for l in lines { NSLog("TYPO-BATTERY %@", l) }
		let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
		attachment.name = "typo-battery-results"
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
