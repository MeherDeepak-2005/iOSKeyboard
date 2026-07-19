import UIKit

// Keystroke path = insertText only. Autocorrect is a fast read on word boundaries;
// suggestions are debounced. The engine receives up to 8 words of sentence-bounded
// context via `contextWords` — the n-gram prior uses the last 2, a future neural
// rescorer uses all of it.

final class KeyboardViewController: UIInputViewController {

	private var keyboard: KeyboardView!
	private var heightConstraint: NSLayoutConstraint?
	private let engine = KeyboardEngine.shared   // process-wide: see KeyboardEngine.shared

	private enum Mode { case predict, complete(String), revert(String), glided(String) }
	private var mode: Mode = .predict
	private var generation = 0
	private var suggestWork: DispatchWorkItem?
	private var suggestionModeResolved = false
	private var suggestionsVisible = true
	private var hostConnectionReady = false
	private var supplementaryLexiconRequested = false
	private enum SuggestionPresentation {
		case ranked(words: [String], prefix: String?)
		case glide(winner: String, alternatives: [String])
	}
	private var suggestionPresentation = SuggestionPresentation.ranked(words: [], prefix: nil)
	private struct GlidePreviewRequest {
		let path: [CGPoint]
		let times: [TimeInterval]
		let layout: GlideLayout
		let sequence: Int
	}
	private var pendingGlidePreview: GlidePreviewRequest?
	private var glidePreviewInFlight = false
	private var glidePreviewGeneration = 0
	private var glidePreviewSequence = 0
	private var activeGlideDocumentContext: String?
	private var activeGlideContext: [String] = []
	private var activeGlideAutoShift = false
	private var glidePreviewEnabled = false

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

	/// Resolved only after the host connection is live. Calling
	/// `needsInputModeSwitchKey` during extension prewarming produces an inaccurate result
	/// and a UIKit warning; until then, omit the key and rebuild once if iOS requires it.
	private var showsGlobe = false

	private let boundary = CharacterSet(charactersIn: " .,!?;:")

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .clear
		buildKeyboard()

		// Follow the host app's light/dark appearance and rebuild on changes.
		registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
			self.buildKeyboard()
			if self.hostConnectionReady { self.scheduleSuggestions() }
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
		kb.onGlideBegan     = { [weak self] in self?.beginGlidePreview() }
		kb.onGlidePreview   = { [weak self] path, times, layout in
			self?.handleGlidePreview(path, times, layout)
		}
		kb.onGlideCancelled = { [weak self] in self?.cancelGlidePreview(clearStrip: true) }
		kb.onGlide          = { [weak self] path, times, layout in self?.handleGlide(path, times, layout) }
		kb.onClipboardPick  = { [weak self] in self?.handleClipboardPick($0) }
		kb.onOpenClipboard  = { [weak self, weak kb] in
			guard let self, let kb else { return }
			// Capture BEFORE building the panel so a just-copied clip is already in
			// the list the panel loads — this is the only place we read the pasteboard.
			self.captureClipboardIfNeeded()
			kb.showClipboard(hasFullAccess: self.hasFullAccess)
		}
		kb.onOpenMedia      = { [weak self, weak kb] kind in
			guard let self, let kb else { return }
			kb.showMedia(kind: kind, hasFullAccess: self.hasFullAccess)
		}
		// Emoji/media search swaps the strip for a taller header, and the browsing
		// overlays expand the deck; track both. The `keyboard === kb` guard matters:
		// buildKeyboard() (theme/globe change) replaces the view AND the constraint, so
		// a stale view firing this would size the CURRENT constraint from a DEAD view's
		// page — e.g. an expanded emoji height under a letters deck, which reads as a
		// tall keyboard with dead space beneath the keys.
		kb.onHeightChange   = { [weak self, weak kb] in
			guard let self, let kb, self.keyboard === kb else { return }
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
		if hostConnectionReady { updateActionKey() }
		applySuggestionPresentation(to: kb)
	}

