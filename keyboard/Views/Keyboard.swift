import UIKit
import CoreText
import os

// KeyboardView — the on-screen key deck (touches, layout, popups, shift).
// Emoji picker → Emoji.swift; keys/theme/suggestion bar → their own files.

final class KeyboardView: UIView {

	/// The second argument is the tap's landing point relative to the pressed key's
	/// center, in key-grid units (nil for non-letter keys and programmatic inserts) —
	/// the channel model uses it for sub-key precision.
	var onInsert:         ((String, KeyTap?) -> Void)?
	var onDelete:         (() -> Void)?
	var onReturn:         (() -> Void)?
	var onNextKeyboard:   (() -> Void)?
	var onPickSuggestion: ((String) -> Void)?
	/// Fired whenever `keyboardHeight` changes out from under the controller (entering
	/// or leaving emoji search, which swaps the 34 pt strip for the 86 pt search header)
	/// so it can update its height constraint.
	var onHeightChange:   (() -> Void)?

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
	private var page: KeyboardPage = .letters
	private var shift: ShiftState = .on
	private var rows: [[KeyButton]] = []
	private var emojiView: EmojiKeyboardView?
	// Emoji search (Gboard-style): the REAL letter deck types into a query shown in a
	// header where the suggestion strip normally sits; results insert into the host.
	private var emojiSearchHeader: EmojiSearchHeader?
	private var isEmojiSearching = false
	private var emojiQuery = ""
	// Live references so a shift change can relabel in place instead of rebuilding every key.
	private var letterKeys: [(base: String, key: KeyButton)] = []
	private weak var shiftKey: KeyButton?
	private var actionTitle: String?          // contextual label for the action key (go / search / send …)
	private let suggestionBar: SuggestionBar

	/// Light haptic on each key press. Off unless enabled in settings (and the keyboard
	/// has Full Access — otherwise iOS silently ignores the feedback generator).
	var hapticsEnabled = false
	private let haptic = UIImpactFeedbackGenerator(style: .light)

