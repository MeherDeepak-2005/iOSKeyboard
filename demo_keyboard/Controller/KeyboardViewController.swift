import UIKit

// Letter-key path = insertText first. Decoding is asynchronous and publishes one
// versioned snapshot that owns both the suggestion strip and boundary correction.

final class KeyboardViewController: UIInputViewController {

	var keyboard: KeyboardView!
	var heightConstraint: NSLayoutConstraint?
	private var heightMismatchActive = false
	let engine = KeyboardEngine.shared   // process-wide: see KeyboardEngine.shared
	private var personalDataResetObserver: KBPersonalDataResetObserver?
	private var configurationObserver: KBConfigurationObserver?
	private var accessibilityObservers: [NSObjectProtocol] = []

	enum Mode { case predict, complete(String), revert(String), glided(String) }
	var mode: Mode = .predict
	var generation: UInt64 = 0
	var fieldRevision: UInt64 = 0
	var documentRevision: UInt64 = 0
	var wordSessionID: UInt64 = 0
	var layoutRevision: UInt64 = 0
	var fieldInputKind: KeyboardInputKind = .standard
	var configuredLanguageMode: KBLanguageMode = .english
	/// Resolved only at controller/configuration boundaries. The key path reads this
	/// Boolean and never hashes a pack or waits on the health cache lock.
	var configuredLanguageModeAvailable = true
	/// Neural packages are promotion-gated; the shipped tier is selected only here,
	/// between words, and remains fixed until `wordSessionID` advances.
	var wordSessionModelTier: DecodeModelTier = .ngram
	var decodeSnapshot: DecodeSnapshot?
	var presentedDecodeSnapshot: PresentedDecodeSnapshot?
	var currentWordBuffer = ""
	var currentContextBuffer: [String] = []
	/// Next-word-prediction (NWP) benchmark state: the lowercased top-3 shown at the current
	/// word's start and whether an in-context prediction was actually armed. Read once when
	/// the word commits (was the intended word already offered before the first letter?),
	/// then disarmed. Counts only — no text leaves the process.
	var nwpPredictedTop3: Set<String> = []
	var nwpPredictionArmed = false
	var suggestionModeResolved = false
	var suggestionsVisible = true
	var hostConnectionReady = false
	var supplementaryLexiconRequested = false
    var documentReconciler = HostDocumentReconciler()
    var recoveryMonitor: HostDocumentRecoveryMonitor?
    var presentationDocument: HostDocumentSnapshot?
    var expectedLetterInsertion: String?

	enum SuggestionPresentation {
		case ranked(words: [String], prefix: String?, highlightPrimary: Bool)
		case glide(winner: String, alternatives: [String])
	}
	var suggestionPresentation = SuggestionPresentation.ranked(words: [], prefix: nil, highlightPrimary: false)
	struct GlidePreviewRequest {
		let path: [CGPoint]
		let times: [TimeInterval]
		let layout: GlideLayout
		let sequence: Int
	}
	var pendingGlidePreview: GlidePreviewRequest?
	var glidePreviewInFlight = false
	var glidePreviewGeneration = 0
	var glidePreviewSequence = 0
	var activeGlideDocumentContext: String?
	var activeGlideContext: [String] = []
	var activeGlideAutoShift = false
	var activeGlideSessionID: GlideSessionID?
	var glidePreviewEnabled = false
	/// The exact prediction currently visible in the middle suggestion slot. If this
	/// exists at lift, it is the commit authority; the user never sees one word and
	/// receives another from a second release-time decode.
	struct DisplayedGlidePrediction {
		let prediction: GlidePrediction
		let sessionID: GlideSessionID
		let revision: UInt64
		let pointCount: Int
		let endpoint: CGPoint
		let pitch: CGFloat
	}
	var displayedGlidePrediction: DisplayedGlidePrediction?

