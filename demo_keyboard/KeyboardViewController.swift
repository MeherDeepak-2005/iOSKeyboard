import UIKit

// Keystroke path = insertText only. Autocorrect is a fast read on word boundaries;
// suggestions are debounced. The engine receives up to 8 words of sentence-bounded
// context via `contextWords` — the n-gram prior uses the last 2, a future neural
// rescorer uses all of it.

final class KeyboardViewController: UIInputViewController {

	private var keyboard: KeyboardView!
	private var heightConstraint: NSLayoutConstraint?
	private let engine = KeyboardEngine()

	private enum Mode { case predict, complete(String), revert(String) }
	private var mode: Mode = .predict
	private var generation = 0
	private var suggestWork: DispatchWorkItem?

	/// Records the most recent replacement (autocorrect on a boundary, or a picked
	/// completion) so a single Backspace can undo it back to what the user typed —
	/// exactly like the stock keyboard.
	private struct Correction {
		let original: String       // what the user actually typed
		let corrected: String      // what we replaced it with
		var trailing: String       // boundary/space/newline inserted after it (may be "")
		let fromAutocorrect: Bool  // true = engine autocorrect (re-correction must be suppressed on undo)
	}
	private var lastCorrection: Correction?

	/// Manual-fix detection. The one-tap Backspace undo only catches an IMMEDIATE
	/// revert; users just as often backspace through a word and retype it by hand.
	/// Track the word being erased and the first word typed in its place, then feed
	/// the swap to the engine: reverting one of OUR corrections registers as a
	/// rejection (dontCorrect), and hand-fixing their own typo ("js" → "is") demotes
	/// the typo so repetition can't adopt it into the dictionary.
	private var erasedWord = ""
	private var erasedCrossedBoundary = false   // deletion ate the word's leading boundary
	private var replacementStarted = false
	/// Recent autocorrects (typed → corrected), so erasing a correction and retyping
	/// the original is recognizable even after `lastCorrection` expired.
	private var recentCorrections: [(original: String, corrected: String)] = []

	/// Per-tap landing offsets for the word currently being typed, one per letter, so
	/// the channel model can score sub-key precision. Best-effort: cleared on word
	/// boundaries, popped on delete; the engine ignores them unless the count matches
	/// the word length, so any desync is silently safe.
	private var wordTaps: [KeyTap?] = []

	/// Whether the host wants the input-mode-switch (globe) key. Read lazily from
	/// `needsInputModeSwitchKey` only once the host connection exists (viewWillAppear),
	/// never in viewDidLoad — doing so logs an inaccurate-result warning.
	private var showsGlobe = true
	private var globeConfigured = false

	private let boundary = CharacterSet(charactersIn: " .,!?;:")

	override func viewDidLoad() {
		super.viewDidLoad()
		FontInstaller.registerSelectedFont()   // extension renders one font — load only it
		view.backgroundColor = .clear
		buildKeyboard()
		scheduleSuggestions()

		// Contact names + text-replacement shortcuts: suggestable, never mangled.
		requestSupplementaryLexicon { [weak self] lexicon in
			self?.engine.importSupplementaryLexicon(lexicon.entries.map(\.documentText))
		}

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
		// The old height constraint lives on the controller's view, not the removed
		// keyboard — deactivate it or every rebuild (theme/globe change) stacks another.
		heightConstraint?.isActive = false
		heightConstraint = nil

		let theme = currentTheme()
		view.backgroundColor = .clear

		let kb = KeyboardView(theme: theme, showsGlobe: showsGlobe)
		kb.hapticsEnabled   = KBSettings.haptics
		kb.onInsert         = { [weak self] ch, tap in self?.handleInsert(ch, tap: tap) }
		kb.onDelete         = { [weak self] in self?.handleDelete() }
		kb.onReturn         = { [weak self] in self?.handleReturn() }
		kb.onNextKeyboard   = { [weak self] in self?.advanceToNextInputMode() }
		kb.onPickSuggestion = { [weak self] in self?.handlePick($0) }
		kb.onGlideBegan     = { [weak self] in self?.handleGlideBegan() }
		kb.onGlide          = { [weak self] in self?.handleGlide($0) }

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
		resetEraseTracking()           // a new field/host — stale erase state is meaningless
		wordTaps.removeAll(keepingCapacity: true)
		updateSuggestionMode()
		updateActionKey()
		updateAutoShift()
		keyboard?.prepareHaptics()     // prime the engine so the first tap isn't delayed
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		// `needsInputModeSwitchKey` is only accurate once the host connection exists;
		// reading it earlier (viewDidLoad / viewWillAppear) logs an inaccurate-result
		// warning. By viewDidAppear the connection is established. Rebuild only if the
		// globe requirement differs from our default (usually it doesn't → no rebuild).
		guard !globeConfigured else { return }
		globeConfigured = true
		let needsGlobe = needsInputModeSwitchKey
		if needsGlobe != showsGlobe { showsGlobe = needsGlobe; buildKeyboard() }
	}

