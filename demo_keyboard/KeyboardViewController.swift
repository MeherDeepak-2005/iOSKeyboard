import UIKit

// Letter-key path = insertText first. Decoding is asynchronous and publishes one
// versioned snapshot that owns both the suggestion strip and boundary correction.

final class KeyboardViewController: UIInputViewController {

	private var keyboard: KeyboardView!
	private var heightConstraint: NSLayoutConstraint?
	private let engine = KeyboardEngine.shared   // process-wide: see KeyboardEngine.shared
	private var personalDataResetObserver: KBPersonalDataResetObserver?
	private var configurationObserver: KBConfigurationObserver?
	private var accessibilityObservers: [NSObjectProtocol] = []

	private enum Mode { case predict, complete(String), revert(String), glided(String) }
	private var mode: Mode = .predict
	private var generation: UInt64 = 0
	private var fieldRevision: UInt64 = 0
	private var documentRevision: UInt64 = 0
	private var wordSessionID: UInt64 = 0
	private var layoutRevision: UInt64 = 0
	private var fieldInputKind: KeyboardInputKind = .standard
	private var configuredLanguageMode: KBLanguageMode = .english
	/// Resolved only at controller/configuration boundaries. The key path reads this
	/// Boolean and never hashes a pack or waits on the health cache lock.
	private var configuredLanguageModeAvailable = true
	/// Neural packages are promotion-gated; the shipped tier is selected only here,
	/// between words, and remains fixed until `wordSessionID` advances.
	private var wordSessionModelTier: DecodeModelTier = .ngram
	private var decodeSnapshot: DecodeSnapshot?
	private var presentedDecodeSnapshot: PresentedDecodeSnapshot?
	private var currentWordBuffer = ""
	private var currentContextBuffer: [String] = []
	private var suggestionModeResolved = false
	private var suggestionsVisible = true
	private var hostConnectionReady = false
	private var supplementaryLexiconRequested = false
	private enum SuggestionPresentation {
		case ranked(words: [String], prefix: String?, highlightPrimary: Bool)
		case glide(winner: String, alternatives: [String])
		case paste
	}
	private var suggestionPresentation = SuggestionPresentation.ranked(words: [], prefix: nil, highlightPrimary: false)
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
	private var activeGlideSessionID: GlideSessionID?
	private var glidePreviewEnabled = false
	/// The exact prediction currently visible in the middle suggestion slot. If this
	/// exists at lift, it is the commit authority; the user never sees one word and
	/// receives another from a second release-time decode.
	private struct DisplayedGlidePrediction {
		let prediction: GlidePrediction
		let sessionID: GlideSessionID
		let revision: UInt64
		let pointCount: Int
		let endpoint: CGPoint
		let pitch: CGFloat
	}
	private var displayedGlidePrediction: DisplayedGlidePrediction?

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

	/// A glided word is awaiting an explicit verdict. Typing on is intentionally
	/// unlabelled: only selecting an alternative is safe supervision for adaptation.
	private var pendingGlideVerdict = false
	/// Progress is provisional until the user either continues or leaves the field.
	/// An immediate whole-word Backspace cancels it, so leagues never reward a
	/// rejected Glide result.
	private var pendingGlideStatsID: UUID?
	/// Original host context for the most recent Telugu key. Long-press alternatives
	/// replace the already-committed base output against this exact context, preserving
	/// a conjunct or dependent sign instead of deleting its leading consonant.
	private var lastTeluguKeyContext: String?

	/// Resolved only after the host connection is live. Calling
	/// `needsInputModeSwitchKey` during extension prewarming produces an inaccurate result
	/// and a UIKit warning; until then, omit the key and rebuild once if iOS requires it.
	private var showsGlobe = false

	private let boundary = CharacterSet(charactersIn: " .,!?;:")

	override func viewDidLoad() {
		super.viewDidLoad()
		refreshConfiguredLanguageMode()
		view.backgroundColor = .clear
		view.isOpaque = false
		view.layer.isOpaque = false
		inputView?.backgroundColor = .clear
		inputView?.isOpaque = false
		buildKeyboard()
		personalDataResetObserver = KBPersonalDataResetObserver { [weak self] epoch in
			guard let self else { return }
			self.engine.resetPersonalization(to: epoch)
			DispatchQueue.main.async { [weak self] in self?.handlePersonalDataReset() }
		}
		configurationObserver = KBConfigurationObserver { [weak self] in
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				if self.refreshConfiguredLanguageMode() {
					self.invalidateDocumentSession()
				}
				self.buildKeyboard()
				if self.hostConnectionReady { self.scheduleSuggestions() }
			}
		}

