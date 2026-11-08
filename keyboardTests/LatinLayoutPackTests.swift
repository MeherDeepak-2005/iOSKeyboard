import Foundation
import Testing
import UIKit
@testable import keyboard

/// The English deck is built from keyboard/english_layout.kbpack (source:
/// tools/language_packs/sources/en-US/qwerty.json). These pin what each page shows, and
/// that the keys on screen, `KB` and the native decoders share one letter grid.
@MainActor
struct LatinLayoutPackTests {
	private let pack = LatinLayoutPack.english

	private func keyboard(_ kind: KeyboardInputKind = .standard, page: KeyboardSurfacePage = .letters,
		globe: Bool = true) -> KeyboardView {
		let view = KeyboardView(theme: .preview(dark: false, accent: KBPalette.system, customTheme: nil),
			showsGlobe: globe)
		view.traitOverrides.userInterfaceIdiom = .phone
		view.frame = CGRect(x: 0, y: 0, width: 393, height: view.keyboardHeight)
		_ = view.setInputKind(kind)
		if view.page != page { view.page = page; view.reload() }
		view.layoutIfNeeded()
		return view
	}

	/// Each row's spoken labels; letters lowercased (the deck starts shifted).
	private func rows(_ view: KeyboardView) -> [[String]] {
		view.rows.map { row in
			row.map { key in key.letterBase ?? key.accessibilityLabel ?? "?" }
		}
	}

	@Test func shippedPackLoads() {
		#expect(pack.identifier == "en-US.qwerty")
		#expect(pack.version >= 1)
		#expect(pack != LatinLayoutPack.emergencyQWERTY)
	}

	@Test func decodersShareTheDecksGrid() {
		#expect(KB.rows == pack.gridRows)
		#expect(KB.rowOffset == pack.gridRowOffsets)
		#expect(KeyboardEngine.nativeKeyGridInstalled)
		#expect(KBKeyGrid.letters() == pack.gridRows.joined())
		for letter in pack.gridRows.joined().utf8 {
			var x = 0.0, y = 0.0
			#expect(KBKeyGrid.position(letter, x: &x, y: &y))
			let swift = try? #require(KB.pos[letter])
			#expect(swift?.0 == x && swift?.1 == y)
		}
	}

	@Test func lettersPageMatchesStock() {
		let view = keyboard(globe: false)
		#expect(rows(view) == [
			["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
			["a", "s", "d", "f", "g", "h", "j", "k", "l"],
			["Shift", "z", "x", "c", "v", "b", "n", "m", "Delete"],
			["Numbers", "Emoji", "Space", "Return"],
		])
		let e = try? #require(view.rows[0].first { $0.letterBase == "e" })
		#expect(e?.alternatives == ["É", "È", "Ê", "Ë"])          // shifted at a sentence start
	}

	@Test func fieldKeysAndGlobeFollowTheField() {
		#expect(rows(keyboard(.email)).last == ["Numbers", "Next Keyboard", "Emoji", "@", ".", "Space", "Return"])
		#expect(rows(keyboard(.url, globe: false)).last == ["Numbers", "Emoji", "/", ".", "Space", "Return"])
		#expect(rows(keyboard(.twitter, globe: false)).last == ["Numbers", "Emoji", "@", "#", "Space", "Return"])
		#expect(rows(keyboard(.webSearch, globe: false)).last == ["Numbers", "Emoji", ".", "Space", "Return"])
	}

	@Test func numberAndSymbolPagesMatchStock() {
		let numbers = keyboard(page: .numbers, globe: false)
		#expect(rows(numbers) == [
			["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
			["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
			["Symbols", ".", ",", "?", "!", "'", "Delete"],
			["Letters", "Emoji", "Space", "Return"],
		])
		let slash = numbers.rows[1].first { $0.accessibilityLabel == "/" }
		#expect(slash?.alternatives == ["\\"])
		#expect(rows(keyboard(page: .symbols, globe: false)) == [
			["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
			["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
			["Numbers", ".", ",", "?", "!", "'", "Delete"],
			["Letters", "Emoji", "Space", "Return"],
		])
	}

	@Test func numberPadsMatchTheField() {
		let separator = Locale.current.decimalSeparator ?? "."
		#expect(rows(keyboard(.decimalPad, page: .numbers)) == [
			["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"],
			["Letters", separator, "0", "Delete", "Return"],
		])
		let phone = keyboard(.phonePad, page: .numbers)
		#expect(rows(phone).last == ["Letters", "+", "0", "Delete", "Return"])
		#expect(rows(keyboard(.numberPad, page: .numbers)).last == ["Letters", "0", "Delete", "Return"])
		#expect(phone.rows.flatMap { $0 }.allSatisfy { $0.alternatives.isEmpty })   // no long-press on the pad
	}

	@Test func currencyFollowsTheLayoutLocale() {
		#expect(LatinLayoutPack.currencySymbol(for: "en-US") == "$")
		#expect(LatinLayoutPack.currencySymbol(for: "te-IN") == "₹")
	}

	@Test func rejectsADamagedPack() throws {
		let url = try #require(KBPackResources.url(resource: "english_layout", extension: "kbpack"))
		var document = try #require(try PropertyListSerialization.propertyList(
			from: Data(contentsOf: url), format: nil) as? [String: Any])
		var grid = try #require(document["letterGrid"] as? [String: Any])
		grid["rows"] = ["qwertyuiop", "asdfghjkl", "zxcvbn"]                // grid ≠ letters page
		document["letterGrid"] = grid
		let damaged = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
		#expect(throws: LatinLayoutError.invalidGrid) { try LatinLayoutPack.decode(damaged) }
		#expect(throws: (any Error).self) { try LatinLayoutPack.decode(Data("not a pack".utf8)) }
	}
}
