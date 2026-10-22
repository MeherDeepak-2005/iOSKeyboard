// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import UIKit

// Theme + key model enums + KeySpec — extracted from Keyboard.swift.

struct KeyboardTheme {
	let name: String
	let backgroundTop, backgroundBottom: UIColor
	let fallbackBackgroundTop, fallbackBackgroundBottom: UIColor
	let usesSystemTransparency: Bool
	let key, keyText, specialKey, specialKeyText, accentKeyText: UIColor
	let accentStart, accentEnd: UIColor             // action-button gradient stops (full accent)
	let accentSoft, accentSoftText: UIColor         // optional soft accent colors
	let pressedOverlay: UIColor
	let suggestionHighlight, suggestionHighlightBorder: UIColor
	let popupFill, popupText: UIColor
	let shadowColor: UIColor
	let shadowOpacity: Float
	let cornerRadius: CGFloat
	let isDark: Bool
    var isSystemAppearance: Bool = false

    /// The default System appearance follows light/dark traits with neutral keys.
    /// Explicit accents and enabled Theme Studio designs keep their saved colors.
	static func system(dark: Bool) -> KeyboardTheme {
		if KBSettings.customThemeEnabled, let c = KBSettings.customTheme(dark: dark) {
			return custom(c)
		}
		return accentTheme(dark: dark, accent: KBSettings.accent)
	}

	/// Pure resolver used by the companion app's live editor. It deliberately does
	/// not read or mutate App Group settings, so an uncommitted draft cannot leak into
	/// the running extension.
	static func preview(dark: Bool, accent: KBAccent,
		customTheme: KBCustomTheme?) -> KeyboardTheme {
		if let customTheme { return custom(customTheme) }
		return accentTheme(dark: dark, accent: accent)
	}

