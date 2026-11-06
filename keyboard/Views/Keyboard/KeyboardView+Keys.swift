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
		for row in rows { orderedAccessibilityElements.append(contentsOf: row) }
		accessibilityElements = orderedAccessibilityElements
		bringSubviewToFront(suggestionBar)
		touchPopups.values.forEach { bringSubviewToFront($0) }   // page-reload mid-press
		layer.addSublayer(trailLayer)          // keep the glide feedback above freshly-added keys
		layer.addSublayer(trailHeadLayer)
		setNeedsLayout()
		if oldRowCount > 0, oldRowCount != rows.count {
			DispatchQueue.main.async { [weak self] in self?.onHeightChange?() }
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
	func accentAlternatives(for base: String) -> [String] {
		let values: [String]
		switch base.lowercased() {
		case "a": values = ["á", "à", "â", "ä", "ã", "å", "æ"]
		case "c": values = ["ç", "ć", "č"]
		case "e": values = ["é", "è", "ê", "ë"]
		case "i": values = ["í", "ì", "î", "ï"]
		case "n": values = ["ñ", "ń"]
		case "o": values = ["ó", "ò", "ô", "ö", "õ", "ø", "œ"]
		case "s": values = ["ß", "ś", "š"]
		case "u": values = ["ú", "ù", "û", "ü"]
		case "y": values = ["ý", "ÿ"]
		case "z": values = ["ž", "ź"]
		default: values = []
		}
		return shift == .off ? values : values.map { $0.uppercased() }
	}

	private func punctuationAlternatives(for value: String) -> [String] {
		switch value {
		case ".": return ["…"]
		case "?": return ["¿"]
		case "!": return ["¡"]
		case "-": return ["–", "—"]
		case "'": return ["’", "‘", "\""]
		case "\"": return ["“", "”", "'"]
		case "/": return ["\\"]
		default: return []
		}
	}
	private func charSpec(_ c: String) -> KeySpec {
		if page == .letters {
			return KeySpec(label: shifted(c), width: .unit, popup: true, letterBase: c,
				alternatives: accentAlternatives(for: c)) { [weak self] in
				guard let self else { return }
				self.routeInsert(self.shifted(c), self.activeTap)
				if self.shift == .on { self.applyShiftState(.off) }   // in place — no rebuild
			}
		}
		return KeySpec(label: c, width: .unit, popup: true,
			alternatives: punctuationAlternatives(for: c)) { [weak self] in self?.routeInsert(c, nil) }
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
	private func punct(_ c: String) -> KeySpec {
		KeySpec(label: c, width: .flex, popup: true,
			alternatives: punctuationAlternatives(for: c)) { [weak self] in self?.routeInsert(c, nil) }
	}
	private func fixedPunct(_ c: String) -> KeySpec {
		KeySpec(label: c, width: .unit, popup: true,
			alternatives: punctuationAlternatives(for: c)) { [weak self] in self?.routeInsert(c, nil) }
	}

	private func specs() -> [[KeySpec]] {
		let del = KeySpec(symbol: "delete.left", accessibilityLabel: "Delete",
			role: .special, width: .modifier, repeats: true) { [weak self] in self?.routeDelete() }
		let ret: KeySpec = {
			if let t = displayedActionTitle, !t.isEmpty {
				return KeySpec(label: t, accessibilityLabel: t, role: .accent, width: .ret) { [weak self] in self?.routeReturn() }
			}
			return KeySpec(symbol: "return", accessibilityLabel: "Return",
				role: .accent, width: .ret) { [weak self] in self?.routeReturn() }
		}()
		let space = KeySpec(label: spaceTitle, accessibilityLabel: "Space", width: .flex,
			isSpace: true) { [weak self] in
			self?.routeInsert(" ", nil)
			self?.returnToLettersFromSymbolPage()   // stock: space snaps back to ABC from 123/#+=
		}
		// Bottom-row page switches (123/ABC) are utility width; the #+= / 123 key in
		// the third symbol row matches delete across from it, as stock does.
		func switchKey(_ l: String, to t: KeyboardSurfacePage,
			width: KeyWidth = .utility) -> KeySpec {
			let spoken = t == .letters ? "Letters" : (t == .numbers ? "Numbers" : "Symbols")
			return KeySpec(label: l, accessibilityLabel: spoken,
				role: .special, width: width) { [weak self] in self?.page = t; self?.reload() }
		}
		let emojiKey = KeySpec(symbol: "face.smiling", accessibilityLabel: "Emoji",
			role: .special, width: .utility) { [weak self] in self?.showEmoji() }
		func bottom(_ leading: KeySpec, extras: [KeySpec] = [],
			trailingExtras: [KeySpec] = []) -> [KeySpec] {
			var r = [leading]
			if showsGlobe {
				r.append(KeySpec(symbol: "keyboard", accessibilityLabel: "Next Keyboard",
					role: .special, width: .utility, isInputModeSwitch: true) { [weak self] in self?.onNextKeyboard?() })
			}
			r.append(emojiKey)
			r.append(contentsOf: extras)
			r.append(space)
			r.append(contentsOf: trailingExtras)
			r.append(ret)
			return r
		}
		let shiftKey = KeySpec(symbol: shiftSymbol, accessibilityLabel: "Shift",
			role: .special, width: .modifier, isShift: true) { [weak self] in
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
		switch page {
		case .letters, .alternateLetters:
			if languageMode == .telugu {
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
				result[result.count - 1].append(del)
				result.append(bottom(switchKey("123", to: .numbers),
					trailingExtras: languageLayout.bottomKeys.map(scriptSpec)))
				return result
			}
			let extras: [KeySpec]
			switch inputKind {
			case .email: extras = [fixedPunct("@"), fixedPunct(".")]
			case .url: extras = [fixedPunct("/"), fixedPunct(".")]
			case .webSearch: extras = [fixedPunct(".")]
			case .twitter: extras = [fixedPunct("@"), fixedPunct("#")]
			default: extras = []
			}
			return [
				KB.rows[0].map { charSpec(String($0)) },
				KB.rows[1].map { charSpec(String($0)) },
				[shiftKey] + KB.rows[2].map { charSpec(String($0)) } + [del],
				bottom(switchKey("123", to: .numbers), extras: extras)
			]
		case .numbers:
			if inputKind.usesDedicatedNumberPad {
				func digit(_ value: String) -> KeySpec {
					KeySpec(label: value, width: .flex, popup: true) { [weak self] in
						self?.routeInsert(value, nil)
					}
				}
				let auxiliary: KeySpec? = {
					switch inputKind {
					case .decimalPad: return digit(Locale.current.decimalSeparator ?? ".")
					case .phonePad: return digit("+")
					default: return nil
					}
				}()
				var final = [switchKey("ABC", to: .letters)]
				if let auxiliary { final.append(auxiliary) }
				final.append(digit("0")); final.append(del); final.append(ret)
				return [
					["1", "2", "3"].map(digit),
					["4", "5", "6"].map(digit),
					["7", "8", "9"].map(digit),
					final
				]
			}
			if languageMode == .telugu, let digits = languageLayout.numbers.rows.first {
				return [
					digits.map(scriptSpec),
					["-","/",":",";","(",")","₹","&","@","\""].map(charSpec),
					[switchKey("#+=", to: .symbols, width: .modifier)] + [".",",","?","!","'"].map(punct) + [del],
					bottom(switchKey("ABC", to: .letters))
				]
			}
			return [
				["1","2","3","4","5","6","7","8","9","0"].map(charSpec),
				["-","/",":",";","(",")","$","&","@","\""].map(charSpec),
				[switchKey("#+=", to: .symbols, width: .modifier)] + [".",",","?","!","'"].map(punct) + [del],
				bottom(switchKey("ABC", to: .letters))
			]
		case .symbols:
			return [
				["[","]","{","}","#","%","^","*","+","="].map(charSpec),
				["_","\\","|","~","<",">","€","£","¥","•"].map(charSpec),
				[switchKey("123", to: .numbers, width: .modifier)] + [".",",","?","!","'"].map(punct) + [del],
				bottom(switchKey("ABC", to: .letters))
			]
		case .emoji, .media, .clipboard:
			return []   // these use a full-bounds overlay, not a key grid
		}
	}
}
