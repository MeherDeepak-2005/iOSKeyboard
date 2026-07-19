import UIKit

// Shared settings + theming model (App Group) — extracted from Keyboard.swift.

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
	/// User-defined SentencePiece token prepended to every model context.
	var modelTag: String {
		switch self {
		case .english:  return "<en>"
		case .tenglish: return "<xlit>"
		case .telugu:   return "<te>"
		}
	}
	/// Only English is wired up today; the others are visible but inert.
	var isAvailable: Bool { self == .english }
}

enum KBWordCase {
	static func sentenceDisplay(_ word: String, capitalized: Bool) -> String {
		guard capitalized, !word.isEmpty else { return word }
		return word.prefix(1).uppercased() + word.dropFirst()
	}
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

	/// Substring identifying this font's file(s) in the bundle, for selective
	/// registration in the extension (see FontInstaller.registerSelectedFont). nil for
	/// system-design fonts, which ship no files.
	var fileToken: String? {
		switch self {
		case .jetBrains: return "JetBrains"
		case .hack:      return "Hack"
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

/// Theme Studio custom theme — ROLE-based colors (letters / special keys / action
/// key / text / background), not per-individual-key: that maps 1:1 onto KeyRole,
/// reads coherently, and keeps the blob a few dozen bytes. Background is a vertical
/// gradient (set start == end for a solid) or a photo (downscaled by the APP at
/// save time — the extension only ever decodes a keyboard-sized image).
struct KBCustomTheme: Codable, Equatable {
	var keys: UInt32        = 0xFFFFFF   // letter-key fill
	var special: UInt32     = 0xDDE1EA   // shift / delete / 123 / globe fill
	var accentStart: UInt32 = 0x37C26B   // action-key gradient
	var accentEnd: UInt32   = 0x1E9E5A
	var text: UInt32        = 0x1B1B1D   // key glyphs + suggestions
	var bgStart: UInt32     = 0xF2F0F4   // background gradient (top → bottom)
	var bgEnd: UInt32       = 0xE4E1E9
	var dark = false                     // dark-surface treatment (popups, highlights)
	var usesPhoto = false                // kb_theme_bg.jpg in the App Group backs the deck
}

enum KBSettings {
	nonisolated static let appGroup = "group.com.swiftuimasterclass.keyboard"
	/// Open the App Group preference suite once per process. Reconstructing it at every
	/// read causes unnecessary CFPreferences container attachment work in the extension
	/// and can repeat Apple's `kCFPreferencesAnyUser` diagnostic.
	nonisolated(unsafe) static let sharedDefaults = UserDefaults(suiteName: appGroup) ?? .standard
	private static var store: UserDefaults { sharedDefaults }

	private enum Key {
		static let language = "kb.language"
		static let accent   = "kb.accent"
		static let font     = "kb.font"
		static let haptics  = "kb.haptics"
		static let neural   = "kb.neural"
		static let glideCap = "kb.glidecapture"
		static let hasUsed  = "kb.hasused"
		static let fullAccess = "kb.fullaccess"
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
	/// KLIPY API key (klipy.com/developers). App Group first (host app can set it);
	/// falls back to an optional "KlipyAPIKey" Info.plist entry. Empty = GIF/sticker
	/// panel shows its "add key" hint and makes no network calls.
	static var klipyAPIKey: String {
		get {
			if let k = store.string(forKey: "kb.klipy.key"), !k.isEmpty { return k }
			return (Bundle.main.object(forInfoDictionaryKey: "KlipyAPIKey") as? String) ?? ""
		}
		set { store.set(newValue, forKey: "kb.klipy.key") }
	}
	/// Stable ANONYMOUS id KLIPY scopes per-user recents/ads to. Random UUID minted
	/// once — never derived from anything personal.
	static var klipyCustomerID: String {
		if let id = store.string(forKey: "kb.klipy.customer") { return id }
		let id = UUID().uuidString
		store.set(id, forKey: "kb.klipy.customer")
		return id
	}
	static var font: KBFont {
		get { KBFont(rawValue: store.string(forKey: Key.font) ?? "") ?? .system }
		set { store.set(newValue.rawValue, forKey: Key.font) }
	}
	/// Haptic tap on each key press. Default on. Requires keyboard Full Access to fire.
	static var haptics: Bool {
		get { store.object(forKey: Key.haptics) as? Bool ?? true }
		set { store.set(newValue, forKey: Key.haptics) }
	}
	/// Set by the extension after it is presented at least once. iOS does not expose a
	/// reliable API for checking whether this specific third-party keyboard is enabled.
	static var hasUsedKeyboard: Bool {
		get { store.bool(forKey: Key.hasUsed) }
		set { store.set(newValue, forKey: Key.hasUsed) }
	}
	/// Last Full Access state observed by the extension after a real host connection.
	/// The containing app cannot query this directly, so it presents this cached state.
	static var lastFullAccess: Bool {
		get { store.bool(forKey: Key.fullAccess) }
		set { store.set(newValue, forKey: Key.fullAccess) }
	}
	/// Load the on-device neural rescorer. Default ON — it earns its ~20-30 MB working
	/// set with better ranking, and it already sheds that memory when the OS signals
	/// pressure (NeuralScorer's pressure source) and only loads with real headroom
	/// (minAvailableMBToLoad). Active while it helps, dropped when the budget is tight.
	static var neuralRescorer: Bool {
		get { store.object(forKey: Key.neural) as? Bool ?? true }
		set { store.set(newValue, forKey: Key.neural) }
	}
	/// DEBUG capture: append each glide's grid path + decoded words to a JSONL file in the
	/// App Group, so tools/glide_eval/calibrate.py can fit the harness noise model to real
	/// strokes. OFF by default; on-device only; never leaves the device.
	static var glideCapture: Bool {
		get { store.object(forKey: Key.glideCap) as? Bool ?? false }
		set { store.set(newValue, forKey: Key.glideCap) }
	}

	/// URL of the on-device personalisation model in the shared App Group container.
	/// Both the app and the extension resolve to the same file, so the app can delete it directly.
	static var userModelURL: URL? {
		FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
			.appendingPathComponent("kb_model.json")
	}

	// MARK: Theme Studio

	/// The saved custom theme (nil = never designed one). Enabling is a SEPARATE
	/// flag so switching back to a stock accent keeps the design for later.
	static var customTheme: KBCustomTheme? {
		get {
			guard let data = store.data(forKey: "kb.customtheme") else { return nil }
			return try? JSONDecoder().decode(KBCustomTheme.self, from: data)
		}
		set {
			if let newValue, let data = try? JSONEncoder().encode(newValue) {
				store.set(data, forKey: "kb.customtheme")
			} else {
				store.removeObject(forKey: "kb.customtheme")
			}
		}
	}
	static var customThemeEnabled: Bool {
		get { store.bool(forKey: "kb.customtheme.on") }
		set { store.set(newValue, forKey: "kb.customtheme.on") }
	}
	/// The custom background photo, pre-downscaled by the app (see ThemeStudioView).
	static var themePhotoURL: URL? {
		FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
			.appendingPathComponent("kb_theme_bg.jpg")
	}
}
