import UIKit

extension KeyboardView {
	// MARK: Build keys

	func reload() {
		let oldRowCount = rows.count
		endCursorHold()
		alternativeTimers.values.forEach { $0.invalidate() }
		alternativeTimers.removeAll(keepingCapacity: false)
		alternativePopups.values.forEach { $0.removeFromSuperview() }
		alternativePopups.removeAll(keepingCapacity: false)
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = specs().map { row in
			row.map { spec -> KeyButton in
				let b = KeyButton(spec: spec, theme: theme)
				addSubview(b)
				return b
			}
		}
		// Cache the keys a shift change touches, so applyShiftState can relabel in place.
		let all = rows.flatMap { $0 }
		letterKeys = all.compactMap { k in k.letterBase.map { (base: $0, key: k) } }
		for key in all where !key.alternatives.isEmpty {
			let values = key.alternatives
			key.setAlternatives(values) { [weak self, weak key] value in
				guard let self else { return }
				if self.languageMode == .telugu {
					self.routeOutput(self.teluguOutput(for: value), nil)
				} else {
					self.routeInsert(value, nil)
				}
				if key?.letterBase != nil, self.shift == .on { self.applyShiftState(.off) }
			}
		}
		shiftKey = all.first { $0.isShift }
		actionKey = all.first { $0.role == .accent }
		applyActionKeyState()
		var orderedAccessibilityElements: [Any] = [suggestionBar]
		// A search types on this deck: its header and results come first.
		let searchViews: [UIView?] = [emojiSearchHeader, mediaSearchHeader, mediaSearchStrip]
		orderedAccessibilityElements.append(contentsOf: searchViews.compactMap { $0 })
		for row in rows { orderedAccessibilityElements.append(contentsOf: row) }
		accessibilityElements = orderedAccessibilityElements
		bringSubviewToFront(suggestionBar)
		touchPopups.values.forEach { bringSubviewToFront($0) }   // page-reload mid-press
		layer.addSublayer(trailLayer)          // keep the glide feedback above freshly-added keys
		layer.addSublayer(trailHeadLayer)
		setNeedsLayout()
		if oldRowCount > 0, oldRowCount != rows.count {
			DispatchQueue.main.async { [weak self] in self?.onHeightChange?(false) }
		}
	}

	/// Test seam for keeping visual centers and the decoder's normalized QWERTY grid
	/// in lockstep. A mismatch here directly creates systematic tap and Glide errors.
	func letterCenter(for letter: Character) -> CGPoint? {
		guard let frame = letterKeys.first(where: { $0.base.first == letter })?.key.frame else { return nil }
		return CGPoint(x: frame.midX, y: frame.midY)
	}

	func keyAccessibilityLabels() -> [String] {
		rows.flatMap { $0 }.compactMap(\.accessibilityLabel)
	}

    func keyLabelForTesting(at point: CGPoint) -> String? { key(at: point)?.accessibilityLabel }

	func keyFramesForTesting() -> [CGRect] {
		rows.flatMap { $0 }.map(\.frame)
	}

	func shifted(_ c: String) -> String { shift == .off ? c : c.uppercased() }

	/// The Latin layout pack the deck is built from (pages, long-press variants, field keys).
	var latinLayout: LatinLayoutPack { .english }

	/// Long-press variants for a key, from the layout pack; a letter's follow shift.
	func accentAlternatives(for base: String) -> [String] {
		let values = latinLayout.alternatives[base.lowercased()] ?? []
		return shift == .off ? values : values.map { $0.uppercased() }
	}

	private func characterSpec(_ text: String, width: LayoutKey.Width?, accessibilityLabel: String?,
		variants: Bool = true) -> KeySpec {
		if page == .letters, text.count == 1, text.first?.isLetter == true {
			return KeySpec(label: shifted(text), accessibilityLabel: accessibilityLabel,
				width: keyWidth(width), popup: true, letterBase: text,
				alternatives: accentAlternatives(for: text)) { [weak self] in
				guard let self else { return }
				self.routeInsert(self.shifted(text), self.activeTap)
				if self.shift == .on { self.applyShiftState(.off) }   // in place — no rebuild
			}
		}
		return KeySpec(label: text, accessibilityLabel: accessibilityLabel, width: keyWidth(width),
			popup: true, alternatives: variants ? latinLayout.alternatives[text] ?? [] : []) { [weak self] in
			self?.routeInsert(text, nil)
		}
	}
	private func scriptSpec(_ descriptor: KeyboardKeyDescriptor) -> KeySpec {
		KeySpec(label: descriptor.label,
			accessibilityLabel: descriptor.accessibilityLabel,
			width: .unit,
			popup: true,
			committedText: descriptor.output.literal,
			alternatives: descriptor.alternatives,
			glyphScale: Self.teluguGlyphScale) { [weak self] in
				self?.routeOutput(descriptor.output, nil)
			}
	}