	private static func accentTheme(dark: Bool, accent: KBAccent) -> KeyboardTheme {
        let system = accent.id == KBPalette.system.id
		let g = accent.gradient(dark: dark)
		let accentHSL = KBHSL(g.endColor)
		let highContrast = UIAccessibility.isDarkerSystemColorsEnabled
		let specialFill = system
            // Dark: the same tone as letter keys over the system material, as stock iOS 26.
            ? UIColor(white: dark ? 0.32 : 0.67, alpha: highContrast ? 1 : 0.65)
            : accentHSL.color(
			saturation: accentHSL.saturation * (dark ? 0.58 : 0.48),
			lightness: dark ? min(accentHSL.lightness + 0.18, 0.72) : max(accentHSL.lightness - 0.08, 0.34),
			alpha: highContrast ? (dark ? 0.44 : 0.32) : (dark ? 0.18 : 0.14)
		)
		let accentSoftFill = system ? specialFill : accentHSL.color(
			saturation: accentHSL.saturation * (dark ? 0.78 : 0.68),
			lightness: dark ? min(accentHSL.lightness + 0.22, 0.76) : max(accentHSL.lightness - 0.03, 0.38),
			alpha: highContrast ? (dark ? 0.58 : 0.44) : (dark ? 0.34 : 0.24)
		)
		let proposedActionStart = KBHSL(g.startColor).color(
			saturation: KBHSL(g.startColor).saturation * 0.88,
			lightness: dark ? min(KBHSL(g.startColor).lightness + 0.06, 0.64)
				: max(KBHSL(g.startColor).lightness - 0.02, 0.38),
			alpha: 0.94)
		let proposedActionEnd = KBHSL(g.endColor).color(
			saturation: KBHSL(g.endColor).saturation * 0.90,
			lightness: dark ? min(KBHSL(g.endColor).lightness + 0.08, 0.62)
				: max(KBHSL(g.endColor).lightness, 0.36),
			alpha: 0.96)
		let actionText = bestContrastingText(over: [proposedActionStart, proposedActionEnd])
        let actionStart = ensuringContrast(system ? g.startColor : proposedActionStart, against: actionText)
        let actionEnd = ensuringContrast(system ? g.endColor : proposedActionEnd, against: actionText)
		// The deck paints no tint of its own. iOS draws its keyboard material behind
		// the extension AND in a strip above it that the extension can't cover; any
		// tint here makes that strip read as a separate band over the suggestions.
		// Accessibility settings replace it with the opaque fallback below.
		if dark {
			return KeyboardTheme(name: "Dark",
				backgroundTop: .clear,
				backgroundBottom: .clear,
				fallbackBackgroundTop: UIColor(hex: 0x29292E),
				fallbackBackgroundBottom: UIColor(hex: 0x202025),
				usesSystemTransparency: true,
				key: UIColor(white: 1, alpha: highContrast ? 0.34 : 0.165), keyText: UIColor(hex: 0xF4F4F6),
				specialKey: specialFill, specialKeyText: UIColor(hex: 0xECECF0),
				accentKeyText: actionText,
				accentStart: actionStart, accentEnd: actionEnd,
				accentSoft: accentSoftFill, accentSoftText: UIColor(hex: 0xECECF0),
				pressedOverlay: UIColor.white.withAlphaComponent(highContrast ? 0.25 : 0.18),
				suggestionHighlight: UIColor.white.withAlphaComponent(highContrast ? 0.27 : 0.17),
				suggestionHighlightBorder: UIColor.white.withAlphaComponent(highContrast ? 0.42 : 0.12),
				popupFill: UIColor(hex: highContrast ? 0x55555C : 0x48484E),
				popupText: UIColor(hex: 0xFAFAFC),
					shadowColor: .white, shadowOpacity: 0, cornerRadius: 8, isDark: true, isSystemAppearance: system)
		} else {
			return KeyboardTheme(name: "Light",
				backgroundTop: .clear,
				backgroundBottom: .clear,
				fallbackBackgroundTop: UIColor(hex: 0xE1E2E6),
				fallbackBackgroundBottom: UIColor(hex: 0xD4D6DB),
				usesSystemTransparency: true,
				key: UIColor(white: 1, alpha: highContrast ? 0.78 : 0.48), keyText: UIColor(hex: 0x161618),
				specialKey: specialFill, specialKeyText: UIColor(hex: 0x1B1B1D),
				accentKeyText: actionText,
				accentStart: actionStart, accentEnd: actionEnd,
				accentSoft: accentSoftFill, accentSoftText: UIColor(hex: 0x1B1B1D),
				pressedOverlay: UIColor.black.withAlphaComponent(highContrast ? 0.18 : 0.11),
				suggestionHighlight: UIColor.white.withAlphaComponent(highContrast ? 0.88 : 0.62),
				suggestionHighlightBorder: UIColor.black.withAlphaComponent(highContrast ? 0.22 : 0.08),
				popupFill: .white,
				popupText: UIColor(hex: 0x151517),
					shadowColor: UIColor(white: 0, alpha: 1), shadowOpacity: 0, cornerRadius: 8, isDark: false, isSystemAppearance: system)
		}
	}

