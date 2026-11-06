import UIKit

final class KeyboardView: UIView {

	/// The second argument is the tap's landing point relative to the pressed key's
	/// center, in key-grid units (nil for non-letter keys and programmatic inserts) —
	/// the channel model uses it for sub-key precision.
	var onInsert:         ((String, KeyTap?) -> Void)?
	var onKeyOutput:      ((KeyOutput, KeyTap?) -> Void)?
	var onDelete:         (() -> Void)?
	var onReturn:         (() -> Void)?
	var onCursorModeBegan: (() -> Void)?
	var onCursorMove:     ((Int) -> Void)?
	var onCursorModeEnded: (() -> Void)?
	/// A long-press alternate replaces the base character already committed on
	/// touch-down. The controller owns the atomic proxy edit and buffer revision.
	var onReplaceLastInput: ((String, String) -> Void)?
	var onNextKeyboard:   (() -> Void)?
	var onInputModeEvent: ((UIView, UIEvent) -> Void)?
	var onPickSuggestion: ((String) -> Void)?
	/// Fired whenever `keyboardHeight` changes out from under the controller (entering
	/// or leaving emoji search, which swaps the 34 pt strip for the 86 pt search header)
	/// so it can update its height constraint.
	var onHeightChange:   (() -> Void)?
	/// Width/orientation changed the physical layout profile. The controller includes
	/// this revision in decode requests so no touch model survives a geometry change.
	var onGeometryChange: (() -> Void)?
	var onOpenMedia: ((KlipyKind) -> Void)?
	/// Clipboard was selected in the tools row. The controller captures the
	/// pasteboard (once, explicitly) and calls back into `showClipboard(hasFullAccess:)`.
	var onOpenClipboard: (() -> Void)?
	/// A history row was picked in the clipboard panel.
	var onClipboardPick: ((String) -> Void)?
	/// The explicit Paste current clipboard action in the clipboard panel was tapped.
	var onPaste: (() -> Void)?

	/// Set to the tapped key's landing offset for the duration of `key.action()`, so
	/// the char closures can attach it to `onInsert`. nil outside a live letter tap.
	var onTouchSample: ((String, UInt64, String?, TimeInterval, KeyTap?) -> Void)?
	var recordedTouches: [UITouch: (UInt64, String?, KeyTap?)] = [:]
	var nextRecordedTouch: UInt64 = 0
	/// True while a held key's auto-repeat fires: one hold is one physical tap.
	var isRepeatingKey = false
	var activeTap: KeyTap?
	/// Next-character priors (letter → 0…1) from the engine's background pass, used to
	/// invisibly enlarge likely keys' targets. Purely a tie-breaker on edge/gap taps.
	var charPriors: [Character: Double] = [:]
	/// Horizontal key pitch (center-to-center of adjacent unit keys), captured during
	/// layout so tap offsets convert to the same grid units the spatial model uses.
	var unitPitch: CGFloat = 30

	let theme: KeyboardTheme
	let deckLayer = CAGradientLayer()
	let showsGlobe: Bool
	let languageMode: KBLanguageMode
	let languageLayout: KeyboardLayoutDescriptor
	var page: KeyboardSurfacePage = .letters
	var shift: ShiftState = .on
	var rows: [[KeyButton]] = []
	var emojiView: EmojiKeyboardView?
	var mediaView: MediaPanelView?
	var clipboardView: ClipboardPanelView?
	var mediaSearchHeader: EmojiSearchHeader?
	var mediaSearchStrip: MediaSearchStrip?
	var isMediaSearching = false
	var mediaQuery = ""
	var mediaSearchKind: KlipyKind = .gifs
	var mediaHasFullAccess = false
	// Emoji search (Gboard-style): the REAL letter deck types into a query shown in a
	// header where the suggestion strip normally sits; results insert into the host.
	var emojiSearchHeader: EmojiSearchHeader?
	var isEmojiSearching = false
	var emojiQuery = ""
	// Live references so a shift change can relabel in place instead of rebuilding every key.
	var letterKeys: [(base: String, key: KeyButton)] = []
	weak var shiftKey: KeyButton?
	weak var actionKey: KeyButton?
	var lastShiftTapAt: TimeInterval = 0
	var actionTitle: String?          // contextual label for the action key (go / search / send …)
	var actionEnabled = true
	let suggestionBar: SuggestionBar
	private(set) var inputKind: KeyboardInputKind = .standard
	var lastLayoutWidth: CGFloat = 0
	var lastLayoutProfile: KeyboardLayoutMetrics.Profile?

	/// Light haptic on each key press. Off unless enabled in settings; iOS remains the
	/// authority for physical-device availability and system haptic preferences.
	var hapticsEnabled = false
	let keyHaptic = UISelectionFeedbackGenerator()
	let actionHaptic = UIImpactFeedbackGenerator(style: .light)

