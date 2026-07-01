import UIKit
import CoreText

// Add this file to BOTH targets (app + keyboard extension). Pure UIKit.

// MARK: - Font installer
//
// Registers any .ttf/.otf bundled in the current target at runtime, so custom
// fonts (e.g. Nerd Fonts) work in BOTH the app and the keyboard extension without
// editing each target's Info.plist. Add the font files to a target, call this once,
// then reference them by PostScript name in KBFont.customFamily.

enum FontInstaller {
	private static var done = false
	static func registerBundledFonts() {
		guard !done else { return }
		done = true
		let bundle = Bundle(for: KeyboardView.self)   // the target that owns this code
		for ext in ["ttf", "otf"] {
			for url in bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
				CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
			}
		}
	}
}

// MARK: - Color

extension UIColor {
	convenience init(hex: UInt32) {
		self.init(red: CGFloat((hex >> 16) & 0xFF)/255,
				  green: CGFloat((hex >> 8) & 0xFF)/255,
				  blue: CGFloat(hex & 0xFF)/255, alpha: 1)
	}
	/// Mix toward another colour. fraction 0 = self, 1 = other.
	func blended(with other: UIColor, fraction f: CGFloat) -> UIColor {
		var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
		var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
		getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
		other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
		return UIColor(red: r1+(r2-r1)*f, green: g1+(g2-g1)*f, blue: b1+(b2-b1)*f, alpha: a1+(a2-a1)*f)
	}
}

// MARK: - Shared settings (App Group: written by the app, read by the extension)
//
// The app and the keyboard extension are separate processes. They share state through
// an App Group UserDefaults suite. The app writes; the keyboard reads on each launch.

enum KBLanguage: String, CaseIterable {
	case english  = "English"
	case tenglish = "Tenglish"
	case telugu   = "Telugu"

	var subtitle: String {
		switch self {
		case .english:  return "QWERTY"
		case .tenglish: return "Type in English, get Telugu"
		case .telugu:   return "Telugu script"
		}
	}
	/// Only English is wired up today; the others are visible but inert.
	var isAvailable: Bool { self == .english }
}

enum KBFont: String, CaseIterable {
	case system   = "System"
	case rounded  = "Rounded"
	case serif    = "Serif"
	case mono     = "Monospaced"
	// Custom families need a bundled .ttf/.otf in the EXTENSION target. Until the file
	// is added these fall back to System (see FontInstaller.register / customFamily).
	case jetBrains = "JetBrains Mono"
	case hack      = "Hack"

	var subtitle: String {
		switch self {
		case .system:    return "San Francisco"
		case .rounded:   return "SF Rounded"
		case .serif:     return "New York"
		case .mono:      return "SF Mono"
		case .jetBrains: return "Nerd Font · needs file"
		case .hack:      return "Nerd Font · needs file"
		}
	}

	private var systemDesign: UIFontDescriptor.SystemDesign? {
		switch self {
		case .system:  return .default
		case .rounded: return .rounded
		case .serif:   return .serif
		case .mono:    return .monospaced
		default:       return nil
		}
	}
	/// PostScript name of the bundled custom font, if any. Update these to match the
	/// real names of the files you drop in (see the Fonts guide).
	var customFamily: String? {
		switch self {
		case .jetBrains: return "JetBrainsMonoNFM-Regular"
		case .hack:      return "HackNFM-Regular"
		default:         return nil
		}
	}

	func uiFont(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
		if let family = customFamily, let custom = UIFont(name: family, size: size) { return custom }
		let base = UIFont.systemFont(ofSize: size, weight: weight)
		if let design = systemDesign, let d = base.fontDescriptor.withDesign(design) {
			return UIFont(descriptor: d, size: size)
		}
		return base
	}
}

struct KBGradient: Hashable {
	let start: UInt32
	let end: UInt32
	var startColor: UIColor { UIColor(hex: start) }
	var endColor: UIColor { UIColor(hex: end) }
}

/// An accent the user can pick. Each has a Light and Dark gradient so it sits well
/// on either background. Drives the action button + active accents.
struct KBAccent: Identifiable, Hashable {
	let id: String
	let name: String
	let light: KBGradient
	let dark: KBGradient

	func gradient(dark: Bool) -> KBGradient { dark ? self.dark : self.light }
	/// A single representative colour for small UI (swatch border, tints).
	func tint(dark: Bool) -> UIColor { gradient(dark: dark).endColor }
}

