import UIKit

extension KeyboardView {
	// MARK: Multi-touch — fire on contact, track every finger

	private func showPopup(for key: KeyButton, at point: CGPoint, touch: UITouch) {
		guard let popupView = makeKeyPopup(for: key, at: point) else { return }
		addSubview(popupView)
		bringSubviewToFront(popupView)
		touchPopups[touch] = popupView
		popupShownAt[touch] = ProcessInfo.processInfo.systemUptime
		key.setCovered(true)
		poppedKeys[touch] = key
	}

	/// Stock-style balloon: a wide head carrying the character, joined by a neck to a
	/// stem that is the pressed cap itself. The extension cannot draw above its own
	/// bounds, so a top-row head borrows the suggestion strip and slides down over the
	/// cap rather than growing the deck. Edge heads shift inward; the stem stays put.
	func makeKeyPopup(for key: KeyButton, at point: CGPoint) -> UIView? {
		guard let text = key.popupText else { return nil }
		let keyFrame = key.frame
		let edge: CGFloat = 2
		let headWidth = min(max(keyFrame.width * 1.65, 56), max(1, bounds.width - edge * 2))
		let preferredHeadHeight = max(keyFrame.height * 1.3, 54)
		let headX = min(max(keyFrame.midX - headWidth / 2, edge),
			max(edge, bounds.width - edge - headWidth))
		// Lower rows: the head sits above the cap. Top row: pinned to the deck top, and
		// with no strip above it the head may swallow the whole cap.
		let headTop = max(edge, keyFrame.minY + 2 - preferredHeadHeight)
		let headBottom = min(headTop + preferredHeadHeight, keyFrame.maxY)
		let popupFrame = CGRect(x: min(headX, keyFrame.minX), y: headTop,
			width: max(headX + headWidth, keyFrame.maxX) - min(headX, keyFrame.minX),
			height: keyFrame.maxY - headTop)

		let popupView = UIView(frame: popupFrame)
		popupView.isUserInteractionEnabled = false
		popupView.backgroundColor = .clear
		popupView.layer.masksToBounds = false
		popupView.layer.zPosition = 1000

		// Local geometry. Every piece winds the same way, so nonzero fill unions them.
		let head = CGRect(x: headX - popupFrame.minX, y: 0,
			width: headWidth, height: headBottom - headTop)
		let stem = CGRect(x: keyFrame.minX - popupFrame.minX, y: keyFrame.minY - headTop,
			width: keyFrame.width, height: keyFrame.height)
		let headRadius: CGFloat = 12
		let path = UIBezierPath(roundedRect: head, cornerRadius: headRadius)
		path.append(UIBezierPath(roundedRect: stem, cornerRadius: theme.cornerRadius))
		let neckTop = head.maxY - headRadius
		let neckBottom = min(head.maxY + 8, stem.maxY - theme.cornerRadius)
		if neckBottom > neckTop {
			let neck = UIBezierPath()
			neck.move(to: CGPoint(x: head.minX, y: neckTop))
			neck.addLine(to: CGPoint(x: head.maxX, y: neckTop))
			neck.addQuadCurve(to: CGPoint(x: stem.maxX, y: neckBottom),
				controlPoint: CGPoint(x: stem.maxX, y: head.maxY))
			neck.addLine(to: CGPoint(x: stem.minX, y: neckBottom))
			neck.addQuadCurve(to: CGPoint(x: head.minX, y: neckTop),
				controlPoint: CGPoint(x: stem.minX, y: head.maxY))
			neck.close()
			path.append(neck)
		}

		let shapeLayer = CAShapeLayer()
		shapeLayer.frame = popupView.bounds
		shapeLayer.path = path.cgPath
		shapeLayer.fillColor = theme.popupFill.cgColor

		shapeLayer.shadowColor = UIColor.black.cgColor
		shapeLayer.shadowOpacity = theme.isDark ? 0.45 : 0.20
		shapeLayer.shadowRadius = 4
		shapeLayer.shadowOffset = CGSize(width: 0, height: 2)
		shapeLayer.shadowPath = path.cgPath

		popupView.layer.addSublayer(shapeLayer)

		let label = UILabel(frame: head.insetBy(dx: 4, dy: 2))
		label.text = text
		label.textAlignment = .center
		label.font = .systemFont(ofSize: min(text.count > 1 ? 30 : 38, head.height * 0.72),
			weight: UIAccessibility.isBoldTextEnabled ? .medium : .regular)
		label.adjustsFontSizeToFitWidth = true
		label.minimumScaleFactor = 0.65
		label.textColor = theme.popupText

		popupView.addSubview(label)
		return popupView
	}
	private func removePopup(for touch: UITouch, afterMinimumDuration: Bool = false) {
		if afterMinimumDuration, let popup = touchPopups[touch], let shownAt = popupShownAt[touch] {
			// Deferred edge touches can begin and end in the same display frame.
			// Keep feedback visible without delaying the already-committed character.
			let remaining = 0.10 - (ProcessInfo.processInfo.systemUptime - shownAt)
			if remaining > 0 {
				DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak popup] in
					guard let self, let popup, self.touchPopups[touch] === popup else { return }
					self.removePopup(for: touch)
				}
				return
			}
		}
		touchPopups.removeValue(forKey: touch)?.removeFromSuperview()
		popupShownAt[touch] = nil
		if let key = poppedKeys.removeValue(forKey: touch),
			!poppedKeys.values.contains(where: { $0 === key }) {
			key.setCovered(false)
		}
	}
	private func registerKey(_ key: KeyButton, at point: CGPoint, for touch: UITouch) {
		touchKeys[touch]?.setHighlighted(false)
		removePopup(for: touch)
		touchKeys[touch] = key
		key.setHighlighted(true)
		showPopup(for: key, at: point, touch: touch)
	}
	private func clearRegisteredKey(for touch: UITouch, keepingPopupBriefly: Bool = false) {
		touchKeys[touch]?.setHighlighted(false)
		touchKeys[touch] = nil
		removePopup(for: touch, afterMinimumDuration: keepingPopupBriefly)
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


	private func beginRepeat(_ key: KeyButton, touch: UITouch) {
		endRepeat()
		repeatKey = key
		repeatTouch = touch
		let t = Timer(timeInterval: 0.09, repeats: true) { [weak self, weak key] _ in
			guard let self, let key, self.repeatKey === key else { self?.endRepeat(); return }
			self.isRepeatingKey = true
			key.trigger()
			self.isRepeatingKey = false
		}
		t.fireDate = Date().addingTimeInterval(0.4)     // hold ~0.4s before it starts repeating
		RunLoop.main.add(t, forMode: .common)
		repeatTimer = t
	}
	private func endRepeat() {
		repeatTimer?.invalidate(); repeatTimer = nil
		repeatTouch = nil; repeatKey = nil
	}


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

	func endCursorHold(notify: Bool = true) {
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
			// Sampled before the key acts, so the touch-down precedes its own key event and
			// carries the word session it was typed in. Touches UIKit finished without an
			// ended/cancelled callback must not hold the cap.
			if recordedTouches.count >= 20 {
				recordedTouches = recordedTouches.filter { $0.key.phase != .ended && $0.key.phase != .cancelled }
			}
			if onTouchSample != nil, recordedTouches.count < 20 {
				let recordedKey = key.popupText ?? key.committedText
				let recordedTap = keyTap(for: key, at: p)
				nextRecordedTouch &+= 1
				recordedTouches[touch] = (nextRecordedTouch, recordedKey, recordedTap)
				onTouchSample?("touch-down", nextRecordedTouch, recordedKey, touch.timestamp, recordedTap)
			}
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

	private func finishRecordedTouch(_ touch: UITouch, cancelled: Bool) {
		guard let (id, key, tap) = recordedTouches.removeValue(forKey: touch) else { return }
		onTouchSample?(cancelled ? "touch-cancel" : "touch-up", id, key, touch.timestamp, tap)
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
			finishRecordedTouch(touch, cancelled: false)
			if cursorTouch === touch { endCursorHold() }
			if finishAlternatives(for: touch, commit: true) {
				if touch == glideTouch { glideTouch = nil; glide = nil; clearTrail() }
				clearRegisteredKey(for: touch, keepingPopupBriefly: true)
				continue
			}
			if let key = touchKeys[touch], key.isInputModeSwitch {
				if let event { onInputModeEvent?(key, event) }
				clearRegisteredKey(for: touch, keepingPopupBriefly: true)
				continue
			}
			if touch == glideTouch, glide?.isGlide == true {   // a glide: decode, commit nothing
				let pts = glide?.points ?? []
				let times = glide?.times ?? []
				let layout = glideLayout()
				glideTouch = nil; glide = nil; lastGlidePreviewTime = 0; clearTrail()
				clearRegisteredKey(for: touch, keepingPopupBriefly: true)
				onGlide?(pts, times, layout)
				continue
			}
			if touch == repeatTouch {                          // delete: just stop
				endRepeat()
				clearRegisteredKey(for: touch, keepingPopupBriefly: true)
				continue
			}
			if touch == glideTouch { glideTouch = nil; glide = nil; clearTrail() }
			clearRegisteredKey(for: touch, keepingPopupBriefly: true)
		}
	}
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			finishRecordedTouch(touch, cancelled: true)
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

	func key(at p: CGPoint) -> KeyButton? {
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
                // Modifier caps own their whole visible rectangle. Letter priors
                // can arbitrate the gutters but cannot steal a deliberate Delete.
                if key.widthKind == .modifier, f.contains(p) { return key }
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

	// MARK: Glide typing (P1: trajectory capture + tap/glide classification)
	//
	// A glide is one continuous finger stroke across the letters. We keep fire-on-contact
	// for taps (the start letter commits instantly), and only when a tracked finger
	// wanders past a threshold do we RECLASSIFY it as a glide: suppress its popup /
	// highlight / auto-repeat, ask the controller to remove the start letter it already
	// inserted, draw a trail, and on lift hand the whole path to the decoder. Decoding
	// itself is a later phase — `onGlide` is the seam.

	/// Letter-key centers + pitches for the decoder's view→grid mapping.
	func glideLayout() -> GlideLayout {
		let centers: [(letter: Character, point: CGPoint)] = letterKeys.compactMap {
			guard let ch = $0.base.first else { return nil }
			return (ch, CGPoint(x: $0.key.frame.midX, y: $0.key.frame.midY))
		}
		return GlideLayout(centers: centers, xPitch: unitPitch, yPitch: rowHeight + rowSpacing)
	}

	struct GlideTrack {
		var startKey: KeyButton?
		var points: [CGPoint] = []
		var times: [TimeInterval] = []          // per-sample touch timestamps (for velocity/dwell)
		var length: CGFloat = 0                 // cumulative path length
		var keys = Set<ObjectIdentifier>()      // distinct keys the path has entered
		var isGlide = false
	}

	/// Telugu legends are drawn smaller and the rows shorter: the script's glyphs read
	/// large and the deck carries ~5 glyph rows, so at Latin size it towers over stock.
	static let teluguGlyphScale: CGFloat = 0.6
	static let teluguRowHeightScale: CGFloat = 0.78


	/// Extra height for browsing overlays, without changing key geometry. The GIF and
	/// sticker grid gets ~2.5 GIF rows / 3 sticker rows instead of a cramped 1.5.
	static let mediaExpansion: CGFloat = 88
}