	/// Prime the Taptic Engine so the first key tap fires without latency.
	func prepareHaptics() { if hapticsEnabled { haptic.prepare() } }

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
	var onGlide: (([CGPoint], GlideLayout) -> Void)?

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
		var length: CGFloat = 0                 // cumulative path length
		var keys = Set<ObjectIdentifier>()      // distinct keys the path has entered
		var isGlide = false
	}
	private var glideTouch: UITouch?            // the single finger tracked for a glide
	private var glide: GlideTrack?
	private let trailLayer = CAShapeLayer()
	/// A stroke becomes a glide once it travels this far AND crosses into a second key —
	/// enough to tell a deliberate swipe from a jittery tap. Tuned for real hands in P5.
	private var glideThreshold: CGFloat { unitPitch * 0.85 }

	private let keySpacing: CGFloat = 6
	private let rowSpacing: CGFloat = 8         // rows sit a touch closer; the reclaimed space…
	private let rowHeight:  CGFloat = 45        // …goes into taller, easier-to-hit keys
	private let stripHeight: CGFloat = 34       // predictive strip trimmed (was 40) to free that space
	private let sidePad: CGFloat = 6            // keeps q/p off the screen edges
	private let topPad: CGFloat = 5
	private let botPad: CGFloat = 6

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

	private var headerSpace: CGFloat { isEmojiSearching ? EmojiSearchHeader.height : stripSpace }

	var keyboardHeight: CGFloat { headerSpace + topPad + rowHeight*4 + rowSpacing*3 + botPad }

	init(theme: KeyboardTheme, showsGlobe: Bool = true) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.suggestionBar = SuggestionBar(theme: theme)
		super.init(frame: .zero)
		backgroundColor = .clear
		deckLayer.colors = [theme.backgroundTop.cgColor, theme.backgroundBottom.cgColor]
		deckLayer.startPoint = CGPoint(x: 0.5, y: 0)
		deckLayer.endPoint = CGPoint(x: 0.5, y: 1)
		layer.insertSublayer(deckLayer, at: 0)
		trailLayer.fillColor = nil
		trailLayer.lineWidth = 9
		trailLayer.lineCap = .round
		trailLayer.lineJoin = .round
		trailLayer.strokeColor = theme.accentStart.withAlphaComponent(0.30).cgColor
		layer.addSublayer(trailLayer)
		isMultipleTouchEnabled = true            // <-- fast typists / overlapping fingers
		addSubview(suggestionBar)
		suggestionBar.isHidden = !showsSuggestions    // start collapsed until the host is known
		suggestionBar.onPick = { [weak self] in self?.onPickSuggestion?($0) }
		reload()
	}
	required init?(coder: NSCoder) { fatalError() }
	deinit { repeatTimer?.invalidate() }

	func setSuggestions(_ s: [String], typedPrefix: String? = nil) {
		suggestionBar.setSuggestions(s, typedPrefix: typedPrefix)
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
		guard shift != .locked, !isEmojiSearching else { return }
		applyShiftState(on ? .on : .off)
	}

	/// Change shift state WITHOUT rebuilding the keys. The hot path used to call reload()
	/// here — recreating all ~33 key views on every auto-shift (each sentence start, each
	/// shifted letter). Now we just relabel the letter keys and swap the shift glyph.
	private func applyShiftState(_ new: ShiftState) {
		guard shift != new else { return }
		shift = new
		guard page == .letters else { return }   // shift only affects the letters layout
		for (base, key) in letterKeys { key.setTitle(shifted(base)) }
		shiftKey?.setSymbol(shiftSymbol)
	}

	/// Set the contextual label on the action (return) key. Pass nil for a plain
	/// newline glyph. Only rebuilds when it actually changes.
	func setActionTitle(_ title: String?) {
		guard title != actionTitle else { return }
		actionTitle = title
		reload()
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
		addSubview(ev)
		emojiView = ev
		onHeightChange?()                             // height snaps back if search was up
		setNeedsLayout()
	}
	private func hideEmoji() {
		emojiView?.removeFromSuperview()
		emojiView = nil
		page = .letters
		shift = .on                                   // sentences resume capitalized
		suggestionBar.isHidden = !showsSuggestions
		reload()
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
		onInsert?(s, tap)
	}
	private func routeDelete() {
		if isEmojiSearching {
			// Only edits the query — never reaches into the host document from search.
			if !emojiQuery.isEmpty { emojiQuery.removeLast(); refreshEmojiSearch() }
			return
		}
		onDelete?()
	}
	private func routeReturn() {
		if isEmojiSearching { exitEmojiSearch(backToEmoji: true); return }
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
		CATransaction.begin(); CATransaction.setDisableActions(true)
		deckLayer.frame = bounds
		CATransaction.commit()
		if page == .emoji {
			emojiView?.frame = bounds
			return
		}
		if isEmojiSearching {
			emojiSearchHeader?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: EmojiSearchHeader.height)
		} else {
			suggestionBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripSpace)
		}

		let W = bounds.width - sidePad*2
		guard W > 0 else { return }
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
			let flexW = flexCount > 0 ? max(1, (W - fixedSum - gaps)/CGFloat(flexCount)) : 0
			let content = fixedSum + flexW*CGFloat(flexCount) + gaps
			var x = sidePad + (flexCount == 0 ? (W - content)/2 : 0)
			for b in row {
				let w = b.widthKind == .flex ? flexW : fixed(b.widthKind)
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
	private let popupClearDelay: TimeInterval = 0.018

	var containingKeys: [String] = []
	private func showPopup(for key: KeyButton, at point: CGPoint, touch: UITouch) {
		guard let text = key.popupText else { return }

		// Prevent duplicates for the same touch.
		touchPopups[touch]?.removeFromSuperview()

		let keyFrame = key.frame
		let edge: CGFloat = 3
		let gap: CGFloat = 4

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
		let desiredY = keyFrame.minY - popupHeight - gap
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

		// A simple rounded rectangle: no neck or tail.
		let bubblePath = UIBezierPath(
			roundedRect: popupView.bounds,
			cornerRadius: 11
		)

		let shapeLayer = CAShapeLayer()
		shapeLayer.frame = popupView.bounds
		shapeLayer.path = bubblePath.cgPath
		shapeLayer.fillColor = (
			theme.isDark
				? UIColor(hex: 0x4A4A50)
				: UIColor.white
		).cgColor

		shapeLayer.shadowColor = UIColor.black.cgColor
		shapeLayer.shadowOpacity = theme.isDark ? 0.45 : 0.20
		shapeLayer.shadowRadius = 4
		shapeLayer.shadowOffset = CGSize(width: 0, height: 2)
		shapeLayer.shadowPath = bubblePath.cgPath

		popupView.layer.addSublayer(shapeLayer)

		let label = UILabel(frame: popupView.bounds.insetBy(dx: 4, dy: 2))
		label.text = text
		label.textAlignment = .center
		label.font = theme.font.uiFont(
			ofSize: min(34, popupHeight * 0.78)
		)
		label.textColor = theme.isDark
			? UIColor(hex: 0xECECF0)
			: UIColor(hex: 0x1B1B1D)

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
	private func clearCommittedPopups(except preservedTouch: UITouch? = nil) {
		for touch in Array(touchPopups.keys) {
			if let preservedTouch, touch === preservedTouch { continue }
			guard !pendingCommit.contains(touch), touch != repeatTouch else { continue }
			clearRegisteredKey(for: touch)
		}
	}
	private func registerKey(_ key: KeyButton, at point: CGPoint, for touch: UITouch) {
		clearCommittedPopups(except: touch)
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
			key.action()
		}
		t.fireDate = Date().addingTimeInterval(0.4)     // hold ~0.4s before it starts repeating
		RunLoop.main.add(t, forMode: .common)
		repeatTimer = t
	}
	private func endRepeat() {
		repeatTimer?.invalidate(); repeatTimer = nil
		repeatTouch = nil; repeatKey = nil
	}

	// Keys register on LIFT, not on contact (Apple-style): touch-down only previews
	// (highlight + balloon). A deferred key commits when the finger lifts, OR when a NEW
	// key is pressed while it's still held — fast "roll onto the next key before releasing
	// the last" typing, committed in press order. Delete is the exception: it fires on
	// contact and auto-repeats while held. Because nothing is inserted until lift, a glide
	// simply never commits its letter — there's no insert to undo.
	private var pendingCommit: Set<UITouch> = []       // deferred taps awaiting lift/rollover

	/// Fire a deferred key: the one under the finger at `p` (updated as the finger moves,
	/// so a slide-and-lift commits the key you release on). Idempotent via `pendingCommit`.
	private func commit(_ touch: UITouch, at p: CGPoint) {
		guard pendingCommit.remove(touch) != nil, let key = touchKeys[touch] else { return }
		if touch == glideTouch { glideTouch = nil; glide = nil; clearTrail() }  // it was a tap

		let shouldHoldPopup = key.popupText != nil
		if shouldHoldPopup, touchPopups[touch] == nil {
			showPopup(for: key, at: p, touch: touch)
		}

		activeTap = keyTap(for: key, at: p)
		key.action()
		activeTap = nil

		if shouldHoldPopup {
			DispatchQueue.main.asyncAfter(deadline: .now() + popupClearDelay) { [weak self, weak key] in
				guard let self, !self.pendingCommit.contains(touch) else { return }
				if let key, self.touchKeys[touch] === key {
					self.clearRegisteredKey(for: touch)
				} else {
					self.removePopup(for: touch)
				}
			}
		} else {
			clearRegisteredKey(for: touch)
		}
	}

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			// A classified glide owns the deck: other fingers are ignored.
			if glide?.isGlide == true { continue }
			// Rollover: a new key press finalizes any keys still held under other fingers.
			for held in Array(pendingCommit) where held != touch { commit(held, at: held.location(in: self)) }

			let p = touch.location(in: self)
			guard let key = key(at: p) else { continue }
			registerKey(key, at: p, for: touch)           // preview follows the registered key
			if hapticsEnabled { haptic.impactOccurred(intensity: 0.6); haptic.prepare() }
			if key.repeats {
				key.action()                              // delete: immediate + auto-repeat
				beginRepeat(key, touch: touch)
			} else {
				pendingCommit.insert(touch)               // everything else registers on lift
				if glideTouch == nil,
				   page == .letters,
				   !isEmojiSearching,               // search queries are tapped, not glided
				   key.letterBase != nil {
					glideTouch = touch
					glide = GlideTrack(startKey: key, points: [p], keys: [ObjectIdentifier(key)])
				}
			}
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

			guard pendingCommit.contains(touch),
				  let newKey = key(at: point) else {
				continue
			}

			if newKey !== touchKeys[touch] {
				registerKey(newKey, at: point, for: touch)
			}
		}
	}
	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			if touch == glideTouch, glide?.isGlide == true {   // a glide: decode, commit nothing
				let pts = glide?.points ?? []
				let layout = glideLayout()
				glideTouch = nil; glide = nil; clearTrail()
				pendingCommit.remove(touch)
				clearRegisteredKey(for: touch)
				onGlide?(pts, layout)
				continue
			}
			if touch == repeatTouch {                          // delete: just stop
				endRepeat()
				clearRegisteredKey(for: touch)
				continue
			}
			commit(touch, at: touch.location(in: self))        // deferred tap → register on lift
		}
	}
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			if touch == glideTouch { glideTouch = nil; glide = nil; clearTrail() }
			pendingCommit.remove(touch)                        // cancelled: never commit
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
	/// it from `pendingCommit` (nothing was inserted, so the swipe decodes on lift instead).
	private func trackGlide(_ touch: UITouch) {
		guard var glide = glide else { return }

		let point = touch.location(in: self)

		if let lastPoint = glide.points.last {
			glide.length += hypot(
				point.x - lastPoint.x,
				point.y - lastPoint.y
			)
		}

		glide.points.append(point)

		// Important: glide classification uses actual visible letter frames,
		// not dynamically expanded tap regions.
		if let letterKey = visualLetterKey(at: point) {
			glide.keys.insert(ObjectIdentifier(letterKey))
		}

		if !glide.isGlide,
		   glide.length >= glideThreshold,
		   glide.keys.count >= 2 {
			glide.isGlide = true

			clearRegisteredKey(for: touch)
			pendingCommit.remove(touch)
		}

		self.glide = glide

		if glide.isGlide {
			updateTrail(glide.points)
		}
	}
	private func updateTrail(_ points: [CGPoint]) {
		guard points.count > 1 else { return }
		let path = UIBezierPath()
		path.move(to: points[0])
		for p in points.dropFirst() { path.addLine(to: p) }
		CATransaction.begin(); CATransaction.setDisableActions(true)
		trailLayer.path = path.cgPath
		CATransaction.commit()
	}
	private func clearTrail() {
		CATransaction.begin(); CATransaction.setDisableActions(true)
		trailLayer.path = nil
		CATransaction.commit()
	}

	private func key(at p: CGPoint) -> KeyButton? {
		var best: KeyButton?
		var bestDist = CGFloat.greatestFiniteMagnitude
		for row in rows {
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
		}
		return best                                           // nearest key — gaps aren't dead zones
	}

	// MARK: Build keys

	private func reload() {
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
		shiftKey = all.first { $0.isShift }
		bringSubviewToFront(suggestionBar)
		touchPopups.values.forEach { bringSubviewToFront($0) }   // page-reload mid-press
		layer.addSublayer(trailLayer)          // keep the glide trail above the freshly-added keys
		setNeedsLayout()
	}

	private func shifted(_ c: String) -> String { shift == .off ? c : c.uppercased() }
	private var shiftSymbol: String {
		switch shift { case .off: return "shift"; case .on: return "shift.fill"; case .locked: return "capslock.fill" }
	}
	private func charSpec(_ c: String) -> KeySpec {
		if page == .letters {
			return KeySpec(label: shifted(c), width: .unit, popup: true, letterBase: c) { [weak self] in
				guard let self else { return }
				self.routeInsert(self.shifted(c), self.activeTap)
				if self.shift == .on { self.applyShiftState(.off) }   // in place — no rebuild
			}
		}
		return KeySpec(label: c, width: .unit, popup: true) { [weak self] in self?.routeInsert(c, nil) }
	}
	private func punct(_ c: String) -> KeySpec {
		KeySpec(label: c, width: .flex, popup: true) { [weak self] in self?.routeInsert(c, nil) }
	}

	private func specs() -> [[KeySpec]] {
		let del = KeySpec(symbol: "delete.left", role: .accentSoft, width: .wide, repeats: true) { [weak self] in self?.routeDelete() }
		let ret: KeySpec = {
			if let t = actionTitle, !t.isEmpty {
				return KeySpec(label: t, role: .accent, width: .ret, pill: true) { [weak self] in self?.routeReturn() }
			}
			return KeySpec(symbol: "return", role: .accent, width: .ret, pill: true) { [weak self] in self?.routeReturn() }
		}()
		let space = KeySpec(label: "space", width: .flex, pill: true) { [weak self] in
			self?.routeInsert(" ", nil)
			self?.returnToLettersFromSymbolPage()   // stock: space snaps back to ABC from 123/#+=
		}
		func switchKey(_ l: String, to t: KeyboardPage) -> KeySpec {
			KeySpec(label: l, role: .special, width: .wide, pill: true) { [weak self] in self?.page = t; self?.reload() }
		}
		let emojiKey = KeySpec(symbol: "face.smiling", role: .special, width: .unit, pill: false) { [weak self] in self?.showEmoji() }
		func bottom(_ leading: KeySpec) -> [KeySpec] {
			var r = [leading]
			if showsGlobe { r.append(KeySpec(symbol: "globe", role: .special, width: .unit, pill: true) { [weak self] in self?.onNextKeyboard?() }) }
			r.append(emojiKey)
			r.append(space); r.append(ret); return r
		}
		let shiftKey = KeySpec(symbol: shiftSymbol, role: .accentSoft, width: .wide, isShift: true) { [weak self] in
			guard let self else { return }
			let next: ShiftState
			switch self.shift { case .off: next = .on; case .on: next = .locked; case .locked: next = .off }
			self.applyShiftState(next)                              // in place — no rebuild
		}
		switch page {
		case .letters:
			return [
				["q","w","e","r","t","y","u","i","o","p"].map(charSpec),
				["a","s","d","f","g","h","j","k","l"].map(charSpec),
				[shiftKey] + ["z","x","c","v","b","n","m"].map(charSpec) + [del],
				bottom(switchKey("123", to: .numbers))
			]
		case .numbers:
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
		case .emoji:
			return []   // the emoji page is an overlay collection view, not a key grid
		}
	}
}