		// Follow the host app's light/dark appearance and rebuild on changes.
		registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
			self.buildKeyboard()
			if self.hostConnectionReady { self.scheduleSuggestions() }
		}
		let accessibilityNotifications: [Notification.Name] = [
			UIAccessibility.boldTextStatusDidChangeNotification,
			UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
			UIAccessibility.differentiateWithoutColorDidChangeNotification,
			UIAccessibility.reduceTransparencyStatusDidChangeNotification,
			UIAccessibility.reduceMotionStatusDidChangeNotification,
		]
		for name in accessibilityNotifications {
			accessibilityObservers.append(NotificationCenter.default.addObserver(
				forName: name, object: nil, queue: .main) { [weak self] _ in
					guard let self else { return }
					self.buildKeyboard()
					if self.hostConnectionReady { self.scheduleSuggestions() }
				})
		}
	}

	deinit {
		for observer in accessibilityObservers { NotificationCenter.default.removeObserver(observer) }
	}

	private func handlePersonalDataReset() {
		KBStats.synchronizeAfterExternalReset()
		invalidateSuggestionRequests(cancelEngineWork: true)
		cancelGlidePreview(clearStrip: true)
		lastCorrection = nil
		recentCorrections.removeAll(keepingCapacity: false)
		wordTaps.removeAll(keepingCapacity: false)
		pendingGlideVerdict = false
		KBStats.cancel(pendingGlideStatsID)
		pendingGlideStatsID = nil
		cursorModeActive = false
		resetEraseTracking()
		mode = .predict
		suggestionPresentation = .ranked(words: [], prefix: nil, highlightPrimary: false)
		applySuggestionPresentation(to: keyboard)
		if hostConnectionReady { scheduleSuggestions() }
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
		view.isOpaque = false
		view.layer.isOpaque = false
		inputView?.backgroundColor = .clear
		inputView?.isOpaque = false

		let kb = KeyboardView(theme: theme, showsGlobe: showsGlobe,
			languageMode: activeLanguageMode)
		// A prewarmed extension has no reliable text proxy yet. Exposing those keys lets
		// an immediate tap race the one-time globe/trait rebuild and silently disappear.
		kb.isUserInteractionEnabled = hostConnectionReady
		kb.accessibilityElementsHidden = !hostConnectionReady
		kb.hapticsEnabled   = KBSettings.haptics
		kb.glideEnabled     = activeLanguageMode == .english
		kb.onInsert         = { [weak self] ch, tap in self?.handleInsert(ch, tap: tap) }
		kb.onKeyOutput      = { [weak self] output, tap in self?.handleKeyOutput(output, tap: tap) }
		kb.onReplaceLastInput = { [weak self] base, replacement in
			self?.handleReplaceLastInput(base: base, with: replacement)
		}
		kb.onDelete         = { [weak self] in self?.handleDelete() }
		kb.onReturn         = { [weak self] in self?.handleReturn() }
		kb.onCursorModeBegan = { [weak self] in self?.beginCursorMode() }
		kb.onCursorMove     = { [weak self] in self?.moveCursor(by: $0) }
		kb.onCursorModeEnded = { [weak self] in self?.endCursorMode() }
		kb.onNextKeyboard   = { [weak self] in self?.advanceToNextInputMode() }
		kb.onInputModeEvent = { [weak self] sender, event in
			self?.handleInputModeList(from: sender, with: event)
		}
		kb.onPickSuggestion = { [weak self] in self?.handlePick($0) }
		kb.onOpenMedia = { [weak self, weak kb] kind in
			guard let self, let kb, self.keyboard === kb else { return }
			kb.showMedia(kind: kind, hasFullAccess: self.hasFullAccess)
		}
		kb.onOpenClipboard = { [weak self, weak kb] in
			guard let self, let kb, self.keyboard === kb else { return }
			self.captureClipboardIfNeeded()
			kb.showClipboard(hasFullAccess: self.hasFullAccess)
		}
		kb.onClipboardPick = { [weak self] in self?.handleClipboardPick($0) }
		kb.onPaste = { [weak self] in self?.handlePasteChip() }
		kb.onGlideBegan     = { [weak self] in self?.beginGlidePreview() }
		kb.onGlidePreview   = { [weak self] path, times, layout in
			self?.handleGlidePreview(path, times, layout)
		}
		kb.onGlideCancelled = { [weak self] in self?.cancelGlidePreview(clearStrip: true) }
		kb.onGlide          = { [weak self] path, times, layout in self?.handleGlide(path, times, layout) }
		// Emoji search swaps the strip for a taller header. The `keyboard === kb` guard matters:
		// buildKeyboard() (theme/globe change) replaces the view AND the constraint, so
		// a stale view firing this would size the CURRENT constraint from a DEAD view's
		// page — e.g. an expanded emoji height under a letters deck, which reads as a
		// tall keyboard with dead space beneath the keys.
		kb.onHeightChange   = { [weak self, weak kb] in
			guard let self, let kb, self.keyboard === kb else { return }
			self.heightConstraint?.constant = kb.keyboardHeight
		}
		kb.onGeometryChange = { [weak self] in
			guard let self else { return }
			self.layoutRevision &+= 1
			self.invalidateSuggestionRequests(cancelEngineWork: true)
			if self.hostConnectionReady { self.scheduleSuggestions() }
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
		kb.setInputKind(fieldInputKind)
		kb.prepareHaptics()
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
		hostConnectionReady = false
		if refreshConfiguredLanguageMode() { buildKeyboard() }
		keyboard?.isUserInteractionEnabled = false
		keyboard?.accessibilityElementsHidden = true
		view.backgroundColor = .clear
		view.isOpaque = false
		inputView?.backgroundColor = .clear
		inputView?.isOpaque = false
		keyboard?.hapticsEnabled = KBSettings.haptics
		suggestionModeResolved = false
		suggestionsVisible = true
		keyboard?.setShowsSuggestions(true)
		if fieldInputKind != .standard {
			fieldInputKind = .standard
			layoutRevision &+= 1
			keyboard?.setInputKind(.standard)
		}
		keyboard?.glideEnabled = activeLanguageMode == .english
		if let keyboard { heightConstraint?.constant = keyboard.keyboardHeight }
		invalidateDocumentSession()
		resetEraseTracking()           // a new field/host — stale erase state is meaningless
		wordTaps.removeAll(keepingCapacity: true)
		KBStats.confirm(pendingGlideStatsID)
		pendingGlideStatsID = nil
		pendingGlideVerdict = false
		cursorModeActive = false
		// Host field properties are still unreliable here. The first text-input callback
		// resolves the strip and globe after the extension-host connection is live.
		keyboard?.prepareHaptics()     // prime the engine so the first tap isn't delayed
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		hostConnectionReady = false
		keyboard?.isUserInteractionEnabled = false
		keyboard?.accessibilityElementsHidden = true
		KBStats.confirm(pendingGlideStatsID)
		pendingGlideStatsID = nil
		KBStats.flush()
		KBDiagnostics.recorder.flush()
	}

	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
		KBDiagnostics.recorder.memoryPressure(critical: false)
		keyboard?.releaseTransientMediaForMemoryPressure()
		KBMediaCache.purge()
		engine.handleMemoryPressure()
	}

	override func textDidChange(_ textInput: UITextInput?) {
		super.textDidChange(textInput)
		let firstConnection = hostConnectionDidBecomeAvailable()
		let traitsChanged = updateInputTraits()
		let userTouch = isUserDocumentTouch
		if traitsChanged || userTouch { invalidateDocumentSession() }
		if firstConnection || traitsChanged || userTouch { scheduleSuggestions() }
		updateActionKey()
		updateAutoShift()              // cursor moved / host cleared the field
		snapBackFromOverlaysIfUserTouched()
	}

	override func selectionDidChange(_ textInput: UITextInput?) {
		super.selectionDidChange(textInput)
		let firstConnection = hostConnectionDidBecomeAvailable()
		let traitsChanged = updateInputTraits()
		let userTouch = isUserDocumentTouch
		if traitsChanged || userTouch { invalidateDocumentSession() }
		if firstConnection || traitsChanged || userTouch { scheduleSuggestions() }
		snapBackFromOverlaysIfUserTouched()
	}

	/// UIInputViewController can be prewarmed without a live host connection, so proxy
	/// reads and prediction work start only after the host invokes an input callback.
	@discardableResult
	private func hostConnectionDidBecomeAvailable() -> Bool {
		let firstConnection = !hostConnectionReady
		if firstConnection {
			hostConnectionReady = true
			KBSettings.markKeyboardObserved(fullAccess: hasFullAccess)
			let requiresSwitchKey = needsInputModeSwitchKey
			if showsGlobe != requiresSwitchKey {
				showsGlobe = requiresSwitchKey
				buildKeyboard()
			}
		}
		keyboard?.isUserInteractionEnabled = true
		keyboard?.accessibilityElementsHidden = false
		resolveSuggestionModeIfNeeded()

		if !supplementaryLexiconRequested {
			supplementaryLexiconRequested = true
			requestSupplementaryLexicon { [weak self] lexicon in
				self?.engine.importSupplementaryLexicon(lexicon.entries.map(\.documentText))
			}
		}
		if firstConnection {
			updateActionKey()
			updateAutoShift()
		}
		return firstConnection
	}

	/// Tapping the input field (or otherwise moving the cursor by hand) while the emoji
	/// page or emoji search is up returns to the letter deck — stock
	/// behavior. Guarded by the proxy-edit timestamp so our own inserts/deletes never
	/// trigger it.
	private func snapBackFromOverlaysIfUserTouched() {
		guard isUserDocumentTouch, keyboard?.dismissOverlaysIfActive() == true else { return }
		scheduleSuggestions()          // the bar is live again — refill it for the new context
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
		let automatic = textDocumentProxy.enablesReturnKeyAutomatically ?? false
		keyboard?.setActionEnabled(!automatic || textDocumentProxy.hasText)
	}

	@discardableResult
	private func updateInputTraits() -> Bool {
		let kind: KeyboardInputKind
		switch textDocumentProxy.keyboardType ?? .default {
		case .emailAddress: kind = .email
		case .URL: kind = .url
		case .webSearch: kind = .webSearch
		case .twitter: kind = .twitter
		case .numbersAndPunctuation: kind = .numbersAndPunctuation
		case .numberPad, .asciiCapableNumberPad: kind = .numberPad
		case .decimalPad: kind = .decimalPad
		case .phonePad: kind = .phonePad
		default: kind = .standard
		}
		guard kind != fieldInputKind else { return false }
		fieldInputKind = kind
		layoutRevision &+= 1
		keyboard?.setInputKind(kind)
		keyboard?.glideEnabled = activeLanguageMode == .english
		return true
	}

	/// Tenglish is a prose mode. Host traits take precedence so a user's language
	/// preference can never transliterate an email address, URL, handle, or number.
	private var activeLanguageMode: KBLanguageMode {
		guard configuredLanguageModeAvailable, !isSecureField else { return .english }
		switch fieldInputKind {
		case .standard, .webSearch:
			return configuredLanguageMode
		case .email, .url, .twitter, .numbersAndPunctuation,
			 .numberPad, .decimalPad, .phonePad:
			return .english
		}
	}

	/// Preserve the durable preference while resolving a safe mode for this extension
	/// session. This may hash language resources, so callers are deliberately limited to
	/// lifecycle/configuration callbacks rather than key handlers.
	@discardableResult
	private func refreshConfiguredLanguageMode() -> Bool {
		let preferred = KBSettings.preferredLanguageMode
		let available = preferred.isRuntimeAvailable
		let changed = preferred != configuredLanguageMode
			|| available != configuredLanguageModeAvailable
		configuredLanguageMode = preferred
		configuredLanguageModeAvailable = available
		return changed
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
		if let c = lastCorrection, c.fromAutocorrect, activeLanguageMode == .english {
			engine.correctionStood(c.original)
		}
	}

	/// Moving on does not establish intent. Drop the pending sample without adapting.
	private func resolveGlideUnverified() {
		if pendingGlideVerdict { pendingGlideVerdict = false; engine.glideUnverified() }
		KBStats.confirm(pendingGlideStatsID)
		pendingGlideStatsID = nil
	}

	private func learnCommittedWord(context: [String], word: String) {
		guard activeLanguageMode == .english else { return }
		engine.learn(context: context, word: word)
	}

	private func recordReplacement(original: String, replacement: String) {
		guard activeLanguageMode == .english else { return }
		engine.wordReplaced(original: original, with: replacement)
	}

	private func rejectCorrection(_ word: String) {
		guard activeLanguageMode == .english else { return }
		engine.dontCorrect(word)
	}

	/// Timestamp of the last plain space, for the double-space → ". " shortcut.
	private var lastSpaceAt: TimeInterval = 0

	/// Uptime of the last edit WE made through the proxy. textDidChange /
	/// selectionDidChange arriving without a recent programmatic edit means the user
	/// touched the document directly (tapped the input field, moved the cursor) —
	/// the signal that snaps the emoji page / emoji search back to the letter deck.
	private var lastProxyEditAt: TimeInterval = 0
	private func noteProxyEdit() {
		lastProxyEditAt = ProcessInfo.processInfo.systemUptime
		documentRevision &+= 1
		generation &+= 1
		decodeSnapshot = nil
		presentedDecodeSnapshot = nil
		keyboard?.setKeyPriors([:])
	}

	/// Model selection happens only here, between words. The selected tier is then
	/// copied into every DecodeRequest until the next session boundary.
	private func advanceWordSession() {
		let finishedSession = wordSessionID
		wordSessionID &+= 1
		engine.discardModelSession(finishedSession)
		wordSessionModelTier = engine.preferredModelTier(for: activeLanguageMode)
	}

	@inline(__always)
	private func insertIntoHost(_ text: String) {
		#if DEBUG || INTERNAL_NEURAL
		let started = ProcessInfo.processInfo.systemUptime
		let signpost = KBDiagnostics.beginHostInsert()
		textDocumentProxy.insertText(text)
		KBDiagnostics.endHostInsert(signpost,
			milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
		#else
		// Shipping key path: no clocks, signposts, locks, dispatches, or model work
		// before the host edit.
		textDocumentProxy.insertText(text)
		#endif
	}

	/// Replaces an exact suffix without assuming that UIKit and Swift use the same
	/// deletion unit for Indic text. This is intentionally reserved for explicit
	/// correction/pick transactions, never the ordinary letter insertion path.
	@discardableResult
	private func replaceHostSuffix(_ suffix: String, with replacement: String) -> Bool {
		guard let initial = textDocumentProxy.documentContextBeforeInput,
			let plan = HostSuffixReplacementPlan(contextBeforeInput: initial,
				suffix: suffix, replacement: replacement) else { return false }
		var context = initial
		for _ in 0...plan.maximumDeleteCount {
			switch plan.state(for: context) {
			case .readyToInsert:
				if !plan.replacement.isEmpty { insertIntoHost(plan.replacement) }
				return true
			case .invalid:
				return false
			case .deleteBackward:
				textDocumentProxy.deleteBackward()
				guard let updated = textDocumentProxy.documentContextBeforeInput,
					updated != context else { return false }
				context = updated
			}
		}
		return false
	}

	// MARK: Clipboard — capture on panel open, insert from saved history

	/// Capture the current system pasteboard into history. Called ONLY when the user
	/// opens the clipboard panel — a deliberate action, so iOS's one "pasted from" notice
	/// reads as expected (there is no banner-free way to read arbitrary text; `changeCount`
	/// dedupe means at most one read per distinct copy). We never read on the type path,
	/// so copying elsewhere raises no banner and never stalls layout.
	///
	/// Hardening over afda5b4 (Improvements.md P0 §3): (1) never capture while a secure
	/// field is focused — password managers paste into those; (2) advance
	/// `consumedChangeCount` only AFTER a confirmed non-empty read, so a transient read
	/// failure retries on the next open instead of silently dropping the copy (the old
	/// code consumed first). Sensitive-content rejection (OTP / card numbers) and the
	/// retention TTL live in `KBClipboard.add`.
	private func captureClipboardIfNeeded() {
		guard hasFullAccess, !isSecureField else { return }
		let pb = UIPasteboard.general
		let count = pb.changeCount
		guard count != KBClipboard.consumedChangeCount else { return }
		guard pb.hasStrings else { KBClipboard.consumedChangeCount = count; return }
		guard let text = pb.string,
			  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		KBClipboard.consumedChangeCount = count      // only after a confirmed read
		KBClipboard.add(text)
	}

	/// Should the strip show a "Paste" offer? True when the field is empty (the user
	/// just cleared it or focused a blank field) and there is unconsumed clipboard text
	/// — the "copied, then deleted it" moment. Uses METADATA only (changeCount /
	/// hasStrings), so deciding to show the offer never fires iOS's paste banner; the
	/// contents are read only when the offer is tapped (handlePasteChip).
	private func offersPaste() -> Bool {
		guard hasFullAccess, !isSecureField, suggestionsAllowed else { return false }
		let before = textDocumentProxy.documentContextBeforeInput ?? ""
		guard before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
		let pb = UIPasteboard.general
		return pb.hasStrings && pb.changeCount != KBClipboard.consumedChangeCount
	}

	/// The "Paste" offer was tapped — the ONE deliberate pasteboard read (one banner).
	/// Marks the change consumed (so the offer does not re-appear for the same copy) and
	/// saves it to history, then inserts like any clipboard pick.
	private func handlePasteChip() {
		guard hasFullAccess, !isSecureField else { return }
		let pb = UIPasteboard.general
		guard pb.hasStrings, let text = pb.string,
			  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		KBClipboard.consumedChangeCount = pb.changeCount
		KBClipboard.add(text)
		handleClipboardPick(text)
		scheduleSuggestions()
	}

	/// A history row from the clipboard panel. Inserts and stays on the panel
	/// (multi-paste, Gboard-style). Never learned — clips aren't typing.
	private func handleClipboardPick(_ text: String) {
		noteProxyEdit()
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		resetEraseTracking()
		wordTaps.removeAll(keepingCapacity: true)
		insertIntoHost(text)
		lastCorrection = nil
		updateAutoShift()
	}

	private func invalidateDocumentSession() {
		fieldRevision &+= 1
		documentRevision &+= 1
		advanceWordSession()
		decodeSnapshot = nil
		presentedDecodeSnapshot = nil
		currentWordBuffer = ""
		currentContextBuffer.removeAll(keepingCapacity: true)
		wordTaps.removeAll(keepingCapacity: true)
		generation &+= 1
		engine.cancelSuggestions()
	}

	/// True when a document change arrived that we didn't cause. The 0.5 s window
	/// absorbs the host's async delivery of our own inserts/deletes.
	private var isUserDocumentTouch: Bool {
		ProcessInfo.processInfo.systemUptime - lastProxyEditAt > 0.5
	}

	private func handleInsert(_ ch: String, tap: KeyTap? = nil) {
		lastTeluguKeyContext = nil
		if ch.count == 1, let c = ch.first, isWordChar(c) {
			let wasInsideWord = !currentWordBuffer.isEmpty
			// Hot path: the host edit is the first meaningful operation. Everything
			// else is post-insert bookkeeping and asynchronous decode scheduling.
			insertIntoHost(ch)
			noteProxyEdit()
			wordTaps.append(tap)
			currentWordBuffer.append(c)
			trackReplacementStart(wasInsideWord: wasInsideWord)
			let acceptedCorrection = lastCorrection
			let unresolvedGlide = pendingGlideVerdict
			let acceptedGlideStatsID = pendingGlideStatsID
			lastCorrection = nil
			pendingGlideVerdict = false
			pendingGlideStatsID = nil
			let revision = documentRevision
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				if let acceptedCorrection, acceptedCorrection.fromAutocorrect,
				   self.activeLanguageMode == .english {
					self.engine.correctionStood(acceptedCorrection.original)
				}
				if unresolvedGlide { self.engine.glideUnverified() }
				KBStats.confirm(acceptedGlideStatsID)
				guard revision == self.documentRevision else { return }
				self.updateAutoShift()
				self.scheduleSuggestions()
			}
			return
		}

		resolveCorrectionAsAccepted()
		resolveGlideUnverified()

		// Double-space → period + space (stock shortcut). Only after a word, only in
		// normal prose fields, only within the double-tap window.
		if ch == " " {
			let now = ProcessInfo.processInfo.systemUptime
			if now - lastSpaceAt < 0.6 {
				let before = textDocumentProxy.documentContextBeforeInput ?? ""
				if before.hasSuffix(" "), let prev = before.dropLast().last,
				   isWordChar(prev), suggestionsAllowed {
					textDocumentProxy.deleteBackward()
					insertIntoHost(". ")
					noteProxyEdit()
					advanceWordSession()
					wordTaps.removeAll(keepingCapacity: true)
					lastCorrection = nil
					lastSpaceAt = 0
					resetEraseTracking()
					updateAutoShift()
					scheduleSuggestions()
					return
				}
			}
			lastSpaceAt = now
		}

		if ch.count == 1, let u = ch.unicodeScalars.first, boundary.contains(u) {
			// Must run BEFORE autocorrect: a manual revert (erased our correction, retyped
			// the original) registers a rejection synchronously (dontCorrect → stateLock), so
			// the very commit that completes the revert is already exempt from re-correction.
			let typedWord = currentWordBuffer
			let decodeContext = currentDecodeSnapshot?.request.context ?? currentContextBuffer
			resolveManualFix(typedWord)
			var correction = applyAutocorrectIfNeeded()
			if correction == nil, activeLanguageMode == .english {
				engine.learnTouchProfile(word: typedWord, taps: wordTaps)
			}
			let committedWord = correction?.corrected ?? typedWord
			// Never learn from secure fields — password fragments must not enter the
			// persisted personal model. (Stats ride the same gate: password words
			// shouldn't count toward streaks either.)
			if !committedWord.isEmpty, !isSecureField {
				learnCommittedWord(context: decodeContext, word: committedWord)
				KBStats.noteCommitted(glided: false)
			}
			// Punctuation right after an auto-inserted space: delete the space first
			// so punctuation lands directly after the word ("word." not "word .").
			// Only when the space was ours (lastCorrection?.trailing) — never touches
			// a space the user explicitly typed.
			if ch != " ", ch != "\n", lastCorrection?.trailing == " " {
				textDocumentProxy.deleteBackward()
			}
			insertIntoHost(ch)
			noteProxyEdit()
			correction?.trailing = ch
			lastCorrection = correction
			advanceWordSession()
			wordTaps.removeAll(keepingCapacity: true)
			currentWordBuffer = ""
		} else {
			lastCorrection = nil
			insertIntoHost(ch)
			noteProxyEdit()
			advanceWordSession()
			wordTaps.removeAll(keepingCapacity: true)
			currentWordBuffer = ""
		}
		updateAutoShift()
		scheduleSuggestions()
	}

	private func handleKeyOutput(_ output: KeyOutput, tap: KeyTap?) {
		if case .text(let text) = output {
			handleInsert(text, tap: tap)
			return
		}
		guard activeLanguageMode == .telugu, !isSecureField else { return }
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		let before = textDocumentProxy.documentContextBeforeInput ?? ""
		let edit = TeluguComposer.edit(for: output, contextBeforeInput: before)
		guard edit.deleteBackwardCount > 0 || !edit.insertion.isEmpty else { return }
		for _ in 0..<edit.deleteBackwardCount { textDocumentProxy.deleteBackward() }
		if !edit.insertion.isEmpty { insertIntoHost(edit.insertion) }
		noteProxyEdit()
		lastTeluguKeyContext = before
		lastCorrection = nil
		wordTaps.removeAll(keepingCapacity: true)
		currentWordBuffer = trailingWord(applying: edit, to: before)
		updateAutoShift()
		scheduleSuggestions()
	}

	private func trailingWord(applying edit: TeluguHostEdit, to context: String) -> String {
		var simulated = context
		for _ in 0..<edit.deleteBackwardCount where !simulated.isEmpty { simulated.removeLast() }
		simulated.append(contentsOf: edit.insertion)
		return trailingWord(simulated)
	}

	/// Long-press alternatives replace the base glyph that was already inserted on
	/// touch-down. Keep the host edit first, then revise local touch/decode identity.
	private func handleReplaceLastInput(base: String, with replacement: String) {
		guard !replacement.isEmpty else { return }
		if activeLanguageMode == .telugu, let originalContext = lastTeluguKeyContext {
			let normalizedBase = TeluguComposer.normalized(base)
			let normalizedReplacement = TeluguComposer.normalized(replacement)
			let baseScalars = Array(normalizedBase.unicodeScalars)
			let replacementScalars = Array(normalizedReplacement.unicodeScalars)
			if replacementScalars.starts(with: baseScalars) {
				let suffix = replacementScalars.dropFirst(baseScalars.count)
					.map(String.init).joined()
				if !suffix.isEmpty { insertIntoHost(suffix) }
			} else {
				// Pack-defined replacements that are not base+suffix are restricted to
				// standalone keys (for example Latin/Telugu digits).
				textDocumentProxy.deleteBackward()
				insertIntoHost(normalizedReplacement)
			}
			noteProxyEdit()
			currentWordBuffer = trailingWord(originalContext + normalizedReplacement)
			wordTaps.removeAll(keepingCapacity: true)
			lastCorrection = nil
			updateAutoShift()
			scheduleSuggestions()
			return
		}
		textDocumentProxy.deleteBackward()
		insertIntoHost(replacement)
		noteProxyEdit()
		if !currentWordBuffer.isEmpty,
		   replacement.allSatisfy({ isWordChar($0) }) {
			currentWordBuffer.removeLast()
			currentWordBuffer.append(contentsOf: replacement.map(canonical))
			if !wordTaps.isEmpty { wordTaps.removeLast() }
			wordTaps.append(nil)
		} else {
			currentWordBuffer = ""
			wordTaps.removeAll(keepingCapacity: true)
		}
		lastCorrection = nil
		updateAutoShift()
		scheduleSuggestions()
	}

	private var cursorModeActive = false

	/// Space was inserted immediately on touch-down. Once the hold threshold wins,
	/// retract only that provisional space and freeze decoding until movement ends.
	private func beginCursorMode() {
		guard !cursorModeActive else { return }
		cursorModeActive = true
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		lastCorrection = nil
		if textDocumentProxy.documentContextBeforeInput?.hasSuffix(" ") == true {
			textDocumentProxy.deleteBackward()
			noteProxyEdit()
		}
		advanceWordSession()
		currentWordBuffer = ""
		currentContextBuffer.removeAll(keepingCapacity: true)
		wordTaps.removeAll(keepingCapacity: true)
		resetEraseTracking()
		invalidateSuggestionRequests(cancelEngineWork: true)
		setSuggestionBar([])
	}

	private func moveCursor(by offset: Int) {
		guard cursorModeActive, offset != 0 else { return }
		textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
		noteProxyEdit()
	}

	private func endCursorMode() {
		guard cursorModeActive else { return }
		cursorModeActive = false
		advanceWordSession()
		updateAutoShift()
		scheduleSuggestions()
	}

	private func handleReturn() {
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		let typedWord = currentWordBuffer
		let decodeContext = currentDecodeSnapshot?.request.context ?? currentContextBuffer
		resolveManualFix(typedWord)
		var correction = applyAutocorrectIfNeeded()
		if correction == nil, activeLanguageMode == .english {
			engine.learnTouchProfile(word: typedWord, taps: wordTaps)
		}
		let committedWord = correction?.corrected ?? typedWord
		if !committedWord.isEmpty, !isSecureField {
			learnCommittedWord(context: decodeContext, word: committedWord)
			KBStats.noteCommitted(glided: false)
		}
		insertIntoHost("\n")
		noteProxyEdit()
		correction?.trailing = "\n"
		lastCorrection = correction
		advanceWordSession()
		wordTaps.removeAll(keepingCapacity: true)
		currentWordBuffer = ""
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
				if pendingGlideVerdict {
					pendingGlideVerdict = false
					engine.glideRejected()
					KBStats.cancel(pendingGlideStatsID)
					pendingGlideStatsID = nil
				}
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
			if pendingGlideVerdict, c.original.isEmpty, !c.fromAutocorrect {
				pendingGlideVerdict = false
				engine.glideRejected()
				KBStats.cancel(pendingGlideStatsID)
				pendingGlideStatsID = nil
			}
			lastCorrection = nil
			resetEraseTracking()
			wordTaps.removeAll(keepingCapacity: true)   // word rewritten — offsets no longer align
			guard replaceHostSuffix(expected, with: c.original) else {
				updateAutoShift()
				scheduleSuggestions()
				return
			}
			// Walk back the exact learned replacement for every source (autocorrect,
			// completion, or Glide). Autocorrect additionally needs a session keep so
			// the next boundary does not immediately fight the user's undo.
			if !isSecureField, !c.corrected.isEmpty {
				recordReplacement(original: c.corrected, replacement: c.original)
			}
			if c.fromAutocorrect {
				rejectCorrection(c.original)
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
				guard replaceHostSuffix(partial, with: s) else { return }
			} else {
				insertIntoHost(s)
			}
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
			guard replaceHostSuffix(partial, with: s + " ") else { return }
			learnCommittedWord(context: ctx, word: s)
			if !isSecureField { KBStats.noteCommitted(glided: false) }
			// Swapping the typed word for a different suggestion is strong evidence the
			// typed word was a mistake — lift its keep protection and walk back a use.
			// This is the "typed mjght, then picked might" healing path.
			if partial.lowercased() != s.lowercased() {
				recordReplacement(original: partial, replacement: s)
			}
			lastCorrection = Correction(original: partial, corrected: s, trailing: " ", fromAutocorrect: false)
		case .predict:
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			insertIntoHost(s + " ")
			learnCommittedWord(context: ctx, word: s)
			if !isSecureField { KBStats.noteCommitted(glided: false) }
			lastCorrection = nil        // nothing the user "typed" to revert to
		case .revert(let original):
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			if s == original, let corrected = lastCompleteWord(ctx) {
				guard replaceHostSuffix(corrected + " ", with: original + " ") else { return }
				rejectCorrection(original)
				recordReplacement(original: corrected, replacement: original)
			} else {
				insertIntoHost(s + " ")
			}
			lastCorrection = nil
		case .glided(let committed):
			// Swap the glided word for one of its shape alternatives: replace word + its
			// trailing space, learn the replacement, heal the wrong learn (Gboard-style).
			// #37: the picked alternative is the TRUE word — feed its shape cost as the
			// correct sample so the decoder learns to rank the user's real intent higher.
			if pendingGlideVerdict { pendingGlideVerdict = false; engine.glideCorrected(to: s) }
			KBStats.confirm(pendingGlideStatsID)
			pendingGlideStatsID = nil
			let oldAlternatives: [String]
			if case .glide(_, let alternatives) = suggestionPresentation {
				oldAlternatives = alternatives
			} else {
				oldAlternatives = []
			}
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			let replacement = SuggestionCasePolicy.display(s,
				sentenceStart: shouldAutoShift(textDocumentProxy.documentContextBeforeInput))
			guard replaceHostSuffix(committed + " ", with: replacement + " ") else { return }
			learnCommittedWord(context: ctx, word: s)
			if committed.lowercased() != s.lowercased() {
				recordReplacement(original: committed, replacement: s)
			}
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
		guard suggestionsAllowed, !isSecureField else { return nil }
		let snapshot: PresentedDecodeSnapshot
		if let current = currentPresentedDecodeSnapshot {
			snapshot = current
		} else {
			// A fast boundary can arrive before the asynchronous strip update. Only
			// Tenglish has a bounded synchronous fallback: one memory-mapped exact lookup.
			// English and neural work remain strictly off the host-insertion path.
			let request = makeDecodeRequest(currentWord: currentWordBuffer,
				context: currentContextBuffer, generation: generation)
			guard let canonical = engine.immediateBoundarySnapshot(request) else { return nil }
			let presented = SuggestionCasePolicy.present(canonical,
				sentenceStart: shouldAutoShift(textDocumentProxy.documentContextBeforeInput))
			decodeSnapshot = canonical
			presentedDecodeSnapshot = presented
			snapshot = presented
		}
		let word = snapshot.canonical.request.currentWord
		guard !word.isEmpty,
			  let correction = snapshot.correction,
			  correction != word else { return nil }
		for _ in 0..<word.count { textDocumentProxy.deleteBackward() }
		insertIntoHost(correction)
		noteProxyEdit()
		recentCorrections.append((original: word, corrected: correction))
		if recentCorrections.count > 4 { recentCorrections.removeFirst() }
		return Correction(original: word, corrected: correction, trailing: "", fromAutocorrect: true)
	}

	private var currentDecodeSnapshot: DecodeSnapshot? {
		guard let snapshot = decodeSnapshot else { return nil }
		let request = snapshot.request
		guard request.fieldRevision == fieldRevision,
			  request.documentRevision == documentRevision,
			  request.wordSessionID == wordSessionID,
			  request.generation == generation,
			  request.layoutRevision == layoutRevision,
			  request.currentWord == currentWordBuffer,
			  request.context == currentContextBuffer,
			  request.languageMode == activeLanguageMode,
			  request.requestedModelTier == wordSessionModelTier,
			  snapshot.modelTier == wordSessionModelTier else { return nil }
		return snapshot
	}

	private var currentPresentedDecodeSnapshot: PresentedDecodeSnapshot? {
		guard let canonical = currentDecodeSnapshot,
			  let presented = presentedDecodeSnapshot,
			  presented.canonical == canonical else { return nil }
		return presented
	}

	// MARK: Glide typing

	/// The swipe lifted: decode → rerank → commit the winner (word + trailing space, with
	/// auto-space after letters and sentence-start capitalization), learn it, and leave the
	/// runner-up shapes on the bar as one-tap swaps. A single Backspace removes the whole
	/// glided word (`Correction` with empty original). Nothing commits on a rejected swipe.
	private func handleGlide(_ path: [CGPoint], _ times: [TimeInterval], _ layout: GlideLayout) {
		let liftAt = ProcessInfo.processInfo.systemUptime
		let sessionID = activeGlideSessionID
		let publishedPrediction: GlidePrediction? = {
			guard let shown = displayedGlidePrediction,
				  shown.sessionID == sessionID,
				  path.count >= shown.pointCount,
				  let finalEndpoint = path.last else { return nil }
			var addedArc: CGFloat = 0
			let start = max(1, shown.pointCount)
			if start < path.count {
				for index in start..<path.count {
					addedArc += hypot(path[index].x - path[index - 1].x,
						path[index].y - path[index - 1].y)
				}
			}
			let endpointDelta = hypot(finalEndpoint.x - shown.endpoint.x,
				finalEndpoint.y - shown.endpoint.y)
			let materialThreshold = max(6, shown.pitch * 0.28)
			guard addedArc <= materialThreshold, endpointDelta <= materialThreshold else { return nil }
			return shown.prediction
		}()
		// Context cannot change while this finger is down. Reuse the one snapshot taken
		// when Glide began instead of making another host XPC read on lift. Never inspect
		// document text for a secure field.
		let secure = isSecureField
		let before = secure ? "" : activeGlideDocumentContext ?? textDocumentProxy.documentContextBeforeInput ?? ""
		let context = activeGlideDocumentContext == nil ? contextWords(before, max: 8) : activeGlideContext
		// Cancel any tap decode the provisional start letter triggered. The engine's
		// generation ticket also cooperatively stops a trie walk already in progress.
		invalidateSuggestionRequests(cancelEngineWork: true)
		resetEraseTracking()
		wordTaps.removeAll(keepingCapacity: true)
		guard !secure else { return }                    // no gliding passwords
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		if publishedPrediction == nil, let sessionID {
			endGlidePreviewUI(clearStrip: false, cancelEngineSession: false)
			engine.finishGlideSession(sessionID, path: path, times: times, layout: layout) {
				[weak self] word, alternatives in
				guard let self else { return }
				guard let word else { self.scheduleSuggestions(); return }
				self.commitGlidedWord(word, alternatives: alternatives, context: context,
					documentContext: before, liftAt: liftAt)
			}
			return
		}
		cancelGlidePreview(clearStrip: false)
		engine.glide(path: path, times: times, layout: layout, context: context,
			publishedPrediction: publishedPrediction) { [weak self] word, alternatives in
			guard let self else { return }
			guard let word else { self.scheduleSuggestions(); return }
			self.commitGlidedWord(word, alternatives: alternatives, context: context,
							   documentContext: before, liftAt: liftAt)
		}
	}

	private func commitGlidedWord(_ word: String, alternatives: [String], context: [String]? = nil,
							   documentContext: String? = nil, liftAt: TimeInterval) {
		let ctx = documentContext ?? textDocumentProxy.documentContextBeforeInput ?? ""
		let autoShift = shouldAutoShift(ctx)
		let display = SuggestionCasePolicy.display(word, sentenceStart: autoShift)
		var text = display + " "
		if let last = ctx.last, isWordChar(last) { text = " " + text }
		insertIntoHost(text)
		noteProxyEdit()
		KBDiagnostics.logGlideCommit(ms: (ProcessInfo.processInfo.systemUptime - liftAt) * 1_000)

		// Everything below is bookkeeping after the visible insertion.
		learnCommittedWord(context: context ?? contextWords(ctx, max: 8), word: word)
		lastCorrection = Correction(original: "", corrected: display, trailing: " ", fromAutocorrect: false)
		mode = .glided(display)
		pendingGlideVerdict = true
		KBStats.cancel(pendingGlideStatsID)
		pendingGlideStatsID = KBStats.noteProvisional(glided: true)
		let displayedAlternatives = alternatives.map {
			SuggestionCasePolicy.display($0, sentenceStart: autoShift)
		}
		setGlideSuggestionBar(winner: display, alternatives: displayedAlternatives)
		updateAutoShift()
	}

	private func beginGlidePreview() {
		// Starting another gesture leaves the previous result unlabelled.
		resolveGlideUnverified()
		invalidateSuggestionRequests(cancelEngineWork: true)
		glidePreviewGeneration &+= 1
		pendingGlidePreview = nil
		displayedGlidePrediction = nil
		engine.cancelGlidePreviews()
		guard hostConnectionReady, !isSecureField else {
			glidePreviewEnabled = false
			activeGlideDocumentContext = nil
			activeGlideContext.removeAll(keepingCapacity: true)
			activeGlideAutoShift = false
			keyboard?.setGlidePreview(nil)
			return
		}
		// Letter taps commit on touch-down for sub-frame latency. Crossing the Glide
		// threshold reclassifies that touch, so retract exactly that provisional start
		// letter before capturing context or decoding the path.
		textDocumentProxy.deleteBackward()
		noteProxyEdit()
		if !wordTaps.isEmpty { wordTaps.removeLast() }
		if !currentWordBuffer.isEmpty { currentWordBuffer.removeLast() }
		glidePreviewEnabled = true
		let before = textDocumentProxy.documentContextBeforeInput ?? ""
		activeGlideDocumentContext = before
		activeGlideContext = contextWords(before, max: 8)
		activeGlideAutoShift = shouldAutoShift(before)
		activeGlideSessionID = engine.beginGlideSession(context: activeGlideContext)
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
		guard !glidePreviewInFlight, let request = pendingGlidePreview,
			let sessionID = activeGlideSessionID else { return }
		pendingGlidePreview = nil
		glidePreviewInFlight = true
		let generation = glidePreviewGeneration
		let capitalize = activeGlideAutoShift
		engine.updateGlideSession(sessionID, path: request.path, times: request.times,
			layout: request.layout) { [weak self] update in
			guard let self else { return }
			self.glidePreviewInFlight = false
			guard generation == self.glidePreviewGeneration else {
				self.startNextGlidePreviewIfNeeded()
				return
			}
			// A newer path snapshot may have arrived while this decode was running.
			// Never flash the older winner; move directly to the newest queued path.
			if request.sequence == self.glidePreviewSequence,
			   let update, update.sessionID == self.activeGlideSessionID {
				let prediction = update.prediction
				let word = SuggestionCasePolicy.display(prediction.word,
					sentenceStart: capitalize)
				let alternatives = prediction.alternatives.prefix(2).map {
					SuggestionCasePolicy.display($0, sentenceStart: capitalize)
				}
				if let endpoint = request.path.last {
					self.displayedGlidePrediction = DisplayedGlidePrediction(
						prediction: prediction,
						sessionID: update.sessionID,
						revision: update.revision,
						pointCount: request.path.count,
						endpoint: endpoint,
						pitch: request.layout.xPitch)
				}
				self.keyboard?.setGlidePreview(word, alternatives: alternatives,
					confident: prediction.margin >= 0.75)
			} else if request.sequence == self.glidePreviewSequence {
				self.displayedGlidePrediction = nil
				self.keyboard?.setGlidePreview(nil)
			}
			self.startNextGlidePreviewIfNeeded()
		}
	}

	private func cancelGlidePreview(clearStrip: Bool) {
		endGlidePreviewUI(clearStrip: clearStrip, cancelEngineSession: true)
	}

	private func endGlidePreviewUI(clearStrip: Bool, cancelEngineSession: Bool) {
		glidePreviewGeneration &+= 1
		glidePreviewSequence &+= 1
		pendingGlidePreview = nil
		if cancelEngineSession, let sessionID = activeGlideSessionID {
			engine.cancelGlideSession(sessionID)
		}
		activeGlideSessionID = nil
		activeGlideDocumentContext = nil
		activeGlideContext.removeAll(keepingCapacity: true)
		activeGlideAutoShift = false
		glidePreviewEnabled = false
		displayedGlidePrediction = nil
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
	private func trackReplacementStart(wasInsideWord: Bool) {
		guard !erasedWord.isEmpty, !replacementStarted else { return }
		replacementStarted = true
		if wasInsideWord { resetEraseTracking() }
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
			rejectCorrection(committed)
			decodeSnapshot = nil
			presentedDecodeSnapshot = nil
		}
		recordReplacement(original: erased, replacement: committed)
	}

	// MARK: Suggestions — versioned, background-computed

	private func scheduleSuggestions() {
		generation &+= 1
		let requestGeneration = generation
		refreshSuggestions(requestGeneration: requestGeneration)
	}

	private func invalidateSuggestionRequests(cancelEngineWork: Bool = false) {
		generation &+= 1
		decodeSnapshot = nil
		presentedDecodeSnapshot = nil
		if cancelEngineWork { engine.cancelSuggestions() }
	}

	private func refreshSuggestions(requestGeneration: UInt64) {
		guard requestGeneration == generation else { return }
		guard suggestionsAllowed else {
			decodeSnapshot = nil
			presentedDecodeSnapshot = nil
			setSuggestionBar([])
			return
		}
		let gen = requestGeneration
		let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
		let current = trailingWord(ctx)
		let revert = (lastCorrection?.fromAutocorrect == true) ? lastCorrection?.original : nil
		let context = contextWords(ctx, max: 8)
		currentWordBuffer = current
		currentContextBuffer = context
		let request = makeDecodeRequest(currentWord: current, context: context, generation: gen)
		engine.decode(request) { [weak self] snapshot in
			guard let self, gen == self.generation,
				  snapshot.isValid(for: request) else { return }
			let presented = SuggestionCasePolicy.present(snapshot,
				sentenceStart: self.shouldAutoShift(ctx))
			self.decodeSnapshot = snapshot
			self.presentedDecodeSnapshot = presented
			self.keyboard.setKeyPriors(snapshot.nextCharacterPriors)
			if current.isEmpty {
				if let revert {
					self.mode = .revert(revert)
					self.setSuggestionBar([revert] + presented.suggestions.prefix(2).map(\.text))
				} else {
					self.mode = .predict
					if self.offersPaste() {
						// Empty field + fresh clipboard text → offer Paste in place of
						// next-word predictions (the "copied, then deleted it" moment).
						self.setPasteBar()
					} else {
						self.setSuggestionBar(presented.suggestions.map(\.text))
					}
				}
			} else {
				self.mode = .complete(current)
				let exactPrimary = presented.suggestions.first?.isExactTypedCandidate == true
				self.setSuggestionBar(presented.suggestions.map(\.text), typedPrefix: current,
					highlightPrimary: presented.correction != nil || exactPrimary)
			}
		}
	}

	private func makeDecodeRequest(currentWord: String, context: [String],
								   generation: UInt64) -> DecodeRequest {
		let taps = wordTaps.count == currentWord.count ? wordTaps : nil
		return DecodeRequest(fieldRevision: fieldRevision,
			documentRevision: documentRevision,
			wordSessionID: wordSessionID,
			generation: generation,
			layoutRevision: layoutRevision,
			currentWord: currentWord,
			context: context,
			taps: activeLanguageMode == .english ? taps : nil,
			languageMode: activeLanguageMode,
			requestedModelTier: wordSessionModelTier)
	}

	private func setSuggestionBar(_ suggestions: [String], typedPrefix: String? = nil,
							  highlightPrimary: Bool = false) {
		suggestionPresentation = .ranked(words: suggestions, prefix: typedPrefix,
			highlightPrimary: highlightPrimary)
		keyboard?.setSuggestions(suggestions, typedPrefix: typedPrefix,
			highlightPrimary: highlightPrimary)
	}

	private func setGlideSuggestionBar(winner: String, alternatives: [String]) {
		suggestionPresentation = .glide(winner: winner, alternatives: alternatives)
		keyboard?.setGlideResult(winner, alternatives: alternatives)
	}

	private func setPasteBar() {
		suggestionPresentation = .paste
		keyboard?.setPasteOffer(true)
	}

	private func applySuggestionPresentation(to keyboard: KeyboardView) {
		switch suggestionPresentation {
		case .ranked(let words, let prefix, let highlightPrimary):
			keyboard.setSuggestions(words, typedPrefix: prefix,
				highlightPrimary: highlightPrimary)
		case .glide(let winner, let alternatives):
			keyboard.setGlideResult(winner, alternatives: alternatives)
		case .paste:
			keyboard.setPasteOffer(true)
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