	private func teluguOutput(for value: String) -> KeyOutput {
		TeluguComposer.output(forLiteral: value)
	}

	private func keyWidth(_ width: LayoutKey.Width?, default fallback: KeyWidth = .unit) -> KeyWidth {
		switch width {
		case .unit?: return .unit
		case .flex?: return .flex
		case .modifier?: return .modifier
		case .utility?: return .utility
		case .return?: return .ret
		case nil: return fallback
		}
	}

	private var fieldExtraKeys: [String] {
		let kind: String
		switch inputKind {
		case .email: kind = "email"
		case .url: kind = "url"
		case .webSearch: kind = "webSearch"
		case .twitter: kind = "twitter"
		default: return []
		}
		return latinLayout.fieldExtras[kind] ?? []
	}

	private func specs() -> [[KeySpec]] {
		switch page {
		case .letters, .alternateLetters:
			if languageMode == .telugu { return teluguLetterSpecs() }
			return pageSpecs(latinLayout.letters)
		case .numbers:
			if inputKind.usesDedicatedNumberPad { return pageSpecs(latinLayout.numberPad) }
			if languageMode == .telugu, let digits = languageLayout.numbers.rows.first {
				// Telugu digits over the Latin punctuation rows, with the Telugu locale's currency.
				var rows = pageSpecs(latinLayout.numbers,
					currencyLocale: TeluguLanguagePack.shared.metadata?.locale)
				rows[0] = digits.map(scriptSpec)
				return rows
			}
			return pageSpecs(latinLayout.numbers)
		case .symbols:
			return pageSpecs(latinLayout.symbols)
		case .emoji, .media, .clipboard:
			return []   // these use a full-bounds overlay, not a key grid
		}
	}

	/// A layout page's rows, then its bottom row (the number pad has none).
	private func pageSpecs(_ layoutPage: LayoutPage, currencyLocale: String? = nil) -> [[KeySpec]] {
		let currency = LatinLayoutPack.currencySymbol(for: currencyLocale ?? latinLayout.locale)
		func specs(_ row: [LayoutKey]) -> [KeySpec] {
			row.flatMap { key -> [KeySpec] in
				switch key {
				case let .character(text, width, label):
					return [characterSpec(text, width: width, accessibilityLabel: label,
						variants: layoutPage.longPressVariants)]
				case let .control(control, width, target, label):
					return controlSpecs(control, width: width, target: target, label: label,
						currency: currency, variants: layoutPage.longPressVariants)
				}
			}
		}
		var rows = layoutPage.rows.map(specs)
		if let bottom = layoutPage.bottomRow { rows.append(specs(bottom)) }
		return rows
	}

	private func controlSpecs(_ control: LayoutKey.Control, width: LayoutKey.Width?,
		target: LayoutKey.PageTarget?, label: String?, currency: String,
		variants: Bool) -> [KeySpec] {
		switch control {
		case .shift: return [shiftKeySpec(width: keyWidth(width, default: .modifier))]
		case .delete: return [deleteKeySpec()]
		case .return: return [returnKeySpec()]
		case .space: return [spaceKeySpec()]
		case .emoji:
			return [KeySpec(symbol: "face.smiling", accessibilityLabel: "Emoji",
				role: .special, width: keyWidth(width, default: .utility)) { [weak self] in self?.showEmoji() }]
		case .globe:
			guard showsGlobe else { return [] }
			return [KeySpec(symbol: "keyboard", accessibilityLabel: "Next Keyboard",
				role: .special, width: keyWidth(width, default: .utility), isInputModeSwitch: true) { [weak self] in
				self?.onNextKeyboard?()
			}]
		case .page:
			guard let target, let label else { return [] }
			// Bottom-row page switches (123/ABC) are utility width; the #+= / 123 key in
			// the third symbol row matches delete across from it, as stock does.
			let surface: KeyboardSurfacePage
			let spoken: String
			switch target {
			case .letters: surface = .letters; spoken = "Letters"
			case .numbers: surface = .numbers; spoken = "Numbers"
			case .symbols: surface = .symbols; spoken = "Symbols"
			}
			return [KeySpec(label: label, accessibilityLabel: spoken, role: .special,
				width: keyWidth(width, default: .utility)) { [weak self] in
				self?.page = surface; self?.reload()
			}]
		case .fieldExtras:
			return fieldExtraKeys.map { characterSpec($0, width: .unit, accessibilityLabel: nil) }
		case .padAuxiliary:
			let value: String
			switch inputKind {
			case .decimalPad: value = Locale.current.decimalSeparator ?? "."
			case .phonePad: value = "+"
			default: return []
			}
			return [characterSpec(value, width: width ?? .flex, accessibilityLabel: nil, variants: variants)]
		case .currency:
			return [characterSpec(currency, width: width, accessibilityLabel: nil, variants: variants)]
		}
	}

