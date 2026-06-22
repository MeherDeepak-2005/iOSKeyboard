import UIKit

// The keystroke path is now: insertText (+ a fast one-word autocorrect on word
// boundaries). NOTHING blocks. Suggestions are DEBOUNCED onto a later run-loop
// tick, so fast typing never schedules a slow completion lookup per key.

final class KeyboardViewController: UIInputViewController {

	private var keyboard: KeyboardView!
	private let engine = KeyboardEngine()

	private enum Mode { case predict, complete(String), revert(String) }
	private var mode: Mode = .predict
	private var generation = 0
	private var suggestWork: DispatchWorkItem?
	private var pendingRevert: String?

	private let boundary = CharacterSet(charactersIn: " .,!?;:")

	override func viewDidLoad() {
		super.viewDidLoad()
		

		let theme = traitCollection.userInterfaceStyle == .dark ? KeyboardTheme.doistDark : KeyboardTheme.doistLight
		
		let kb = KeyboardView(theme: theme, showsGlobe: needsInputModeSwitchKey)
		kb.onInsert         = { [weak self] in self?.handleInsert($0) }
		kb.onDelete         = { [weak self] in self?.handleDelete() }
		kb.onReturn         = { [weak self] in self?.handleReturn() }
		kb.onNextKeyboard   = { [weak self] in self?.advanceToNextInputMode() }
		kb.onPickSuggestion = { [weak self] in self?.handlePick($0) }

		kb.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(kb)
		NSLayoutConstraint.activate([
			kb.leadingAnchor.constraint(equalTo: view.leadingAnchor),
			kb.trailingAnchor.constraint(equalTo: view.trailingAnchor),
			kb.topAnchor.constraint(equalTo: view.topAnchor),
			kb.bottomAnchor.constraint(equalTo: view.bottomAnchor)
		])
		let h = view.heightAnchor.constraint(equalToConstant: kb.keyboardHeight)
		h.priority = .required - 1
		h.isActive = true
		keyboard = kb

		scheduleSuggestions()
	}

	// MARK: Key handling — the hot path

	private func handleInsert(_ ch: String) {
		if ch.count == 1, let u = ch.unicodeScalars.first, boundary.contains(u) {
			pendingRevert = applyAutocorrectIfNeeded()        // fast, main thread, one word
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			let w = trailingWord(ctx)
			if !w.isEmpty { engine.learn(previous: previousWord(ctx), word: w) }
		} else {
			pendingRevert = nil
		}
		textDocumentProxy.insertText(ch)                       // the ONLY guaranteed-immediate work
		scheduleSuggestions()
	}

	private func handleReturn() {
		pendingRevert = applyAutocorrectIfNeeded()
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		let w = trailingWord(ctx)
		if !w.isEmpty { engine.learn(previous: previousWord(ctx), word: w) }
		textDocumentProxy.insertText("\n")
		scheduleSuggestions()
	}

	private func handleDelete() {
		pendingRevert = nil
		textDocumentProxy.deleteBackward()
		scheduleSuggestions()
	}

	private func handlePick(_ s: String) {
		switch mode {
		case .complete(let partial):
			let prev = previousWord(textDocumentProxy.documentContextBeforeInput ?? "")
			for _ in 0..<partial.count { textDocumentProxy.deleteBackward() }
			textDocumentProxy.insertText(s + " ")
			engine.learn(previous: prev, word: s)
		case .predict:
			let prev = lastCompleteWord(textDocumentProxy.documentContextBeforeInput ?? "")
			textDocumentProxy.insertText(s + " ")
			engine.learn(previous: prev, word: s)
		case .revert(let original):
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			if s == original, let corrected = lastCompleteWord(ctx) {
				textDocumentProxy.deleteBackward()
				for _ in 0..<corrected.count { textDocumentProxy.deleteBackward() }
				textDocumentProxy.insertText(original + " ")
				engine.dontCorrect(original)
			} else {
				textDocumentProxy.insertText(s + " ")
			}
		}
		pendingRevert = nil
		scheduleSuggestions()
	}

	// MARK: Autocorrect (fast, non-blocking)

	@discardableResult
	private func applyAutocorrectIfNeeded() -> String? {
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		let word = trailingWord(ctx)
		guard !word.isEmpty,
			  let correction = engine.autocorrection(for: word, previous: previousWord(ctx)),
			  correction != word else { return nil }
		for _ in 0..<word.count { textDocumentProxy.deleteBackward() }
		textDocumentProxy.insertText(correction)
		return word
	}

	// MARK: Suggestions — debounced, background-computed

	private func scheduleSuggestions() {
		suggestWork?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.refreshSuggestions() }
		suggestWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
	}

	private func refreshSuggestions() {
		generation += 1
		let gen = generation
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		let current = trailingWord(ctx)
		let revert = pendingRevert

		if current.isEmpty {
			let prev = lastCompleteWord(ctx)
			engine.suggestions(currentWord: "", previous: prev) { [weak self] preds in
				guard let self, gen == self.generation else { return }
				if let revert {
					self.mode = .revert(revert)
					self.keyboard.setSuggestions([revert] + preds.prefix(2))
				} else {
					self.mode = .predict
					self.keyboard.setSuggestions(preds)
				}
			}
		} else {
			let prev = previousWord(ctx)
			engine.suggestions(currentWord: current, previous: prev) { [weak self] comps in
				guard let self, gen == self.generation else { return }
				self.mode = .complete(current)
				self.keyboard.setSuggestions(comps)
			}
		}
	}

	// MARK: Word parsing on the text before the cursor

	private func isWordChar(_ c: Character) -> Bool { c.isLetter || c == "'" }

	private func trailingWord(_ s: String) -> String {
		var w = ""
		for c in s.reversed() { if isWordChar(c) { w.insert(c, at: w.startIndex) } else { break } }
		return w
	}

	private func lastCompleteWord(_ s: String) -> String? {
		var chars = Array(s)
		while let last = chars.last, !isWordChar(last) { chars.removeLast() }
		var w = ""
		while let last = chars.last, isWordChar(last) { w.insert(last, at: w.startIndex); chars.removeLast() }
		return w.isEmpty ? nil : w
	}

	private func previousWord(_ s: String) -> String? {
		var chars = Array(s)
		while let last = chars.last, isWordChar(last) { chars.removeLast() }
		return lastCompleteWord(String(chars))
	}
}
