import UIKit
import Darwin

// Shared settings + theming model (App Group) — extracted from Keyboard.swift.

enum KBWordCase {
	static func sentenceDisplay(_ word: String, capitalized: Bool) -> String {
		guard capitalized, !word.isEmpty else { return word }
		return word.prefix(1).uppercased() + word.dropFirst()
	}
}

nonisolated enum KBLanguageMode: String, Codable, CaseIterable, Identifiable, Sendable {
	case english
	/// Keep the legacy raw value so installed users migrate without a preference reset.
	case tenglishToTelugu = "tenglish"
	case romanTelugu = "roman_telugu"
	case telugu

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .english: return "English"
		case .tenglishToTelugu: return "Tenglish to Telugu"
		case .romanTelugu: return "Tenglish (Roman)"
		case .telugu: return "Telugu (Native)"
		}
	}

	var detail: String {
		switch self {
		case .english: return "English QWERTY"
		case .tenglishToTelugu: return "Roman typing with Telugu conversion"
		case .romanTelugu: return "Romanised Telugu in Latin script"
		case .telugu: return "Native Telugu layout"
		}
	}

	var isRuntimeAvailable: Bool {
		switch self {
		case .english: return true
		case .tenglishToTelugu, .romanTelugu, .telugu:
			// Parsing alone is insufficient: a stale or partially copied resource may
			// still have a valid header. Runtime activation uses the same manifest/hash
			// verdict surfaced by the companion app.
			return LanguagePackHealthInspector.bundledHealth(for: self).isReady
		}
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
/// gradient (set start == end for a solid).
struct KBCustomTheme: Codable, Equatable {
	var keys: UInt32        = 0xFFFFFF   // letter-key fill
	var special: UInt32     = 0xDDE1EA   // shift / delete / 123 / globe fill
	var accentStart: UInt32 = 0x37C26B   // action-key gradient
	var accentEnd: UInt32   = 0x1E9E5A
	var text: UInt32        = 0x1B1B1D   // key glyphs + suggestions
	var bgStart: UInt32     = 0xF2F0F4   // background gradient (top → bottom)
	var bgEnd: UInt32       = 0xE4E1E9
	var dark = false                     // dark-surface treatment (popups, highlights)
}

struct KBCustomThemePair: Codable, Equatable {
	var light: KBCustomTheme
	var dark: KBCustomTheme

	static func defaults(accent: KBAccent) -> KBCustomThemePair {
		let lightGradient = accent.gradient(dark: false)
		let darkGradient = accent.gradient(dark: true)
		var light = KBCustomTheme()
		light.accentStart = lightGradient.start
		light.accentEnd = lightGradient.end
		var dark = KBCustomTheme(
			keys: 0x343439,
			special: 0x29292E,
			accentStart: darkGradient.start,
			accentEnd: darkGradient.end,
			text: 0xF2F2F4,
			bgStart: 0x242428,
			bgEnd: 0x1B1B1F,
			dark: true
		)
		dark.dark = true
		return KBCustomThemePair(light: light, dark: dark)
	}
}

enum KBSettings {
	nonisolated static let appGroup = "group.com.swiftuimasterclass.keyboard"
	/// Open the App Group preference suite once per process. Reconstructing it at every
	/// read causes unnecessary CFPreferences container attachment work in the extension
	/// and can repeat Apple's `kCFPreferencesAnyUser` diagnostic.
	nonisolated(unsafe) static let sharedDefaults = UserDefaults(suiteName: appGroup) ?? .standard
	private static var store: UserDefaults { sharedDefaults }
	private static let configurationNotification = CFNotificationName(
		"com.swiftuimasterclass.keyboard.configuration-changed" as CFString
	)

	private enum Key {
		static let accent   = "kb.accent"
		static let haptics  = "kb.haptics"
		static let language = "kb.language"
		static let glideCap = "kb.glidecapture"
		static let neuralEnabled = "kb.neural.enabled"
		static let hasUsed  = "kb.hasused"
		static let lastSeen = "kb.keyboard.lastSeen"
		static let fullAccess = "kb.fullaccess"
		static let fullAccessObservedAt = "kb.fullaccess.observedAt"
		static let extensionLanguageReport = "kb.language.extension.report.v1"
	}
	/// KLIPY mobile client key injected through the extension's `KLIPY_API_KEY`
	/// build setting. It is intentionally treated as a public, rotatable client
	/// identifier; no secret is hardcoded in source or user preferences.
	static var klipyAPIKey: String {
		let value = Bundle.main.object(forInfoDictionaryKey: "KLIPYAPIKey") as? String ?? ""
		return value.contains("$(") ? "" : value.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	/// KLIPY applies content filtering in its Partner Panel, per API key. Remote
	/// media fails closed until Release engineering records that review in the build
	/// setting; supplying a key alone is intentionally insufficient.
	static var klipyContentFilterApproved: Bool {
		let value = Bundle.main.object(forInfoDictionaryKey: "KLIPYContentFilterApproved")
		if let enabled = value as? Bool { return enabled }
		guard let raw = value as? String, !raw.contains("$(") else { return false }
		return ["1", "true", "yes"].contains(raw.lowercased())
	}
	static var klipyMediaEnabled: Bool {
		let value = Bundle.main.object(forInfoDictionaryKey: "KLIPYMediaEnabled")
		if let enabled = value as? Bool { return enabled }
		guard let raw = value as? String, !raw.contains("$(") else { return false }
		return ["1", "true", "yes"].contains(raw.lowercased())
	}

	static var accentID: String {
		get { store.string(forKey: Key.accent) ?? KBPalette.default.id }
		set { store.set(newValue, forKey: Key.accent) }
	}
	static var accent: KBAccent { KBPalette.accent(id: accentID) }
	/// The user's durable selection. A temporarily missing or rejected extension pack
	/// must not rewrite this preference to English.
	static var preferredLanguageMode: KBLanguageMode {
		get {
			guard let raw = store.string(forKey: Key.language),
				  let mode = KBLanguageMode(rawValue: raw) else {
				return .english
			}
			return mode
		}
		set {
			store.set(newValue.rawValue, forKey: Key.language)
			postConfigurationChange()
		}
	}
	/// Effective mode for this process/session. The caller can safely build a keyboard
	/// from this value while the preferred mode remains available for recovery UI.
	static var effectiveLanguageMode: KBLanguageMode {
		let preferred = preferredLanguageMode
		return preferred.isRuntimeAvailable ? preferred : .english
	}
	/// Source-compatibility alias. New code should state whether it wants preferred or
	/// effective semantics explicitly.
	static var languageMode: KBLanguageMode {
		get { preferredLanguageMode }
		set { preferredLanguageMode = newValue }
	}

	static func languagePackHealth(for mode: KBLanguageMode) -> LanguagePackHealth {
		let local = LanguagePackHealthInspector.bundledHealth(for: mode)
		guard !LanguagePackHealthInspector.isExtensionProcess else { return local }
		return reconciledLanguagePackHealth(local: local,
			extensionReport: extensionLanguageReport, hasUsedKeyboard: hasUsedKeyboard)
	}

	/// Pure reconciliation seam used by the app and regression tests. Local corruption
	/// wins over stale-install messaging, while an observed extension load failure is
	/// surfaced verbatim instead of being collapsed into a generic validation label.
	static func reconciledLanguagePackHealth(local: LanguagePackHealth,
		extensionReport report: KeyboardExtensionLanguageReport?,
		hasUsedKeyboard: Bool) -> LanguagePackHealth {
		guard local.languageMode != .english, hasUsedKeyboard else { return local }
		guard local.isReady else { return local }
		guard let report else {
			return local.replacingState(.appExtensionBuildMismatch,
				detail: "The installed keyboard has not reported this app build yet. Open Glyph once from the globe menu.")
		}
		guard report.marketingVersion == local.marketingVersion,
			  report.buildVersion == local.buildVersion else {
			return local.replacingState(.appExtensionBuildMismatch,
				detail: "App build \(local.marketingVersion) (\(local.buildVersion)) and the last-seen keyboard build \(report.marketingVersion) (\(report.buildVersion)) differ.")
		}
		guard let extensionHealth = report.healthByLanguage[local.languageMode.rawValue] else {
			return local.replacingState(.appExtensionBuildMismatch,
				detail: "The installed keyboard did not report a \(local.languageMode.displayName) pack. Open the keyboard once after updating.")
		}
		if !extensionHealth.isReady { return extensionHealth }
		guard extensionHealth.packSignature == local.packSignature else {
			return local.replacingState(.appExtensionBuildMismatch,
				detail: "The app and keyboard extension contain different \(local.languageMode.displayName) resources.")
		}
		return extensionHealth
	}

	static var extensionLanguageReport: KeyboardExtensionLanguageReport? {
		guard let data = store.data(forKey: Key.extensionLanguageReport) else { return nil }
		return try? JSONDecoder().decode(KeyboardExtensionLanguageReport.self, from: data)
	}
	/// Haptic tap on each key press. Default on; availability is controlled by iOS.
	static var haptics: Bool {
		get { store.object(forKey: Key.haptics) as? Bool ?? true }
		set {
			store.set(newValue, forKey: Key.haptics)
			postConfigurationChange()
		}
	}
	/// Set by the extension after it is presented at least once. iOS does not expose a
	/// reliable API for checking whether this specific third-party keyboard is enabled.
	static var hasUsedKeyboard: Bool {
		get { store.bool(forKey: Key.hasUsed) }
		set { store.set(newValue, forKey: Key.hasUsed) }
	}
	static var keyboardLastSeenAt: Date? {
		let value = store.double(forKey: Key.lastSeen)
		return value > 0 ? Date(timeIntervalSince1970: value) : nil
	}
	static func markKeyboardObserved(fullAccess: Bool) {
		let now = Date().timeIntervalSince1970
		store.set(true, forKey: Key.hasUsed)
		store.set(now, forKey: Key.lastSeen)
		store.set(fullAccess, forKey: Key.fullAccess)
		store.set(now, forKey: Key.fullAccessObservedAt)
		// Hashing the pack is deliberately kept off extension presentation and key input.
		DispatchQueue.global(qos: .utility).async {
			let health = [KBLanguageMode.tenglishToTelugu, .romanTelugu, .telugu].map {
				LanguagePackHealthInspector.bundledHealth(for: $0)
			}
			let report = KeyboardExtensionLanguageReport(observedAt: Date(),
				marketingVersion: LanguagePackHealthInspector.marketingVersion,
				buildVersion: LanguagePackHealthInspector.buildVersion,
				healthByLanguage: Dictionary(uniqueKeysWithValues: health.map {
					($0.languageMode.rawValue, $0)
				}))
			if let data = try? JSONEncoder().encode(report) {
				store.set(data, forKey: Key.extensionLanguageReport)
			}
		}
	}
	/// Last Full Access state observed by the extension after a real host connection.
	/// The containing app cannot query this directly, so it presents this cached state.
	static var lastFullAccess: Bool {
		get { store.bool(forKey: Key.fullAccess) }
		set {
			store.set(newValue, forKey: Key.fullAccess)
			store.set(Date().timeIntervalSince1970, forKey: Key.fullAccessObservedAt)
		}
	}
	static var lastFullAccessObservedAt: Date? {
		let value = store.double(forKey: Key.fullAccessObservedAt)
		return value > 0 ? Date(timeIntervalSince1970: value) : nil
	}
	/// DEBUG capture: append each glide's grid path + decoded words to a JSONL file in the
	/// App Group, so tools/glide_eval/calibrate.py can fit the harness noise model to real
	/// strokes. OFF by default; on-device only; never leaves the device.
	static var glideCapture: Bool {
		get { store.object(forKey: Key.glideCap) as? Bool ?? false }
		set { store.set(newValue, forKey: Key.glideCap) }
	}

	/// On/off switch for the neural rescorer. Default on. Inert in Release builds, which
	/// bundle no neural prior (the tier is always n-gram there); it only has an effect in
	/// Debug / INTERNAL_NEURAL builds that load a prior. The engine reads it fresh at each
	/// word-session boundary, so toggling it takes effect on the next word — no rebuild.
	static var neuralEnabled: Bool {
		get { store.object(forKey: Key.neuralEnabled) as? Bool ?? true }
		set {
			store.set(newValue, forKey: Key.neuralEnabled)
			// Wake the extension process so the next word session re-reads the flag,
			// instead of waiting for a keyboard restart / lazy cross-process sync.
			postConfigurationChange()
		}
	}

	/// URL of the on-device personalisation model in the shared App Group container.
	/// Both the app and the extension resolve to the same file, so the app can delete it directly.
	static var userModelURL: URL? {
		KBPersonalData.modelURL(for: KBPersonalData.currentEpoch)
	}

	// MARK: Theme Studio

	/// The saved custom theme (nil = never designed one). Enabling is a SEPARATE
	/// flag so switching back to a stock accent keeps the design for later.
	static var customThemes: KBCustomThemePair? {
		get {
			guard let data = store.data(forKey: "kb.customtheme") else { return nil }
			if let pair = try? JSONDecoder().decode(KBCustomThemePair.self, from: data) {
				return pair
			}
			// One-time migration from the old single-appearance editor. Preserve the
			// authored side and provide a contrast-safe counterpart for system switching.
			guard let legacy = try? JSONDecoder().decode(KBCustomTheme.self, from: data) else { return nil }
			var pair = KBCustomThemePair.defaults(accent: accent)
			if legacy.dark { pair.dark = legacy } else { pair.light = legacy }
			return pair
		}
		set {
			if let newValue, let data = try? JSONEncoder().encode(newValue) {
				store.set(data, forKey: "kb.customtheme")
			} else {
				store.removeObject(forKey: "kb.customtheme")
			}
		}
	}
	static func customTheme(dark: Bool) -> KBCustomTheme? {
		guard let themes = customThemes else { return nil }
		return dark ? themes.dark : themes.light
	}
	static var customThemeEnabled: Bool {
		get { store.bool(forKey: "kb.customtheme.on") }
		set { store.set(newValue, forKey: "kb.customtheme.on") }
	}
	/// Atomic user-facing appearance commit. The extension observes the Darwin
	/// notification and rebuilds once, rather than seeing a half-written group of keys.
	static func applyAppearance(accentID: String, customThemes: KBCustomThemePair?, enabled: Bool) {
		store.set(accentID, forKey: Key.accent)
		if let customThemes, let data = try? JSONEncoder().encode(customThemes) {
			store.set(data, forKey: "kb.customtheme")
		} else {
			store.removeObject(forKey: "kb.customtheme")
		}
		store.set(enabled, forKey: "kb.customtheme.on")
		postConfigurationChange()
	}

	private static func postConfigurationChange() {
		store.set(store.integer(forKey: "kb.configuration.revision") + 1,
				  forKey: "kb.configuration.revision")
		store.synchronize()
		CFNotificationCenterPostNotification(
			CFNotificationCenterGetDarwinNotifyCenter(),
			configurationNotification,
			nil,
			nil,
			true
		)
	}

	fileprivate static func addConfigurationObserver(_ observer: UnsafeRawPointer) {
		CFNotificationCenterAddObserver(
			CFNotificationCenterGetDarwinNotifyCenter(),
			observer,
			{ _, rawObserver, _, _, _ in
				guard let rawObserver else { return }
				Unmanaged<KBConfigurationObserver>.fromOpaque(rawObserver)
					.takeUnretainedValue().receiveChange()
			},
			configurationNotification.rawValue,
			nil,
			.deliverImmediately
		)
	}

	fileprivate static func removeConfigurationObserver(_ observer: UnsafeRawPointer) {
		CFNotificationCenterRemoveObserver(
			CFNotificationCenterGetDarwinNotifyCenter(), observer,
			configurationNotification, nil
		)
	}
}

final class KBConfigurationObserver {
	private let handler: () -> Void

	init(handler: @escaping () -> Void) {
		self.handler = handler
		KBSettings.addConfigurationObserver(Unmanaged.passUnretained(self).toOpaque())
	}

	deinit {
		KBSettings.removeConfigurationObserver(Unmanaged.passUnretained(self).toOpaque())
	}

	fileprivate func receiveChange() { handler() }
}