/// The palette for the Themes page. Each accent ships a Light and a Dark gradient; the
/// keyboard (and the Themes preview) automatically render the variant for the user's
/// current Light/Dark mode. Grouped by colour family for easy browsing.
enum KBPalette {
	static let `default` = emerald

	static let emerald = KBAccent(id: "emerald", name: "Emerald",
		light: KBGradient(start: 0x37C26B, end: 0x1E9E5A),
		dark:  KBGradient(start: 0x33B566, end: 0x18854C))

	static let groups: [(title: String, accents: [KBAccent])] = [
		("Greens", [
			emerald,
			KBAccent(id: "leaf", name: "Leaf",
				light: KBGradient(start: 0x6FB544, end: 0x4E8E2E),
				dark:  KBGradient(start: 0x78C84E, end: 0x57A338)),
			KBAccent(id: "mint", name: "Mint",
				light: KBGradient(start: 0x44CFA0, end: 0x21B287),
				dark:  KBGradient(start: 0x53DCAB, end: 0x2FC795)),
			KBAccent(id: "teal", name: "Teal",
				light: KBGradient(start: 0x16A89B, end: 0x0B7C76),
				dark:  KBGradient(start: 0x1CB4A6, end: 0x108A82)),
			KBAccent(id: "forest", name: "Forest",
				light: KBGradient(start: 0x4C9E45, end: 0x2C6E30),
				dark:  KBGradient(start: 0x4F9E45, end: 0x357A38)),
		]),
		("Blues", [
			KBAccent(id: "sky", name: "Sky",
				light: KBGradient(start: 0x55B4FF, end: 0x2F97EC),
				dark:  KBGradient(start: 0x63BCFF, end: 0x39A4F5)),
			KBAccent(id: "ocean", name: "Ocean",
				light: KBGradient(start: 0x3A7BF0, end: 0x2056D6),
				dark:  KBGradient(start: 0x4585F0, end: 0x2A60D9)),
			KBAccent(id: "indigo", name: "Indigo",
				light: KBGradient(start: 0x5560E0, end: 0x3A44C6),
				dark:  KBGradient(start: 0x5F69E8, end: 0x434FD6)),
		]),
		("Purples", [
			KBAccent(id: "lavender", name: "Lavender",
				light: KBGradient(start: 0xAE9BFF, end: 0x8E78FA),
				dark:  KBGradient(start: 0xBBA6FF, end: 0x9C84FF)),
			KBAccent(id: "plum", name: "Plum",
				light: KBGradient(start: 0x9A4FD0, end: 0x7733AE),
				dark:  KBGradient(start: 0xA75FE0, end: 0x8642C2)),
		]),
		("Warm", [
			KBAccent(id: "coral", name: "Coral",
				light: KBGradient(start: 0xFF8C76, end: 0xF2654E),
				dark:  KBGradient(start: 0xFF9079, end: 0xF56A52)),
			KBAccent(id: "rose", name: "Rose",
				light: KBGradient(start: 0xFF87B0, end: 0xE5588C),
				dark:  KBGradient(start: 0xFF92B8, end: 0xF56AA0)),
			KBAccent(id: "amber", name: "Amber",
				light: KBGradient(start: 0xFFC24B, end: 0xF5A11F),
				dark:  KBGradient(start: 0xFFC85A, end: 0xF7AE2E)),
			KBAccent(id: "rust", name: "Rust",
				light: KBGradient(start: 0xE2682E, end: 0xBE4C1A),
				dark:  KBGradient(start: 0xE87238, end: 0xCC5A22)),
		]),
		("Neutral", [
			KBAccent(id: "graphite", name: "Graphite",
				light: KBGradient(start: 0x70757E, end: 0x474B52),
				dark:  KBGradient(start: 0x7A7F88, end: 0x4E535A)),
			KBAccent(id: "slate", name: "Slate",
				light: KBGradient(start: 0x78828F, end: 0x566070),
				dark:  KBGradient(start: 0x6E7889, end: 0x4C5666)),
		]),
	]

	static var all: [KBAccent] { groups.flatMap { $0.accents } }
	static func accent(id: String) -> KBAccent { all.first { $0.id == id } ?? `default` }
}

enum KBSettings {
	static let appGroup = "group.com.swiftuimasterclass.keyboard"
	private static var store: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

	private enum Key {
		static let language = "kb.language"
		static let accent   = "kb.accent"
		static let font     = "kb.font"
		static let haptics  = "kb.haptics"
	}