	// MARK: Contextual action key — mirrors the host field's Return key (go / search / send …)

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		resetEraseTracking()           // a new field/host — stale erase state is meaningless
		wordTaps.removeAll(keepingCapacity: true)
		pendingGlideAccept = false     // don't attribute a new field's first action to an old glide
		// Host field properties are still unreliable here. The first text-input callback
		// resolves the strip and globe after the extension-host connection is live.
		keyboard?.prepareHaptics()     // prime the engine so the first tap isn't delayed
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		KBStats.flush()                // keyboard dismissing — bank the buffered word counts
	}

	override func textDidChange(_ textInput: UITextInput?) {
		super.textDidChange(textInput)
		hostConnectionDidBecomeAvailable()
		// Deliberately NOT re-evaluating the strip here: it is resolved once after connection
		// and stays fixed, so it never flickers open/closed while typing. Only the action
		// key and shift state track the cursor.
		updateActionKey()
		updateAutoShift()              // cursor moved / host cleared the field
		snapBackFromOverlaysIfUserTouched()
	}

	override func selectionDidChange(_ textInput: UITextInput?) {
		super.selectionDidChange(textInput)
		hostConnectionDidBecomeAvailable()
		snapBackFromOverlaysIfUserTouched()
	}

	/// UIInputViewController can be prewarmed without a live host connection, so proxy
	/// reads and prediction work start only after the host invokes an input callback.
	private func hostConnectionDidBecomeAvailable() {
		guard !hostConnectionReady else { return }
		hostConnectionReady = true
		KBSettings.hasUsedKeyboard = true
		KBSettings.lastFullAccess = hasFullAccess
		let requiresSwitchKey = needsInputModeSwitchKey
		if showsGlobe != requiresSwitchKey {
			showsGlobe = requiresSwitchKey
			buildKeyboard()
		}
		resolveSuggestionModeIfNeeded()

		if !supplementaryLexiconRequested {
			supplementaryLexiconRequested = true
			requestSupplementaryLexicon { [weak self] lexicon in
				self?.engine.importSupplementaryLexicon(lexicon.entries.map(\.documentText))
			}
		}
		updateActionKey()
		updateAutoShift()
		scheduleSuggestions()
	}

	/// Tapping the input field (or otherwise moving the cursor by hand) while the emoji
	/// page, emoji search, or clipboard panel is up returns to the letter deck — stock
	/// behavior. Guarded by the proxy-edit timestamp so our own inserts/deletes never
	/// trigger it.
	private func snapBackFromOverlaysIfUserTouched() {
		guard isUserDocumentTouch, keyboard?.dismissOverlaysIfActive() == true else { return }
		scheduleSuggestions()          // the bar is live again — refill it for the new context
	}

	// MARK: Clipboard — capture on panel open, insert from saved history

	/// Capture the current system pasteboard into history. Called ONLY when the user
	/// opens the clipboard panel — a deliberate action, so iOS's one "pasted from"
	/// notice reads as expected (there is no banner-free way to read arbitrary text;
	/// `changeCount` dedupe means at most one read per distinct copy). We never read
	/// on the type path, so copying elsewhere raises no banner and never stalls layout.
	private func captureClipboardIfNeeded() {
		guard hasFullAccess else { return }
		let pb = UIPasteboard.general
		let count = pb.changeCount
		guard count != KBClipboard.consumedChangeCount else { return }
		KBClipboard.consumedChangeCount = count
		guard pb.hasStrings, let text = pb.string,
			  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		KBClipboard.add(text)
	}

	/// A history row from the clipboard panel. Inserts and stays on the panel
	/// (multi-paste, Gboard-style). Never learned — clips aren't typing.
	private func handleClipboardPick(_ text: String) {
		noteProxyEdit()
		resolveCorrectionAsAccepted()
		resolveGlideAccepted()
		resetEraseTracking()
		wordTaps.removeAll(keepingCapacity: true)
		textDocumentProxy.insertText(text)
		lastCorrection = nil
		updateAutoShift()
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
	/// host field type is reliably readable (the first input callback) we disable it for suppressed
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

	/// Uptime of the last edit WE made through the proxy. textDidChange /
	/// selectionDidChange arriving without a recent programmatic edit means the user
	/// touched the document directly (tapped the input field, moved the cursor) —
	/// the signal that snaps the emoji page / emoji search back to the letter deck.
	private var lastProxyEditAt: TimeInterval = 0
	private func noteProxyEdit() { lastProxyEditAt = ProcessInfo.processInfo.systemUptime }

	/// True when a document change arrived that we didn't cause. The 0.5 s window
	/// absorbs the host's async delivery of our own inserts/deletes.
	private var isUserDocumentTouch: Bool {
		ProcessInfo.processInfo.systemUptime - lastProxyEditAt > 0.5
	}

	private func handleInsert(_ ch: String, tap: KeyTap? = nil) {
		noteProxyEdit()
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
			// persisted personal model. (Stats ride the same gate: password words
			// shouldn't count toward streaks either.)
			if !w.isEmpty, !isSecureField {
				engine.learn(context: contextWords(ctx, max: 8), word: w)
				KBStats.note(glided: false)
			}
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
		noteProxyEdit()
		resolveCorrectionAsAccepted()
		resolveGlideAccepted()
		resolveManualFix(trailingWord(textDocumentProxy.documentContextBeforeInput ?? ""))
		var correction = applyAutocorrectIfNeeded()
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		let w = trailingWord(ctx)
		if !w.isEmpty, !isSecureField {
			engine.learn(context: contextWords(ctx, max: 8), word: w)
			KBStats.note(glided: false)
		}
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
			self.noteProxyEdit()
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
		noteProxyEdit()
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
		noteProxyEdit()
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
			KBStats.note(glided: false)
			// Swapping the typed word for a different suggestion is strong evidence the
			// typed word was a mistake — lift its keep protection and walk back a use.
			// This is the "typed mjght, then picked might" healing path.
			if partial.lowercased() != s.lowercased() { engine.wordReplaced(original: partial, with: s) }
			lastCorrection = Correction(original: partial, corrected: s, trailing: " ", fromAutocorrect: false)
		case .predict:
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			textDocumentProxy.insertText(s + " ")
			engine.learn(context: ctx, word: s)
			KBStats.note(glided: false)
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
			let oldAlternatives: [String]
			if case .glide(_, let alternatives) = suggestionPresentation {
				oldAlternatives = alternatives
			} else {
				oldAlternatives = []
			}
			for _ in 0..<(committed.count + 1) { textDocumentProxy.deleteBackward() }
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			let replacement = KBWordCase.sentenceDisplay(
				s, capitalized: shouldAutoShift(textDocumentProxy.documentContextBeforeInput))
			textDocumentProxy.insertText(replacement + " ")
			engine.learn(context: ctx, word: s)
			if committed.lowercased() != s.lowercased() { engine.wordReplaced(original: committed, with: s) }
			lastCorrection = Correction(original: "", corrected: replacement, trailing: " ", fromAutocorrect: false)
			mode = .glided(replacement)          // further swaps keep working
			let alternatives = uniqueWords([committed] + oldAlternatives, excluding: replacement)
			setGlideSuggestionBar(winner: replacement, alternatives: alternatives)
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
	private func handleGlide(_ path: [CGPoint], _ times: [TimeInterval], _ layout: GlideLayout) {
		let liftAt = ProcessInfo.processInfo.systemUptime
		// Context cannot change while this finger is down. Reuse the one snapshot taken
		// when Glide began instead of making another host XPC read on lift. Never inspect
		// document text for a secure field.
		let secure = isSecureField
		let before = secure ? "" : activeGlideDocumentContext ?? textDocumentProxy.documentContextBeforeInput ?? ""
		let context = activeGlideDocumentContext == nil ? contextWords(before, max: 8) : activeGlideContext
		cancelGlidePreview(clearStrip: false)
		// Cancel the debounced suggestion pass the start-letter triggered: without
		// this, it fires 60 ms into the swipe and queues engine work the glide
		// decode then has to wait behind. The engine also bumps suggestGen to
		// invalidate any pass that already reached the engine queue.
		invalidateSuggestionRequests(cancelEngineWork: true)
		resetEraseTracking()
		wordTaps.removeAll(keepingCapacity: true)
		guard !secure else { return }                    // no gliding passwords
		resolveCorrectionAsAccepted()
		resolveGlideAccepted()                           // a prior glided word stood — record it
		engine.glide(path: path, times: times, layout: layout, context: context) { [weak self] word, alternatives in
			guard let self else { return }
			guard let word else { self.scheduleSuggestions(); return }
			self.commitGlidedWord(word, alternatives: alternatives, context: context,
							   documentContext: before, liftAt: liftAt)
		}
	}

	private func commitGlidedWord(_ word: String, alternatives: [String], context: [String]? = nil,
							   documentContext: String? = nil, liftAt: TimeInterval) {
		noteProxyEdit()
		let ctx = documentContext ?? textDocumentProxy.documentContextBeforeInput ?? ""
		let autoShift = shouldAutoShift(ctx)
		let display = KBWordCase.sentenceDisplay(word, capitalized: autoShift)
		var text = display + " "
		if let last = ctx.last, isWordChar(last) { text = " " + text }
		textDocumentProxy.insertText(text)
		KBDiagnostics.logGlideCommit(ms: (ProcessInfo.processInfo.systemUptime - liftAt) * 1_000)

		// Everything below is bookkeeping after the visible insertion.
		engine.learn(context: context ?? contextWords(ctx, max: 8), word: word)
		KBStats.note(glided: true)
		lastCorrection = Correction(original: "", corrected: display, trailing: " ", fromAutocorrect: false)
		mode = .glided(display)
		pendingGlideAccept = true
		let displayedAlternatives = alternatives.map {
			KBWordCase.sentenceDisplay($0, capitalized: autoShift)
		}
		setGlideSuggestionBar(winner: display, alternatives: displayedAlternatives)
		updateAutoShift()
		maybeRescorePreviousWord()
	}

	private func beginGlidePreview() {
		// Starting another deliberate gesture means the previous glided word stood. Apply
		// that supervised profile update before the first preview so sigma/gate remain
		// unchanged between this gesture's live rankings and its release-time ranking.
		resolveGlideAccepted()
		invalidateSuggestionRequests(cancelEngineWork: true)
		glidePreviewGeneration &+= 1
		pendingGlidePreview = nil
		engine.cancelGlidePreviews()
		guard hostConnectionReady, !isSecureField else {
			glidePreviewEnabled = false
			activeGlideDocumentContext = nil
			activeGlideContext.removeAll(keepingCapacity: true)
			activeGlideAutoShift = false
			keyboard?.setGlidePreview(nil)
			return
		}
		glidePreviewEnabled = true
		let before = textDocumentProxy.documentContextBeforeInput ?? ""
		activeGlideDocumentContext = before
		activeGlideContext = contextWords(before, max: 8)
		activeGlideAutoShift = shouldAutoShift(before)
	}

	private func handleGlidePreview(_ path: [CGPoint], _ times: [TimeInterval], _ layout: GlideLayout) {
		guard glidePreviewEnabled else { return }
		glidePreviewSequence &+= 1
		pendingGlidePreview = GlidePreviewRequest(
			path: path,
			times: times,
			layout: layout,
			sequence: glidePreviewSequence
		)
		startNextGlidePreviewIfNeeded()
	}

	private func startNextGlidePreviewIfNeeded() {
		guard !glidePreviewInFlight, let request = pendingGlidePreview else { return }
		pendingGlidePreview = nil
		glidePreviewInFlight = true
		let generation = glidePreviewGeneration
		let capitalize = activeGlideAutoShift
		engine.glidePreview(path: request.path, times: request.times, layout: request.layout,
							context: activeGlideContext) { [weak self] prediction in
			guard let self else { return }
			self.glidePreviewInFlight = false
			guard generation == self.glidePreviewGeneration else {
				self.startNextGlidePreviewIfNeeded()
				return
			}
			// A newer path snapshot may have arrived while this decode was running.
			// Never flash the older winner; move directly to the newest queued path.
			if request.sequence == self.glidePreviewSequence, let prediction {
				let word = KBWordCase.sentenceDisplay(prediction.word, capitalized: capitalize)
				self.keyboard?.setGlidePreview(word)
			} else if request.sequence == self.glidePreviewSequence {
				self.keyboard?.setGlidePreview(nil)
			}
			self.startNextGlidePreviewIfNeeded()
		}
	}

	private func cancelGlidePreview(clearStrip: Bool) {
		glidePreviewGeneration &+= 1
		glidePreviewSequence &+= 1
		pendingGlidePreview = nil
		engine.cancelGlidePreviews()
		activeGlideDocumentContext = nil
		activeGlideContext.removeAll(keepingCapacity: true)
		activeGlideAutoShift = false
		glidePreviewEnabled = false
		if clearStrip { keyboard?.setGlidePreview(nil) }
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
		generation &+= 1
		let requestGeneration = generation
		let work = DispatchWorkItem { [weak self] in
			self?.refreshSuggestions(requestGeneration: requestGeneration)
		}
		suggestWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
	}

	private func invalidateSuggestionRequests(cancelEngineWork: Bool = false) {
		suggestWork?.cancel()
		suggestWork = nil
		generation &+= 1
		if cancelEngineWork { engine.cancelSuggestions() }
	}

	private func refreshSuggestions(requestGeneration: Int) {
		guard requestGeneration == generation else { return }
		guard suggestionsAllowed else { setSuggestionBar([]); return }
		let gen = requestGeneration
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
		suggestionPresentation = .ranked(words: suggestions, prefix: typedPrefix)
		keyboard?.setSuggestions(suggestions, typedPrefix: typedPrefix)
	}

	private func setGlideSuggestionBar(winner: String, alternatives: [String]) {
		suggestionPresentation = .glide(winner: winner, alternatives: alternatives)
		keyboard?.setGlideResult(winner, alternatives: alternatives)
	}

	private func applySuggestionPresentation(to keyboard: KeyboardView) {
		switch suggestionPresentation {
		case .ranked(let words, let prefix):
			keyboard.setSuggestions(words, typedPrefix: prefix)
		case .glide(let winner, let alternatives):
			keyboard.setGlideResult(winner, alternatives: alternatives)
		}
	}

	private func uniqueWords(_ words: [String], excluding excluded: String) -> [String] {
		var seen = Set([excluded.lowercased()])
		return words.filter { seen.insert($0.lowercased()).inserted }
	}

	// MARK: Word parsing on the text before the cursor

	/// Hosts with smart punctuation (the iOS default in most text views) transform the
	/// ASCII apostrophe we insert into U+2019 (') in the stored text. Without accepting
	/// it here, every contraction fragments at the quote — "what's" parses as "s" —
	/// so autocorrect judges fragments and learn() adopts them into suggestions.
	private func isWordChar(_ c: Character) -> Bool {
		c.isLetter || c == "'" || c == "\u{2019}" || c == "\u{02BC}"
	}
	/// Canonical form for the engine: the lexicon, n-grams, and tokenizer all store
	/// ASCII apostrophes. One-to-one per Character, so parsed word lengths (and the
	/// deleteBackward counts derived from them) are unchanged.
	private func canonical(_ c: Character) -> Character {
		(c == "\u{2019}" || c == "\u{02BC}") ? "'" : c
	}

	private func trailingWord(_ s: String) -> String {
		var w = ""
		for c in s.reversed() { if isWordChar(c) { w.insert(canonical(c), at: w.startIndex) } else { break } }
		return w
	}

	private func lastCompleteWord(_ s: String) -> String? {
		var chars = Array(s)
		while let last = chars.last, !isWordChar(last) { chars.removeLast() }
		var w = ""
		while let last = chars.last, isWordChar(last) { w.insert(canonical(last), at: w.startIndex); chars.removeLast() }
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
			while let last = chars.last, isWordChar(last) { w.insert(canonical(last), at: w.startIndex); chars.removeLast() }
			if w.isEmpty { break }
			words.insert(w, at: 0)
		}
		return words
	}
}