	/// Records the most recent replacement (autocorrect on a boundary, or a picked
	/// completion) so a single Backspace can undo it back to what the user typed —
	/// exactly like the stock keyboard.
	struct Correction {
		let original: String       // what the user actually typed
		let corrected: String      // what we replaced it with
		var trailing: String       // boundary/space/newline inserted after it (may be "")
		let fromAutocorrect: Bool  // engine autocorrect: suppress re-correction on undo
		var recordedWordSessionID: UInt64? = nil
	}
	var lastCorrection: Correction?

	/// Manual-fix detection. The one-tap Backspace undo only catches an IMMEDIATE
	/// revert; users just as often backspace through a word and retype it by hand.
	/// Track the word being erased and the first word typed in its place, then feed
	/// the swap to the engine: reverting one of OUR corrections registers as a
	/// rejection (dontCorrect), and hand-fixing their own typo ("js" → "is") demotes
	/// the typo so repetition can't adopt it into the dictionary.
	var erasedWord = ""
	var erasedCrossedBoundary = false   // deletion ate the word's leading boundary
	var replacementStarted = false
	/// Recent autocorrects (typed → corrected), so erasing a correction and retyping
	/// the original is recognizable even after `lastCorrection` expired.
	var recentCorrections: [(original: String, corrected: String)] = []

	/// Per-tap landing offsets for the word currently being typed, one per letter, so
	/// the channel model can score sub-key precision. Best-effort: cleared on word
	/// boundaries, popped on delete; the engine ignores them unless the count matches
	/// the word length, so any desync is silently safe.
	var wordTaps: [KeyTap?] = []

	/// Typing-speed and per-key evidence for the word being typed: the typing recorder and
	/// the per-key diagnostics read it, the decoder never does. Reset with the word session.
	struct TypingTrace {
		var keystrokes: [KBTypingRecorder.Keystroke] = []
		var startedAt: Double?
		var backspaces = 0
		/// Letters erased from this word, in reading order; the next letters typed replace them.
		var erasedLetters: [Character] = []
	}
	var typingTrace = TypingTrace()
	var lastKeyUptime = 0.0

	/// A glided word is awaiting an explicit verdict. Typing on is intentionally
	/// unlabelled: only selecting an alternative is safe supervision for adaptation.
	var pendingGlideVerdict = false
	/// Progress is provisional until the user either continues or leaves the field.
	/// An immediate whole-word Backspace cancels it, so leagues never reward a
	/// rejected Glide result.
	var pendingGlideStatsID: UUID?
	/// Original host context for the most recent Telugu key. Long-press alternatives
	/// replace the already-committed base output against this exact context, preserving
	/// a conjunct or dependent sign instead of deleting its leading consonant.
	var lastTeluguKeyContext: String?

	/// Resolved only after the host connection is live. Calling
	/// `needsInputModeSwitchKey` during extension prewarming produces an inaccurate result
	/// and a UIKit warning; until then, omit the key and rebuild once if iOS requires it.
	var showsGlobe = false

	let boundary = CharacterSet(charactersIn: " .,!?;:")

	override func loadView() {
		let root = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
		root.allowsSelfSizing = true
		view = root
	}

	func updateKeyboardHeight() {
		guard let keyboard else { return }
		let desired = keyboard.keyboardHeight
		guard desired.isFinite, desired > 0 else { return }
		rootInputView?.desiredHeight = desired
		heightConstraint?.constant = desired
		let size = CGSize(width: view.bounds.width, height: desired)
		if preferredContentSize != size { preferredContentSize = size }
	}