	static var language: KBLanguage {
		get { KBLanguage(rawValue: store.string(forKey: Key.language) ?? "") ?? .english }
		set { store.set(newValue.rawValue, forKey: Key.language) }
	}
	static var accentID: String {
		get { store.string(forKey: Key.accent) ?? KBPalette.default.id }
		set { store.set(newValue, forKey: Key.accent) }
	}
	static var accent: KBAccent { KBPalette.accent(id: accentID) }
	static var font: KBFont {
		get { KBFont(rawValue: store.string(forKey: Key.font) ?? "") ?? .system }
		set { store.set(newValue.rawValue, forKey: Key.font) }
	}
	/// Haptic tap on each key press. Default on. Requires keyboard Full Access to fire.
	static var haptics: Bool {
		get { store.object(forKey: Key.haptics) as? Bool ?? true }
		set { store.set(newValue, forKey: Key.haptics) }
	}
}

// MARK: - Theme

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

enum KeyboardPage { case letters, numbers, symbols }
enum ShiftState   { case off, on, locked }
enum KeyRole      { case normal, special, accent, accentSoft }   // accentSoft = lighter tint of the accent (shift/delete)
enum KeyWidth     { case unit, wide, ret, flex }

private struct KeySpec {
	var label: String? = nil
	var symbol: String? = nil
	var role: KeyRole = .normal
	var width: KeyWidth = .unit
	var pill: Bool = false           // fully-rounded (capsule) instead of normal roundness
	var action: () -> Void
}

// MARK: - Key (now a dumb view — KeyboardView owns the touches)

final class KeyButton: UIView {
	let widthKind: KeyWidth
	let action: () -> Void
	private let dark: Bool
	private let gradient: CAGradientLayer?        // non-nil for the accent (action) key
	private let dim = UIView()                    // press-feedback overlay (works on any fill)
	private let dimColor: UIColor
	private let isPill: Bool                       // capsule rounding
	private let baseRadius: CGFloat

	fileprivate init(spec: KeySpec, theme: KeyboardTheme) {
		self.widthKind = spec.width
		self.action = spec.action
		self.dark = theme.isDark
		self.gradient = spec.role == .accent ? CAGradientLayer() : nil
		self.dimColor = theme.isDark ? UIColor(white: 1, alpha: 0.18) : UIColor(white: 0, alpha: 0.12)
		self.isPill = spec.pill
		self.baseRadius = theme.cornerRadius
		super.init(frame: .zero)
		isUserInteractionEnabled = false        // touches handled by KeyboardView

		let fg: UIColor
		switch spec.role {
		case .normal:     fg = theme.keyText
		case .special:    fg = theme.specialKeyText
		case .accent:     fg = theme.accentKeyText
		case .accentSoft: fg = theme.accentSoftText
		}

		// Background: a gradient for the action key, a flat fill otherwise.
		if let gradient {
			gradient.colors = [theme.accentStart.cgColor, theme.accentEnd.cgColor]
			gradient.startPoint = CGPoint(x: 0, y: 0)
			gradient.endPoint   = CGPoint(x: 1, y: 1)
			gradient.cornerRadius = theme.cornerRadius
			gradient.cornerCurve = .continuous
			layer.addSublayer(gradient)
		} else {
			switch spec.role {
			case .special:    backgroundColor = theme.specialKey
			case .accentSoft: backgroundColor = theme.accentSoft
			default:          backgroundColor = theme.key
			}
		}

		dim.isUserInteractionEnabled = false
		dim.backgroundColor = .clear
		dim.layer.cornerRadius = theme.cornerRadius
		dim.layer.cornerCurve = .continuous
		addSubview(dim)

		let content: UIView
		if let symbol = spec.symbol {
			let iv = UIImageView(image: UIImage(systemName: symbol,
				withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)))
			iv.tintColor = fg
			content = iv
		} else {
			let lbl = UILabel()
			lbl.text = spec.label
			lbl.textColor = fg
			let multi = (spec.label?.count ?? 0) > 1
			// Single characters (the letters you type) honour the user's font choice.
			// Multi-char functional labels (space, 123, go) stay on the system font.
			lbl.font = multi ? .systemFont(ofSize: 16, weight: .medium)
							 : theme.font.uiFont(ofSize: 23)
			content = lbl
		}
		content.translatesAutoresizingMaskIntoConstraints = false
		addSubview(content)
		NSLayoutConstraint.activate([
			content.centerXAnchor.constraint(equalTo: centerXAnchor),
			content.centerYAnchor.constraint(equalTo: centerYAnchor)
		])