	/// Build the deck look from a Theme Studio design. Keys go SOLID (translucency is
	/// the stock glass look; over a chosen gradient/photo, solid role colors read as
	/// intended).
	static func custom(_ c: KBCustomTheme) -> KeyboardTheme {
		let text = UIColor(hex: c.text)
		let keyFill = UIColor(hex: c.keys)
		let specialFill = UIColor(hex: c.special)
		// Glyph on the action key: follow the accent's own brightness, not the theme's
		// dark flag — a pale mint action key needs dark text even in a dark theme.
		let proposedAccentStart = UIColor(hex: c.accentStart)
		let proposedAccentEnd = UIColor(hex: c.accentEnd)
		let accentGlyph = bestContrastingText(over: [proposedAccentStart, proposedAccentEnd])
		let accentStart = ensuringContrast(proposedAccentStart, against: accentGlyph)
		let accentEnd = ensuringContrast(proposedAccentEnd, against: accentGlyph)
		let softAccent = mix(specialFill, accentEnd, accentAmount: 0.30)
		return KeyboardTheme(name: "Custom",
			backgroundTop: UIColor(hex: c.bgStart),
			backgroundBottom: UIColor(hex: c.bgEnd),
			fallbackBackgroundTop: UIColor(hex: c.bgStart),
			fallbackBackgroundBottom: UIColor(hex: c.bgEnd),
			usesSystemTransparency: false,
			key: keyFill, keyText: text,
			specialKey: specialFill, specialKeyText: text,
			accentKeyText: accentGlyph,
			accentStart: accentStart, accentEnd: accentEnd,
			accentSoft: softAccent, accentSoftText: bestContrastingText(over: [softAccent]),
			pressedOverlay: c.dark ? UIColor.white.withAlphaComponent(0.18) : UIColor.black.withAlphaComponent(0.11),
			suggestionHighlight: c.dark ? UIColor.white.withAlphaComponent(0.18) : UIColor.white.withAlphaComponent(0.62),
			suggestionHighlightBorder: c.dark ? UIColor.white.withAlphaComponent(0.13) : UIColor.black.withAlphaComponent(0.08),
			popupFill: c.dark ? UIColor(hex: 0x48484E) : .white,
			popupText: c.dark ? UIColor(hex: 0xFAFAFC) : UIColor(hex: 0x151517),
				shadowColor: c.dark ? .white : UIColor(white: 0, alpha: 1),
				shadowOpacity: 0, cornerRadius: 8, isDark: c.dark)
	}

	/// WCAG relative luminance of a hex RGB (0…1), including sRGB linearization.
	static func luminance(_ hex: UInt32) -> Double {
		func linear(_ encoded: Double) -> Double {
			encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
		}
		let r = linear(Double((hex >> 16) & 0xFF) / 255)
		let g = linear(Double((hex >> 8) & 0xFF) / 255)
		let b = linear(Double(hex & 0xFF) / 255)
		return 0.2126 * r + 0.7152 * g + 0.0722 * b
	}

	static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
		let lighter = max(luminance(a), luminance(b))
		let darker = min(luminance(a), luminance(b))
		return (lighter + 0.05) / (darker + 0.05)
	}

	private static func bestContrastingText(over fills: [UIColor]) -> UIColor {
		// Pure endpoints guarantee that one choice reaches WCAG 4.5:1 for every
		// opaque sRGB fill. Near-black/near-white leave a small mid-luminance gap.
		let black = UIColor.black
		let white = UIColor.white
		func worstContrast(_ foreground: UIColor) -> Double {
			fills.map { contrastRatio(foreground, $0) }.min() ?? 1
		}
		return worstContrast(black) >= worstContrast(white) ? black : white
	}

	private static func ensuringContrast(_ fill: UIColor, against foreground: UIColor,
		minimum: Double = 4.55) -> UIColor {
		guard contrastRatio(fill, foreground) < minimum else { return fill }
		let foregroundIsBlack = contrastRatio(foreground, .black) < 2
		let target: UIColor = foregroundIsBlack ? .white : .black
		var low: CGFloat = 0
		var high: CGFloat = 1
		for _ in 0..<18 {
			let amount = (low + high) / 2
			if contrastRatio(mix(fill, target, accentAmount: amount), foreground) >= minimum {
				high = amount
			} else {
				low = amount
			}
		}
		return mix(fill, target, accentAmount: high)
	}

	static func contrastRatio(_ a: UIColor, _ b: UIColor) -> Double {
		func lum(_ color: UIColor) -> Double {
			var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, alpha: CGFloat = 0
			guard color.getRed(&r, green: &g, blue: &bl, alpha: &alpha) else { return 0 }
			func linear(_ x: CGFloat) -> Double {
				let v = Double(x)
				return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
			}
			return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(bl)
		}
		let l1 = lum(a), l2 = lum(b)
		return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
	}

	private static func mix(_ base: UIColor, _ accent: UIColor, accentAmount: CGFloat) -> UIColor {
		var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
		var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
		guard base.getRed(&br, green: &bg, blue: &bb, alpha: &ba),
			  accent.getRed(&ar, green: &ag, blue: &ab, alpha: &aa) else { return base }
		let t = min(max(accentAmount, 0), 1)
		return UIColor(red: br + (ar - br) * t, green: bg + (ag - bg) * t,
			blue: bb + (ab - bb) * t, alpha: ba + (aa - ba) * t)
	}
}

