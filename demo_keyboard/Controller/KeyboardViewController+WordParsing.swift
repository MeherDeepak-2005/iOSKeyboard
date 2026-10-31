import UIKit

extension KeyboardViewController {
	// MARK: Word parsing on the text before the cursor

	/// Hosts with smart punctuation (the iOS default in most text views) transform the
	/// ASCII apostrophe we insert into U+2019 (') in the stored text. Without accepting
	/// it here, every contraction fragments at the quote — "what's" parses as "s" —
	/// so autocorrect judges fragments and learn() adopts them into suggestions.
	func isWordChar(_ c: Character) -> Bool {
		c.isLetter || c == "'" || c == "\u{2019}" || c == "\u{02BC}"
	}
	/// Canonical form for the engine: the lexicon, n-grams, and tokenizer all store
	/// ASCII apostrophes. One-to-one per Character, so parsed word lengths (and the
	/// deleteBackward counts derived from them) are unchanged.
	func canonical(_ c: Character) -> Character {
		(c == "\u{2019}" || c == "\u{02BC}") ? "'" : c
	}

	func trailingWord(_ s: String) -> String {
		var w = ""
		for c in s.reversed() { if isWordChar(c) { w.insert(canonical(c), at: w.startIndex) } else { break } }
		return w
	}

	func lastCompleteWord(_ s: String) -> String? {
		var chars = Array(s)
		while let last = chars.last, !isWordChar(last) { chars.removeLast() }
		var w = ""
		while let last = chars.last, isWordChar(last) { w.insert(canonical(last), at: w.startIndex); chars.removeLast() }
		return w.isEmpty ? nil : w
	}

	/// Up to `max` complete words immediately before any trailing partial word,
	/// oldest→newest, stopping at a sentence boundary (. ! ? or newline) — context
	/// from the previous sentence would only mislead the prior.
	func contextWords(_ s: String, max: Int) -> [String] {
		let sentenceEnd = Set<Character>(".!?\n")
		var chars = Array(s)
		while let last = chars.last, isWordChar(last) { chars.removeLast() }   // drop trailing partial
		var words: [String] = []
		outer: while words.count < max {
			while let last = chars.last, !isWordChar(last) {
				if sentenceEnd.contains(last) { break outer }
				chars.removeLast()
			}
			if chars.isEmpty { break }
			var w = ""
			while let last = chars.last, isWordChar(last) { w.insert(canonical(last), at: w.startIndex); chars.removeLast() }
			if w.isEmpty { break }
			words.insert(w, at: 0)
		}
		return words
	}
}
