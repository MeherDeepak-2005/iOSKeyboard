// MIGRATION-FILE: planned SPLIT | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: SWIFT_IOS normalizes/loads; CPP_CORE receives an immutable normalized safety lookup view.
import Foundation

// Safety lexicon: mmap'd exact-match blocklist — extracted from Keyboard.swift.

// MIGRATION: planned SPLIT | stage=search | target=SafetyLookup
// MIGRATION-SPLIT: SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view.
final class KBSafetyLexicon {
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=SafetyNormalization
	// MIGRATION-NOTE: Preserve current Unicode normalization, case/width folding and every action/language rule.
	enum Action: UInt8 { case allow = 0, demote = 1, suppressSuggest = 2, suppressAlways = 3 }
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=SafetyNormalization
	// MIGRATION-NOTE: Preserve current Unicode normalization, case/width folding and every action/language rule.
	enum Language: UInt8 { case english = 1, telugu = 2, tenglish = 3 }

	private let data: Data
	private let count: Int
	private let blobBase: Int
	private static let indexBase = 24
	private static let entrySize = 24
	var entryCount: Int { count }

	/// nil unless `safety.kbguard` is in the bundle (extension only ships it).
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=SafetyNormalization
	// MIGRATION-NOTE: Preserve current Unicode normalization, case/width folding and every action/language rule.
	static func bundled(name: String = "safety") -> KBSafetyLexicon? {
		guard let url = Bundle.main.url(forResource: name, withExtension: "kbguard") else { return nil }
		return KBSafetyLexicon(url: url)
	}

	// MIGRATION: planned SPLIT | stage=search | target=SafetyLookup
	// MIGRATION-SPLIT: SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view.
	init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 24,
			  Array(d[0..<8]) == Array("KBGUARD1".utf8) else { return nil }
		func u16(_ o: Int) -> Int { Int(UInt16(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) })) }
		func u32(_ o: Int) -> Int { Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) })) }
		guard u16(8) == 1, u16(10) == Self.entrySize else { return nil }
		count = u32(12)
		let blobBytes = u32(16)
		guard count <= (d.count - Self.indexBase) / Self.entrySize else { return nil }
		blobBase = Self.indexBase + count * Self.entrySize
		guard blobBase <= d.count, blobBytes == d.count - blobBase else { return nil }
		for index in 0..<count {
			let base = Self.indexBase + index * Self.entrySize
			let offset = u32(base + 8)
			let length = u16(base + 12)
			guard offset <= blobBytes, length <= blobBytes - offset else { return nil }
		}
		data = d
	}

	/// FNV-1a 64 over normalized UTF-8 — must match the offline builder exactly.
	// MIGRATION: planned CPP_CORE | stage=search | target=SafetyLookup
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private static func hash(_ s: String) -> UInt64 {
		var h: UInt64 = 0xcbf29ce484222325
		for b in s.utf8 { h ^= UInt64(b); h &*= 0x100000001b3 }
		return h
	}

	/// Normalization mirrors the manifest: Telugu present → NFC; otherwise casefold +
	/// curly→ASCII apostrophes + width fold + whitespace collapse.
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=SafetyNormalization
	// MIGRATION-NOTE: Preserve current Unicode normalization, case/width folding and every action/language rule.
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

	// MIGRATION: planned CPP_CORE | stage=search | target=SafetyLookup
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func entryHash(_ i: Int) -> UInt64 {
		data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Self.indexBase + i * Self.entrySize, as: UInt64.self) }
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=SafetyLookup
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func entryTerm(_ i: Int) -> String {
		let base = Self.indexBase + i * Self.entrySize
		let off = Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self) }))
		let len = Int(UInt16(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 12, as: UInt16.self) }))
		let a = blobBase + off
		return String(decoding: data[a..<a + len], as: UTF8.self)
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=SafetyLookup
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func entryAction(_ i: Int) -> Action {
		let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Self.indexBase + i * Self.entrySize + 15, as: UInt8.self) }
		return Action(rawValue: raw) ?? .allow
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=SafetyLookup
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func entryLanguage(_ i: Int) -> Language? {
		let raw = data.withUnsafeBytes {
			$0.loadUnaligned(fromByteOffset: Self.indexBase + i * Self.entrySize + 14,
				as: UInt8.self)
		}
		return Language(rawValue: raw)
	}

	// MIGRATION: planned SPLIT | stage=search | target=SafetyLookup
	// MIGRATION-SPLIT: SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view.
	private func matchingIndex(for word: String) -> Int? {
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
				while i > 0, entryHash(i - 1) == h { i -= 1 }
				while i < count, entryHash(i) == h {
					if entryTerm(i) == norm { return i }
					i += 1
				}
				return nil
			}
		}
		return nil
	}

	/// The blocklist action for a single term (exact match, collision-checked).
	// MIGRATION: planned SPLIT | stage=search | target=SafetyLookup
	// MIGRATION-SPLIT: SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view.
	func action(for word: String) -> Action {
		matchingIndex(for: word).map(entryAction) ?? .allow
	}

	// MIGRATION: planned SPLIT | stage=search | target=SafetyLookup
	// MIGRATION-SPLIT: SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view.
	func language(for word: String) -> Language? {
		matchingIndex(for: word).flatMap(entryLanguage)
	}

	/// True when the term should never be suggested or corrected TO.
	// MIGRATION: planned SPLIT | stage=search | target=SafetyLookup
	// MIGRATION-SPLIT: SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view.
	func isBlocked(_ word: String) -> Bool {
		switch action(for: word) {
		case .suppressSuggest, .suppressAlways: return true
		case .allow, .demote: return false
		}
	}
}
