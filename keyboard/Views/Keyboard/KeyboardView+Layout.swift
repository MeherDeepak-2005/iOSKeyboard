import UIKit

extension KeyboardView {
	// MARK: Layout

	override func layoutSubviews() {
		super.layoutSubviews()
		let resolvedMetrics = metrics
		trailLayer.lineWidth = max(7, min(10, resolvedMetrics.rowHeight * 0.20))
		if lastLayoutProfile != resolvedMetrics.profile || lastLayoutWidth != bounds.width {
			let wasResolved = lastLayoutProfile != nil
			lastLayoutProfile = resolvedMetrics.profile
			lastLayoutWidth = bounds.width
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
			// Over the header's second (results) row: 44pt search row + 48pt results.
			mediaSearchStrip?.frame = CGRect(x: 6, y: 44, width: max(0, bounds.width - 12), height: 48)
		} else {
			suggestionBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripSpace)
		}

		let availableWidth = bounds.width - sidePad * 2
		let W = min(availableWidth, resolvedMetrics.maximumDeckWidth)
		guard W > 0 else { return }
		let deckOriginX = (bounds.width - W) / 2
		let unit = max(1, (W - keySpacing*9)/10)
		unitPitch = unit + keySpacing            // grid-unit scale for tap offsets
		// Where Z…M start: half a key in from the A…L row's own half-key indent.
		let letterInset = unit*1.5 + keySpacing/2
		// Stock proportions (393pt: shift/delete 44, 123/emoji 42.5, return 91.6).
		let modifierW = unit * KeyWidth.modifierUnits
		func fixed(_ k: KeyWidth) -> CGFloat {
			switch k {
			case .unit: return unit
			case .modifier: return modifierW
			case .utility: return unit * KeyWidth.utilityUnits
			case .ret: return unit * KeyWidth.returnUnits
			case .flex: return 0
			}
		}

		var y = headerSpace + topPad
		for row in rows {
            // Keep Z…M on the existing ten-unit letter grid. Narrowing just the
            // edge caps must not move letter centers or the glide/touch model.
            if row.count == 9, row.first?.isShift == true,
                row.dropFirst().dropLast().allSatisfy({ $0.letterBase != nil }) {
                row[0].frame = CGRect(x: deckOriginX, y: y, width: modifierW, height: rowHeight)
                for (index, key) in row.dropFirst().dropLast().enumerated() {
                    key.frame = CGRect(x: deckOriginX + letterInset + keySpacing + CGFloat(index) * unitPitch,
                        y: y, width: unit, height: rowHeight)
                }
                row[8].frame = CGRect(x: deckOriginX + W - modifierW, y: y,
                    width: modifierW, height: rowHeight)
                y += rowHeight + rowSpacing
                continue
            }
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
}
