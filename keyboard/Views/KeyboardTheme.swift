import UIKit

// Theme + key model enums + KeySpec — extracted from Keyboard.swift.

struct KeyboardTheme {
	let name: String
	let backgroundTop, backgroundBottom: UIColor
	let key, keyText, specialKey, specialKeyText, accentKeyText: UIColor
	let accentStart, accentEnd: UIColor             // action-button gradient stops (full accent)
	let accentSoft, accentSoftText: UIColor         // shift/delete = lighter tint of the accent
	let shadowColor: UIColor
	let shadowOpacity: Float
	let cornerRadius: CGFloat
	let isDark: Bool
	var font: KBFont = .system

	/// Modern Material-style keyboard. The action key uses the full accent gradient;
	/// shift/delete use a lighter tint of that same accent. Special keys stay neutral.
	static func system(dark: Bool) -> KeyboardTheme {
		let accent = KBSettings.accent
		let g = accent.gradient(dark: dark)
		// Transparent "glass" styling: the deck background is fully clear so the system
		// blur behind the keyboard shows through, and keys use translucent fills instead
		// of solid ones so the glass effect stays visible on every key.
		if dark {
			return KeyboardTheme(name: "Dark",
				backgroundTop: .clear,
				backgroundBottom: .clear,
				key: UIColor(white: 1, alpha: 0.16), keyText: UIColor(hex: 0xECECF0),
				specialKey: UIColor(white: 1, alpha: 0.09), specialKeyText: UIColor(hex: 0xECECF0),
				accentKeyText: .white,
				accentStart: g.startColor, accentEnd: g.endColor,
				accentSoft: UIColor(white: 1, alpha: 0.09), accentSoftText: UIColor(hex: 0xECECF0),
				shadowColor: .white, shadowOpacity: 0, cornerRadius: 8, isDark: true,
				font: KBSettings.font)
		} else {
			return KeyboardTheme(name: "Light",
				backgroundTop: .clear,
				backgroundBottom: .clear,
				key: UIColor(white: 1, alpha: 0.42), keyText: UIColor(hex: 0x1B1B1D),
				specialKey: UIColor(white: 1, alpha: 0.22), specialKeyText: UIColor(hex: 0x1B1B1D),
				accentKeyText: .white,
				accentStart: g.startColor, accentEnd: g.endColor,
				accentSoft: UIColor(white: 1, alpha: 0.22), accentSoftText: UIColor(hex: 0x1B1B1D),
				shadowColor: UIColor(white: 0, alpha: 1), shadowOpacity: 0, cornerRadius: 8, isDark: false,
				font: KBSettings.font)
		}
	}
}

// MARK: - Model

enum KeyboardPage { case letters, numbers, symbols, emoji, clipboard, media }
enum ShiftState   { case off, on, locked }
enum KeyRole      { case normal, special, accent, accentSoft }   // accentSoft = lighter tint of the accent (shift/delete)
enum KeyWidth     { case unit, wide, ret, flex }

struct KeySpec {
	var label: String? = nil
	var symbol: String? = nil
	var role: KeyRole = .normal
	var width: KeyWidth = .unit
	var pill: Bool = false           // fully-rounded (capsule) instead of normal roundness
	var repeats: Bool = false        // fires continuously while held (delete)
	var popup: Bool = false          // show the stock-style character balloon on press
	var letterBase: String? = nil    // lowercase base letter → enables in-place shift relabelling
	var isShift: Bool = false        // the shift key, whose glyph updates on shift changes
	var action: () -> Void
}

