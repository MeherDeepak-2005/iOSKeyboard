import UIKit

// Keystroke path = insertText only. Autocorrect is a fast read on word boundaries;
// suggestions are debounced. The engine receives up to 8 words of sentence-bounded
// context via `contextWords` — the n-gram prior uses the last 2, a future neural
// rescorer uses all of it.

final class KeyboardViewController: UIInputViewController {

	private var keyboard: KeyboardView!
	private var heightConstraint: NSLayoutConstraint?
	private let engine = KeyboardEngine()

	private enum Mode { case predict, complete(String), revert(String), glided(String) }
	private var mode: Mode = .predict
	private var generation = 0
	private var suggestWork: DispatchWorkItem?
	private var suggestionModeResolved = false
	private var suggestionsVisible = true
	private var currentSuggestions: [String] = []
	private var currentSuggestionPrefix: String?

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

	/// #37 glide adaptation: a glided word was just committed and is awaiting the user's
	/// verdict. Typing on / a newline / another glide → the word stood (accepted); a bar
	/// swap → corrected; a Backspace that erases it → rejected. Whichever comes first feeds
	/// the engine's per-user σ / gate tuning, then this clears.
	private var pendingGlideAccept = false

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
		kb.onGlide          = { [weak self] path, layout in self?.handleGlide(path, layout) }
		// Emoji search swaps the suggestion strip for a taller search header; track it.
		kb.onHeightChange   = { [weak self, weak kb] in
			guard let self, let kb else { return }
			self.heightConstraint?.constant = kb.keyboardHeight
		}

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
		if suggestionModeResolved {
			kb.setShowsSuggestions(suggestionsVisible)
			h.constant = kb.keyboardHeight
		}
		updateActionKey()
		kb.setSuggestions(currentSuggestions, typedPrefix: currentSuggestionPrefix)
	}

	// MARK: Contextual action key — mirrors the host field's Return key (go / search / send …)

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		resetEraseTracking()           // a new field/host — stale erase state is meaningless
		wordTaps.removeAll(keepingCapacity: true)
		pendingGlideAccept = false     // don't attribute a new field's first action to an old glide
		// Strip is NOT resolved here: the field type is unreliable this early. It stays at its
		// default (open) until viewDidAppear resolves it once — no premature toggling.
		updateActionKey()
		updateAutoShift()
		keyboard?.prepareHaptics()     // prime the engine so the first tap isn't delayed
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		// The text proxy's field type (URL / search / etc.) is only reliable once the host
		// connection is established — same reason as the globe key below. This is the single
		// point we resolve the strip: normal apps keep the strip that was already showing;
		// suppressed fields (Safari address bar & friends) disable it once, for good.
		resolveSuggestionModeIfNeeded()
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
		// Deliberately NOT re-evaluating the strip here: it is resolved once (viewDidAppear)
		// and stays fixed, so it never flickers open/closed while typing. Only the action
		// key and shift state track the cursor.
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

	/// Resolve the strip's visibility ONCE per keyboard presentation, then leave it fixed.
	/// The strip starts open (normal apps: on from the first frame). The first time the
	/// host field type is reliably readable (viewDidAppear) we disable it for suppressed
	/// fields — after that it never changes, so there is no per-keystroke flicker.
	private func resolveSuggestionModeIfNeeded() {
		guard !suggestionModeResolved else { return }
		suggestionModeResolved = true
		let allowed = suggestionsAllowed
		suggestionsVisible = allowed
		keyboard?.setShowsSuggestions(allowed)
		if let h = heightConstraint, let kb = keyboard, h.constant != kb.keyboardHeight {
			h.constant = kb.keyboardHeight
		}
		if !allowed { setSuggestionBar([]) }
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

	/// #37: a committed glided word stood (the user moved on without undoing or swapping it).
	/// Report the acceptance so the engine can treat the winner's shape cost as a correct
	/// sample. Called at the entry of the non-undo handlers, exactly like the accept above.
	private func resolveGlideAccepted() {
		if pendingGlideAccept { pendingGlideAccept = false; engine.glideAccepted() }
	}

	/// Timestamp of the last plain space, for the double-space → ". " shortcut.
	private var lastSpaceAt: TimeInterval = 0

	private func handleInsert(_ ch: String, tap: KeyTap? = nil) {
		resolveCorrectionAsAccepted()
		resolveGlideAccepted()
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
			// Must run BEFORE autocorrect: a manual revert (erased our correction, retyped
			// the original) registers a rejection synchronously (dontCorrect → stateLock), so
			// the very commit that completes the revert is already exempt from re-correction.
			resolveManualFix(trailingWord(textDocumentProxy.documentContextBeforeInput ?? ""))
			var correction = applyAutocorrectIfNeeded()
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			let w = trailingWord(ctx)
			// Never learn from secure fields — password fragments must not enter the
			// persisted personal model.
			if !w.isEmpty, !isSecureField { engine.learn(context: contextWords(ctx, max: 8), word: w) }
			// Punctuation right after an auto-inserted space: delete the space first
			// so punctuation lands directly after the word ("word." not "word .").
			// Only when the space was ours (lastCorrection?.trailing) — never touches
			// a space the user explicitly typed.
			if ch != " ", ch != "\n", lastCorrection?.trailing == " " {
				textDocumentProxy.deleteBackward()
			}
			textDocumentProxy.insertText(ch)
			correction?.trailing = ch
			lastCorrection = correction
			maybeRescorePreviousWord()      // n-1 rescue now that this word is committed
		} else {
			lastCorrection = nil
			textDocumentProxy.insertText(ch)
		}
		updateAutoShift()
		scheduleSuggestions()
	}

	private func handleReturn() {
		resolveCorrectionAsAccepted()
		resolveGlideAccepted()
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

	// MARK: Previous-word (n-1) rescue — Apple-style "poler game → poker game"

	/// After a word commits at a space boundary, ask the engine (async, neural) whether the
	/// PREVIOUS word should change given the just-committed word as evidence. Applies the fix
	/// behind the cursor only if the text tail is STILL exactly "<prev> <current> " when the
	/// answer arrives (the user may have kept typing), so it never corrupts moved text.
	private func maybeRescorePreviousWord() {
		guard !isSecureField else { return }
		guard (textDocumentProxy.documentContextAfterInput ?? "").isEmpty else { return }  // cursor at end
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		guard ctx.hasSuffix(" ") else { return }
		let trimmed = String(ctx.dropLast())                          // drop the committing space
		let current = trailingWord(trimmed)
		guard !current.isEmpty else { return }
		let beforeCurrent = String(trimmed.dropLast(current.count))
		guard beforeCurrent.hasSuffix(" ") else { return }            // exactly one space between words
		let prevZone = String(beforeCurrent.dropLast())
		let prev = trailingWord(prevZone)
		guard prev.count >= 3 else { return }
		let leftContext = contextWords(prevZone, max: 8)              // words BEFORE the previous word
		let expected = "\(prev) \(current) "                          // tail we must still see to apply

		engine.rescorePreviousWord(prev: prev, current: current, leftContext: leftContext) { [weak self] replacement in
			guard let self, let replacement, replacement != prev else { return }
			// Nothing must have moved since we measured: same tail, cursor still at the end.
			guard (self.textDocumentProxy.documentContextAfterInput ?? "").isEmpty,
				  (self.textDocumentProxy.documentContextBeforeInput ?? "").hasSuffix(expected) else { return }
			// Preserve the previous word's leading case (e.g. sentence-start capitalization).
			var repl = replacement
			if let f = prev.first, f.isUppercase { repl = repl.prefix(1).uppercased() + repl.dropFirst() }
			// Reach back over "prev current " and rewrite only the previous word.
			let back = prev.count + 1 + current.count + 1
			for _ in 0..<back { self.textDocumentProxy.deleteBackward() }
			self.textDocumentProxy.insertText("\(repl) \(current) ")
			self.engine.wordReplaced(original: prev, with: replacement)   // lift keep + demote the old use
		}
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
			// Validate the correction is still present in the document before undoing.
			// If the user selected-all and then backspaced, the field is empty and the
			// correction no longer exists; executing the undo path would insert the
			// original typed word ("coeevitjkn") into the now-cleared field.
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			let expected = c.corrected + c.trailing
			guard !expected.isEmpty, ctx.hasSuffix(expected) else {
				if pendingGlideAccept { pendingGlideAccept = false; engine.glideRejected() }
				lastCorrection = nil
				let erased = ctx.last
				textDocumentProxy.deleteBackward()
				if let erased, isWordChar(erased), !wordTaps.isEmpty { wordTaps.removeLast() }
				else { wordTaps.removeAll(keepingCapacity: true) }
				trackErase(of: erased)
				updateAutoShift()
				scheduleSuggestions()
				return
			}
			// #37: a glided word (empty original, not an autocorrect) being backspaced away is
			// a rejection — the engine drops its pending sample without moving the statistics.
			if pendingGlideAccept, c.original.isEmpty, !c.fromAutocorrect {
				pendingGlideAccept = false
				engine.glideRejected()
			}
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
		case .glided(let committed):
			// Swap the glided word for one of its shape alternatives: replace word + its
			// trailing space, learn the replacement, heal the wrong learn (Gboard-style).
			// #37: the picked alternative is the TRUE word — feed its shape cost as the
			// correct sample so the decoder learns to rank the user's real intent higher.
			if pendingGlideAccept { pendingGlideAccept = false; engine.glideCorrected(to: s) }
			for _ in 0..<(committed.count + 1) { textDocumentProxy.deleteBackward() }
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			var replacement = s
			if shouldAutoShift(textDocumentProxy.documentContextBeforeInput) {
				replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
			}
			textDocumentProxy.insertText(replacement + " ")
			engine.learn(context: ctx, word: s)
			if committed.lowercased() != s.lowercased() { engine.wordReplaced(original: committed, with: s) }
			lastCorrection = Correction(original: "", corrected: replacement, trailing: " ", fromAutocorrect: false)
			mode = .glided(replacement)          // further swaps keep working
			updateAutoShift()
			return                               // keep the alternatives on the bar
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

	/// The swipe lifted: decode → rerank → commit the winner (word + trailing space, with
	/// auto-space after letters and sentence-start capitalization), learn it, and leave the
	/// runner-up shapes on the bar as one-tap swaps. A single Backspace removes the whole
	/// glided word (`Correction` with empty original). Nothing commits on a rejected swipe.
	private func handleGlide(_ path: [CGPoint], _ layout: GlideLayout) {
		// Cancel the debounced suggestion pass the start-letter triggered: without
		// this, it fires 60 ms into the swipe and queues engine work the glide
		// decode then has to wait behind. The engine also bumps suggestGen to
		// invalidate any pass that already reached the engine queue.
		suggestWork?.cancel()
		resetEraseTracking()
		wordTaps.removeAll(keepingCapacity: true)
		guard !isSecureField else { return }             // no gliding passwords
		resolveCorrectionAsAccepted()
		resolveGlideAccepted()                           // a prior glided word stood — record it
		let before = textDocumentProxy.documentContextBeforeInput ?? ""
		let context = contextWords(before, max: 8)
		engine.glide(path: path, layout: layout, context: context) { [weak self] word, alternatives in
			guard let self else { return }
			guard let word else { self.scheduleSuggestions(); return }
			let ctx = self.textDocumentProxy.documentContextBeforeInput ?? ""
			var display = word
			if self.shouldAutoShift(ctx) { display = display.prefix(1).uppercased() + display.dropFirst() }
			var text = display + " "
			if let last = ctx.last, self.isWordChar(last) { text = " " + text }   // auto-space after letters
			self.textDocumentProxy.insertText(text)
			self.engine.learn(context: context, word: word)
			self.lastCorrection = Correction(original: "", corrected: display, trailing: " ", fromAutocorrect: false)
			self.mode = .glided(display)
			self.pendingGlideAccept = true               // #37: awaiting the user's verdict on this word
			// Alternatives stay on the bar until the next input (no scheduleSuggestions here,
			// or the debounced pass would wipe them 60 ms later).
			self.keyboard?.setSuggestions(alternatives)
			self.updateAutoShift()
			self.maybeRescorePreviousWord()      // n-1 rescue: the glided word is now committed
		}
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
		guard suggestionsAllowed else { setSuggestionBar([]); return }
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
					self.setSuggestionBar([revert] + preds.prefix(2))
				} else {
					self.mode = .predict
					self.setSuggestionBar(preds)
				}
			}
		} else {
			let taps = wordTaps.count == current.count ? wordTaps : nil
			engine.suggestions(currentWord: current, context: context, taps: taps) { [weak self] comps, priors in
				guard let self, gen == self.generation else { return }
				self.mode = .complete(current)
				self.keyboard.setKeyPriors(priors)
				// Ghost styling: dim the completion remainder past what the user typed.
				self.setSuggestionBar(comps, typedPrefix: current)
			}
		}
	}

	private func setSuggestionBar(_ suggestions: [String], typedPrefix: String? = nil) {
		currentSuggestions = suggestions
		currentSuggestionPrefix = typedPrefix
		keyboard?.setSuggestions(suggestions, typedPrefix: typedPrefix)
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
