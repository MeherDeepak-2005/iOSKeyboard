import UIKit
import CoreText
import os
import SwiftUI

// KeyboardView — the on-screen key deck (touches, layout, popups, shift).
// Emoji picker → Emoji.swift; keys/theme/suggestion bar → their own files.

struct KeyboardLayoutMetrics: Equatable {
	enum Profile: Equatable { case compactPhone, phone, largePhone, landscapePhone, pad }
	let profile: Profile
	let rowHeight, keySpacing, rowSpacing, sidePadding, topPadding, bottomPadding: CGFloat
	let maximumDeckWidth: CGFloat

	/// A copy with the row height (and inter-row gap) scaled — used to make the taller
	/// multi-row Telugu deck more compact without touching Latin geometry.
	func scalingRowHeight(_ factor: CGFloat) -> KeyboardLayoutMetrics {
		.init(profile: profile, rowHeight: rowHeight * factor, keySpacing: keySpacing,
			rowSpacing: rowSpacing * factor, sidePadding: sidePadding, topPadding: topPadding,
			bottomPadding: bottomPadding, maximumDeckWidth: maximumDeckWidth)
	}

	static func resolve(width: CGFloat, idiom: UIUserInterfaceIdiom) -> KeyboardLayoutMetrics {
		if idiom == .pad {
			return .init(profile: .pad, rowHeight: 48, keySpacing: 7, rowSpacing: 8,
				sidePadding: 12, topPadding: 6, bottomPadding: 7, maximumDeckWidth: 820)
		}
		if width >= 600 {
			return .init(profile: .landscapePhone, rowHeight: 36, keySpacing: 5, rowSpacing: 5,
				sidePadding: 10, topPadding: 3, bottomPadding: 4, maximumDeckWidth: 700)
		}
		if width <= 360 {
			return .init(profile: .compactPhone, rowHeight: 40, keySpacing: 5, rowSpacing: 11,
				sidePadding: 5, topPadding: 4, bottomPadding: 5, maximumDeckWidth: .greatestFiniteMagnitude)
		}
		if width >= 430 {
			return .init(profile: .largePhone, rowHeight: 43, keySpacing: 6, rowSpacing: 13,
				sidePadding: 7, topPadding: 4, bottomPadding: 6, maximumDeckWidth: .greatestFiniteMagnitude)
		}
		return .init(profile: .phone, rowHeight: 42, keySpacing: 6, rowSpacing: 12,
			sidePadding: 6, topPadding: 4, bottomPadding: 5, maximumDeckWidth: .greatestFiniteMagnitude)
	}
}

private final class KeyAlternativesView: UIView {
	private let options: [String]
	private var labels: [UILabel] = []
	private let selection = UIView()
	private(set) var selectedIndex = 0

	init(options: [String], theme: KeyboardTheme) {
		self.options = options
		super.init(frame: .zero)
		backgroundColor = theme.popupFill
		layer.cornerRadius = 12
		layer.cornerCurve = .continuous
		layer.shadowColor = UIColor.black.cgColor
		layer.shadowOpacity = theme.isDark ? 0.42 : 0.20
		layer.shadowRadius = 6
		layer.shadowOffset = CGSize(width: 0, height: 2)
		selection.backgroundColor = theme.accentSoft
		selection.layer.cornerRadius = 9
		selection.layer.cornerCurve = .continuous
		addSubview(selection)
		for option in options {
			let label = UILabel()
			label.text = option
			label.textAlignment = .center
			label.textColor = theme.popupText
			label.font = .systemFont(ofSize: 24,
				weight: UIAccessibility.isBoldTextEnabled ? .medium : .regular)
			labels.append(label)
			addSubview(label)
		}
		isAccessibilityElement = false
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		guard !labels.isEmpty else { return }
		let width = bounds.width / CGFloat(labels.count)
		selection.frame = CGRect(x: CGFloat(selectedIndex) * width + 3, y: 3,
			width: max(0, width - 6), height: max(0, bounds.height - 6))
		for (index, label) in labels.enumerated() {
			label.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
		}
	}

	func select(atX x: CGFloat) {
		guard !labels.isEmpty, bounds.width > 0 else { return }
		let index = min(labels.count - 1, max(0,
			Int(floor(x / (bounds.width / CGFloat(labels.count))))))
		guard index != selectedIndex else { return }
		selectedIndex = index
		setNeedsLayout()
	}

