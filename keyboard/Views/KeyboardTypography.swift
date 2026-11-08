import UIKit

/// The keyboard's type scale. Every label uses the system font (SF Pro); its sizes and
/// weights are named here instead of being typed at each call site.
///
/// - Keys, key balloons and long-press options keep fixed sizes, as the stock keyboard's
///   do: they are sized to the key, not to the reader's text size.
/// - Suggestions and panel text follow Dynamic Type, capped so they still fit the
///   strip's and panels' fixed heights.
/// - Bold Text (Accessibility) moves every style one weight heavier.
enum KeyboardTypography {
	private static var bold: Bool { UIAccessibility.isBoldTextEnabled }

	private static func system(_ size: CGFloat, _ weight: UIFont.Weight, bolder: UIFont.Weight) -> UIFont {
		.systemFont(ofSize: size, weight: bold ? bolder : weight)
	}

	/// Follows the reader's text size up to `cap` times the design size.
	private static func scaled(_ size: CGFloat, _ weight: UIFont.Weight, bolder: UIFont.Weight,
		style: UIFont.TextStyle, cap: CGFloat) -> UIFont {
		UIFontMetrics(forTextStyle: style).scaledFont(for: system(size, weight, bolder: bolder),
			maximumPointSize: (size * cap).rounded())
	}

	// MARK: Keys (fixed)

	/// A one-character key legend. Lowercase letters are drawn larger so their x-height
	/// matches stock; `scale` shrinks the legend for the compact multi-row Telugu deck.
	static func keyCharacter(lowercase: Bool, scale: CGFloat = 1) -> UIFont {
		system((lowercase ? 25.3 : 23) * scale, .regular, bolder: .medium)
	}

	/// A word on a key: 123, ABC, #+=, return labels such as "send".
	static func keyWord(scale: CGFloat = 1) -> UIFont {
		system(16 * scale, .medium, bolder: .semibold)
	}

	/// The press balloon above a key, sized to the balloon's head.
	static func keyBalloon(headHeight: CGFloat, word: Bool) -> UIFont {
		system(min(word ? 30 : 38, headHeight * 0.72), .regular, bolder: .medium)
	}

	/// A long-press option (é, è, …).
	static var keyAlternative: UIFont { system(24, .regular, bolder: .medium) }

	// MARK: Suggestion strip

	static var suggestion: UIFont { scaled(17, .regular, bolder: .semibold, style: .body, cap: 21 / 17) }

	// MARK: Panels (emoji, GIFs, stickers, clipboard)

	/// Search field text and placeholder.
	static var searchField: UIFont { scaled(16, .regular, bolder: .medium, style: .callout, cap: 1.2) }
	/// The Emoji · GIFs · Stickers switch.
	static var panelTab: UIFont { scaled(13, .semibold, bolder: .bold, style: .footnote, cap: 1.2) }
	/// Footer and toolbar buttons (ABC).
	static var panelButton: UIFont { scaled(15, .semibold, bolder: .bold, style: .subheadline, cap: 1.2) }
	/// An inline action beside panel content (the clipboard's Paste).
	static var panelAction: UIFont { scaled(14, .medium, bolder: .semibold, style: .subheadline, cap: 1.2) }
	/// A panel's heading (the clipboard's title).
	static var panelTitle: UIFont { scaled(14, .semibold, bolder: .bold, style: .subheadline, cap: 1.2) }
	/// Loading, offline and no-results messages.
	static var status: UIFont { scaled(14, .medium, bolder: .semibold, style: .subheadline, cap: 1.2) }
	/// A panel with nothing in it yet ("No recent emoji").
	static var emptyState: UIFont { scaled(15, .medium, bolder: .semibold, style: .subheadline, cap: 1.2) }
	/// A clipboard item's text.
	static var listItem: UIFont { scaled(15, .regular, bolder: .medium, style: .subheadline, cap: 1.2) }
	/// Section headings in the emoji grid ("RECENTLY USED").
	static var sectionHeader: UIFont { scaled(11, .semibold, bolder: .bold, style: .caption2, cap: 1.2) }
	/// A short confirmation ("Copied").
	static var toast: UIFont { scaled(14, .semibold, bolder: .bold, style: .subheadline, cap: 1.2) }
	/// Attribution under media ("Powered by KLIPY").
	static var caption: UIFont { scaled(9, .medium, bolder: .semibold, style: .caption2, cap: 1.2) }
}