		layer.cornerRadius = theme.cornerRadius
		layer.cornerCurve = .continuous
		// Soft modern drop shadow. shadowPath is set in layoutSubviews so Core Animation
		// never rasterizes an offscreen blur on the hot path.
		layer.shadowColor = theme.shadowColor.cgColor
		layer.shadowOpacity = theme.shadowOpacity
		layer.shadowRadius = 2.5
		layer.shadowOffset = CGSize(width: 0, height: 1)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		let r = isPill ? bounds.height / 2 : baseRadius     // capsule for functional keys
		CATransaction.begin(); CATransaction.setDisableActions(true)
		layer.cornerRadius = r
		gradient?.cornerRadius = r
		gradient?.frame = bounds
		dim.layer.cornerRadius = r
		dim.frame = bounds
		CATransaction.commit()
		layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: r).cgPath
	}

	func setHighlighted(_ on: Bool) { dim.backgroundColor = on ? dimColor : .clear }
}

// MARK: - Suggestion bar (its own touches — taps a candidate)

final class SuggestionBar: UIView {
	var onPick: ((String) -> Void)?
	private var buttons: [UIButton] = []
	private let sep1 = UIView(), sep2 = UIView()

	init(theme: KeyboardTheme) {
		super.init(frame: .zero)
		backgroundColor = .clear
		let stack = UIStackView()
		stack.axis = .horizontal
		stack.distribution = .fillEqually
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor)
		])
		for i in 0..<3 {
			let b = UIButton(type: .custom)
			b.titleLabel?.font = .systemFont(ofSize: 16)
			b.setTitleColor(theme.keyText, for: .normal)
			b.tag = i
			b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
			buttons.append(b)
			stack.addArrangedSubview(b)
		}
		for s in [sep1, sep2] {
			s.backgroundColor = theme.keyText.withAlphaComponent(0.15)
			addSubview(s)
		}
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		let w = bounds.width / 3
		let inset: CGFloat = 10
		sep1.frame = CGRect(x: w, y: inset, width: 0.5, height: bounds.height - inset*2)
		sep2.frame = CGRect(x: w*2, y: inset, width: 0.5, height: bounds.height - inset*2)
	}

	func setSuggestions(_ s: [String]) {
		for (i, b) in buttons.enumerated() {
			let t = i < s.count ? s[i] : ""
			b.setTitle(t, for: .normal)
			b.isEnabled = !t.isEmpty
		}
	}

	@objc private func tap(_ sender: UIButton) {
		if let t = sender.title(for: .normal), !t.isEmpty { onPick?(t) }
	}
}

// MARK: - Keyboard

final class KeyboardView: UIView {

	var onInsert:         ((String) -> Void)?
	var onDelete:         (() -> Void)?
	var onReturn:         (() -> Void)?
	var onNextKeyboard:   (() -> Void)?
	var onPickSuggestion: ((String) -> Void)?

	private let theme: KeyboardTheme
	private let deckLayer = CAGradientLayer()
	private let showsGlobe: Bool
	private var page: KeyboardPage = .letters
	private var shift: ShiftState = .on
	private var rows: [[KeyButton]] = []
	private var actionTitle: String?          // contextual label for the action key (go / search / send …)
	private let suggestionBar: SuggestionBar

	/// Light haptic on each key press. Off unless enabled in settings (and the keyboard
	/// has Full Access — otherwise iOS silently ignores the feedback generator).
	var hapticsEnabled = false
	private let haptic = UIImpactFeedbackGenerator(style: .rigid)

	/// Prime the Taptic Engine so the first key tap fires without latency.
	func prepareHaptics() { if hapticsEnabled { haptic.prepare() } }

	private let keySpacing: CGFloat = 6
	private let rowSpacing: CGFloat = 11
	private let rowHeight:  CGFloat = 42       // shorter keys → matches stock iOS proportions
	private let stripHeight: CGFloat = 44
	private let sidePad: CGFloat = 3
	private let topPad: CGFloat = 5
	private let botPad: CGFloat = 5

