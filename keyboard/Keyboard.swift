import UIKit
import CoreText
import os

// Add this file to BOTH targets (app + keyboard extension). Pure UIKit.

// MARK: - Font installer
//
// Registers any .ttf/.otf bundled in the current target at runtime, so custom
// fonts (e.g. Nerd Fonts) work in BOTH the app and the keyboard extension without
// editing each target's Info.plist. Add the font files to a target, call this once,
// then reference them by PostScript name in KBFont.customFamily.

enum FontInstaller {
	private static var done = false

	/// Register EVERY bundled font. Used by the APP (its Fonts page previews all of
	/// them). Do not call from the extension — see registerSelectedFont.
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

	/// Register ONLY the font the user picked. The keyboard extension renders a single
	/// font at a time, so loading the others just burns its tight memory budget. (iOS
	/// On-Demand Resources aren't available to app extensions — NSBundleResourceRequest
	/// is app-only — so selective registration is the mechanism; the files still ship
	/// in the bundle, they're simply not mapped into the font system.) A system-design
	/// font has no file to load, so this registers nothing.
	static func registerSelectedFont() {
		guard !done else { return }
		done = true
		guard let token = KBSettings.font.fileToken else { return }
		let bundle = Bundle(for: KeyboardView.self)
		for ext in ["ttf", "otf"] {
			for url in bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
			where url.lastPathComponent.range(of: token, options: .caseInsensitive) != nil {
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

// MARK: - Diagnostics (extension measures, app displays — bridged via App Group)
//
// The neural model, the memory-pressure events, and the jetsam kill-limit all live
// in the EXTENSION process; the app runs separately and cannot read them directly.
// So the extension records a compact snapshot into the shared App Group and the app
// reads it back. What the app shows is therefore the LAST typing session's numbers,
// not a live feed — the extension isn't running while the app is in the foreground.
enum KBDiagnostics {

	/// Everything the app displays. All sizes in MB; times in seconds.
	struct Snapshot: Codable {
		var updated = Date.distantPast
		var modelActive = false
		var loadCount = 0           // times the model became resident (incl. reloads)
		var dropCount = 0           // times pressure evicted a resident model
		var warningCount = 0
		var criticalCount = 0
		var activeSeconds = 0.0     // cumulative time the model was resident
		var lastLoadMs = 0.0        // most recent MLModel load latency
		var peakFootprintMB = 0.0   // highest phys_footprint seen (what jetsam watches)
		var minAvailableMB = 0.0    // lowest headroom seen (0 = never sampled)
		var limitMB = 0.0           // inferred kill ceiling = footprint + headroom, at the tightest moment
	}

	static let key = "kb.diag"
	static var store: UserDefaults { UserDefaults(suiteName: KBSettings.appGroup) ?? .standard }
	private static let log = Logger(subsystem: KBSettings.appGroup, category: "diag")

	// MARK: App side — read + reset

	static func read() -> Snapshot {
		guard let data = store.data(forKey: key),
			  let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
		return s
	}
	static func reset() { store.removeObject(forKey: key); Recorder.shared.clear() }

	// MARK: Live ranking log — see how the neural + n-gram scorers rank each candidate
	//
	// When `verbose` is on, the engine logs one message per keystroke to the unified
	// log (category "ranking"): every candidate's channel cost, neural score, n-gram
	// score, blended prior, and final rank, plus the autocorrect margin-gate decision.
	// Watch it live while typing:
	//   log stream --predicate 'subsystem == "group.com.swiftuimasterclass.keyboard"' --level info

	#if DEBUG
	static let defaultVerbose = true
	#else
	static let defaultVerbose = false
	#endif
	static var verbose: Bool {
		get { store.object(forKey: "kb.diag.verbose") as? Bool ?? defaultVerbose }
		set { store.set(newValue, forKey: "kb.diag.verbose") }
	}
	private static let rankLog = Logger(subsystem: KBSettings.appGroup, category: "ranking")

	struct RankRow {
		let word: String
		let cost, logFreq, neural, ngram, prior, score: Double
	}

	/// One candidate table per ranking pass. `rows` already sorted best-first.
	static func logRanking(label: String, context: [String], rows: [RankRow], modelActive: Bool, ms: Double) {
		guard verbose else { return }
		func f(_ x: Double) -> String { String(format: "%+.2f", x) }
		let ctx = context.suffix(4).joined(separator: " ")
		var lines = ["[\(label)] ctx=\"\(ctx)\"  model=\(modelActive ? "ACTIVE" : "ngram-only")  (\(String(format: "%.1f", ms)) ms)  score = chan + blend + 0.3·freq"]
		for (i, r) in rows.prefix(6).enumerated() {
			let word = r.word.count >= 12 ? String(r.word.prefix(12))
				: r.word.padding(toLength: 12, withPad: " ", startingAt: 0)
			let neu = r.neural.isNaN ? "   —  " : f(r.neural)
			lines.append("  \(i < 3 ? "▶" : " ") \(word) chan \(f(-r.cost))  neu \(neu)  ng \(f(r.ngram))  blend \(f(r.prior))  freq \(String(format: "%.2f", r.logFreq))  = \(f(r.score))")
		}
		rankLog.info("\(lines.joined(separator: "\n"), privacy: .public)")
	}

	/// The autocorrect margin-gate outcome for the word just committed.
	static func logDecision(typed: String, best: String?, margin: Double, threshold: Double, corrected: Bool) {
		guard verbose else { return }
		rankLog.info("[autocorrect] typed=\"\(typed, privacy: .public)\" best=\"\(best ?? "—", privacy: .public)\" margin=\(String(format: "%.2f", margin), privacy: .public) gate=\(String(format: "%.1f", threshold), privacy: .public) → \(corrected ? "CORRECT" : "keep typed", privacy: .public)")
	}

	/// Next-word prediction: which words, and how many came from beam search vs n-gram.
	static func logPredict(context: [String], words: [String], beam: Int, ngram: Int) {
		guard verbose else { return }
		let ctx = context.suffix(4).joined(separator: " ")
		rankLog.info("[predict] ctx=\"\(ctx, privacy: .public)\" → \(words.joined(separator: ", "), privacy: .public)  (beam \(beam), ngram \(ngram))")
	}

	// MARK: Measurement primitives (only meaningful INSIDE the memory-limited extension)

	/// The process's physical footprint in bytes — the exact quantity jetsam meters.
	static func footprintBytes() -> UInt64 {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
		let kr = withUnsafeMutablePointer(to: &info) { p in
			p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
			}
		}
		return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
	}

	/// Bytes remaining before THIS process is jetsam-killed. Returns the extension's
	/// tight budget when called there; ~0 / large in the roomy host app, so only the
	/// extension records it.
	static func availableBytes() -> UInt64 {
		let a = os_proc_available_memory()
		return a > 0 ? UInt64(a) : 0
	}

	// MARK: Extension side — the accumulator

	static var recorder: Recorder { Recorder.shared }

	/// Owns the running snapshot in the extension. Cheap (a few counters); persists to
	/// the App Group only on state transitions and every 16th sample, so it never adds
	/// disk churn to the typing path.
	final class Recorder {
		static let shared = Recorder()
		private let lock = NSLock()
		private var snap: Snapshot
		private var activeSince: Date?
		private var tick = 0

		private init() { snap = KBDiagnostics.read() }

		func clear() { lock.lock(); snap = Snapshot(); activeSince = nil; tick = 0; lock.unlock() }

		/// The model became resident — initial load or a lazy reload after a drop.
		func modelActivated(loadMs: Double) {
			lock.lock()
			snap.loadCount += 1
			snap.lastLoadMs = loadMs
			snap.modelActive = true
			activeSince = Date()
			persistLocked()
			lock.unlock()
			KBDiagnostics.log.notice("model active (load \(Int(loadMs)) ms)")
		}

		/// Memory pressure fired; the engine dropped the model if it was resident.
		func memoryPressure(critical: Bool, modelWasActive: Bool) {
			lock.lock()
			if critical { snap.criticalCount += 1 } else { snap.warningCount += 1 }
			if modelWasActive {
				snap.dropCount += 1
				foldActiveLocked()
				snap.modelActive = false
			}
			sampleLocked()
			persistLocked()
			lock.unlock()
			KBDiagnostics.log.notice("pressure \(critical ? "critical" : "warning"), dropped \(modelWasActive ? "yes" : "no")")
		}

		/// Cheap footprint/headroom sample. Call from the background suggestion pass.
		func sample() {
			lock.lock()
			sampleLocked()
			tick += 1
			if tick % 16 == 0 { persistLocked() }
			lock.unlock()
		}

		private func sampleLocked() {
			let foot = Double(KBDiagnostics.footprintBytes()) / 1_048_576
			let avail = Double(KBDiagnostics.availableBytes()) / 1_048_576
			if foot > snap.peakFootprintMB { snap.peakFootprintMB = foot }
			if avail > 0, snap.minAvailableMB == 0 || avail < snap.minAvailableMB {
				snap.minAvailableMB = avail
				snap.limitMB = foot + avail        // the ceiling, inferred at the tightest point
			}
		}
		private func foldActiveLocked() {
			if let since = activeSince {
				snap.activeSeconds += Date().timeIntervalSince(since)
				activeSince = nil
			}
		}
		private func persistLocked() {
			var out = snap
			if let since = activeSince { out.activeSeconds += Date().timeIntervalSince(since) }  // include the open interval
			out.updated = Date()
			if let data = try? JSONEncoder().encode(out) { KBDiagnostics.store.set(data, forKey: KBDiagnostics.key) }
		}
	}
}

// MARK: - Safety lexicon (mmap'd exact-match blocklist — replaces hardcoded profanity)
//
// `safety.kbguard` is a curated, hash-indexed blocklist built offline (LDNOOBW en +
// Wiktionary te vulgarities). Lookups are FNV-1a-64 binary searches with a string-blob
// confirm to rule out hash collisions; the file is memory-mapped, so like langdata.bin
// its pages are clean/evictable and barely count against the extension's memory limit.
//
// Format (little-endian), from the build manifest:
//   header  magic "KBGUARD1"[8], u16 version, u16 entrySize(=24), u32 count,
//           u32 blobBytes, u32 reserved
//   entry   u64 hash, u32 utf8Offset, u16 utf8Len, u8 langID, u8 actionID,
//           u16 flags, u16 sourceID, u32 reserved   (sorted by hash asc)
//   blob    normalized UTF-8 term bytes
final class KBSafetyLexicon {
	enum Action: UInt8 { case allow = 0, demote = 1, suppressSuggest = 2, suppressAlways = 3 }

	private let data: Data
	private let count: Int
	private let blobBase: Int
	private static let indexBase = 24
	private static let entrySize = 24

	/// nil unless `safety.kbguard` is in the bundle (extension only ships it).
	static func bundled(name: String = "safety") -> KBSafetyLexicon? {
		guard let url = Bundle.main.url(forResource: name, withExtension: "kbguard") else { return nil }
		return KBSafetyLexicon(url: url)
	}

	init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 24,
			  Array(d[0..<8]) == Array("KBGUARD1".utf8) else { return nil }
		func u16(_ o: Int) -> Int { Int(UInt16(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) })) }
		func u32(_ o: Int) -> Int { Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) })) }
		guard u16(8) == 1, u16(10) == Self.entrySize else { return nil }
		count = u32(12)
		blobBase = Self.indexBase + count * Self.entrySize
		guard blobBase <= d.count else { return nil }
		data = d
	}

	/// FNV-1a 64 over normalized UTF-8 — must match the offline builder exactly.
	private static func hash(_ s: String) -> UInt64 {
		var h: UInt64 = 0xcbf29ce484222325
		for b in s.utf8 { h ^= UInt64(b); h &*= 0x100000001b3 }
		return h
	}

	/// Normalization mirrors the manifest: Telugu present → NFC; otherwise casefold +
	/// curly→ASCII apostrophes + width fold + whitespace collapse.
	static func normalize(_ value: String) -> String {
		if value.unicodeScalars.contains(where: { (0x0C00...0x0C7F).contains($0.value) }) {
			return value.precomposedStringWithCanonicalMapping.split { $0.isWhitespace }.joined(separator: " ")
		}
		let folded = value
			.replacingOccurrences(of: "\u{2019}", with: "'")
			.replacingOccurrences(of: "\u{2018}", with: "'")
			.replacingOccurrences(of: "`", with: "'")
			.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
		return folded.split { $0.isWhitespace }.joined(separator: " ")
	}

	private func entryHash(_ i: Int) -> UInt64 {
		data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Self.indexBase + i * Self.entrySize, as: UInt64.self) }
	}
	private func entryTerm(_ i: Int) -> String {
		let base = Self.indexBase + i * Self.entrySize
		let off = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self) }))
		let len = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 12, as: UInt16.self) }))
		let a = blobBase + off
		return String(decoding: data[a..<a + len], as: UTF8.self)
	}
	private func entryAction(_ i: Int) -> Action {
		let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Self.indexBase + i * Self.entrySize + 15, as: UInt8.self) }
		return Action(rawValue: raw) ?? .allow
	}

	/// The blocklist action for a single term (exact match, collision-checked).
	func action(for word: String) -> Action {
		let norm = Self.normalize(word)
		let h = Self.hash(norm)
		var lo = 0, hi = count - 1
		while lo <= hi {
			let mid = (lo + hi) >> 1
			let hv = entryHash(mid)
			if hv < h { lo = mid + 1 }
			else if hv > h { hi = mid - 1 }
			else {
				var i = mid
				while i > 0, entryHash(i - 1) == h { i -= 1 }   // rewind to the first equal hash
				while i < count, entryHash(i) == h {
					if entryTerm(i) == norm { return entryAction(i) }   // confirm bytes → no collision
					i += 1
				}
				return .allow
			}
		}
		return .allow
	}

	/// True when the term should never be suggested or corrected TO.
	func isBlocked(_ word: String) -> Bool {
		switch action(for: word) {
		case .suppressSuggest, .suppressAlways: return true
		case .allow, .demote: return false
		}
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

enum KeyboardPage { case letters, numbers, symbols, emoji }
enum ShiftState   { case off, on, locked }
enum KeyRole      { case normal, special, accent, accentSoft }   // accentSoft = lighter tint of the accent (shift/delete)
enum KeyWidth     { case unit, wide, ret, flex }

private struct KeySpec {
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

// MARK: - Key (now a dumb view — KeyboardView owns the touches)

final class KeyButton: UIView {
	let widthKind: KeyWidth
	let action: () -> Void
	let repeats: Bool
	let letterBase: String?          // lowercase base letter (for in-place shift relabelling)
	let isShift: Bool                // shift key → its glyph is swapped on shift changes
	private let canPopup: Bool       // show the character balloon on press
	private let dark: Bool
	private let gradient: CAGradientLayer?        // non-nil for the accent (action) key
	private let dim = UIView()                    // press-feedback overlay (works on any fill)
	private let dimColor: UIColor
	private let isPill: Bool                       // capsule rounding
	private let baseRadius: CGFloat
	private var label: UILabel?                    // set for text keys — updated in place on shift
	private var iconView: UIImageView?            // set for symbol keys (e.g. the shift glyph)

	/// Character to show in the press balloon (nil = no balloon). Reads the live label
	/// so it always reflects the current shift/case.
	var popupText: String? { canPopup ? label?.text : nil }

	fileprivate init(spec: KeySpec, theme: KeyboardTheme) {
		self.widthKind = spec.width
		self.action = spec.action
		self.repeats = spec.repeats
		self.letterBase = spec.letterBase
		self.isShift = spec.isShift
		self.canPopup = spec.popup
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
			let iv = UIImageView(image: UIImage(systemName: symbol, withConfiguration: Self.symbolConfig))
			iv.tintColor = fg
			content = iv
			iconView = iv
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
			label = lbl
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

	static let symbolConfig = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)

	/// Relabel a text key in place (used to switch letters between lower/upper case on a
	/// shift change, without rebuilding the view).
	func setTitle(_ text: String) { label?.text = text }
	/// Swap a symbol key's glyph in place (used for shift → shift.fill → capslock.fill).
	func setSymbol(_ name: String) {
		iconView?.image = UIImage(systemName: name, withConfiguration: Self.symbolConfig)
	}
}

// MARK: - Suggestion bar (its own touches — taps a candidate)

final class SuggestionBar: UIView {
	var onPick: ((String) -> Void)?
	private var buttons: [UIButton] = []
	private let sep1 = UIView(), sep2 = UIView()
	private let textColor: UIColor
	private let dimColor: UIColor

	init(theme: KeyboardTheme) {
		self.textColor = theme.keyText
		self.dimColor = theme.keyText.withAlphaComponent(0.45)
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
			b.titleLabel?.font = .systemFont(ofSize: 17)
			b.titleLabel?.adjustsFontSizeToFitWidth = true
			b.titleLabel?.minimumScaleFactor = 0.8
			b.setTitleColor(theme.keyText, for: .normal)
			b.tag = i
			b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
			buttons.append(b)
			stack.addArrangedSubview(b)
		}
		for s in [sep1, sep2] {
			s.backgroundColor = theme.keyText.withAlphaComponent(0.12)
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

	/// `typedPrefix` (the word the user is mid-typing) turns completions into ghost
	/// text: the part the user already typed renders solid, the completion remainder
	/// dims — the closest an iOS keyboard extension can get to in-field grey preview
	/// (the host text field is off-limits to us).
	func setSuggestions(_ s: [String], typedPrefix: String? = nil) {
		for (i, b) in buttons.enumerated() {
			let t = i < s.count ? s[i] : ""
			b.isEnabled = !t.isEmpty
			guard !t.isEmpty else { b.setTitle("", for: .normal); b.setAttributedTitle(nil, for: .normal); continue }
			if let p = typedPrefix, !p.isEmpty, t.count > p.count,
			   t.lowercased().hasPrefix(p.lowercased()) {
				let attr = NSMutableAttributedString(
					string: String(t.prefix(p.count)),
					attributes: [.foregroundColor: textColor, .font: b.titleLabel?.font as Any])
				attr.append(NSAttributedString(
					string: String(t.dropFirst(p.count)),
					attributes: [.foregroundColor: dimColor, .font: b.titleLabel?.font as Any]))
				b.setAttributedTitle(attr, for: .normal)
			} else {
				b.setAttributedTitle(nil, for: .normal)
				b.setTitle(t, for: .normal)
			}
		}
	}

	@objc private func tap(_ sender: UIButton) {
		// Attributed titles don't populate title(for:), so read the label text.
		if let t = sender.titleLabel?.text, !t.isEmpty { onPick?(t) }
	}
}

// MARK: - Emoji picker
//
// Emoji are Unicode text, not bundled images: the system's Apple Color Emoji font
// draws the glyphs, so we only ship the code points and insert them through the same
// `onInsert` path as any character. No assets, no size cost.

/// App Group-backed most-recently-used emoji (newest first, capped). Shared so the
/// "Recently Used" row survives the frequent extension relaunches.
enum KBEmojiRecents {
	private static let key = "kb.emoji.recents"
	private static let cap = 30
	private static var store: UserDefaults { UserDefaults(suiteName: KBSettings.appGroup) ?? .standard }
	static func all() -> [String] { store.stringArray(forKey: key) ?? [] }
	static func add(_ e: String) {
		var list = all().filter { $0 != e }
		list.insert(e, at: 0)
		store.set(Array(list.prefix(cap)), forKey: key)
	}
}

struct EmojiCategory { let name: String; let icon: String; let emojis: [String] }

/// Zero-copy reader for `emoji.bin` (built by tools/build_emoji_data.py). The
/// catalog used to be split from string literals into ~1,300 heap Strings on the
/// emoji page's first open; the mapped file keeps it in clean, evictable pages and
/// decodes ONE emoji per collection-view cell, on demand.
///
/// Format v2 (all u32 little-endian): header (magic "KBEM", version, categoryCount
/// C, stringCount N, mapCount M), C × (nameIdx, iconIdx, emojiStart, emojiCount)
/// records, u32 × (N+1) byte offsets, M × (wordIdx, emojiIdx) word→emoji pairs
/// sorted by word bytes, utf8 blob. v1 files have no map (M treated as 0, header
/// 4 words instead of 5).
final class EmojiStore {
	private let data: Data
	let categoryCount: Int
	private let stringCount: Int
	private let mapCount: Int
	private let catBase, offsBase, mapBase, blobBase: Int

	/// nil unless `emoji.bin` ships in the current target — EmojiData.categories
	/// below remains as the fallback.
	static let bundled: EmojiStore? = {
		guard let url = Bundle.main.url(forResource: "emoji", withExtension: "bin") else { return nil }
		return EmojiStore(url: url)
	}()

	private init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 16 else { return nil }
		func u32(_ off: Int) -> Int {
			Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
		}
		guard u32(0) == 0x4B42454D else { return nil }               // magic "KBEM"
		let version = u32(4)
		guard version == 1 || version == 2 else { return nil }
		categoryCount = u32(8)
		stringCount   = u32(12)
		mapCount = version >= 2 ? u32(16) : 0
		catBase  = version >= 2 ? 20 : 16
		offsBase = catBase + 16 * categoryCount
		mapBase  = offsBase + 4 * (stringCount + 1)
		blobBase = mapBase + 8 * mapCount
		guard blobBase <= d.count else { return nil }
		data = d
	}

	private func u32(_ off: Int) -> Int {
		Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
	}
	private func stringBytes(_ idx: Int) -> Data {
		let a = blobBase + u32(offsBase + 4 * idx), b = blobBase + u32(offsBase + 4 * (idx + 1))
		return data[a..<b]
	}
	private func string(_ idx: Int) -> String { String(decoding: stringBytes(idx), as: UTF8.self) }

	func name(_ cat: Int) -> String { string(u32(catBase + 16 * cat)) }
	func icon(_ cat: Int) -> String { string(u32(catBase + 16 * cat + 4)) }
	func emojiCount(_ cat: Int) -> Int { u32(catBase + 16 * cat + 12) }
	func emoji(_ cat: Int, _ item: Int) -> String {
		string(u32(catBase + 16 * cat + 8) + item)
	}

	/// The emoji mapped to an exact (lowercase) word, or nil. Binary search over the
	/// word→emoji table, comparing raw utf8 bytes to match the builder's sort order.
	func emoji(forWord lw: String) -> String? {
		guard mapCount > 0 else { return nil }
		let key = Array(lw.utf8)
		var lo = 0, hi = mapCount - 1
		while lo <= hi {
			let mid = (lo + hi) >> 1
			let wordIdx = u32(mapBase + 8 * mid)
			let cmp = compare(stringBytes(wordIdx), key)
			if cmp < 0 { lo = mid + 1 }
			else if cmp > 0 { hi = mid - 1 }
			else { return string(u32(mapBase + 8 * mid + 4)) }
		}
		return nil
	}

	/// Lexicographic byte compare: <0 if `a` sorts before `b`, 0 if equal, >0 after.
	private func compare(_ a: Data, _ b: [UInt8]) -> Int {
		var i = a.startIndex, j = 0
		while i < a.endIndex, j < b.count {
			if a[i] != b[j] { return a[i] < b[j] ? -1 : 1 }
			i = a.index(after: i); j += 1
		}
		let ra = a.endIndex - i, rb = b.count - j
		return ra == rb ? 0 : (ra < rb ? -1 : 1)
	}
}

/// Fallback catalog for a missing `emoji.bin`. The literals themselves are clean
/// text-segment bytes, but `categories` materializes ~1,300 heap Strings — which
/// is exactly why the mmap'd EmojiStore is preferred. Lazy: untouched when the
/// binary resource is present.
enum EmojiData {
	static let categories: [EmojiCategory] = [
		EmojiCategory(name: "Smileys & People", icon: "face.smiling", emojis:
			"😀 😃 😄 😁 😆 😅 😂 🤣 🥲 😊 😇 🙂 🙃 😉 😌 😍 🥰 😘 😗 😙 😚 😋 😛 😝 😜 🤪 🤨 🧐 🤓 😎 🥳 🤩 😏 😒 😞 😔 😟 😕 🙁 ☹️ 😣 😖 😫 😩 🥺 😢 😭 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😱 😨 😰 😥 😓 🤗 🤔 🤭 🤫 🤥 😶 😐 😑 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😵 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕 👋 🤚 ✋ 🖖 👌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🙏 💪 🦶 🦵 👀 👁 👅 👄 🧠".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Animals & Nature", icon: "pawprint", emojis:
			"🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐒 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🐛 🦋 🐌 🐞 🐜 🦗 🕷 🐢 🐍 🦎 🦖 🦕 🐙 🦑 🦐 🦀 🐡 🐠 🐟 🐬 🐳 🐋 🦈 🐊 🐅 🐆 🦓 🦍 🐘 🦏 🐫 🦒 🐃 🐂 🐄 🐎 🐖 🐏 🐑 🐐 🌵 🎄 🌲 🌳 🌴 🌱 🌿 ☘️ 🍀 🎍 🌾 🌺 🌻 🌹 🌷 🌸 🌼 🌞 🌝 🌚 ⭐️ 🌟 ✨ ⚡️ 🔥 🌈 ☀️ ⛅️ ☁️ 🌧 ⛈ ❄️ ☃️ 💧 🌊".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Food & Drink", icon: "fork.knife", emojis:
			"🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶 🌽 🥕 🧄 🧅 🥔 🍠 🥐 🍞 🥖 🥨 🧀 🥚 🍳 🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🥪 🌮 🌯 🥗 🍝 🍜 🍲 🍣 🍱 🍛 🍤 🍙 🍚 🍥 🥟 🍦 🍰 🎂 🍮 🍭 🍬 🍫 🍿 🍩 🍪 ☕️ 🍵 🥤 🧃 🍺 🍻 🥂 🍷 🥃 🍸 🍹 🧉".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Activity", icon: "figure.run", emojis:
			"⚽️ 🏀 🏈 ⚾️ 🥎 🎾 🏐 🏉 🥏 🎱 🏓 🏸 🏒 🏑 🥍 🏏 🥅 ⛳️ 🏹 🎣 🥊 🥋 🎽 ⛸ 🥌 🛷 🎿 ⛷ 🏂 🏋️ 🤼 🤸 ⛹️ 🤺 🤾 🏌️ 🏇 🧘 🏄 🏊 🤽 🚣 🚴 🚵 🎪 🎭 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🎻 🎲 🎯 🎳 🎮 🎰 🧩 🏆 🥇 🥈 🥉 🏅".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Travel & Places", icon: "car", emojis:
			"🚗 🚕 🚙 🚌 🚎 🏎 🚓 🚑 🚒 🚐 🚚 🚛 🚜 🛴 🚲 🛵 🏍 🚨 🚔 🚍 🚘 🚖 🚡 🚠 🚟 🚃 🚋 🚝 🚄 🚅 🚈 🚂 🚆 🚇 🚊 🚉 ✈️ 🛫 🛬 💺 🚁 🚀 🛸 🚤 ⛵️ 🛶 🚢 ⚓️ 🗺 🗽 🗼 🏰 🏯 🏟 🎡 🎢 🎠 ⛲️ 🏖 🏝 ⛰ 🏔 🗻 🌋 🏕 ⛺️ 🏠 🏡 🏘 🏢 🏬 🏦 🏨 🏪 🏫 🏩 💒 🏛 ⛪️ 🕌 🕍 🛕".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Objects", icon: "lightbulb", emojis:
			"⌚️ 📱 💻 ⌨️ 🖥 🖨 🖱 💽 💾 💿 📷 📸 📹 🎥 📞 ☎️ 📟 📺 📻 ⏱ ⏰ 🕰 ⌛️ ⏳ 📡 🔋 🔌 💡 🔦 🕯 🧯 💸 💵 💴 💶 💷 💰 💳 🧾 💎 ⚖️ 🔧 🔨 🛠 🔩 ⚙️ 🧰 🧲 🔫 💣 🔪 🚬 ⚰️ 🏺 🔮 📿 💈 🔭 🔬 🕳 💊 💉 🩸 🌡 🧷 🧵 🧶 👓 🕶 🌂 ☂️ 🧳 🎒 👜 👛 👝 🛍 🎁 🎈 🎏 🎀 🎉 🎊".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Symbols", icon: "heart", emojis:
			"❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💯 ✅ ❌ ❎ ➕ ➖ ➗ ✖️ ♾ 💲 ™️ ©️ ®️ 〰️ ➰ ➿ 🔚 🔙 🔛 🔝 🔜 ✔️ ☑️ 🔘 🔴 🟠 🟡 🟢 🔵 🟣 ⚫️ ⚪️ 🟤 🔺 🔻 🔸 🔹 🔶 🔷 🔳 🔲 ▪️ ▫️ ◼️ ◻️ ⬛️ ⬜️ 🟥 🟧 🟨 🟩 🟦 🟪 ⭐️ 🌟 ❓ ❗️ ‼️ ⁉️ 💤 🎵 🎶".split(separator: " ").map(String.init)),
	]
}

private final class EmojiCell: UICollectionViewCell {
	let label = UILabel()
	override init(frame: CGRect) {
		super.init(frame: frame)
		label.textAlignment = .center
		label.font = .systemFont(ofSize: 30)
		label.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(label)
		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
		])
	}
	required init?(coder: NSCoder) { fatalError() }
}