/// Small HSL utility used to derive coherent role colors from every user-selected
/// accent. HSL is preferable here because changing lightness does not also shift the
/// hue, so action, modifier, and mode keys remain recognizably related.
private struct KBHSL {
	let hue: CGFloat
	let saturation: CGFloat
	let lightness: CGFloat

	init(_ color: UIColor) {
		var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
		guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
			hue = 0; saturation = 0; lightness = 0.5
			return
		}
		let maximum = max(red, green, blue)
		let minimum = min(red, green, blue)
		let delta = maximum - minimum
		lightness = (maximum + minimum) / 2
		if delta == 0 {
			hue = 0
			saturation = 0
			return
		}
		saturation = delta / (1 - abs(2 * lightness - 1))
		let rawHue: CGFloat
		if maximum == red {
			rawHue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
		} else if maximum == green {
			rawHue = (blue - red) / delta + 2
		} else {
			rawHue = (red - green) / delta + 4
		}
		hue = (rawHue / 6 + 1).truncatingRemainder(dividingBy: 1)
	}

	func color(saturation: CGFloat, lightness: CGFloat, alpha: CGFloat) -> UIColor {
		let s = min(max(saturation, 0), 1)
		let l = min(max(lightness, 0), 1)
		let chroma = (1 - abs(2 * l - 1)) * s
		let sector = hue * 6
		let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
		let rgb: (CGFloat, CGFloat, CGFloat)
		switch sector {
		case 0..<1: rgb = (chroma, x, 0)
		case 1..<2: rgb = (x, chroma, 0)
		case 2..<3: rgb = (0, chroma, x)
		case 3..<4: rgb = (0, x, chroma)
		case 4..<5: rgb = (x, 0, chroma)
		default: rgb = (chroma, 0, x)
		}
		let match = l - chroma / 2
		return UIColor(red: rgb.0 + match, green: rgb.1 + match, blue: rgb.2 + match, alpha: alpha)
	}
}

// MARK: - Model

enum KeyboardSurfacePage { case letters, alternateLetters, numbers, symbols, emoji, media, clipboard }
enum KeyboardInputKind: Equatable {
	case standard, email, url, webSearch, twitter
	case numbersAndPunctuation, numberPad, decimalPad, phonePad

	var usesDedicatedNumberPad: Bool {
		switch self { case .numberPad, .decimalPad, .phonePad: return true; default: return false }
	}
}
enum ShiftState   { case off, on, locked }
enum KeyRole      { case normal, special, accent, accentSoft }   // optional soft accent role
enum KeyWidth     {
	case unit, modifier, utility, ret, flex

	/// Widths in letter-key units, matched to the stock iOS deck. Shift/delete
	/// (and #+=) sit at the 44pt tap-target minimum; the bottom row's
	/// 123/ABC, globe and emoji keys are a touch narrower; return is wide
	/// enough for its "send"/"search" labels.
	static let modifierUnits: CGFloat = 1.35
	static let utilityUnits: CGFloat = 1.3
	static let returnUnits: CGFloat = 2.8
}

struct KeySpec {
	var label: String? = nil
	var symbol: String? = nil
	var accessibilityLabel: String? = nil
	var role: KeyRole = .normal
	var width: KeyWidth = .unit
	var repeats: Bool = false        // fires continuously while held (delete)
	var popup: Bool = false          // show the stock-style character balloon on press
	var letterBase: String? = nil    // lowercase base letter → enables in-place shift relabelling
	var committedText: String? = nil // literal inserted before a long-press replacement
	var isShift: Bool = false        // the shift key, whose glyph updates on shift changes
	var isInputModeSwitch: Bool = false
	var isSpace: Bool = false
	var alternatives: [String] = []
	/// Multiplier on the key legend's point size. 1.0 for Latin; Telugu script keys pass
	/// a smaller value so the tall multi-row Indic deck can use shorter, more compact keys.
	var glyphScale: CGFloat = 1.0
	var action: () -> Void
}