	var selectedValue: String { options[selectedIndex] }
	var baseValue: String { options[0] }
}

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
	/// The suggestion strip's clipboard icon was tapped. The controller captures the
	/// pasteboard (once, explicitly) and calls back into `showClipboard(hasFullAccess:)`.
	var onOpenClipboard: (() -> Void)?
	/// A history row was picked in the clipboard panel.
	var onClipboardPick: ((String) -> Void)?
	/// The "Paste" offer in the suggestion strip was tapped (empty field + fresh copy).
	var onPaste: (() -> Void)?

	/// Set to the tapped key's landing offset for the duration of `key.action()`, so
	/// the char closures can attach it to `onInsert`. nil outside a live letter tap.
	private var activeTap: KeyTap?
	/// Next-character priors (letter → 0…1) from the engine's background pass, used to
	/// invisibly enlarge likely keys' targets. Purely a tie-breaker on edge/gap taps.
	private var charPriors: [Character: Double] = [:]
	/// Horizontal key pitch (center-to-center of adjacent unit keys), captured during
	/// layout so tap offsets convert to the same grid units the spatial model uses.
	private var unitPitch: CGFloat = 30

	private let theme: KeyboardTheme
	private let deckLayer = CAGradientLayer()
	private let showsGlobe: Bool
	private let languageMode: KBLanguageMode
	private let languageLayout: KeyboardLayoutDescriptor
	private var page: KeyboardSurfacePage = .letters
	private var shift: ShiftState = .on
	private var rows: [[KeyButton]] = []
	private var emojiView: EmojiKeyboardView?
	private var mediaView: MediaPanelView?
	private var clipboardView: ClipboardPanelView?
	private var mediaSearchHeader: EmojiSearchHeader?
	private var isMediaSearching = false
	private var mediaQuery = ""
	private var mediaSearchKind: KlipyKind = .gifs
	private var mediaHasFullAccess = false
	// Emoji search (Gboard-style): the REAL letter deck types into a query shown in a
	// header where the suggestion strip normally sits; results insert into the host.
	private var emojiSearchHeader: EmojiSearchHeader?
	private var isEmojiSearching = false
	private var emojiQuery = ""
	// Live references so a shift change can relabel in place instead of rebuilding every key.
	private var letterKeys: [(base: String, key: KeyButton)] = []
	private weak var shiftKey: KeyButton?
	private weak var actionKey: KeyButton?
	private var lastShiftTapAt: TimeInterval = 0
	private var actionTitle: String?          // contextual label for the action key (go / search / send …)
	private var actionEnabled = true
	private let suggestionBar: SuggestionBar
	private(set) var inputKind: KeyboardInputKind = .standard
	private var lastLayoutProfile: KeyboardLayoutMetrics.Profile?

	/// Light haptic on each key press. Off unless enabled in settings; iOS remains the
	/// authority for physical-device availability and system haptic preferences.
	var hapticsEnabled = false
	private let keyHaptic = UISelectionFeedbackGenerator()
	private let actionHaptic = UIImpactFeedbackGenerator(style: .light)

	/// Prime the Taptic Engine so the first key tap fires without latency.
	func prepareHaptics() {
		guard hapticsEnabled else { return }
		keyHaptic.prepare()
		actionHaptic.prepare()
	}

	// MARK: Glide typing (P1: trajectory capture + tap/glide classification)
	//
	// A glide is one continuous finger stroke across the letters. We keep fire-on-contact
	// for taps (the start letter commits instantly), and only when a tracked finger
	// wanders past a threshold do we RECLASSIFY it as a glide: suppress its popup /
	// highlight / auto-repeat, ask the controller to remove the start letter it already
	// inserted, draw a trail, and on lift hand the whole path to the decoder. Decoding
	// itself is a later phase — `onGlide` is the seam.

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

	/// Letter-key centers + pitches for the decoder's view→grid mapping.
	private func glideLayout() -> GlideLayout {
		let centers: [(letter: Character, point: CGPoint)] = letterKeys.compactMap {
			guard let ch = $0.base.first else { return nil }
			return (ch, CGPoint(x: $0.key.frame.midX, y: $0.key.frame.midY))
		}
		return GlideLayout(centers: centers, xPitch: unitPitch, yPitch: rowHeight + rowSpacing)
	}

	private struct GlideTrack {
		var startKey: KeyButton?
		var points: [CGPoint] = []
		var times: [TimeInterval] = []          // per-sample touch timestamps (for velocity/dwell)
		var length: CGFloat = 0                 // cumulative path length
		var keys = Set<ObjectIdentifier>()      // distinct keys the path has entered
		var isGlide = false
	}
	private var glideTouch: UITouch?            // the single finger tracked for a glide
	private var glide: GlideTrack?
	private let trailLayer = CAShapeLayer()
	private let trailHeadLayer = CAShapeLayer()
	private var lastGlidePreviewTime: TimeInterval = 0
	private let glidePreviewInterval: TimeInterval = 0.035
	/// A stroke becomes a glide once it travels this far AND crosses into a second key —
	/// enough to tell a deliberate swipe from a jittery tap. Tuned for real hands in P5.
	private var glideThreshold: CGFloat { unitPitch * 0.85 }

	private let stripHeight: CGFloat = 44       // full minimum touch target for suggestions
	/// Telugu legends are drawn smaller and the rows shorter: the script's glyphs read
	/// large and the deck carries ~5 glyph rows, so at Latin size it towers over stock.
	private static let teluguGlyphScale: CGFloat = 0.6
	private static let teluguRowHeightScale: CGFloat = 0.78
	private var metrics: KeyboardLayoutMetrics {
		let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
		let base = KeyboardLayoutMetrics.resolve(width: width,
			idiom: traitCollection.userInterfaceIdiom)
		return languageMode == .telugu ? base.scalingRowHeight(Self.teluguRowHeightScale) : base
	}
	private var keySpacing: CGFloat { metrics.keySpacing }
	private var rowSpacing: CGFloat { metrics.rowSpacing }
	private var rowHeight: CGFloat { metrics.rowHeight }
	private var sidePad: CGFloat { metrics.sidePadding }
	private var topPad: CGFloat { metrics.topPadding }
	private var botPad: CGFloat { metrics.bottomPadding }

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
	private let collapsedTopPad: CGFloat = 0
	private var stripSpace: CGFloat { showsSuggestions ? stripHeight : collapsedTopPad }

	private var headerSpace: CGFloat {
		(isEmojiSearching || isMediaSearching) ? EmojiSearchHeader.height : stripSpace
	}

	/// Reserved for a browsing overlay without changing key geometry.
	private var expansionSpace: CGFloat { 0 }

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
		suggestionBar.onOpenClipboard = { [weak self] in self?.onOpenClipboard?() }
		suggestionBar.onPaste = { [weak self] in self?.onPaste?() }
		reload()
	}
	required init?(coder: NSCoder) { fatalError() }
	deinit {
		repeatTimer?.invalidate()
		cursorTimer?.invalidate()
		alternativeTimers.values.forEach { $0.invalidate() }
		NotificationCenter.default.removeObserver(self)
	}

	@objc private func reduceTransparencyDidChange() {
		updateBackdrop()
	}

	private func updateBackdrop() {
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

	/// Show/hide the strip's "Paste" offer (metadata-driven; the controller decides when).
	func setPasteOffer(_ show: Bool) {
		suggestionBar.setPasteOffer(show)
	}

	func setGlidePreview(_ word: String?, alternatives: [String] = [],
		confident: Bool = true) {
		suggestionBar.setGlidePreview(word, alternatives: alternatives, confident: confident)
	}

	func setGlideResult(_ word: String, alternatives: [String]) {
		suggestionBar.setGlideResult(word, alternatives: alternatives)
	}

	/// Show or hide the predictive strip. Hiding it shortens the keyboard; the controller
	/// updates its height constraint from `keyboardHeight` afterwards.
	func setShowsSuggestions(_ on: Bool) {
		guard on != showsSuggestions else { return }
		showsSuggestions = on
		suggestionBar.isHidden = !on
		setNeedsLayout()
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
	private func applyShiftState(_ new: ShiftState) {
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
		guard let actionKey else { return }
		if let title, !title.isEmpty {
			actionKey.setTitle(title)
			actionKey.accessibilityLabel = title
		} else {
			actionKey.setSymbol("return")
			actionKey.accessibilityLabel = "Return"
		}
	}

	func setActionEnabled(_ enabled: Bool) {
		actionEnabled = enabled
		actionKey?.setInputEnabled(enabled)
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

	// MARK: Emoji page (overlay collection view, not a key grid)

	private func showEmoji() {
		if isEmojiSearching { tearDownEmojiSearch() }   // emoji key pressed mid-search
		guard page != .emoji else { return }
		page = .emoji
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = []
		suggestionBar.isHidden = true
		let ev = EmojiKeyboardView(theme: theme, showsGlobe: showsGlobe)
		ev.onPick = { [weak self] in self?.onInsert?($0, nil) }
		ev.onDelete = { [weak self] in self?.onDelete?() }
		ev.onNextKeyboard = { [weak self] in self?.onNextKeyboard?() }
		ev.onABC = { [weak self] in self?.hideEmoji() }
		ev.onSearch = { [weak self] in self?.showEmojiSearch() }
		ev.onGIF = { [weak self] in self?.onOpenMedia?(.gifs) }
		ev.onStickers = { [weak self] in self?.onOpenMedia?(.stickers) }
		addSubview(ev)
		emojiView = ev
		onHeightChange?()                             // height snaps back if search was up
		setNeedsLayout()
		KBDiagnostics.recorder.sample()               // emoji page footprint shows up in health telemetry
	}
	private func hideEmoji() {
		emojiView?.removeFromSuperview()
		emojiView = nil
		page = .letters
		shift = .on                                   // sentences resume capitalized
		suggestionBar.isHidden = !showsSuggestions
		reload()
		onHeightChange?()                             // expansion released
	}

	func showMedia(kind: KlipyKind, query: String? = nil, hasFullAccess: Bool) {
		mediaHasFullAccess = hasFullAccess
		if isEmojiSearching { tearDownEmojiSearch() }
		if isMediaSearching { tearDownMediaSearch() }
		emojiView?.removeFromSuperview(); emojiView = nil
		discardMediaPanel()
		page = .media
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = []
		suggestionBar.isHidden = true
		let panel = MediaPanelView(theme: theme, showsGlobe: showsGlobe,
			hasFullAccess: hasFullAccess, kind: kind, query: query)
		panel.onABC = { [weak self] in self?.hideMedia() }
		panel.onNextKeyboard = { [weak self] in self?.onNextKeyboard?() }
		panel.onSearch = { [weak self] in self?.showMediaSearch(kind: $0) }
		addSubview(panel)
		mediaView = panel
		onHeightChange?()
		setNeedsLayout()
	}

	private func hideMedia() {
		discardMediaPanel()
		if isMediaSearching { tearDownMediaSearch() }
		page = .letters
		suggestionBar.isHidden = !showsSuggestions
		reload()
		onHeightChange?()
	}

	// MARK: Clipboard panel (overlay at deck height — the emoji-page pattern)

	func showClipboard(hasFullAccess: Bool) {
		if isEmojiSearching { tearDownEmojiSearch() }
		if isMediaSearching { tearDownMediaSearch() }
		emojiView?.removeFromSuperview(); emojiView = nil
		discardMediaPanel()
		guard page != .clipboard else { return }
		page = .clipboard
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = []
		suggestionBar.isHidden = true
		let panel = ClipboardPanelView(theme: theme, showsGlobe: showsGlobe, hasFullAccess: hasFullAccess)
		panel.onPick = { [weak self] in self?.onClipboardPick?($0) }
		panel.onABC = { [weak self] in self?.hideClipboard() }
		panel.onNextKeyboard = { [weak self] in self?.onNextKeyboard?() }
		addSubview(panel)
		clipboardView = panel
		onHeightChange?()
		setNeedsLayout()
	}

	private func hideClipboard() {
		clipboardView?.removeFromSuperview()
		clipboardView = nil
		page = .letters
		shift = .on
		suggestionBar.isHidden = !showsSuggestions
		reload()
		onHeightChange?()
	}

	private func showMediaSearch(kind: KlipyKind) {
		guard page == .media, !isMediaSearching else { return }
		discardMediaPanel()
		isMediaSearching = true
		mediaSearchKind = kind
		mediaQuery = ""
		page = .letters
		shift = .off
		suggestionBar.isHidden = true
		let header = EmojiSearchHeader(theme: theme)
		header.placeholder = "Search \(kind.displayName.lowercased())"
		header.onCancel = { [weak self] in self?.exitMediaSearch(submit: false) }
		header.onClear = { [weak self] in self?.mediaQuery = ""; self?.refreshMediaSearch() }
		addSubview(header)
		mediaSearchHeader = header
		reload(); refreshMediaSearch(); onHeightChange?(); setNeedsLayout()
	}

	private func refreshMediaSearch() {
		mediaSearchHeader?.update(query: mediaQuery, results: [], showingRecents: true)
	}

	private func tearDownMediaSearch() {
		mediaSearchHeader?.removeFromSuperview(); mediaSearchHeader = nil
		isMediaSearching = false
	}

	private func discardMediaPanel() {
		mediaView?.prepareForDismissal()
		mediaView?.removeFromSuperview()
		mediaView = nil
	}

	private func exitMediaSearch(submit: Bool) {
		guard isMediaSearching else { return }
		let query = mediaQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		mediaQuery = ""
		tearDownMediaSearch()
		showMedia(kind: mediaSearchKind, query: submit && !query.isEmpty ? query : nil,
			hasFullAccess: mediaHasFullAccess)
	}

	// MARK: Emoji search — the real deck types into a query (no mini keyboard)

	private func showEmojiSearch() {
		guard page == .emoji, !isEmojiSearching else { return }
		emojiView?.removeFromSuperview()
		emojiView = nil
		isEmojiSearching = true
		emojiQuery = ""
		page = .letters
		shift = .off                                  // emoji keywords are lowercase
		suggestionBar.isHidden = true
		let header = EmojiSearchHeader(theme: theme)
		header.onCancel = { [weak self] in self?.exitEmojiSearch(backToEmoji: true) }
		header.onClear = { [weak self] in
			guard let self else { return }
			emojiQuery = ""
			refreshEmojiSearch()
		}
		header.onPick = { [weak self] e in
			// Insert into the HOST document (stays in search, Gboard-style).
			self?.onInsert?(e, nil)
			KBEmojiRecents.add(e)
		}
		addSubview(header)
		emojiSearchHeader = header
		reload()
		refreshEmojiSearch()
		onHeightChange?()
		setNeedsLayout()
	}

	/// Remove the search chrome without deciding what comes next (caller picks the page).
	private func tearDownEmojiSearch() {
		emojiSearchHeader?.removeFromSuperview()
		emojiSearchHeader = nil
		isEmojiSearching = false
		emojiQuery = ""
	}

	private func exitEmojiSearch(backToEmoji: Bool) {
		guard isEmojiSearching else { return }
		tearDownEmojiSearch()
		if backToEmoji {
			showEmoji()                               // fires onHeightChange itself
		} else {
			suggestionBar.isHidden = !showsSuggestions
			reload()
			onHeightChange?()
			setNeedsLayout()
		}
	}

	/// The user touched the host document directly (tapped the input field, moved the
	/// cursor): snap the emoji page or emoji search back to
	/// the letter deck, stock-style. Returns true when something was actually dismissed
	/// (the controller refreshes the suggestion bar only then).
	@discardableResult
	func dismissOverlaysIfActive() -> Bool {
		if isEmojiSearching { exitEmojiSearch(backToEmoji: false); return true }
		if isMediaSearching { tearDownMediaSearch(); page = .letters; reload(); return true }
		if page == .emoji { hideEmoji(); return true }
		if page == .media { hideMedia(); return true }
		if page == .clipboard { hideClipboard(); return true }
		return false
	}

	/// Keyboard extensions can be terminated without a recoverable warning. If one
	/// does arrive, remove media immediately and release the clean atlas mapping; the
	/// next emoji open remaps the already-generated file.
	func releaseTransientMediaForMemoryPressure() {
		_ = dismissOverlaysIfActive()
		EmojiAtlas.purgeShared()
	}


	private func refreshEmojiSearch() {
		guard let header = emojiSearchHeader else { return }
		let results = emojiQuery.isEmpty
			? KBEmojiRecents.all()
			: (EmojiStore.bundled?.search(emojiQuery) ?? [])
		header.update(query: emojiQuery, results: results, showingRecents: emojiQuery.isEmpty)
	}

	// While emoji search is active the deck's keys edit the query; otherwise they
	// pass straight through to the controller. All key actions route through these.
	private func routeInsert(_ s: String, _ tap: KeyTap?) {
		if isEmojiSearching {
			emojiQuery += s.lowercased()
			refreshEmojiSearch()
			return
		}
		if isMediaSearching {
			mediaQuery += s.lowercased()
			refreshMediaSearch()
			return
		}
		onInsert?(s, tap)
	}
	private func routeOutput(_ output: KeyOutput, _ tap: KeyTap?) {
		if isEmojiSearching {
			if case .text(let text) = output { routeInsert(text, tap) }
			return
		}
		onKeyOutput?(output, tap)
	}
	private func routeDelete() {
		if isEmojiSearching {
			// A live query: delete edits the query, never the host document.
			if !emojiQuery.isEmpty { emojiQuery.removeLast(); refreshEmojiSearch(); return }
			// Empty query: fall through to the host — the emoji just inserted from the
			// results strip stays erasable without leaving search.
		}
		if isMediaSearching, !mediaQuery.isEmpty {
			mediaQuery.removeLast(); refreshMediaSearch(); return
		}
		onDelete?()
	}
	private func routeReturn() {
		if isEmojiSearching { exitEmojiSearch(backToEmoji: true); return }
		if isMediaSearching { exitMediaSearch(submit: true); return }
		onReturn?()
	}

	/// After a space on the numbers/symbols page, snap back to letters (stock behavior).
	/// Guarded so it is a no-op — and never rebuilds — during ordinary letter typing.
	private func returnToLettersFromSymbolPage() {
		guard page == .numbers || page == .symbols else { return }
		page = .letters
		reload()
	}

	// MARK: Layout

	override func layoutSubviews() {
		super.layoutSubviews()
		let resolvedMetrics = metrics
		trailLayer.lineWidth = max(7, min(10, resolvedMetrics.rowHeight * 0.20))
		if lastLayoutProfile != resolvedMetrics.profile {
			let wasResolved = lastLayoutProfile != nil
			lastLayoutProfile = resolvedMetrics.profile
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self.onHeightChange?()
				if wasResolved { self.onGeometryChange?() }
			}
		}
		CATransaction.begin(); CATransaction.setDisableActions(true)
		deckLayer.frame = bounds
		CATransaction.commit()
		if page == .emoji {
			emojiView?.frame = bounds
			return
		}
		if page == .media {
			mediaView?.frame = bounds
			return
		}
		if page == .clipboard {
			clipboardView?.frame = bounds
			return
		}
		if isEmojiSearching {
			emojiSearchHeader?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: EmojiSearchHeader.height)
		} else if isMediaSearching {
			mediaSearchHeader?.frame = CGRect(x: 0, y: 0, width: bounds.width,
				height: EmojiSearchHeader.height)
		} else {
			suggestionBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripSpace)
		}

		let availableWidth = bounds.width - sidePad * 2
		let W = min(availableWidth, resolvedMetrics.maximumDeckWidth)
		guard W > 0 else { return }
		let deckOriginX = (bounds.width - W) / 2
		let unit = max(1, (W - keySpacing*9)/10)
		unitPitch = unit + keySpacing            // grid-unit scale for tap offsets
		let wide = unit*1.5 + keySpacing/2
		let retW = unit*2 + keySpacing
		func fixed(_ k: KeyWidth) -> CGFloat {
			switch k { case .unit: return unit; case .wide: return wide; case .ret: return retW; case .flex: return 0 }
		}

		var y = headerSpace + topPad
		for row in rows {
			let flexCount = row.filter { $0.widthKind == .flex }.count
			let fixedSum = row.reduce(0) { $0 + fixed($1.widthKind) }
			let gaps = keySpacing * CGFloat(max(0, row.count - 1))
			let minimumFlexWidth = CGFloat(flexCount)
			let fixedScale = fixedSum > 0
				? min(1, max(0, (W - gaps - minimumFlexWidth) / fixedSum)) : 1
			let scaledFixedSum = fixedSum * fixedScale
			let flexW = flexCount > 0
				? max(1, (W - scaledFixedSum - gaps) / CGFloat(flexCount)) : 0
			let content = scaledFixedSum + flexW*CGFloat(flexCount) + gaps
			var x = deckOriginX + (flexCount == 0 ? (W - content)/2 : 0)
			for b in row {
				let w = b.widthKind == .flex ? flexW : fixed(b.widthKind) * fixedScale
				b.frame = CGRect(x: x, y: y, width: w, height: rowHeight)
				x += w + keySpacing
			}
			y += rowHeight + rowSpacing
		}
	}

	// MARK: Multi-touch — fire on contact, track every finger

	private var touchKeys: [UITouch: KeyButton] = [:]

	// Stock-style character balloon above the pressed key. One per active touch so
	// two-thumb typing shows both; removed on lift, slide-off, or cancel.
	private var touchPopups: [UITouch: UIView] = [:]
	private var poppedKeys: [UITouch: KeyButton] = [:]   // key whose glyph is hidden under its balloon
	private var alternativeTimers: [UITouch: Timer] = [:]
	private var alternativePopups: [UITouch: KeyAlternativesView] = [:]

	var containingKeys: [String] = []
	private func showPopup(for key: KeyButton, at point: CGPoint, touch: UITouch) {
		guard let text = key.popupText else { return }

		// Prevent duplicates for the same touch.
		touchPopups[touch]?.removeFromSuperview()

		let keyFrame = key.frame
		let edge: CGFloat = 3
		let tailHeight: CGFloat = 7

		// Prefer a key-height balloon, but cap it to the visible keyboard bounds.
		let popupWidth = max(keyFrame.width * 1.32, 42)
		let preferredPopupHeight = keyFrame.height + 5
		let maximumPopupHeight = max(1, bounds.height - edge * 2)
		let popupHeight = min(preferredPopupHeight, maximumPopupHeight)

		// Taps in expanded edge/gap targets resolve to a key even when they are outside
		// the visible cap. Anchor those previews at the touch so the popup follows the
		// same resolved press that will commit on lift.
		let anchorX = keyFrame.contains(point) ? keyFrame.midX : point.x
		let desiredX = anchorX - popupWidth / 2
		let maximumX = max(edge, bounds.width - edge - popupWidth)
		let popupX = min(max(desiredX, edge), maximumX)

		// Normally place it just above the key, then clamp within the keyboard frame.
		let desiredY = keyFrame.minY - popupHeight
		let maximumY = max(edge, bounds.height - edge - popupHeight)
		let popupY = min(max(edge, desiredY), maximumY)

		let popupFrame = CGRect(
			x: popupX,
			y: popupY,
			width: popupWidth,
			height: popupHeight
		)

		let popupView = UIView(frame: popupFrame)
		popupView.isUserInteractionEnabled = false
		popupView.backgroundColor = .clear
		popupView.layer.masksToBounds = false
		popupView.layer.zPosition = 1000

		let body = CGRect(x: 0, y: 0, width: popupView.bounds.width,
			height: max(1, popupView.bounds.height - tailHeight))
		let bubblePath = UIBezierPath(roundedRect: body, cornerRadius: 11)
		let anchor = min(max(keyFrame.midX - popupFrame.minX, 10), popupFrame.width - 10)
		let tail = UIBezierPath()
		tail.move(to: CGPoint(x: anchor - 7, y: body.maxY - 1))
		tail.addLine(to: CGPoint(x: anchor, y: popupView.bounds.maxY))
		tail.addLine(to: CGPoint(x: anchor + 7, y: body.maxY - 1))
		tail.close()
		bubblePath.append(tail)

		let shapeLayer = CAShapeLayer()
		shapeLayer.frame = popupView.bounds
		shapeLayer.path = bubblePath.cgPath
		shapeLayer.fillColor = theme.popupFill.cgColor

		shapeLayer.shadowColor = UIColor.black.cgColor
		shapeLayer.shadowOpacity = theme.isDark ? 0.45 : 0.20
		shapeLayer.shadowRadius = 4
		shapeLayer.shadowOffset = CGSize(width: 0, height: 2)
		shapeLayer.shadowPath = bubblePath.cgPath

		popupView.layer.addSublayer(shapeLayer)

		let label = UILabel(frame: body.insetBy(dx: 4, dy: 2))
		label.text = text
		label.textAlignment = .center
		label.font = .systemFont(ofSize: min(34, popupHeight * 0.78))
		label.textColor = theme.popupText

		popupView.addSubview(label)
		addSubview(popupView)
		bringSubviewToFront(popupView)

		touchPopups[touch] = popupView

		key.setCovered(true)
		poppedKeys[touch] = key
	}
	private func removePopup(for touch: UITouch) {
		touchPopups[touch]?.removeFromSuperview()
		touchPopups[touch] = nil
		poppedKeys[touch]?.setCovered(false)
		poppedKeys[touch] = nil
	}
	private func registerKey(_ key: KeyButton, at point: CGPoint, for touch: UITouch) {
		touchKeys[touch]?.setHighlighted(false)
		removePopup(for: touch)
		touchKeys[touch] = key
		key.setHighlighted(true)
		showPopup(for: key, at: point, touch: touch)
	}
	private func clearRegisteredKey(for touch: UITouch) {
		touchKeys[touch]?.setHighlighted(false)
		touchKeys[touch] = nil
		removePopup(for: touch)
	}

	private func beginAlternatives(for key: KeyButton, touch: UITouch,
								 base: String, alternatives: [String]) {
		guard !alternatives.isEmpty else { return }
		alternativeTimers[touch]?.invalidate()
		let options = [base] + alternatives.filter { $0 != base }
		let timer = Timer(timeInterval: 0.34, repeats: false) { [weak self, weak key, weak touch] _ in
			guard let self, let key, let touch,
				  self.touchKeys[touch] === key,
				  self.glide?.isGlide != true else { return }
			self.showAlternatives(options, for: key, touch: touch)
		}
		RunLoop.main.add(timer, forMode: .common)
		alternativeTimers[touch] = timer
	}

	private func showAlternatives(_ options: [String], for key: KeyButton, touch: UITouch) {
		alternativeTimers[touch] = nil
		removePopup(for: touch)
		let popup = KeyAlternativesView(options: options, theme: theme)
		let optionWidth: CGFloat = 42
		let width = min(bounds.width - 8, optionWidth * CGFloat(options.count))
		let height: CGFloat = 50
		let desiredX = key.frame.midX - width / 2
		let x = min(max(4, desiredX), max(4, bounds.width - width - 4))
		let y = max(3, key.frame.minY - height - 4)
		popup.frame = CGRect(x: x, y: y, width: width, height: height)
		addSubview(popup)
		bringSubviewToFront(popup)
		alternativePopups[touch] = popup
		key.setCovered(true)
		poppedKeys[touch] = key
		if hapticsEnabled { keyHaptic.selectionChanged(); keyHaptic.prepare() }
	}

	private func updateAlternativeSelection(for touch: UITouch, at point: CGPoint) {
		guard let popup = alternativePopups[touch] else { return }
		// Keep the originally committed base while the finger remains on the key.
		guard point.y <= popup.frame.maxY + 16 else { return }
		popup.select(atX: point.x - popup.frame.minX)
	}

	@discardableResult
	private func finishAlternatives(for touch: UITouch, commit: Bool) -> Bool {
		alternativeTimers[touch]?.invalidate()
		alternativeTimers[touch] = nil
		guard let popup = alternativePopups.removeValue(forKey: touch) else { return false }
		let baseSelected = popup.selectedIndex == 0
		let base = popup.baseValue
		let replacement = popup.selectedValue
		popup.removeFromSuperview()
		poppedKeys[touch]?.setCovered(false)
		poppedKeys[touch] = nil
		if commit, !baseSelected { replaceLastRoutedInput(base: base, with: replacement) }
		return true
	}

	private func replaceLastRoutedInput(base: String, with replacement: String) {
		if isEmojiSearching {
			if !emojiQuery.isEmpty { emojiQuery.removeLast() }
			emojiQuery.append(contentsOf: replacement.lowercased())
			refreshEmojiSearch()
		} else {
			onReplaceLastInput?(base, replacement)
		}
	}

	// Press-and-hold auto-repeat (delete): one timer, tied to the finger holding it.
	private var repeatTimer: Timer?
	private var repeatTouch: UITouch?
	private weak var repeatKey: KeyButton?

	private func beginRepeat(_ key: KeyButton, touch: UITouch) {
		endRepeat()
		repeatKey = key
		repeatTouch = touch
		let t = Timer(timeInterval: 0.09, repeats: true) { [weak self, weak key] _ in
			guard let self, let key, self.repeatKey === key else { self?.endRepeat(); return }
			key.trigger()
		}
		t.fireDate = Date().addingTimeInterval(0.4)     // hold ~0.4s before it starts repeating
		RunLoop.main.add(t, forMode: .common)
		repeatTimer = t
	}
	private func endRepeat() {
		repeatTimer?.invalidate(); repeatTimer = nil
		repeatTouch = nil; repeatKey = nil
	}

	// Space cursor control. A normal tap remains touch-down-fast. Holding retracts
	// that one provisional space, then horizontal motion moves the host cursor.
	private var cursorTimer: Timer?
	private weak var cursorTouch: UITouch?
	private weak var cursorKey: KeyButton?
	private var cursorStartX: CGFloat = 0
	private var cursorStep = 0
	private var isCursorTracking = false

	private func beginCursorHold(_ key: KeyButton, touch: UITouch, point: CGPoint) {
		endCursorHold()
		cursorTouch = touch
		cursorKey = key
		cursorStartX = point.x
		let timer = Timer(timeInterval: 0.32, repeats: false) { [weak self, weak key, weak touch] _ in
			guard let self, let key, let touch,
				  self.cursorTouch === touch,
				  self.touchKeys[touch] === key else { return }
			self.cursorTimer = nil
			self.isCursorTracking = true
			self.removePopup(for: touch)
			self.onCursorModeBegan?()
			if self.hapticsEnabled { self.keyHaptic.selectionChanged(); self.keyHaptic.prepare() }
		}
		RunLoop.main.add(timer, forMode: .common)
		cursorTimer = timer
	}

	private func updateCursorHold(_ touch: UITouch, point: CGPoint) {
		guard cursorTouch === touch, isCursorTracking else { return }
		let stepWidth = max(12, unitPitch * 0.45)
		let nextStep = Int((point.x - cursorStartX) / stepWidth)
		let delta = nextStep - cursorStep
		guard delta != 0 else { return }
		cursorStep = nextStep
		onCursorMove?(delta)
		if hapticsEnabled { keyHaptic.selectionChanged(); keyHaptic.prepare() }
	}

	private func endCursorHold(notify: Bool = true) {
		cursorTimer?.invalidate()
		cursorTimer = nil
		let wasTracking = isCursorTracking
		cursorTouch = nil
		cursorKey = nil
		cursorStep = 0
		isCursorTracking = false
		if notify, wasTracking { onCursorModeEnded?() }
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		// UIKit gives a Set. Sort simultaneous begins so multi-touch replay and fast
		// thumb rollover commit in a deterministic order.
		let ordered = touches.sorted {
			if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
			let a = $0.location(in: self), b = $1.location(in: self)
			return a.x == b.x ? a.y < b.y : a.x < b.x
		}
		for touch in ordered {
			// A classified glide owns the deck: other fingers are ignored.
			if glide?.isGlide == true { continue }

			let p = touch.location(in: self)
			guard let key = key(at: p) else { continue }
			if key.isInputModeSwitch {
				if let event { onInputModeEvent?(key, event) } else { key.trigger() }
				performHaptic(for: key)
				registerKey(key, at: p, for: touch)
				continue
			}
			if key.repeats {
				key.trigger()                             // delete: immediate + auto-repeat
				performHaptic(for: key)
				registerKey(key, at: p, for: touch)
				beginRepeat(key, touch: touch)
			} else {
				// Commit on touch-down. If this becomes a glide, `onGlideBegan` retracts
				// this one provisional start letter before any preview/final decode.
				activeTap = keyTap(for: key, at: p)
				key.trigger()
				activeTap = nil
				performHaptic(for: key)
				// Popup allocation, highlighting, and long-press timers are deliberately
				// after the host edit; they must never delay visible text insertion.
				registerKey(key, at: p, for: touch)
				if let base = key.committedText ?? key.popupText {
					beginAlternatives(for: key, touch: touch, base: base,
						alternatives: key.alternatives)
				}
				if key.isSpace, !isEmojiSearching {
					beginCursorHold(key, touch: touch, point: p)
				}
				if glideEnabled,
				   glideTouch == nil,
				   page == .letters,
				   !isEmojiSearching,   // search queries are tapped, not glided
				   key.letterBase != nil {
					glideTouch = touch
					lastGlidePreviewTime = 0
					glide = GlideTrack(startKey: key, points: [p], times: [touch.timestamp],
									   keys: [ObjectIdentifier(key)])
				}
			}
		}
	}

	private func performHaptic(for key: KeyButton) {
		guard hapticsEnabled else { return }
		if key.letterBase != nil || key.role == .normal {
			keyHaptic.selectionChanged()
			keyHaptic.prepare()
		} else {
			actionHaptic.impactOccurred(intensity: key.repeats ? 0.72 : 0.56)
			actionHaptic.prepare()
		}
	}

	/// The tap's offset from the pressed key's center, in key-grid units (the same
	/// scale as the spatial model's key coordinates). Letter keys only.
	private func keyTap(for key: KeyButton, at p: CGPoint) -> KeyTap? {
		guard key.letterBase != nil, unitPitch > 0 else { return nil }
		let dx = Double((p.x - key.frame.midX) / unitPitch)
		let dy = Double((p.y - key.frame.midY) / (rowHeight + rowSpacing))
		return KeyTap(dx: min(max(dx, -1), 1), dy: min(max(dy, -1), 1))
	}

	/// Next-character priors for target resizing, refreshed by the controller after
	/// each background suggestion pass. Empty = no bias (plain nearest-key).
	func setKeyPriors(_ priors: [Character: Double]) { charPriors = priors }
	override func touchesMoved(
		_ touches: Set<UITouch>,
		with event: UIEvent?
	) {
		for touch in touches {
			let point = touch.location(in: self)
			if cursorTouch === touch {
				updateCursorHold(touch, point: point)
				if isCursorTracking { continue }
			}
			if alternativePopups[touch] != nil {
				updateAlternativeSelection(for: touch, at: point)
				continue
			}
			if let key = touchKeys[touch], key.isInputModeSwitch {
				if let event { onInputModeEvent?(key, event) }
				continue
			}

			if touch == glideTouch, glide != nil {
				trackGlide(touch)
				if glide?.isGlide == true { continue }
			}

			if touch == repeatTouch {
				if let key = touchKeys[touch],
				   !key.frame.contains(point) {
					endRepeat()
				}

				continue
			}

			// A non-glide tap already committed on touch-down. Sliding within the
			// cancellation threshold does not silently change the inserted key.
		}
	}
	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			if cursorTouch === touch { endCursorHold() }
			if finishAlternatives(for: touch, commit: true) {
				if touch == glideTouch { glideTouch = nil; glide = nil; clearTrail() }
				clearRegisteredKey(for: touch)
				continue
			}
			if let key = touchKeys[touch], key.isInputModeSwitch {
				if let event { onInputModeEvent?(key, event) }
				clearRegisteredKey(for: touch)
				continue
			}
			if touch == glideTouch, glide?.isGlide == true {   // a glide: decode, commit nothing
				let pts = glide?.points ?? []
				let times = glide?.times ?? []
				let layout = glideLayout()
				glideTouch = nil; glide = nil; lastGlidePreviewTime = 0; clearTrail()
				clearRegisteredKey(for: touch)
				onGlide?(pts, times, layout)
				continue
			}
			if touch == repeatTouch {                          // delete: just stop
				endRepeat()
				clearRegisteredKey(for: touch)
				continue
			}
			if touch == glideTouch { glideTouch = nil; glide = nil; clearTrail() }
			clearRegisteredKey(for: touch)
		}
	}
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			if cursorTouch === touch { endCursorHold() }
			_ = finishAlternatives(for: touch, commit: false)
			if let key = touchKeys[touch], key.isInputModeSwitch, let event {
				onInputModeEvent?(key, event)
			}
			if touch == glideTouch {
				glideTouch = nil; glide = nil; lastGlidePreviewTime = 0; clearTrail()
				suggestionBar.setGlidePreview(nil)
				onGlideCancelled?()
			}
			if touch == repeatTouch { endRepeat() }
			clearRegisteredKey(for: touch)
		}
	}
	
	// So the deadzone touch doesn't register as Glide and pop up isn't deleted
	private func visualLetterKey(at point: CGPoint) -> KeyButton? {
		for row in rows {
			for key in row {
				guard key.letterBase != nil else { continue }

				let frame = key.frame

				let isInside =
					point.x >= frame.minX &&
					point.x <= frame.maxX &&
					point.y >= frame.minY &&
					point.y <= frame.maxY

				if isInside {
					return key
				}
			}
		}

		return nil
	}

	/// Feed one movement sample into the tracked stroke; reclassify to a glide once it
	/// travels past the threshold across ≥2 keys, then suppress its tap feedback and drop
	/// retract its provisional touch-down letter before the swipe decodes on lift.
	private func trackGlide(_ touch: UITouch) {
		guard var glide = glide else { return }
		let wasGlide = glide.isGlide

		let point = touch.location(in: self)

		if let lastPoint = glide.points.last {
			glide.length += hypot(
				point.x - lastPoint.x,
				point.y - lastPoint.y
			)
		}

		glide.points.append(point)
		glide.times.append(touch.timestamp)

		// Important: glide classification uses actual visible letter frames,
		// not dynamically expanded tap regions.
		if let letterKey = visualLetterKey(at: point) {
			glide.keys.insert(ObjectIdentifier(letterKey))
		}

		if !glide.isGlide,
		   glide.length >= glideThreshold,
		   glide.keys.count >= 2 {
			glide.isGlide = true

			alternativeTimers[touch]?.invalidate()
			alternativeTimers[touch] = nil
			_ = finishAlternatives(for: touch, commit: false)
			clearRegisteredKey(for: touch)
			onGlideBegan?()
		}

		self.glide = glide

		if glide.isGlide {
			updateTrail(glide.points)
			if !wasGlide || touch.timestamp - lastGlidePreviewTime >= glidePreviewInterval {
				lastGlidePreviewTime = touch.timestamp
				onGlidePreview?(glide.points, glide.times, glideLayout())
			}
		}
	}
	private func updateTrail(_ points: [CGPoint]) {
		guard points.count > 1 else { return }
		let path = UIBezierPath()
		path.move(to: points[0])
		if points.count == 2 {
			path.addLine(to: points[1])
		} else {
			for index in 1..<(points.count - 1) {
				let control = points[index]
				let next = points[index + 1]
				let midpoint = CGPoint(x: (control.x + next.x) / 2,
					y: (control.y + next.y) / 2)
				path.addQuadCurve(to: midpoint, controlPoint: control)
			}
			if let penultimate = points.dropLast().last, let last = points.last {
				path.addQuadCurve(to: last, controlPoint: penultimate)
			}
		}
		let point = points[points.count - 1]
		let headDiameter = max(20, min(28, rowHeight * 0.58))
		let head = CGRect(x: point.x - headDiameter / 2,
						  y: point.y - headDiameter / 2,
						  width: headDiameter,
						  height: headDiameter)
		CATransaction.begin(); CATransaction.setDisableActions(true)
		trailLayer.path = path.cgPath
		trailHeadLayer.path = UIBezierPath(ovalIn: head).cgPath
		CATransaction.commit()
	}
	private func clearTrail() {
		CATransaction.begin(); CATransaction.setDisableActions(true)
		trailLayer.path = nil
		trailHeadLayer.path = nil
		CATransaction.commit()
	}

	private func key(at p: CGPoint) -> KeyButton? {
		// Resolve the visual row first. Language priors may arbitrate a horizontal
		// gap, but can never pull a touch into a different row.
		let row = rows.min { lhs, rhs in
			func verticalDistance(_ keys: [KeyButton]) -> CGFloat {
				guard let first = keys.first else { return .greatestFiniteMagnitude }
				let frame = first.frame
				return max(frame.minY - p.y, 0, p.y - frame.maxY)
			}
			return verticalDistance(lhs) < verticalDistance(rhs)
		} ?? []
		var best: KeyButton?
		var bestDist = CGFloat.greatestFiniteMagnitude
		for key in row {
				let f = key.frame
				// Authoritative inner core: a tap solidly inside a key ALWAYS returns it,
				// so LM target-resizing can only ever affect edge and gap taps — the
				// keyboard never feels like it's fighting a deliberate press.
				if f.insetBy(dx: f.width * 0.28, dy: f.height * 0.28).contains(p) { return key }
				let dx = max(f.minX - p.x, 0, p.x - f.maxX)
				let dy = max(f.minY - p.y, 0, p.y - f.maxY)
				var d = dx*dx + dy*dy                          // squared distance to the key rect
				// LM bias: shrink the effective distance of a likely next letter, capped
				// well under one key pitch so it only ever wins genuinely ambiguous taps.
				if let base = key.letterBase, let prior = charPriors[Character(base)] {
					d -= CGFloat(prior) * unitPitch * unitPitch * 0.12
				}
				if d < bestDist { bestDist = d; best = key }
		}
		return best                                           // nearest key — gaps aren't dead zones
	}

	// MARK: Build keys

	private func reload() {
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
		actionKey?.setInputEnabled(actionEnabled)
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

	func keyFramesForTesting() -> [CGRect] {
		rows.flatMap { $0 }.map(\.frame)
	}

	private func shifted(_ c: String) -> String { shift == .off ? c : c.uppercased() }
	private func accentAlternatives(for base: String) -> [String] {
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
	private var shiftSymbol: String {
		switch shift { case .off: return "shift"; case .on: return "shift.fill"; case .locked: return "capslock.fill" }
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
			role: .accentSoft, width: .wide, repeats: true) { [weak self] in self?.routeDelete() }
		let ret: KeySpec = {
			if let t = actionTitle, !t.isEmpty {
				return KeySpec(label: t, accessibilityLabel: t, role: .accent, width: .ret, pill: true) { [weak self] in self?.routeReturn() }
			}
			return KeySpec(symbol: "return", accessibilityLabel: "Return",
				role: .accent, width: .ret, pill: true) { [weak self] in self?.routeReturn() }
		}()
		let space = KeySpec(label: "space", accessibilityLabel: "Space", width: .flex,
			pill: true, isSpace: true) { [weak self] in
			self?.routeInsert(" ", nil)
			self?.returnToLettersFromSymbolPage()   // stock: space snaps back to ABC from 123/#+=
		}
		func switchKey(_ l: String, to t: KeyboardSurfacePage) -> KeySpec {
			let spoken = t == .letters ? "Letters" : (t == .numbers ? "Numbers" : "Symbols")
			return KeySpec(label: l, accessibilityLabel: spoken,
				role: .special, width: .wide, pill: true) { [weak self] in self?.page = t; self?.reload() }
		}
		let emojiKey = KeySpec(symbol: "face.smiling", accessibilityLabel: "Emoji",
			role: .special, width: .unit, pill: false) { [weak self] in self?.showEmoji() }
		func bottom(_ leading: KeySpec, extras: [KeySpec] = [],
			trailingExtras: [KeySpec] = []) -> [KeySpec] {
			var r = [leading]
			if showsGlobe {
				r.append(KeySpec(symbol: "keyboard", accessibilityLabel: "Next Keyboard",
					role: .special, width: .unit, pill: true, isInputModeSwitch: true) { [weak self] in self?.onNextKeyboard?() })
			}
			r.append(emojiKey)
			r.append(contentsOf: extras)
			r.append(space)
			r.append(contentsOf: trailingExtras)
			r.append(ret)
			return r
		}
		let shiftKey = KeySpec(symbol: shiftSymbol, accessibilityLabel: "Shift",
			role: .accentSoft, width: .wide, isShift: true) { [weak self] in
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
						accessibilityLabel: "Shift", role: .accentSoft, width: .wide,
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
					[switchKey("#+=", to: .symbols)] + [".",",","?","!","'"].map(punct) + [del],
					bottom(switchKey("ABC", to: .letters))
				]
			}
			return [
				["1","2","3","4","5","6","7","8","9","0"].map(charSpec),
				["-","/",":",";","(",")","$","&","@","\""].map(charSpec),
				[switchKey("#+=", to: .symbols)] + [".",",","?","!","'"].map(punct) + [del],
				bottom(switchKey("ABC", to: .letters))
			]
		case .symbols:
			return [
				["[","]","{","}","#","%","^","*","+","="].map(charSpec),
				["_","\\","|","~","<",">","€","£","¥","•"].map(charSpec),
				[switchKey("123", to: .numbers)] + [".",",","?","!","'"].map(punct) + [del],
				bottom(switchKey("ABC", to: .letters))
			]
		case .emoji, .media, .clipboard:
			return []   // these use a full-bounds overlay, not a key grid
		}
	}
}

#if DEBUG
private struct KeyboardMetricsPreview: UIViewRepresentable {
	let dark: Bool
	let language: KBLanguageMode
	let width: CGFloat

	func makeUIView(context: Context) -> KeyboardView {
		let view = KeyboardView(theme: .system(dark: dark), languageMode: language)
		view.setSuggestions(["the", "keyboard", "layout"])
		return view
	}

	func updateUIView(_ uiView: KeyboardView, context: Context) {}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyboardView,
		context: Context) -> CGSize? {
		uiView.frame = CGRect(x: 0, y: 0, width: width, height: 320)
		uiView.layoutIfNeeded()
		return CGSize(width: width, height: uiView.keyboardHeight)
	}
}

#Preview("English 393pt") {
	KeyboardMetricsPreview(dark: false, language: .english, width: 393)
		.frame(width: 393)
		.background(Color(white: 0.55))
}

#Preview("English Dark 430pt") {
	KeyboardMetricsPreview(dark: true, language: .english, width: 430)
		.frame(width: 430)
		.background(Color(white: 0.18))
}

#Preview("Telugu 393pt") {
	KeyboardMetricsPreview(dark: false, language: .telugu, width: 393)
		.frame(width: 393)
		.background(Color(white: 0.55))
}
#endif