	private var rootInputView: KeyboardInputView? { view as? KeyboardInputView }

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		updateKeyboardHeight()
		if let keyboard, view.window != nil {
			let mismatch = abs(view.bounds.height - keyboard.keyboardHeight) > 2
			if mismatch && !heightMismatchActive { KBDiagnostics.noteIntegrityEvent("keyboard-height-mismatch") }
			heightMismatchActive = mismatch
		}
	}

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

		accessibilityObservers.append(NotificationCenter.default.addObserver(
			forName: KeyboardEngine.searchPriorReadyNotification, object: engine, queue: .main) { [weak self] notice in
				guard let self, self.hostConnectionReady, self.suggestionsAllowed,
					self.activeLanguageMode == .english, self.activeGlideSessionID == nil,
					let request = notice.userInfo?["request"] as? DecodeRequest,
					request == self.makeDecodeRequest(currentWord: self.currentWordBuffer,
						context: self.currentContextBuffer, generation: self.generation) else { return }
				self.scheduleSuggestions()
			})

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

	func buildKeyboard() {
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
		let touchViewID = UUID().uuidString
		kb.onTouchSample = { [weak self, weak kb] phase, id, key, time, tap in
			guard let self, let kb, self.keyboard === kb,
				!kb.isEmojiSearching, !kb.isMediaSearching else { return }
			self.recordTyping(phase, text: key, tap: tap, touchID: "\(touchViewID):\(id)", at: time)
		}
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
		kb.onPaste = { [weak self] in self?.handlePasteCurrentClipboard() }
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
			self.updateKeyboardHeight()
		}
		kb.onGeometryChange = { [weak self, weak kb] in
			guard let self, let kb, self.keyboard === kb else { return }
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
		updateKeyboardHeight()
	}

	// MARK: State for Autocorrect
	var currentDecodeSnapshot: DecodeSnapshot? {
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
	var currentPresentedDecodeSnapshot: PresentedDecodeSnapshot? {
		guard let canonical = currentDecodeSnapshot,
			  let presented = presentedDecodeSnapshot,
			  presented.canonical == canonical else { return nil }
		return presented
	}

	// MARK: State for Clipboard
	var cursorModeActive = false

	// MARK: State for Keys
	/// Timestamp of the last plain space, for the double-space → ". " shortcut.
	var lastSpaceAt: TimeInterval = 0
	/// Replaces an exact suffix without assuming that UIKit and Swift use the same
	/// deletion unit for Indic text. This is intentionally reserved for explicit
	/// correction/pick transactions, never the ordinary letter insertion path.
	/// Deletes issued by the most recent `replaceHostSuffix` call, for the pick/revert
	/// diagnostic (#3) — read immediately after the call, before any other edit.
	var lastReplaceDeleteCount = 0

	// MARK: State for Suggestions
	var isSecureField: Bool { textDocumentProxy.isSecureTextEntry ?? false }
	var suggestionsAllowed: Bool { !isSecureField }
	/// Former prediction restrictions remain active only for automatic replacement.
	/// The strip itself no longer inherits this policy (see the commented wiring below).
	var autocorrectionAllowed: Bool {
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
	/// Tenglish is a prose mode. Host traits take precedence so a user's language
	/// preference can never transliterate an email address, URL, handle, or number.
	var activeLanguageMode: KBLanguageMode {
		guard configuredLanguageModeAvailable, !isSecureField else { return .english }
		switch fieldInputKind {
		case .standard, .webSearch:
			return configuredLanguageMode
		case .email, .url, .twitter, .numbersAndPunctuation,
			 .numberPad, .decimalPad, .phonePad:
			return .english
		}
	}

	// MARK: UIKit lifecycle

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		hostConnectionReady = false
        documentReconciler.reset()
        presentationDocument = nil
        keyboard?.dismissTools()
        setSuggestionBar([])
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

	/// Switching to Glyph with the globe key in a field that already has focus sends no
	/// text-input callback until the user taps the field: the keys stayed disabled and the
	/// strip empty. On screen, the host connection is live, so connect now.
	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		// The system's edge-swipe gates delay touches near the screen sides, so Q, A
		// and P arrive late, often with their lift, and their balloon never shows.
		view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
		if !hostConnectionReady { handleHostCallback() }
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		hostConnectionReady = false
        recoveryMonitor?.stop()
        recoveryMonitor = nil
        invalidateSuggestionRequests(cancelEngineWork: true)
        cancelGlidePreview(clearStrip: true)
		keyboard?.isUserInteractionEnabled = false
		keyboard?.accessibilityElementsHidden = true
		KBStats.confirm(pendingGlideStatsID)
		pendingGlideStatsID = nil
		KBStats.flush()
		KBDiagnostics.finishTypingSession()
		KBTypingRecorder.flush()
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
        handleHostCallback()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        handleHostCallback()
    }
}
