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
		XCTAssertTrue(app.navigationBars["Achievements"].waitForExistence(timeout: 2))
		XCTAssertTrue(app.staticTexts["Last 14 days"].exists)
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
	private func key(_ label: String, in app: XCUIApplication) -> XCUIElement {
		let preferred = app.keys[label]
		return preferred.waitForExistence(timeout: 1) ? preferred
			: app.keys[label == label.lowercased() ? label.uppercased() : label.lowercased()]
	}

	/// A straight swipe between two letter keys: the decoder sees every key it crosses.
	@MainActor
	private func glide(_ from: String, to: String, in app: XCUIApplication) {
		let centre = CGVector(dx: 0.5, dy: 0.5)
		key(from, in: app).coordinate(withNormalizedOffset: centre)
			.press(forDuration: 0.05, thenDragTo: key(to, in: app).coordinate(withNormalizedOffset: centre),
				withVelocity: XCUIGestureVelocity(300), thenHoldForDuration: 0.05)
	}

	/// The field's text, with an empty field (which reports its placeholder) as "".
	@MainActor
	private func fieldText(_ field: XCUIElement) -> String {
		let value = field.value as? String ?? ""
		return value == field.placeholderValue ? "" : value
	}

	@MainActor
	private func waitForText(_ field: XCUIElement, toDifferFrom old: String, timeout: TimeInterval = 3) -> String {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			let now = fieldText(field)
			if now != old { return now }
			RunLoop.current.run(until: Date().addingTimeInterval(0.05))
		}
		return fieldText(field)
	}

	/// Regression: in an empty field the host reports no context (nil) while the glide began
	/// with "", so the lift-time check refused to commit the field's first glided word.
	@MainActor
	func testGlideCommitsTheFirstWordOfAnEmptyField() throws {
		try selectLanguage(identifier: "language.english", title: "English")
		let host = launchRuntimeHost()
		// The extension's first launch after an install can take several seconds.
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		let field = host.textFields["runtime.text"]
		XCTAssertEqual(fieldText(field), "")
		glide("h", to: "i", in: host)
		let first = waitForText(field, toDifferFrom: "")
		NSLog("GLIDE-FIRST [%@]", first)
		XCTAssertTrue(first.trimmingCharacters(in: .whitespaces).count >= 2,
			"The first glided word of an empty field was not committed: [\(first)]")
		glide("t", to: "o", in: host)
		let second = waitForText(field, toDifferFrom: first)
		NSLog("GLIDE-SECOND [%@]", second)
		XCTAssertTrue(second.count > first.count + 1, "The second glided word was not committed: [\(second)]")
	}

	/// What the strip shows in the middle for a contraction typed without its apostrophe must
	/// be what Space commits, and the intended word; "she lets" keeps the verb.
	/// Logs CONTRACTION lines with the strip and the committed word.
	@MainActor
	func testContractionsCommitWhatTheStripShows() throws {
		try selectLanguage(identifier: "language.english", title: "English")
		let host = launchRuntimeHost()
		// The extension's first launch after an install can take several seconds.
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		let field = host.textFields["runtime.text"]
		let cases = [("dont", "don't"), ("im", "i'm"), ("cant", "can't"), ("thats", "that's"),
			("youre", "you're"), ("didnt", "didn't"), ("hows", "how's"), ("whys", "why's"),
			("ill", "i'll"), ("its", "it's"), ("she", "she"), ("lets", "lets")]
		var previous = fieldText(field), mismatches: [String] = []
		for (typed, intended) in cases {
			for ch in typed { tapLetter(String(ch), in: host) }
			let primary = host.descendants(matching: .any)["suggestion.primary"]
			// Let the strip settle on the last letter's decode before reading it.
			RunLoop.current.run(until: Date().addingTimeInterval(0.4))
			let shown = primary.exists ? primary.label : ""
			host.keys["Space"].tap()
			let text = waitForText(field, toDifferFrom: previous)
			let committed = String(text.dropFirst(previous.count)).trimmingCharacters(in: .whitespaces)
				.replacingOccurrences(of: "\u{2019}", with: "'")
			previous = text
			NSLog("CONTRACTION %@ strip=[%@] committed=[%@] want=[%@]", typed, shown, committed, intended)
			let strip = shown.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
			if strip != committed.lowercased() {
				mismatches.append("\(typed): strip \(shown), committed \(committed)")
			}
			if committed.lowercased() != intended { NSLog("CONTRACTION-MISS %@ committed=[%@] want=[%@]", typed, committed, intended) }
		}
		// Which word the model picks is accuracy (logged as CONTRACTION-MISS); the strip's middle
		// differing from what Space commits is a bug.
		XCTAssertEqual(mismatches, [], "Space must commit the strip's middle word")
	}

	/// A Backspace right after an autocorrection restores the typed word, the strip then shows
	/// that word in the middle, and the next Space keeps it: the undo must stick. Dictionary
	/// words only, so the undo it teaches leaves nothing new in the phone's learned words.
	/// Logs UNDO lines with non-ASCII characters spelled out.
	/// Keyboard health's "Keyboard memory now" is live while the keyboard is open on that screen,
	/// and keeps the latest reading, with its age, once the keyboard has gone.
	@MainActor
	func testKeyboardHealthFollowsMemoryLive() throws {
		let app = XCUIApplication()
		app.launchArguments = []
		app.launch()
		let health = app.buttons["Keyboard health"]
		for _ in 0..<6 where !health.isHittable { app.swipeUp() }
		guard health.waitForExistence(timeout: 5) else { throw XCTSkip("Keyboard health is a Debug-build screen") }
		health.tap()
		let memory = app.descendants(matching: .any)["health.memory.now"]
		XCTAssertTrue(memory.waitForExistence(timeout: 5))
		app.textFields["health.memory.probe"].tap()
		guard app.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		expectation(for: NSPredicate(format: "label CONTAINS ' · live'"), evaluatedWith: memory)
		waitForExpectations(timeout: 6)
		app.navigationBars.buttons.firstMatch.tap()   // back: the keyboard goes with the field
		RunLoop.current.run(until: Date().addingTimeInterval(4))
		health.tap()
		XCTAssertTrue(memory.waitForExistence(timeout: 5))
		XCTAssertTrue(memory.label.contains(" ago"), memory.label)
	}

	/// Types, then opens emoji, GIFs and stickers and returns to the letters, three times, so the
	/// keyboard's "Memory by surface" log (Keyboard health) shows what each surface leaves behind.
	/// Opt-in, as it scrolls live GIFs: TEST_RUNNER_KB_MEMORY_TOUR=1.
	@MainActor
	func testMemoryAcrossSurfaces() throws {
		try XCTSkipUnless(ProcessInfo.processInfo.environment["KB_MEMORY_TOUR"] == "1",
			"set TEST_RUNNER_KB_MEMORY_TOUR=1 to tour the keyboard's surfaces")
		let host = launchRuntimeHost()   // types English: tour with the keyboard set to English
		let keyboard = host.descendants(matching: .any)["glyph.keyboard"]
		guard keyboard.waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
		func type(_ text: String) {
			for character in text {
				if character == " " { key("Space", in: host).tap() } else { tapLetter(String(character), in: host) }
			}
		}
		func control(_ name: String) -> XCUIElement { keyboard.descendants(matching: .any)[name].firstMatch }
		func tap(_ element: XCUIElement) {
			guard element.waitForExistence(timeout: 5) else {
				return XCTFail("\(element) missing from:\n\(keyboard.debugDescription)")
			}
			element.tap()
		}
		func scroll(_ times: Int) {
			let grid = keyboard.collectionViews.firstMatch
			guard grid.waitForExistence(timeout: 5) else { return }
			for _ in 0..<times { grid.swipeUp(); settle(1.5) }
		}
		for _ in 0..<3 {
			type("hello there how are you "); settle(2)
			tap(key("Emoji", in: host)); settle(2)
			for index in 1...7 { tap(control("emoji.category.\(index)")); settle(0.6) }
			tap(control("GIFs")); settle(4)
			scroll(4)
			tap(control("Stickers")); settle(4)
			scroll(4)
			tap(control("ABC")); settle(3)
		}
	}

	@MainActor
	func testBackspaceUndoOfACorrectionSticks() throws {
		try selectLanguage(identifier: "language.english", title: "English")
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 10) else {
			throw XCTSkip("Glyph is not the active software keyboard")
		}
		let field = host.textFields["runtime.text"]
		let primary = host.descendants(matching: .any)["suggestion.primary"]
		func spelled(_ text: String) -> String {
			text.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "<U+%04X>", $0.value) }.joined()
		}
		func folded(_ text: String) -> String { text.replacingOccurrences(of: "\u{2019}", with: "'").lowercased() }
		func lastWord(_ text: String) -> String { String(text.split(separator: " ").last ?? "") }
		func type(_ word: String) {
			for ch in word { tapLetter(String(ch), in: host) }
			RunLoop.current.run(until: Date().addingTimeInterval(0.4))
		}
		var failures: [String] = [], undone = 0
		for (typed, corrected) in [("shed", "she'd"), ("shell", "she'll"), ("well", "we'll"), ("hell", "he'll")] {
			type("I"); host.keys["Space"].tap()
			type("think"); host.keys["Space"].tap()
			type(typed)
			let before = fieldText(field)
			host.keys["Space"].tap()
			let afterSpace = waitForText(field, toDifferFrom: before)
			host.keys["Delete"].tap()
			let afterUndo = waitForText(field, toDifferFrom: afterSpace)
			RunLoop.current.run(until: Date().addingTimeInterval(0.4))
			let shown = primary.exists ? primary.label : ""
			host.keys["Space"].tap()
			let afterRetry = waitForText(field, toDifferFrom: afterUndo)
			NSLog("UNDO %@ space=[%@] backspace=[%@] strip=[%@] space=[%@]", typed,
				spelled(afterSpace), spelled(afterUndo), shown, spelled(afterRetry))
			// Whether the model corrects is accuracy; once it has, the undo must stick.
			guard folded(lastWord(afterSpace)) != typed else {
				NSLog("UNDO-SKIP %@ was not corrected (want %@)", typed, corrected)
				continue
			}
			undone += 1
			if folded(lastWord(afterUndo)) != typed {
				failures.append("\(typed): Backspace did not restore it: [\(afterUndo)]")
			} else if folded(shown) != typed {
				failures.append("\(typed): strip middle after the undo was [\(shown)]")
			} else if folded(lastWord(afterRetry)) != typed {
				failures.append("\(typed): Space redid the correction after the undo: [\(afterRetry)]")
			}
		}
		XCTAssertGreaterThan(undone, 0, "No case was corrected, so no undo was tested")
		XCTAssertEqual(failures, [])
	}

	private enum ComparedKeyboard: String, CaseIterable { case glyph, apple, gboard }

	/// The name each keyboard has in the globe key's long-press menu (testProbeEnabledKeyboards).
	private func menuName(_ keyboard: ComparedKeyboard) -> String {
		switch keyboard { case .glyph: return "Glyph"; case .apple: return "English"; case .gboard: return "Gboard" }
	}

	/// Selects a keyboard by name from the globe key's long-press menu.
	@MainActor
	private func activate(_ keyboard: ComparedKeyboard, in app: XCUIApplication) -> Bool {
		app.buttons["Next keyboard"].firstMatch.press(forDuration: 1.2)
		// The menu's rows report element type 75; match a row by its label.
		let row = XCUIElement.ElementType(rawValue: 75) ?? .any
		let item = app.descendants(matching: row).matching(NSPredicate(format: "label BEGINSWITH %@", menuName(keyboard))).firstMatch
		guard item.waitForExistence(timeout: 2) else { return false }
		item.tap()
		RunLoop.current.run(until: Date().addingTimeInterval(1.5))
		let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		shot.name = "selected \(keyboard.rawValue)"; shot.lifetime = .keepAlways; add(shot)
		return true
	}

	/// Regression: switching to Glyph with the globe key in a focused field left its keys
	/// disabled and the strip empty until the field was tapped again.
	@MainActor
	func testGlyphTypesRightAfterGlobeSwitch() throws {
		let host = launchRuntimeHost()
		let field = host.textFields["runtime.text"]
		XCTAssertTrue(activate(.apple, in: host))
		XCTAssertTrue(activate(.glyph, in: host))
		XCTAssertTrue(host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 5))
		for ch in "the" { tapLetter(String(ch), in: host) }
		let text = waitForText(field, toDifferFrom: "")
		RunLoop.current.run(until: Date().addingTimeInterval(0.5))
		let primary = host.descendants(matching: .any)["suggestion.primary"]
		NSLog("GLOBE-SWITCH text=[%@] strip=[%@]", text, primary.exists ? primary.label : "")
		XCTAssertEqual(text.lowercased(), "the", "Glyph did not type until the field was tapped")
		XCTAssertFalse(primary.exists ? primary.label.isEmpty : true, "The strip stayed empty after the switch")
	}

	/// Gboard exposes no keys, so it is tapped at key centres measured on the iPhone 17's
	/// screenshot (fractions of the window; QWERTY, default theme, portrait).
	private static let gboardKeys: [Character: CGVector] = {
		var keys: [Character: CGVector] = [:]
		let rows: [(String, [CGFloat], CGFloat)] = [
			("qwertyuiop", [52, 143, 233, 323, 414, 505, 596, 686, 777, 867], 1398),
			("asdfghjkl", [97, 187, 278, 368, 459, 550, 641, 731, 822], 1522),
			("zxcvbnm", [187, 278, 368, 459, 550, 641, 731], 1646)]
		for (letters, xs, y) in rows {
			for (letter, x) in zip(letters, xs) { keys[letter] = CGVector(dx: x / 920, dy: y / 2000) }
		}
		keys[" "] = CGVector(dx: 459.0 / 920, dy: 1770.0 / 2000)
		return keys
	}()

	/// Where each key is, measured once per keyboard: Glyph's and Apple's from their keys' frames,
	/// Gboard's (which exposes none) from its screenshot. Tapping positions skips the per-tap
	/// accessibility search that made the first run take 13 s a word.
	@MainActor
	private func keyPoints(for keyboard: ComparedKeyboard, in app: XCUIApplication) -> [Character: CGPoint] {
		let window = app.windows.firstMatch.frame
		if keyboard == .gboard {
			return Self.gboardKeys.mapValues { CGPoint(x: window.minX + $0.dx * window.width, y: window.minY + $0.dy * window.height) }
		}
		var points: [Character: CGPoint] = [:]
		for key in app.keys.allElementsBoundByIndex where key.exists {
			let label = key.label.lowercased(), centre = CGPoint(x: key.frame.midX, y: key.frame.midY)
			if label.count == 1, let letter = label.first, letter.isLetter { points[letter] = centre }
			else if label == " " || label == "space" { points[" "] = centre }
		}
		return points
	}

	/// Types keyboardComparisonCases into an empty field through Glyph, Apple's keyboard and
	/// Gboard (each enabled in Settings) and logs COMPARE lines; reports, never fails on accuracy.
	@MainActor
	func testCompareKeyboards() throws {
		let host = XCUIApplication()
		host.launchArguments = ["-keyboard-runtime-host"]
		// TEST_RUNNER_KB_COMPARE_PER_BUCKET=n types the first n cases of every kind.
		let perBucket = Int(ProcessInfo.processInfo.environment["KB_COMPARE_PER_BUCKET"] ?? "") ?? .max
		var taken: [String: Int] = [:]
		let cases = keyboardComparisonCases.filter { c in
			taken[c.kind, default: 0] += 1
			return taken[c.kind]! <= perBucket
		}
		let contexts = cases.map(\.context)
		host.launchEnvironment["KB_RUNTIME_CONTEXTS"] = String(decoding: try JSONEncoder().encode(contexts), as: UTF8.self)
		host.launch()
		let field = host.textFields["runtime.text"]
		XCTAssertTrue(field.waitForExistence(timeout: 5))
		field.tap()
		let origin = host.coordinate(withNormalizedOffset: .zero)
		func tap(_ point: CGPoint) { origin.withOffset(CGVector(dx: point.x, dy: point.y)).tap() }
		func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
		// Places the next case's context (or empties the field): every keyboard reads it from the document.
		let nextFrame = host.buttons["runtime.next"].frame
		let next = CGPoint(x: nextFrame.midX, y: nextFrame.midY)
		pause(2)
		var summary: [String] = []
		for keyboard in ComparedKeyboard.allCases {
			guard activate(keyboard, in: host) else {
				NSLog("COMPARE %@ not in the globe menu", keyboard.rawValue)
				continue
			}
			let points = keyPoints(for: keyboard, in: host)
			guard points.count == 27 else {
				NSLog("COMPARE %@ found %ld of 27 keys", keyboard.rawValue, points.count)
				continue
			}
			var right: [String: (Int, Int)] = [:]
			for (n, c) in cases.enumerated() {
				let started = Date()
				tap(next)
				pause(0.2)
				let before = fieldText(field)
				for letter in c.typed { tap(points[letter]!) }
				pause(0.3)   // a typist's pause before Space; lets each keyboard's strip settle
				tap(points[" "]!)
				let text = waitForText(field, toDifferFrom: before, timeout: 1.5)
				// Everything after the context: a split ("julian to") is one wrong commit, not "to".
				let typed = text.hasPrefix(before) ? String(text.dropFirst(before.count)) : String(text.split(separator: " ").last ?? "")
				let committed = typed.trimmingCharacters(in: .whitespaces)
					.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
					.trimmingCharacters(in: .punctuationCharacters)
				let ok = committed == c.intended
				let tally = right[c.kind] ?? (0, 0)
				right[c.kind] = (tally.0 + (ok ? 1 : 0), tally.1 + 1)
				NSLog("COMPARE %@ %@ [%@] %@ -> %@ [want %@] %@ %.1fs", keyboard.rawValue, c.kind, c.context, c.typed,
					committed, c.intended, ok ? "OK" : "MISS", Date().timeIntervalSince(started))
				if n < 3 {
					let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
					shot.name = "\(keyboard.rawValue) \(c.typed)"; shot.lifetime = .keepAlways; add(shot)
				}
			}
			let line = keyboard.rawValue + " " + right.keys.sorted().map { "\($0)=\(right[$0]!.0)/\(right[$0]!.1)" }.joined(separator: " ")
			NSLog("COMPARE-SUMMARY %@", line)
			summary.append(line)
		}
		let attachment = XCTAttachment(string: summary.joined(separator: "\n"))
		attachment.name = "keyboard comparison"; attachment.lifetime = .keepAlways; add(attachment)
	}

	/// Logs the globe key's long-press menu (KBMENU lines): the names it offers for each enabled
	/// keyboard, which testCompareKeyboards selects by.
	@MainActor
	func testProbeEnabledKeyboards() throws {
		let host = launchRuntimeHost()
		RunLoop.current.run(until: Date().addingTimeInterval(2))
		let before = Set(host.descendants(matching: .any).allElementsBoundByIndex.filter(\.exists).map(\.label))
		host.buttons["Next keyboard"].firstMatch.press(forDuration: 1.2)
		RunLoop.current.run(until: Date().addingTimeInterval(1))
		let all = host.descendants(matching: .any).allElementsBoundByIndex.filter(\.exists)
		for element in all where !before.contains(element.label) && !element.label.isEmpty {
			NSLog("KBMENU type=%lu label=[%@] id=[%@] frame=%@", element.elementType.rawValue, element.label,
				element.identifier, NSCoder.string(for: element.frame))
		}
		let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
		shot.name = "globe menu"; shot.lifetime = .keepAlways; add(shot)
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
	/// The tools row exposes Clipboard with a direct, labelled action. The panel
	/// it opens is an extension overlay whose accessibility subtree XCUITest does not
	/// reliably snapshot, so its rendering is covered by the `renderClipboardPanel` unit
	/// test instead; here we only assert the entry point and that the tap does not crash
	/// the keyboard (the strip is still queryable afterward).
	@MainActor
	func testClipboardToolsArePresentAndTappable() throws {
		try selectLanguage(identifier: "language.english", title: "English")
		let host = launchRuntimeHost()
		guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
			throw XCTSkip("Glyph is not the active software keyboard on this simulator")
		}
        let tools = host.descendants(matching: .any)["suggestion.tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        tools.tap()
		let clip = host.descendants(matching: .any)["tools.clipboard"]
		XCTAssertTrue(clip.waitForExistence(timeout: 3), "Clipboard action missing from tools row")
		XCTAssertTrue(clip.isHittable, "Clipboard icon is not hittable")
		clip.tap()
		// The keyboard survived opening the panel: the deck is still there to type on.
		XCTAssertTrue(host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 3),
			"Keyboard disappeared after opening the clipboard panel")
	}

    @MainActor
    func testKeyboardHeightRemainsBoundedAcrossHostEditsAndRotation() throws {
        try selectLanguage(identifier: "language.english", title: "English")
        let host = launchRuntimeHost()
        let deck = host.descendants(matching: .any)["glyph.keyboard"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5), "Enable Glyph as the active software keyboard before running this device test")
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            for _ in 0..<3 {
                host.textFields["runtime.text"].tap()
                let settled = NSPredicate { _, _ in
                    let window = host.windows.firstMatch.frame
                    return deck.exists && deck.frame.height > 100 && deck.frame.height < window.height * 0.70
                }
                expectation(for: settled, evaluatedWith: host)
                waitForExpectations(timeout: 5)
                tapLetter("a", in: host)
                host.buttons["runtime.clear"].tap()
                XCTAssertTrue(host.buttons["suggestion.tools"].isHittable)
            }
            let screenshot = XCTAttachment(screenshot: host.screenshot())
            screenshot.name = "Keyboard height after rotation \(orientation.rawValue)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testUniversalSuggestionsRemainVisibleInURLFieldWithAutocorrectionDisabled() throws {
        let host = XCUIApplication()
        host.launchArguments = ["-keyboard-runtime-host", "-keyboard-runtime-url"]
        host.launch()
        let field = host.textFields["runtime.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
            throw XCTSkip("Glyph is not the active software keyboard on this device")
        }
        let tools = host.buttons["suggestion.tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        XCTAssertTrue(tools.isHittable)
        let primary = host.buttons["suggestion.primary"]
        expectation(for: NSPredicate { _, _ in !primary.label.isEmpty }, evaluatedWith: host)
        waitForExpectations(timeout: 3)
        let stripHeight = tools.frame.height
        for letter in ["Q", "z", "x", "q"] { tapLetter(letter, in: host) }
        host.keys["Space"].tap()
        XCTAssertEqual((field.value as? String)?.lowercased(), "qzxq ",
            "Showing predictions must not enable unwanted URL autocorrection")
        XCTAssertTrue(tools.isHittable)
        XCTAssertEqual(tools.frame.height, stripHeight)
        tools.tap()
        XCTAssertTrue(host.buttons["tools.clipboard"].waitForExistence(timeout: 2))
        add(XCTAttachment(screenshot: host.screenshot()))
    }

    @MainActor
    func testHostSendClearsSuggestionsWithoutSpaceAndKeepsStarterWords() throws {
        try selectLanguage(identifier: "language.english", title: "English")
        let host = launchRuntimeHost()
        guard host.descendants(matching: .any)["glyph.keyboard"].waitForExistence(timeout: 4) else {
            throw XCTSkip("Glyph is not the active software keyboard on this device")
        }
        for letter in ["M", "i", "c", "r", "o", "s", "o", "f", "t"] { tapLetter(letter, in: host) }
        let primary = host.buttons["suggestion.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 3))
        let oldWord = primary.label
        XCTAssertFalse(oldWord.isEmpty)
        host.buttons["runtime.clear"].tap() // programmatic host edit; keyboard inserts no boundary
        let refreshed = NSPredicate { _, _ in
            let field = host.textFields["runtime.text"].value as? String ?? ""
            return (field.isEmpty || field == "Type") && !primary.label.isEmpty && primary.label != oldWord
        }
        expectation(for: refreshed, evaluatedWith: host)
        waitForExpectations(timeout: 3)
        // Copying must not replace any of the suggestion controls with a Paste banner.
        host.buttons["runtime.copy"].tap()
        XCTAssertTrue(primary.exists)
        XCTAssertFalse(host.buttons["suggestion.paste"].exists)
        add(XCTAttachment(screenshot: host.screenshot()))
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