	var keyboardHeight: CGFloat { stripHeight + topPad + rowHeight*4 + rowSpacing*3 + botPad }

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
		isMultipleTouchEnabled = true            // <-- fast typists / overlapping fingers
		addSubview(suggestionBar)
		suggestionBar.onPick = { [weak self] in self?.onPickSuggestion?($0) }
		reload()
	}
	required init?(coder: NSCoder) { fatalError() }

	func setSuggestions(_ s: [String]) { suggestionBar.setSuggestions(s) }

	/// Set the contextual label on the action (return) key. Pass nil for a plain
	/// newline glyph. Only rebuilds when it actually changes.
	func setActionTitle(_ title: String?) {
		guard title != actionTitle else { return }
		actionTitle = title
		reload()
	}

	// MARK: Layout

	override func layoutSubviews() {
		super.layoutSubviews()
		CATransaction.begin(); CATransaction.setDisableActions(true)
		deckLayer.frame = bounds
		CATransaction.commit()
		suggestionBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripHeight)

		let W = bounds.width - sidePad*2
		guard W > 0 else { return }
		let unit = max(1, (W - keySpacing*9)/10)
		let wide = unit*1.5 + keySpacing/2
		let retW = unit*2 + keySpacing
		func fixed(_ k: KeyWidth) -> CGFloat {
			switch k { case .unit: return unit; case .wide: return wide; case .ret: return retW; case .flex: return 0 }
		}

		var y = stripHeight + topPad
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

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			guard let key = key(at: touch.location(in: self)) else { continue }
			key.setHighlighted(true)
			touchKeys[touch] = key
			if hapticsEnabled { haptic.impactOccurred(intensity: 0.9); haptic.prepare() }
			key.action()                        // commit immediately
		}
	}
	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			guard let key = touchKeys[touch] else { continue }
			key.setHighlighted(key.frame.contains(touch.location(in: self)))
		}
	}
	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			touchKeys[touch]?.setHighlighted(false)
			touchKeys[touch] = nil
		}
	}
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		touchesEnded(touches, with: event)
	}

	private func key(at p: CGPoint) -> KeyButton? {
		var best: KeyButton?
		var bestDist = CGFloat.greatestFiniteMagnitude
		for row in rows {
			for key in row {
				if key.frame.contains(p) { return key }       // exact hit
				let dx = max(key.frame.minX - p.x, 0, p.x - key.frame.maxX)
				let dy = max(key.frame.minY - p.y, 0, p.y - key.frame.maxY)
				let d = dx*dx + dy*dy                          // squared distance to the key rect
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
		bringSubviewToFront(suggestionBar)
		setNeedsLayout()
	}

	private func shifted(_ c: String) -> String { shift == .off ? c : c.uppercased() }
	private var shiftSymbol: String {
		switch shift { case .off: return "shift"; case .on: return "shift.fill"; case .locked: return "capslock.fill" }
	}
	private func charSpec(_ c: String) -> KeySpec {
		if page == .letters {
			return KeySpec(label: shifted(c), width: .unit) { [weak self] in
				guard let self else { return }
				self.onInsert?(self.shifted(c))
				if self.shift == .on { self.shift = .off; self.reload() }
			}
		}
		return KeySpec(label: c, width: .unit) { [weak self] in self?.onInsert?(c) }
	}
	private func punct(_ c: String) -> KeySpec {
		KeySpec(label: c, width: .flex) { [weak self] in self?.onInsert?(c) }
	}

	private func specs() -> [[KeySpec]] {
		let del = KeySpec(symbol: "delete.left", role: .accentSoft, width: .wide) { [weak self] in self?.onDelete?() }
		let ret: KeySpec = {
			if let t = actionTitle, !t.isEmpty {
				return KeySpec(label: t, role: .accent, width: .ret, pill: true) { [weak self] in self?.onReturn?() }
			}
			return KeySpec(symbol: "return", role: .accent, width: .ret, pill: true) { [weak self] in self?.onReturn?() }
		}()
		let space = KeySpec(label: "space", width: .flex, pill: true) { [weak self] in self?.onInsert?(" ") }
		func switchKey(_ l: String, to t: KeyboardPage) -> KeySpec {
			KeySpec(label: l, role: .special, width: .wide, pill: true) { [weak self] in self?.page = t; self?.reload() }
		}
		func bottom(_ leading: KeySpec) -> [KeySpec] {
			var r = [leading]
			if showsGlobe { r.append(KeySpec(symbol: "globe", role: .special, width: .unit, pill: true) { [weak self] in self?.onNextKeyboard?() }) }
			r.append(space); r.append(ret); return r
		}
		let shiftKey = KeySpec(symbol: shiftSymbol, role: .accentSoft, width: .wide) { [weak self] in
			guard let self else { return }
			switch self.shift { case .off: self.shift = .on; case .on: self.shift = .locked; case .locked: self.shift = .off }
			self.reload()
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
		}
	}
}
