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