	/// Prime the Taptic Engine so the first key tap fires without latency.
	func prepareHaptics() {
		guard hapticsEnabled else { return }
		keyHaptic.prepare()
		actionHaptic.prepare()
	}

	// MARK: State for Glide
	/// Fired on lift with the full swipe trajectory (view coordinates) plus a snapshot of
	/// the key layout, so the engine can map the path into grid space and decode it. No
	/// letter is ever committed for a glide (lift-commit) — the decoder just gets the path.
	var onGlide: (([CGPoint], [TimeInterval], GlideLayout) -> Void)?
	/// Throttled trajectory snapshots for the background live-winner decoder.
	var onGlideBegan: (() -> Void)?
	var onGlidePreview: (([CGPoint], [TimeInterval], GlideLayout) -> Void)?
	var onGlideCancelled: (() -> Void)?
	/// Tenglish Glide is intentionally disabled until tap transliteration has a trained
	/// FST/LM and its own labelled path benchmark. Disabling here preserves normal
	/// fire-on-touch typing instead of reclassifying a stroke and dropping the first key.
	var glideEnabled = true
	var glideTouch: UITouch?            // the single finger tracked for a glide
	var glide: GlideTrack?
	let trailLayer = CAShapeLayer()
	let trailHeadLayer = CAShapeLayer()
	var lastGlidePreviewTime: TimeInterval = 0
	let glidePreviewInterval: TimeInterval = 0.035
	/// A stroke becomes a glide once it travels this far AND crosses into a second key —
	/// enough to tell a deliberate swipe from a jittery tap. Tuned for real hands in P5.
	var glideThreshold: CGFloat { unitPitch * 0.85 }
	/// iOS 26 hosts extensions inside its glass keyboard container and reserves ~16pt
	/// above our view for the container's rounded top, which we can neither draw in
	/// nor shrink. A 32pt strip brings rim-to-keys to ~52pt, against stock's ~51.
	private let stripHeight: CGFloat = 32
	var metrics: KeyboardLayoutMetrics {
		let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
		let base = KeyboardLayoutMetrics.resolve(width: width,
			idiom: traitCollection.userInterfaceIdiom)
		return languageMode == .telugu ? base.scalingRowHeight(Self.teluguRowHeightScale) : base
	}
	var keySpacing: CGFloat { metrics.keySpacing }
	var rowSpacing: CGFloat { metrics.rowSpacing }
	var rowHeight: CGFloat { metrics.rowHeight }
	var sidePad: CGFloat { metrics.sidePadding }
	var topPad: CGFloat { metrics.topPadding }
	private var botPad: CGFloat { metrics.bottomPadding }
	private let collapsedTopPad: CGFloat = 0
	var stripSpace: CGFloat { showsSuggestions ? stripHeight : collapsedTopPad }
	var headerSpace: CGFloat {
		(isEmojiSearching || isMediaSearching) ? EmojiSearchHeader.height : stripSpace
	}
	private var expansionSpace: CGFloat { page == .media ? Self.mediaExpansion : 0 }
	private var keyRowCount: Int {
		guard languageMode == .telugu,
			  page == .letters || page == .alternateLetters else { return 4 }
		let glyphRows = page == .alternateLetters
			? (languageLayout.alternate ?? languageLayout.primary).rows.count
			: languageLayout.primary.rows.count
		return max(1, glyphRows + 1)
	}
	var keyboardHeight: CGFloat {
		let count = keyRowCount
		return headerSpace + expansionSpace + topPad + rowHeight * CGFloat(count)
			+ rowSpacing * CGFloat(max(0, count - 1)) + botPad
	}
	/// Media search owns the action key: it reads "search" and stays enabled whatever
	/// the host says — an empty message field (WhatsApp) disables return, which would
	/// otherwise make a GIF/sticker query impossible to submit.
	var displayedActionTitle: String? { isMediaSearching ? "search" : actionTitle }
	var displayedActionEnabled: Bool { isMediaSearching || actionEnabled }

	// MARK: State for Touch
	var touchKeys: [UITouch: KeyButton] = [:]
	// Stock-style character balloon above the pressed key. One per active touch so
	// two-thumb typing shows both. Quick taps retain 100ms of visual feedback;
	// cancellation and glide classification dismiss immediately.
	var touchPopups: [UITouch: UIView] = [:]
	var popupShownAt: [UITouch: TimeInterval] = [:]
	var poppedKeys: [UITouch: KeyButton] = [:]   // key whose glyph is hidden under its balloon
	var alternativeTimers: [UITouch: Timer] = [:]
	var alternativePopups: [UITouch: KeyAlternativesView] = [:]
	// Press-and-hold auto-repeat (delete): one timer, tied to the finger holding it.
	var repeatTimer: Timer?
	var repeatTouch: UITouch?
	weak var repeatKey: KeyButton?
	// Space cursor control. A normal tap remains touch-down-fast. Holding retracts
	// that one provisional space, then horizontal motion moves the host cursor.
	var cursorTimer: Timer?
	weak var cursorTouch: UITouch?
	weak var cursorKey: KeyButton?
	var cursorStartX: CGFloat = 0
	var cursorStep = 0
	var isCursorTracking = false