	override func textDidChange(_ textInput: UITextInput?) {
		super.textDidChange(textInput)
		updateSuggestionMode()
		updateActionKey()
		updateAutoShift()              // cursor moved / host cleared the field
	}

	// MARK: Field-aware suggestion gating (mirror stock iOS)
	//
	// In URL / email / search / numeric / password fields — and anywhere the host set
	// `autocorrectionType = .no` — iOS hides the predictive bar. We do the same and, like
	// stock, shrink the keyboard to reclaim that strip. Autocorrect is kept working (per
	// request), except in secure fields where correcting a password is never wanted.

	private var isSecureField: Bool { textDocumentProxy.isSecureTextEntry ?? false }

	private var suggestionsAllowed: Bool {
		let p = textDocumentProxy
		if p.isSecureTextEntry ?? false { return false }
		if p.autocorrectionType == .no { return false }
		switch p.keyboardType {
		case .some(.URL), .some(.emailAddress), .some(.webSearch),
			 .some(.numberPad), .some(.phonePad), .some(.decimalPad),
			 .some(.namePhonePad), .some(.asciiCapableNumberPad):
			return false
		default:
			return true
		}
	}

	private func updateSuggestionMode() {
		let allowed = suggestionsAllowed
		keyboard?.setShowsSuggestions(allowed)
		if let h = heightConstraint, let kb = keyboard, h.constant != kb.keyboardHeight {
			h.constant = kb.keyboardHeight
		}
		if !allowed { keyboard?.setSuggestions([]) }
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

	/// Any action other than the single-Backspace undo (or the bar-undo) means the
	/// last autocorrect STOOD. Report it: acceptance is counter-evidence that resets
	/// the word's rejection tally, so one accidental undo can't slowly turn into a
	/// permanent keep. Called at the entry of every non-undo handler — exactly the
	/// moment the undo affordance expires.
	private func resolveCorrectionAsAccepted() {
		if let c = lastCorrection, c.fromAutocorrect { engine.correctionStood(c.original) }
	}

	/// Timestamp of the last plain space, for the double-space → ". " shortcut.
	private var lastSpaceAt: TimeInterval = 0

	private func handleInsert(_ ch: String, tap: KeyTap? = nil) {
		resolveCorrectionAsAccepted()
		trackReplacementStart()

		// Buffer the tap offset for letter keys (keeps `wordTaps` aligned with the word
		// being typed); any non-letter starts a fresh word, so drop the buffer.
		if ch.count == 1, let c = ch.first, isWordChar(c) {
			wordTaps.append(tap)
		} else {
			wordTaps.removeAll(keepingCapacity: true)
		}

		// Double-space → period + space (stock shortcut). Only after a word, only in
		// normal prose fields, only within the double-tap window.
		if ch == " " {
			let now = ProcessInfo.processInfo.systemUptime
			let before = textDocumentProxy.documentContextBeforeInput ?? ""
			if now - lastSpaceAt < 0.6, before.hasSuffix(" "),
			   let prev = before.dropLast().last, isWordChar(prev), suggestionsAllowed {
				textDocumentProxy.deleteBackward()
				textDocumentProxy.insertText(". ")
				lastCorrection = nil
				lastSpaceAt = 0
				resetEraseTracking()
				updateAutoShift()
				scheduleSuggestions()
				return
			}
			lastSpaceAt = now
		}

		if ch.count == 1, let u = ch.unicodeScalars.first, boundary.contains(u) {
			// Must run BEFORE autocorrect: a manual revert (erased our correction,
			// retyped the original) registers a rejection on the engine barrier, and
			// the queue.sync inside autocorrection() orders after it — so the very
			// commit that completes the revert is already exempt from re-correction.
			resolveManualFix(trailingWord(textDocumentProxy.documentContextBeforeInput ?? ""))
			var correction = applyAutocorrectIfNeeded()
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			let w = trailingWord(ctx)
			// Never learn from secure fields — password fragments must not enter the
			// persisted personal model.
			if !w.isEmpty, !isSecureField { engine.learn(context: contextWords(ctx, max: 8), word: w) }
			textDocumentProxy.insertText(ch)
			correction?.trailing = ch
			lastCorrection = correction
		} else {
			lastCorrection = nil
			textDocumentProxy.insertText(ch)
		}
		updateAutoShift()
		scheduleSuggestions()
	}

	private func handleReturn() {
		resolveCorrectionAsAccepted()
		resolveManualFix(trailingWord(textDocumentProxy.documentContextBeforeInput ?? ""))
		var correction = applyAutocorrectIfNeeded()
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		let w = trailingWord(ctx)
		if !w.isEmpty, !isSecureField { engine.learn(context: contextWords(ctx, max: 8), word: w) }
		textDocumentProxy.insertText("\n")
		correction?.trailing = "\n"
		lastCorrection = correction
		updateAutoShift()
		scheduleSuggestions()
	}

	// MARK: Auto-capitalization — shift arms itself at sentence starts (stock behavior)

	private func updateAutoShift() {
		let ctx = textDocumentProxy.documentContextBeforeInput
		keyboard?.setAutoShift(shouldAutoShift(ctx))
	}

	/// Field start, after a newline, or after sentence-ending punctuation + space.
	private func shouldAutoShift(_ ctx: String?) -> Bool {
		guard let ctx, !ctx.isEmpty else { return true }
		if ctx.hasSuffix("\n") { return true }
		var s = Substring(ctx)
		var sawSpace = false
		while s.last == " " { sawSpace = true; s = s.dropLast() }
		if sawSpace, let l = s.last, ".!?".contains(l) { return true }
		return s.isEmpty        // only whitespace before the cursor
	}

	private func handleDelete() {
		// A single Backspace right after a correction undoes it back to the typed word.
		if let c = lastCorrection {
			lastCorrection = nil
			resetEraseTracking()
			wordTaps.removeAll(keepingCapacity: true)   // word rewritten — offsets no longer align
			for _ in 0..<c.trailing.count { textDocumentProxy.deleteBackward() }
			for _ in 0..<c.corrected.count { textDocumentProxy.deleteBackward() }
			textDocumentProxy.insertText(c.original)
			// Autocorrect would otherwise re-fire on the next space and fight the user;
			// remember they meant this word. (Completion undo needs no such guard.)
			// Also walk back what the boundary just learned for the rejected word.
			if c.fromAutocorrect {
				engine.dontCorrect(c.original)
				engine.wordReplaced(original: c.corrected, with: c.original)
			}
			updateAutoShift()
			scheduleSuggestions()
			return
		}
		let erased = textDocumentProxy.documentContextBeforeInput?.last
		textDocumentProxy.deleteBackward()
		if let erased, isWordChar(erased), !wordTaps.isEmpty { wordTaps.removeLast() }
		else { wordTaps.removeAll(keepingCapacity: true) }
		trackErase(of: erased)
		updateAutoShift()
		scheduleSuggestions()
	}

	private func handlePick(_ s: String) {
		resetEraseTracking()   // picking from the bar is its own flow with its own signals
		wordTaps.removeAll(keepingCapacity: true)

		// Emoji suggestion (last slot, word→emoji match): replace the typed word with
		// the emoji and learn nothing — it isn't a spelling. No trailing space, matching
		// stock QuickType. A letterless string is unambiguously the emoji candidate.
		if !s.isEmpty, !s.contains(where: { $0.isLetter }) {
			resolveCorrectionAsAccepted()
			if case .complete(let partial) = mode {
				for _ in 0..<partial.count { textDocumentProxy.deleteBackward() }
			}
			textDocumentProxy.insertText(s)
			KBEmojiRecents.add(s)
			lastCorrection = nil
			updateAutoShift()
			scheduleSuggestions()
			return
		}

		// Every pick except the bar-undo means any pending autocorrect stood.
		if case .revert(let original) = mode, s == original {} else { resolveCorrectionAsAccepted() }
		switch mode {
		case .complete(let partial):
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			for _ in 0..<partial.count { textDocumentProxy.deleteBackward() }
			textDocumentProxy.insertText(s + " ")
			engine.learn(context: ctx, word: s)
			// Swapping the typed word for a different suggestion is strong evidence the
			// typed word was a mistake — lift its keep protection and walk back a use.
			// This is the "typed mjght, then picked might" healing path.
			if partial.lowercased() != s.lowercased() { engine.wordReplaced(original: partial, with: s) }
			lastCorrection = Correction(original: partial, corrected: s, trailing: " ", fromAutocorrect: false)
		case .predict:
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			textDocumentProxy.insertText(s + " ")
			engine.learn(context: ctx, word: s)
			lastCorrection = nil        // nothing the user "typed" to revert to
		case .revert(let original):
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			if s == original, let corrected = lastCompleteWord(ctx) {
				textDocumentProxy.deleteBackward()
				for _ in 0..<corrected.count { textDocumentProxy.deleteBackward() }
				textDocumentProxy.insertText(original + " ")
				engine.dontCorrect(original)
				engine.wordReplaced(original: corrected, with: original)   // un-learn the undone correction
			} else {
				textDocumentProxy.insertText(s + " ")
			}
			lastCorrection = nil
		}
		updateAutoShift()
		scheduleSuggestions()
	}

	// MARK: Autocorrect (fast, non-blocking)

	@discardableResult
	private func applyAutocorrectIfNeeded() -> Correction? {
		guard !isSecureField else { return nil }
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		let word = trailingWord(ctx)
		// Taps only apply when the buffer still lines up 1:1 with the boundary word.
		let taps = wordTaps.count == word.count ? wordTaps : nil
		guard !word.isEmpty,
			  let correction = engine.autocorrection(for: word, context: contextWords(ctx, max: 8), taps: taps),
			  correction != word else { return nil }
		for _ in 0..<word.count { textDocumentProxy.deleteBackward() }
		textDocumentProxy.insertText(correction)
		recentCorrections.append((original: word, corrected: correction))
		if recentCorrections.count > 4 { recentCorrections.removeFirst() }
		return Correction(original: word, corrected: correction, trailing: "", fromAutocorrect: true)
	}

	// MARK: Glide typing

	/// A tap turned into a glide: the start letter was inserted on contact, so remove
	/// it — the whole word will come from the swipe decoder when the finger lifts.
	private func handleGlideBegan() {
		textDocumentProxy.deleteBackward()
		wordTaps.removeAll(keepingCapacity: true)
		lastCorrection = nil
	}

	/// The swipe lifted with its full trajectory. Turning the path into a word is a
	/// later phase; for now the stroke produces nothing (the start letter is already
	/// gone), and we just resync the keyboard state to the (unchanged) field.
	private func handleGlide(_ path: [CGPoint]) {
		resetEraseTracking()
		updateAutoShift()
		scheduleSuggestions()
	}

	// MARK: Manual-fix detection (backspace-erase → retype, no one-tap undo involved)

	private func resetEraseTracking() {
		erasedWord = ""
		erasedCrossedBoundary = false
		replacementStarted = false
	}

	/// Called for every plain backspace with the character that was just deleted.
	private func trackErase(of char: Character?) {
		replacementStarted = false
		guard let char else { resetEraseTracking(); return }        // deleted at field start
		if isWordChar(char) {
			if erasedCrossedBoundary {
				// Deleting into the PREVIOUS word — that word is the erase target now.
				erasedWord = String(char)
				erasedCrossedBoundary = false
			} else {
				erasedWord.insert(char, at: erasedWord.startIndex)
			}
			if erasedWord.count > 24 { resetEraseTracking() }       // runaway delete, not a fix
		} else if !erasedWord.isEmpty {
			erasedCrossedBoundary = true
		}
	}

	/// First insert after a run of backspaces: typing that resumes INSIDE a word means
	/// the deletes were an intra-word edit ("jst" → backspace → "ust"), not a word
	/// swap — stop tracking rather than misread it.
	private func trackReplacementStart() {
		guard !erasedWord.isEmpty, !replacementStarted else { return }
		replacementStarted = true
		if let prev = (textDocumentProxy.documentContextBeforeInput ?? "").last, isWordChar(prev) {
			resetEraseTracking()
		}
	}

	/// A word is being committed where one was just erased. Two cases:
	/// the erased word was one of OUR corrections and the user retyped exactly what
	/// they had originally typed → a manual undo of autocorrect (register the
	/// rejection, walk the learning back); anything else → a hand-fix of their own
	/// word ("js" → "is"), which demotes the erased word.
	private func resolveManualFix(_ committed: String) {
		defer { resetEraseTracking() }
		let erased = erasedWord
		guard erased.count >= 2, !committed.isEmpty,
			  erased.lowercased() != committed.lowercased(), !isSecureField else { return }
		if let hit = recentCorrections.last(where: { $0.corrected.lowercased() == erased.lowercased() }),
		   hit.original.lowercased() == committed.lowercased() {
			engine.dontCorrect(committed)
		}
		engine.wordReplaced(original: erased, with: committed)
	}

	// MARK: Suggestions — debounced, background-computed

	private func scheduleSuggestions() {
		suggestWork?.cancel()
		let work = DispatchWorkItem { [weak self] in self?.refreshSuggestions() }
		suggestWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
	}

	private func refreshSuggestions() {
		guard suggestionsAllowed else { keyboard?.setSuggestions([]); return }
		generation += 1
		let gen = generation
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		let current = trailingWord(ctx)
		let revert = (lastCorrection?.fromAutocorrect == true) ? lastCorrection?.original : nil
		let context = contextWords(ctx, max: 8)

		if current.isEmpty {
			engine.suggestions(currentWord: "", context: context) { [weak self] preds, priors in
				guard let self, gen == self.generation else { return }
				self.keyboard.setKeyPriors(priors)
				if let revert {
					self.mode = .revert(revert)
					self.keyboard.setSuggestions([revert] + preds.prefix(2))
				} else {
					self.mode = .predict
					self.keyboard.setSuggestions(preds)
				}
			}
		} else {
			let taps = wordTaps.count == current.count ? wordTaps : nil
			engine.suggestions(currentWord: current, context: context, taps: taps) { [weak self] comps, priors in
				guard let self, gen == self.generation else { return }
				self.mode = .complete(current)
				self.keyboard.setKeyPriors(priors)
				// Ghost styling: dim the completion remainder past what the user typed.
				self.keyboard.setSuggestions(comps, typedPrefix: current)
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

	/// Up to `max` complete words immediately before any trailing partial word,
	/// oldest→newest, stopping at a sentence boundary (. ! ? or newline) — context
	/// from the previous sentence would only mislead the prior.
	private func contextWords(_ s: String, max: Int) -> [String] {
		let sentenceEnd = Set<Character>(".!?\n")
		var chars = Array(s)
		while let last = chars.last, isWordChar(last) { chars.removeLast() }   // drop trailing partial
		var words: [String] = []
		outer: while words.count < max {
			while let last = chars.last, !isWordChar(last) {
				if sentenceEnd.contains(last) { break outer }
				chars.removeLast()
			}
			if chars.isEmpty { break }
			var w = ""
			while let last = chars.last, isWordChar(last) { w.insert(last, at: w.startIndex); chars.removeLast() }
			if w.isEmpty { break }
			words.insert(w, at: 0)
		}
		return words
	}
}