	private func deleteKeySpec() -> KeySpec {
		KeySpec(symbol: "delete.left", accessibilityLabel: "Delete",
			role: .special, width: .modifier, repeats: true) { [weak self] in self?.routeDelete() }
	}

	private func returnKeySpec() -> KeySpec {
		if let t = displayedActionTitle, !t.isEmpty {
			return KeySpec(label: t, accessibilityLabel: t, role: .accent, width: .ret) { [weak self] in self?.routeReturn() }
		}
		return KeySpec(symbol: "return", accessibilityLabel: "Return",
			role: .accent, width: .ret) { [weak self] in self?.routeReturn() }
	}

	private func spaceKeySpec() -> KeySpec {
		KeySpec(label: spaceTitle, accessibilityLabel: "Space", width: .flex,
			isSpace: true) { [weak self] in
			self?.routeInsert(" ", nil)
			self?.returnToLettersFromSymbolPage()   // stock: space snaps back to ABC from 123/#+=
		}
	}

	private func shiftKeySpec(width: KeyWidth) -> KeySpec {
		KeySpec(symbol: shiftSymbol, accessibilityLabel: "Shift",
			role: .special, width: width, isShift: true) { [weak self] in
			guard let self else { return }
			let now = ProcessInfo.processInfo.systemUptime
			let isDoubleTap = now - self.lastShiftTapAt <= 0.35
			self.lastShiftTapAt = now
			let next: ShiftState
			if self.shift == .locked {
				next = .off
			} else if isDoubleTap {
				next = .locked
			} else {
				next = self.shift == .off ? .on : .off
			}
			self.applyShiftState(next)                              // in place — no rebuild
		}
	}

	/// Telugu glyph rows come from the Telugu pack; its bottom row is the Latin letters
	/// page's, without per-field keys, and the Telugu pack's extra keys before return.
	private func teluguLetterSpecs() -> [[KeySpec]] {
		let selected = page == .alternateLetters
			? (languageLayout.alternate ?? languageLayout.primary)
			: languageLayout.primary
		let characterRows = selected.rows
		guard (3...6).contains(characterRows.count) else { return [] }
		var result = characterRows.map { $0.map(scriptSpec) }
		if languageLayout.alternate != nil {
			let alternateVisible = page == .alternateLetters
			let toggle = KeySpec(symbol: alternateVisible ? "shift.fill" : "shift",
				accessibilityLabel: "Shift", role: .special, width: .modifier,
				isShift: true) { [weak self] in
					guard let self else { return }
					self.page = alternateVisible ? .letters : .alternateLetters
					self.reload()
				}
			result[result.count - 1].insert(toggle, at: 0)
		}
		result[result.count - 1].append(deleteKeySpec())
		let bottomKeys = (latinLayout.letters.bottomRow ?? []).filter { $0 != .control(.fieldExtras,
			width: nil, target: nil, label: nil) }
		var bottom = pageSpecs(LayoutPage(rows: [], bottomRow: bottomKeys,
			longPressVariants: true)).last ?? []
		let extras = languageLayout.bottomKeys.map(scriptSpec)
		if let returnIndex = bottom.lastIndex(where: { $0.role == .accent }) {
			bottom.insert(contentsOf: extras, at: returnIndex)
		}
		result.append(bottom)
		return result
	}
}