	// MARK: State for Keys
	var shiftSymbol: String {
		switch shift { case .off: return "shift"; case .on: return "shift.fill"; case .locked: return "capslock.fill" }
	}

	// MARK: Lifecycle
	init(theme: KeyboardTheme, showsGlobe: Bool = true,
		 languageMode: KBLanguageMode = .english) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.languageMode = languageMode
		self.languageLayout = KeyboardLayoutDescriptor.forMode(languageMode)
		self.suggestionBar = SuggestionBar(theme: theme)
		super.init(frame: .zero)
		accessibilityIdentifier = "glyph.keyboard"
		backgroundColor = .clear
		isOpaque = false
		layer.isOpaque = false
		deckLayer.startPoint = CGPoint(x: 0.5, y: 0)
		deckLayer.endPoint = CGPoint(x: 0.5, y: 1)
		layer.insertSublayer(deckLayer, at: 0)
		updateBackdrop()
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(reduceTransparencyDidChange),
			name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
			object: nil
		)
		NotificationCenter.default.addObserver(
			self,
			selector: #selector(reduceTransparencyDidChange),
			name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
			object: nil
		)
		trailLayer.fillColor = nil
		trailLayer.lineWidth = 8
		trailLayer.lineCap = .round
		trailLayer.lineJoin = .round
		trailLayer.strokeColor = theme.accentStart.withAlphaComponent(0.38).cgColor
		trailHeadLayer.fillColor = theme.accentStart.withAlphaComponent(0.46).cgColor
		trailHeadLayer.strokeColor = UIColor.white.withAlphaComponent(0.16).cgColor
		trailHeadLayer.lineWidth = 1
		layer.addSublayer(trailLayer)
		layer.addSublayer(trailHeadLayer)
		isMultipleTouchEnabled = true            // <-- fast typists / overlapping fingers
		addSubview(suggestionBar)
		suggestionBar.isHidden = !showsSuggestions    // start collapsed until the host is known
		suggestionBar.onPick = { [weak self] in self?.onPickSuggestion?($0) }
        suggestionBar.onSelectTool = { [weak self] tool in
            guard let self else { return }
            switch tool {
            case .clipboard: self.onOpenClipboard?()
            case .emoji: self.showEmoji()
            case .gifs: self.onOpenMedia?(.gifs)
            case .stickers: self.onOpenMedia?(.stickers)
            }
        }
		reload()
	}
	required init?(coder: NSCoder) { fatalError() }
	deinit {
		repeatTimer?.invalidate()
		cursorTimer?.invalidate()
		alternativeTimers.values.forEach { $0.invalidate() }
		NotificationCenter.default.removeObserver(self)
	}

	/// The predictive-suggestion strip is hidden (and its height reclaimed) in fields where
	/// stock iOS hides predictions — URL/search/numeric/secure. Toggled by the controller.
	/// When blocked the strip closes FULLY (0) — like stock, no leftover "tab" band above
	/// the keys; the row's own topPad still gives breathing room.
	///
	/// Starts OPEN so ordinary apps show the strip from the very first frame with no
	/// transition. The controller resolves the field type ONCE (viewDidAppear) and, only
	/// in a suppressed field (URL / search / secure), disables it a single time — there is
	/// no per-keystroke re-evaluation, so the strip never flickers open/closed as you type.
	private(set) var showsSuggestions = true

	// MARK: Host-driven state changes

	/// Show or hide the predictive strip. Hiding it shortens the keyboard; the controller
	/// updates its height constraint from `keyboardHeight` afterwards.
	func setShowsSuggestions(_ on: Bool) {
		guard on != showsSuggestions else { return }
		showsSuggestions = on
		suggestionBar.isHidden = !on
		setNeedsLayout()
	}

	/// Apply host input traits without reconstructing the whole controller. Returning
	/// true tells the controller that decoder/layout identity changed.
	@discardableResult
	func setInputKind(_ kind: KeyboardInputKind) -> Bool {
		guard inputKind != kind else { return false }
		inputKind = kind
		page = kind == .numbersAndPunctuation || kind.usesDedicatedNumberPad ? .numbers : .letters
		shift = kind == .standard ? shift : .off
		reload()
		return true
	}
}