private final class EmojiHeader: UICollectionReusableView {
	let label = UILabel()
	override init(frame: CGRect) {
		super.init(frame: frame)
		label.font = .systemFont(ofSize: 12, weight: .semibold)
		label.translatesAutoresizingMaskIntoConstraints = false
		addSubview(label)
		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			label.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}
	required init?(coder: NSCoder) { fatalError() }
}

/// The emoji page: a scrollable, category-sectioned grid with a bottom bar (ABC / globe /
/// category quick-nav / delete). Shown as an overlay by KeyboardView; the collection view
/// handles its own scrolling and taps, so KeyboardView's key touch-handling never sees it.
final class EmojiKeyboardView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
	var onPick: ((String) -> Void)?
	var onDelete: (() -> Void)?
	var onABC: (() -> Void)?
	var onNextKeyboard: (() -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private let collection: UICollectionView
	private let bottomBar = UIView()
	/// Recents come from UserDefaults; the catalog comes from the mmap'd EmojiStore
	/// (per-cell decode, no heap catalog) or, if `emoji.bin` is missing, the legacy
	/// in-code categories.
	private enum Section {
		case recents([String])
		case bundled(EmojiStore, Int)
		case legacy(EmojiCategory)
	}
	private var sections: [Section] = []
	private let barHeight: CGFloat = 44

	private func name(of s: Int) -> String {
		switch sections[s] {
		case .recents:                return "Recently Used"
		case .bundled(let st, let c): return st.name(c)
		case .legacy(let cat):        return cat.name
		}
	}
	private func icon(of s: Int) -> String {
		switch sections[s] {
		case .recents:                return "clock"
		case .bundled(let st, let c): return st.icon(c)
		case .legacy(let cat):        return cat.icon
		}
	}
	private func emojiCount(in s: Int) -> Int {
		switch sections[s] {
		case .recents(let list):      return list.count
		case .bundled(let st, let c): return st.emojiCount(c)
		case .legacy(let cat):        return cat.emojis.count
		}
	}
	private func emoji(at ip: IndexPath) -> String {
		switch sections[ip.section] {
		case .recents(let list):      return list[ip.item]
		case .bundled(let st, let c): return st.emoji(c, ip.item)
		case .legacy(let cat):        return cat.emojis[ip.item]
		}
	}

	init(theme: KeyboardTheme, showsGlobe: Bool) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		let layout = UICollectionViewFlowLayout()
		layout.scrollDirection = .horizontal            // swipe left/right through categories
		layout.minimumInteritemSpacing = 0              // between rows within a column
		layout.minimumLineSpacing = 4                   // between columns
		layout.sectionInset = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
		// No section headers in horizontal mode — the bottom category bar navigates.
		collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
		super.init(frame: .zero)

		let recents = KBEmojiRecents.all()
		if !recents.isEmpty { sections.append(.recents(recents)) }
		if let store = EmojiStore.bundled {
			sections.append(contentsOf: (0..<store.categoryCount).map { .bundled(store, $0) })
		} else {
			sections.append(contentsOf: EmojiData.categories.map(Section.legacy))
		}

		collection.backgroundColor = .clear
		collection.dataSource = self
		collection.delegate = self
		collection.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
		collection.register(EmojiHeader.self,
							forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "h")
		collection.alwaysBounceVertical = true
		addSubview(collection)

		buildBottomBar()
		addSubview(bottomBar)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		bottomBar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
		collection.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
	}

	// MARK: Collection data

	func numberOfSections(in cv: UICollectionView) -> Int { sections.count }
	func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { emojiCount(in: s) }

	func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
		let cell = cv.dequeueReusableCell(withReuseIdentifier: "e", for: ip) as! EmojiCell
		cell.label.text = emoji(at: ip)
		return cell
	}
	func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String, at ip: IndexPath) -> UICollectionReusableView {
		let h = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "h", for: ip) as! EmojiHeader
		h.label.text = name(of: ip.section).uppercased()
		h.label.textColor = theme.isDark ? UIColor(white: 1, alpha: 0.5) : UIColor(white: 0, alpha: 0.45)
		return h
	}
	func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
		// Horizontal scroll: fix the row count to the available height; cells are square,
		// so emoji fill top-to-bottom in each column and the grid scrolls sideways.
		let usable = max(44, bounds.height - barHeight - 4)   // minus section insets
		let rows = max(3, Int(usable / 44))
		let side = floor(usable / CGFloat(rows))
		return CGSize(width: side, height: side)
	}
	func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
		let e = emoji(at: ip)
		onPick?(e)
		KBEmojiRecents.add(e)
	}

	// MARK: Bottom bar

	private func buildBottomBar() {
		bottomBar.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.04)
		var leading: [UIButton] = [barButton(title: "ABC") { [weak self] in self?.onABC?() }]
		if showsGlobe { leading.append(barButton(symbol: "globe") { [weak self] in self?.onNextKeyboard?() }) }

		let nav = UIStackView()
		nav.axis = .horizontal
		nav.distribution = .fillEqually
		for i in sections.indices {
			nav.addArrangedSubview(barButton(symbol: icon(of: i)) { [weak self] in
				self?.collection.scrollToItem(at: IndexPath(item: 0, section: i), at: .left, animated: false)
			})
		}
		let del = barButton(symbol: "delete.left") { [weak self] in self?.onDelete?() }

		let stack = UIStackView(arrangedSubviews: leading + [nav, del])
		stack.axis = .horizontal
		stack.spacing = 2
		stack.alignment = .fill
		nav.setContentHuggingPriority(.defaultLow, for: .horizontal)      // nav takes the slack
		for b in leading + [del] {
			b.setContentHuggingPriority(.required, for: .horizontal)
			b.widthAnchor.constraint(equalToConstant: 42).isActive = true
		}
		stack.translatesAutoresizingMaskIntoConstraints = false
		bottomBar.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 4),
			stack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -4),
			stack.topAnchor.constraint(equalTo: bottomBar.topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor)
		])
	}

	private func barButton(title: String? = nil, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
		let b = UIButton(type: .system)
		if let title {
			b.setTitle(title, for: .normal)
			b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
		}
		if let symbol {
			b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
		}
		b.tintColor = theme.specialKeyText
		b.setTitleColor(theme.specialKeyText, for: .normal)
		b.addAction(UIAction { _ in action() }, for: .touchUpInside)
		return b
	}
}

