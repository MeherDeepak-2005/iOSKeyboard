import UIKit

/// Host-facing surface: appearance, the suggestion strip, shift and the action key.
extension KeyboardView {
	@objc func reduceTransparencyDidChange() {
		updateBackdrop()
	}

	func updateBackdrop() {
		let useFallback = theme.usesSystemTransparency
			&& (UIAccessibility.isReduceTransparencyEnabled || UIAccessibility.isDarkerSystemColorsEnabled)
		let top = useFallback ? theme.fallbackBackgroundTop : theme.backgroundTop
		let bottom = useFallback ? theme.fallbackBackgroundBottom : theme.backgroundBottom
		CATransaction.begin(); CATransaction.setDisableActions(true)
		deckLayer.colors = [top.cgColor, bottom.cgColor]
		CATransaction.commit()
	}

	func setSuggestions(_ s: [String], typedPrefix: String? = nil, highlightPrimary: Bool = false) {
		suggestionBar.setSuggestions(s, typedPrefix: typedPrefix, highlightPrimary: highlightPrimary)
	}

    func dismissTools() { suggestionBar.dismissTools() }

	func setGlidePreview(_ word: String?, alternatives: [String] = [],
		confident: Bool = true) {
		suggestionBar.setGlidePreview(word, alternatives: alternatives, confident: confident)
	}

	func setGlideResult(_ word: String, alternatives: [String]) {
		suggestionBar.setGlideResult(word, alternatives: alternatives)
	}

	/// Auto-capitalization driven by the controller (field start / after ". ").
	/// Never touches caps lock. Relabels in place — no view rebuild on the type path.
	/// Ignored during emoji search: the query is case-insensitive and the host
	/// document context that drives auto-shift is irrelevant to it.
	func setAutoShift(_ on: Bool) {
		guard languageMode != .telugu, shift != .locked, !isEmojiSearching else { return }
		applyShiftState(on ? .on : .off)
	}

	/// Change shift state WITHOUT rebuilding the keys. The hot path used to call reload()
	/// here — recreating all ~33 key views on every auto-shift (each sentence start, each
	/// shifted letter). Now we just relabel the letter keys and swap the shift glyph.
	func applyShiftState(_ new: ShiftState) {
		guard shift != new else { return }
		shift = new
		guard page == .letters else { return }   // shift only affects the letters layout
		for (base, key) in letterKeys {
			key.setTitle(shifted(base))
			key.setAlternatives(accentAlternatives(for: base)) { [weak self] value in
				guard let self else { return }
				self.routeInsert(value, nil)
				if self.shift == .on { self.applyShiftState(.off) }
			}
		}
		shiftKey?.setSymbol(shiftSymbol)
	}

	/// Set the contextual label on the action (return) key. Pass nil for a plain
	/// newline glyph. Only rebuilds when it actually changes.
	func setActionTitle(_ title: String?) {
		guard title != actionTitle else { return }
		actionTitle = title
		applyActionKeyState()
	}

	func setActionEnabled(_ enabled: Bool) {
		actionEnabled = enabled
		applyActionKeyState()
	}


	func applyActionKeyState() {
		guard let actionKey else { return }
		let title = displayedActionTitle
		if let title, !title.isEmpty {
			actionKey.setTitle(title)
			actionKey.accessibilityLabel = title
		} else {
			actionKey.setSymbol("return")
			actionKey.accessibilityLabel = "Return"
		}
        actionKey.setActionAppearance(active: title?.isEmpty == false, theme: theme)
		actionKey.setInputEnabled(displayedActionEnabled)
	}

}
