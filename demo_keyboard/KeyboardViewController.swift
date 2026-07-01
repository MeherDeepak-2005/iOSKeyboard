import UIKit

// Keystroke path = insertText only. Autocorrect is a fast read on word boundaries;
// suggestions are debounced. The engine now receives up to two words of context
// (for the trigram), assembled by `contextWords`.

final class KeyboardViewController: UIInputViewController {

	private var keyboard: KeyboardView!
	private var heightConstraint: NSLayoutConstraint?
	private let engine = KeyboardEngine()

	private enum Mode { case predict, complete(String), revert(String) }
	private var mode: Mode = .predict
	private var generation = 0
	private var suggestWork: DispatchWorkItem?
	private var pendingRevert: String?

	private let boundary = CharacterSet(charactersIn: " .,!?;:")

	override func viewDidLoad() {
		super.viewDidLoad()
		FontInstaller.registerBundledFonts()
		view.backgroundColor = .clear
		buildKeyboard()
		scheduleSuggestions()

		// Follow the host app's light/dark appearance and rebuild on changes.
		registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
			self.buildKeyboard()
			self.scheduleSuggestions()
		}
	}

	private func currentTheme() -> KeyboardTheme {
		.system(dark: traitCollection.userInterfaceStyle == .dark)
	}

	private func buildKeyboard() {
		keyboard?.removeFromSuperview()

		let theme = currentTheme()
		view.backgroundColor = .clear

		let kb = KeyboardView(theme: theme, showsGlobe: needsInputModeSwitchKey)
		kb.hapticsEnabled   = KBSettings.haptics
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
		heightConstraint = h
		keyboard = kb
		updateActionKey()
	}

	// MARK: Contextual action key — mirrors the host field's Return key (go / search / send …)

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		updateActionKey()
		keyboard?.prepareHaptics()     // prime the engine so the first tap isn't delayed
	}

	override func textDidChange(_ textInput: UITextInput?) {
		super.textDidChange(textInput)
		updateActionKey()
	}

	private func updateActionKey() {
		keyboard?.setActionTitle(actionTitle(for: textDocumentProxy.returnKeyType ?? .default))
	}

	/// Map the host text field's Return key style to a label. nil → plain newline glyph.
	private func actionTitle(for type: UIReturnKeyType) -> String? {
		switch type {
		case .go:                       return "go"
		case .search, .google, .yahoo:  return "search"
		case .send:                     return "send"
		case .join:                     return "join"
		case .next:                     return "next"
		case .route:                    return "route"
		case .done:                     return "done"
		case .continue:                 return "continue"
		case .emergencyCall:            return "SOS"
		case .default:                  return nil   // plain return → newline glyph
		@unknown default:               return nil
		}
	}

	// MARK: Key handling — the hot path

	private func handleInsert(_ ch: String) {
		if ch.count == 1, let u = ch.unicodeScalars.first, boundary.contains(u) {
			pendingRevert = applyAutocorrectIfNeeded()
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			let w = trailingWord(ctx)
			if !w.isEmpty { engine.learn(context: contextWords(ctx, max: 2), word: w) }
		} else {
			pendingRevert = nil
		}
		textDocumentProxy.insertText(ch)
		scheduleSuggestions()
	}

	private func handleReturn() {
		pendingRevert = applyAutocorrectIfNeeded()
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		let w = trailingWord(ctx)
		if !w.isEmpty { engine.learn(context: contextWords(ctx, max: 2), word: w) }
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
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 2)
			for _ in 0..<partial.count { textDocumentProxy.deleteBackward() }
			textDocumentProxy.insertText(s + " ")
			engine.learn(context: ctx, word: s)
		case .predict:
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 2)
			textDocumentProxy.insertText(s + " ")
			engine.learn(context: ctx, word: s)
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
			  let correction = engine.autocorrection(for: word, context: contextWords(ctx, max: 2)),
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
		let context = contextWords(ctx, max: 2)

		if current.isEmpty {
			engine.suggestions(currentWord: "", context: context) { [weak self] preds in
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
			engine.suggestions(currentWord: current, context: context) { [weak self] comps in
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

	/// Up to `max` complete words immediately before any trailing partial word, oldest→newest.
	private func contextWords(_ s: String, max: Int) -> [String] {
		var chars = Array(s)
		while let last = chars.last, isWordChar(last) { chars.removeLast() }   // drop trailing partial
		var words: [String] = []
		while words.count < max {
			while let last = chars.last, !isWordChar(last) { chars.removeLast() }
			if chars.isEmpty { break }
			var w = ""
			while let last = chars.last, isWordChar(last) { w.insert(last, at: w.startIndex); chars.removeLast() }
			if w.isEmpty { break }
			words.insert(w, at: 0)
		}
		return words
	}
}