// MARK: - Keyboard

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
		// Fit the bubble + neck into the room above the key. The top row sits right under
		// the suggestion strip, so shrink (neck first, then bubble) rather than draw an
		// inverted/clipped shape there.
		var bubbleH = kf.height + 5
		var neckH   = kf.height * 0.5
		let availAbove = max(kf.minY - edge, kf.height * 0.8)
		if bubbleH + neckH > availAbove {
			neckH = max(5, availAbove - bubbleH)
			bubbleH = min(bubbleH, availAbove - neckH)
		}

		// Centre over the key, clamped to the deck edges. When clamped, the bubble slides
		// while the neck stays over the key → the natural asymmetric edge balloon.
		let cx = min(max(kf.midX, edge + bubbleW/2), bounds.width - edge - bubbleW/2)
		let bMinX = cx - bubbleW/2, bMaxX = cx + bubbleW/2
		let top = kf.minY - neckH - bubbleH                  // ≥ edge by construction (see availAbove)
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
			guard let key = touchKeys[touch] else { continue }
			let inside = key.frame.contains(touch.location(in: self))
			key.setHighlighted(inside)
			if !inside { removePopup(for: touch) }               // slid off the key
			if touch == repeatTouch && !inside { endRepeat() }   // → stop repeating too
		}
	}
	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			touchKeys[touch]?.setHighlighted(false)
			touchKeys[touch] = nil
			removePopup(for: touch)
			if touch == repeatTouch { endRepeat() }
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
