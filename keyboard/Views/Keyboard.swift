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

	/// Fired when a live touch turns into a glide, so the controller can delete the
	/// start letter that fire-on-contact already committed.
	var onGlideBegan: (() -> Void)?
	/// Fired on lift with the full swipe trajectory (points in this view's coordinates).
	/// Wired to the decoder in a later phase; today it clears the trail and nothing else.
	var onGlide: (([CGPoint]) -> Void)?

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
	/// A little top padding stays behind so the collapsed keyboard doesn't look choked.
	private(set) var showsSuggestions = true
	private let collapsedTopPad: CGFloat = 10
	private var stripSpace: CGFloat { showsSuggestions ? stripHeight : collapsedTopPad }

	var keyboardHeight: CGFloat { stripSpace + topPad + rowHeight*4 + rowSpacing*3 + botPad }

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
	func setAutoShift(_ on: Bool) {
		guard shift != .locked else { return }
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
		addSubview(ev)
		emojiView = ev
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
		suggestionBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripSpace)

		let W = bounds.width - sidePad*2
		guard W > 0 else { return }
		let unit = max(1, (W - keySpacing*9)/10)
		unitPitch = unit + keySpacing            // grid-unit scale for tap offsets
		let wide = unit*1.5 + keySpacing/2
		let retW = unit*2 + keySpacing
		func fixed(_ k: KeyWidth) -> CGFloat {
			switch k { case .unit: return unit; case .wide: return wide; case .ret: return retW; case .flex: return 0 }
		}

		var y = stripSpace + topPad
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

	private func showPopup(for key: KeyButton, touch: UITouch) {
		guard let text = key.popupText else { return }
		let kf = key.frame
		let edge: CGFloat = 3

		// Bubble sits above the key, wider than it; a tapering neck joins the two so the
		// whole thing reads as one continuous shape rising out of the key — not a
		// detached box floating above it.
		let bubbleW = max(kf.width * 1.32, 42)
		let overlap = kf.height * 0.16                       // dip into the key: no visible seam
		// Full-size on EVERY row, top included. The top-row balloon is allowed to rise
		// over the suggestion strip (and a touch past the top edge) instead of being
		// shrunk, so its preview is the same size as the other rows'.
		let bubbleH = kf.height + 5
		let neckH   = kf.height * 0.5

		// Centre over the key, clamped to the deck edges. When clamped, the bubble slides
		// while the neck stays over the key → the natural asymmetric edge balloon.
		let cx = min(max(kf.midX, edge + bubbleW/2), bounds.width - edge - bubbleW/2)
		let bMinX = cx - bubbleW/2, bMaxX = cx + bubbleW/2
		let top = kf.minY - neckH - bubbleH                  // may be < 0 for the top row (rises over the strip)
		let left = min(bMinX, kf.minX), right = max(bMaxX, kf.maxX)
		let frame = CGRect(x: left, y: top, width: right - left, height: kf.minY + overlap - top)

		// Local coords: bubble x-range, key (neck) x-range, and the y where the neck meets the key.
		let bx0 = bMinX - left, bx1 = bMaxX - left
		let kx0 = kf.minX - left, kx1 = kf.maxX - left
		let r: CGFloat = 11
		let neckY = frame.height - overlap
		let bottomY = frame.height

		let p = UIBezierPath()
		p.move(to: CGPoint(x: bx0, y: r))
		p.addQuadCurve(to: CGPoint(x: bx0 + r, y: 0), controlPoint: CGPoint(x: bx0, y: 0))
		p.addLine(to: CGPoint(x: bx1 - r, y: 0))
		p.addQuadCurve(to: CGPoint(x: bx1, y: r), controlPoint: CGPoint(x: bx1, y: 0))
		p.addLine(to: CGPoint(x: bx1, y: bubbleH - r))
		p.addQuadCurve(to: CGPoint(x: bx1 - r, y: bubbleH), controlPoint: CGPoint(x: bx1, y: bubbleH))
		p.addCurve(to: CGPoint(x: kx1, y: neckY),                          // concave right waist
				   controlPoint1: CGPoint(x: bx1 - r, y: bubbleH + neckH * 0.5),
				   controlPoint2: CGPoint(x: kx1, y: neckY - neckH * 0.5))
		p.addLine(to: CGPoint(x: kx1, y: bottomY))
		p.addLine(to: CGPoint(x: kx0, y: bottomY))
		p.addLine(to: CGPoint(x: kx0, y: neckY))
		p.addCurve(to: CGPoint(x: bx0 + r, y: bubbleH),                    // concave left waist
				   controlPoint1: CGPoint(x: kx0, y: neckY - neckH * 0.5),
				   controlPoint2: CGPoint(x: bx0 + r, y: bubbleH + neckH * 0.5))
		p.addQuadCurve(to: CGPoint(x: bx0, y: bubbleH - r), controlPoint: CGPoint(x: bx0, y: bubbleH))
		p.close()

		let v = UIView(frame: frame)
		v.isUserInteractionEnabled = false
		let shape = CAShapeLayer()
		shape.path = p.cgPath
		shape.fillColor = (theme.isDark ? UIColor(hex: 0x4A4A50) : .white).cgColor
		// Shadow bound to the exact path → Core Animation never rasterizes an offscreen
		// blur on the press path (the old box had shadowRadius but no shadowPath).
		shape.shadowColor = UIColor.black.cgColor
		shape.shadowOpacity = theme.isDark ? 0.5 : 0.20
		shape.shadowRadius = 5
		shape.shadowOffset = CGSize(width: 0, height: 2)
		shape.shadowPath = p.cgPath
		v.layer.addSublayer(shape)

		let l = UILabel(frame: CGRect(x: bx0, y: 0, width: bubbleW, height: bubbleH))
		l.text = text
		l.textAlignment = .center
		l.font = theme.font.uiFont(ofSize: min(26, bubbleH * 0.6))
		l.textColor = theme.isDark ? UIColor(hex: 0xECECF0) : UIColor(hex: 0x1B1B1D)
		v.addSubview(l)
		addSubview(v)
		touchPopups[touch] = v
	}
	private func removePopup(for touch: UITouch) {
		touchPopups[touch]?.removeFromSuperview()
		touchPopups[touch] = nil
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

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			// A glide owns the deck: once a swipe is in progress, other fingers are ignored.
			if glide?.isGlide == true { continue }
			let p = touch.location(in: self)
			guard let key = key(at: p) else { continue }
			touchKeys[touch] = key
			// Feedback FIRST — highlight, balloon, haptic — then the commit. `key.action()`
			// runs the insertText IPC (and autocorrect), which can take a moment; doing it
			// last is what makes the tap feel instant instead of lagging the feedback.
			key.setHighlighted(true)
			showPopup(for: key, touch: touch)
			if hapticsEnabled { haptic.impactOccurred(intensity: 0.6); haptic.prepare() }
			if key.repeats { beginRepeat(key, touch: touch) }
			activeTap = keyTap(for: key, at: p)   // consumed by the char closure in key.action()
			key.action()
			activeTap = nil
			// Begin glide tracking on the first letter-key contact (letters page only).
			// The letter just committed on contact; if this turns into a glide we reclaim it.
			if glideTouch == nil, page == .letters, key.letterBase != nil {
				glideTouch = touch
				glide = GlideTrack(startKey: key, points: [p], keys: [ObjectIdentifier(key)])
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
	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			// The tracked finger runs glide classification; once it's a glide it owns its
			// own feedback (trail, no key highlight), so skip the normal per-key path.
			if touch == glideTouch, glide != nil {
				trackGlide(touch)
				if glide?.isGlide == true { continue }
			}
			guard let key = touchKeys[touch] else { continue }
			let inside = key.frame.contains(touch.location(in: self))
			key.setHighlighted(inside)
			if !inside { removePopup(for: touch) }               // slid off the key
			if touch == repeatTouch && !inside { endRepeat() }   // → stop repeating too
		}
	}
	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			if touch == glideTouch {
				let finished = glide
				glideTouch = nil; glide = nil
				if finished?.isGlide == true {
					clearTrail()
					onGlide?(finished?.points ?? [])
					continue                       // a glide, not a tap — skip tap cleanup
				}
				// Otherwise it was an ordinary tap we happened to track: fall through.
			}
			touchKeys[touch]?.setHighlighted(false)
			touchKeys[touch] = nil
			removePopup(for: touch)
			if touch == repeatTouch { endRepeat() }
		}
	}
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		// A cancelled glide is discarded (no word delivered); the start letter, if this
		// had already become a glide, was removed at classification time.
		if let gt = glideTouch, touches.contains(gt) {
			glideTouch = nil; glide = nil; clearTrail()
		}
		touchesEnded(touches, with: event)
	}

	/// Feed one movement sample into the tracked stroke; reclassify to a glide when it
	/// travels past the threshold across ≥2 keys, then suppress the tap feedback and
	/// reclaim the start letter. Owns the trail while gliding.
	private func trackGlide(_ touch: UITouch) {
		guard var g = glide else { return }
		let p = touch.location(in: self)
		if let last = g.points.last { g.length += hypot(p.x - last.x, p.y - last.y) }
		g.points.append(p)
		if let k = key(at: p) { g.keys.insert(ObjectIdentifier(k)) }
		if !g.isGlide, g.length >= glideThreshold, g.keys.count >= 2 {
			g.isGlide = true
			g.startKey?.setHighlighted(false)
			removePopup(for: touch)
			if touch == repeatTouch { endRepeat() }
			touchKeys[touch] = nil                 // touchesEnded must not treat this as a tap
			onGlideBegan?()                        // controller removes the start letter
		}
		glide = g
		if g.isGlide { updateTrail(g.points) }
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
				self.onInsert?(self.shifted(c), self.activeTap)
				if self.shift == .on { self.applyShiftState(.off) }   // in place — no rebuild
			}
		}
		return KeySpec(label: c, width: .unit, popup: true) { [weak self] in self?.onInsert?(c, nil) }
	}
	private func punct(_ c: String) -> KeySpec {
		KeySpec(label: c, width: .flex, popup: true) { [weak self] in self?.onInsert?(c, nil) }
	}

	private func specs() -> [[KeySpec]] {
		let del = KeySpec(symbol: "delete.left", role: .accentSoft, width: .wide, repeats: true) { [weak self] in self?.onDelete?() }
		let ret: KeySpec = {
			if let t = actionTitle, !t.isEmpty {
				return KeySpec(label: t, role: .accent, width: .ret, pill: true) { [weak self] in self?.onReturn?() }
			}
			return KeySpec(symbol: "return", role: .accent, width: .ret, pill: true) { [weak self] in self?.onReturn?() }
		}()
		let space = KeySpec(label: "space", width: .flex, pill: true) { [weak self] in self?.onInsert?(" ", nil) }
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
