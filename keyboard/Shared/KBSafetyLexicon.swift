import Foundation

// Safety lexicon: mmap'd exact-match blocklist.

final class KBSafetyLexicon {
	enum Action: UInt8 { case allow = 0, demote = 1, suppressSuggest = 2, suppressAlways = 3 }
	enum Language: UInt8 { case english = 1, telugu = 2, tenglish = 3 }

	/// Parsing, validation, the action/language/penalty policy and lookups are native
	/// (kb::SafetyLexicon). Swift keeps resource loading and Unicode normalization.
	let native: KBNativeSafetyLexicon
	var entryCount: Int { Int(native.entryCount) }

	/// nil unless `safety.kbguard` is in the bundle (extension only ships it).
	static func bundled(name: String = "safety") -> KBSafetyLexicon? {
		guard let url = Bundle.main.url(forResource: name, withExtension: "kbguard") else { return nil }
		return KBSafetyLexicon(url: url)
	}

	/// nil when the file is missing or the native reader rejects it.
	init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped),
			  let native = try? KBNativeSafetyLexicon(data: d) else { return nil }
		self.native = native
	}

	private static let foldLocale = Locale(identifier: "en_US_POSIX")

	/// Normalization mirrors the manifest: Telugu present → NFC; otherwise casefold +
	/// curly→ASCII apostrophes + width fold + whitespace collapse.
	///
	/// Every ranked candidate is looked up here on the decode queue, and almost all of
	/// them are plain lowercase ASCII, for which each step below is the identity. That
	/// case returns `value` untouched instead of allocating four intermediate strings
	/// and running an ICU fold; the slow path is unchanged.
	static func normalize(_ value: String) -> String {
		if isNormalizedASCII(value) { return value }
		if value.unicodeScalars.contains(where: { (0x0C00...0x0C7F).contains($0.value) }) {
			return value.precomposedStringWithCanonicalMapping.split { $0.isWhitespace }.joined(separator: " ")
		}
		let folded = value
			.replacingOccurrences(of: "\u{2019}", with: "'")
			.replacingOccurrences(of: "\u{2018}", with: "'")
			.replacingOccurrences(of: "`", with: "'")
			.folding(options: [.caseInsensitive, .widthInsensitive], locale: foldLocale)
		return folded.split { $0.isWhitespace }.joined(separator: " ")
	}

	/// True when `value` is ASCII with nothing for normalize to change: no uppercase
	/// (case fold), no whitespace (collapse), no backtick (apostrophe fold). Width
	/// folding and NFC only ever touch non-ASCII, so ASCII needs neither.
	private static func isNormalizedASCII(_ value: String) -> Bool {
		for b in value.utf8 {
			switch b {
			case 0x61...0x7A, 0x30...0x39: continue          // a-z 0-9, the common case
			case 0x41...0x5A: return false                   // A-Z — needs case folding
			case 0x09...0x0D, 0x20: return false             // ASCII whitespace — needs collapsing
            case 0x60: return false                          // ` — folds to '
			case 0x21...0x5F, 0x7B...0x7E: continue          // remaining ASCII punctuation
			default: return false                            // control bytes and all non-ASCII
			}
		}
		return true
	}

	/// The blocklist action for a single term (exact match, collision-checked natively).
	func action(for word: String) -> Action {
		Action(rawValue: native.action(forNormalized: Self.normalize(word))) ?? .allow
	}

	func language(for word: String) -> Language? {
		Language(rawValue: native.language(forNormalized: Self.normalize(word)))
	}

	/// Ranking penalty: demote 4, either suppress action +infinity, otherwise 0.
	func penalty(for word: String) -> Double {
		native.penalty(forNormalized: Self.normalize(word))
	}

	/// True when the term should never be suggested or corrected TO.
	func isBlocked(_ word: String) -> Bool {
		switch action(for: word) {
		case .suppressSuggest, .suppressAlways: return true
		case .allow, .demote: return false
		}
	}
}
