import Foundation

// Safety lexicon: mmap'd exact-match blocklist — extracted from Keyboard.swift.

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

