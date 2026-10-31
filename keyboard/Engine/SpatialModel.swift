import Foundation

// Spatial model + per-tap coordinates.

nonisolated struct KeyTap: Equatable {
	let dx: Double
	let dy: Double
}

/// Bounded on-device personalization of tap-center means and diagonal covariance.
/// Only aggregate sufficient statistics are persisted; no text or raw touch sequence
/// leaves the decoder. Three row clusters provide enough data to adapt without the
/// severe overfitting of one model per key.
final class TouchSpatialProfile {
	private struct Bucket: Codable, Equatable {
		var count = 0
		var meanX = 0.0
		var meanY = 0.0
		var m2X = 0.0
		var m2Y = 0.0

        var native: [NSNumber] { [Double(count), meanX, meanY, m2X, m2Y].map(NSNumber.init(value:)) }

		mutating func observe(_ tap: KeyTap) {
            let values = KBNumericPolicy.touch(native, x: tap.dx, y: tap.dy, observe: true)
            count = values[0].intValue; meanX = values[1].doubleValue; meanY = values[2].doubleValue
            m2X = values[3].doubleValue; m2Y = values[4].doubleValue
		}
	}

	private struct Stored: Codable, Equatable {
		var version = 1
		var rows = [Bucket(), Bucket(), Bucket()]
	}

	private static let key = "kb.touchprofile"
	private var stored: Stored
	private var unsavedSamples = 0

	init(defaults: UserDefaults = KBSettings.sharedDefaults) {
		if let data = defaults.data(forKey: Self.key),
		   let decoded = try? JSONDecoder().decode(Stored.self, from: data),
		   decoded.version == 1, decoded.rows.count == 3 {
			stored = decoded
		} else {
			stored = Stored()
		}
	}

	func adjusted(_ taps: [KeyTap?]?, typed: String) -> [KeyTap?]? {
		guard let taps, taps.count == typed.utf8.count else { return taps }
		return zip(typed.utf8, taps).map { letter, tap in
			guard let tap, let row = rowIndex(for: letter) else { return tap }
			let bucket = stored.rows[row]
            let values = KBNumericPolicy.touch(bucket.native, x: tap.dx, y: tap.dy, observe: false)
            return KeyTap(dx: values[0].doubleValue, dy: values[1].doubleValue)
		}
	}

	func observe(word: String, taps: [KeyTap?],
				 defaults: UserDefaults = KBSettings.sharedDefaults) {
		guard word.utf8.count == taps.count else { return }
		for (letter, tap) in zip(word.lowercased().utf8, taps) {
			guard let tap, let row = rowIndex(for: letter),
				  abs(tap.dx) <= 0.8, abs(tap.dy) <= 0.8 else { continue }
			stored.rows[row].observe(tap)
			unsavedSamples += 1
		}
		if unsavedSamples >= 32 { save(defaults: defaults) }
	}

	func save(defaults: UserDefaults = KBSettings.sharedDefaults) {
		guard unsavedSamples > 0, let data = try? JSONEncoder().encode(stored) else { return }
		defaults.set(data, forKey: Self.key)
		unsavedSamples = 0
	}

	func reset(defaults: UserDefaults = KBSettings.sharedDefaults) {
		stored = Stored()
		unsavedSamples = 0
		defaults.removeObject(forKey: Self.key)
	}

	private func rowIndex(for letter: UInt8) -> Int? {
		guard let y = KB.pos[letter]?.1 else { return nil }
		return Int(y)
	}
}

nonisolated enum KB {
	static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
	/// Normalized visual center offsets in key pitches. The UIKit deck centers the
	/// nine-key home row by half a pitch; shift places Z one-and-a-half pitches after Q.
	/// These values are shared by tap scoring and Glide decoding, so changing layout
	/// without changing this table is a systematic input error, not a cosmetic issue.
	static let rowOffset: [Double] = [0.0, 0.5, 1.5]
	static let sigma = 1.0
	/// Floor for pressing a different key than the intended one; equals native
	/// `substitutionBase` (fitted on tools/evaluation/autocorrect, 27 Oct 2026).
	static let substitutionBase = 0.6
	static let apostrophe = UInt8(ascii: "'")
	/// Skipping an apostrophe the candidate has but the typed string omitted costs a
	/// fraction of a real deletion: people drop apostrophes constantly (whats, dont,
	/// cant) and the letters page has no ' key, so an omission is the EXPECTED channel
	/// noise for a contraction, not a 1.6-cost edit. Without this, "whats" corrects to
	/// "what" (freq wins the tie at equal cost) instead of "what's" like stock.
	/// Mirrored in tools/lm/eval_harness.py (APOS_SKIP).
	static let apostropheSkipCost = 0.4
	static let pos: [UInt8: (Double, Double)] = {
		var m: [UInt8: (Double, Double)] = [:]
		for (r, row) in rows.enumerated() {
			for (c, ch) in row.utf8.enumerated() { m[ch] = (Double(c) + rowOffset[r], Double(r)) }
		}
		return m
	}()
	/// Spelling (not keyboard) confusions, whatever the key distance; native `spellingSubstitution`.
	/// `typedFirst`: the typed first letter has its own vowel-for-vowel cost (native `firstVowelSubstitutionCost`).
	static let vowelSubstitutionCost = 1.5, firstVowelSubstitutionCost = 1.5, soundAlikeSubstitutionCost = 0.9
	static func spellingSubstitution(_ intended: UInt8, _ typed: UInt8, typedFirst: Bool = false) -> Double {
		spellingSubstitution(intended, typed, vowelCost: typedFirst ? firstVowelSubstitutionCost : vowelSubstitutionCost)
	}
	static func spellingSubstitution(_ intended: UInt8, _ typed: UInt8, vowelCost: Double) -> Double {
		let vowels: Set<UInt8> = [97, 101, 105, 111, 117]   // a e i o u
		if vowels.contains(intended), vowels.contains(typed) { return vowelCost }
		let pair = Set([intended, typed])
		if pair == [99, 107] || pair == [99, 115] || pair == [115, 122] { return soundAlikeSubstitutionCost }   // c/k c/s s/z
		return 3.0
	}
	static func subCost(_ intended: UInt8, _ typed: UInt8, typedFirst: Bool = false) -> Double {
		subCost(intended, typed, vowelCost: typedFirst ? firstVowelSubstitutionCost : vowelSubstitutionCost)
	}
	static func subCost(_ intended: UInt8, _ typed: UInt8, vowelCost: Double) -> Double {
		if intended == typed { return 0 }
		guard let a = pos[intended], let b = pos[typed] else { return 3.0 }
		let d2 = (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)
		return min(3.0, d2 / (2 * sigma * sigma) + substitutionBase, spellingSubstitution(intended, typed, vowelCost: vowelCost))
	}
	/// A spelling confusion of two letters, whatever their keys: vowel for vowel, c/k, c/s, s/z; native `spellingConfusion`.
	static func spellingConfusion(_ a: UInt8, _ b: UInt8) -> Bool {
		a != b && spellingSubstitution(a, b, vowelCost: 0) < 3.0
	}
	/// Row or diagonal keyboard neighbours (squared grid distance ≤ 1.3); native `neighbouringKeys`.
	static func neighbouringKeys(_ a: UInt8, _ b: UInt8) -> Bool {
		guard a != b, let p = pos[a], let q = pos[b] else { return false }
		return (p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) <= 1.3
	}
	/// Which first letters the retained search seeds: no spelling discounts; native `seedFirstLetterCost`.
	static func seedFirstLetterCost(_ label: UInt8, typedFirst: UInt8, tap: KeyTap?) -> Double {
		Trie.firstLetterPenaltyPolicy(typedLength: 8, candidateFirst: label, typedFirst: typedFirst, spelling: false)
			+ subCost(label, typed: typedFirst, tap: tap, vowelCost: 3.0)
	}
	/// Grid position of a letter (col+rowOffset, row) — the coordinate space glide
	/// decoding maps the swipe trajectory into.
	static func grid(for letter: Character) -> (Double, Double)? {
		guard let a = letter.asciiValue else { return nil }
		return pos[a]
	}
	/// Continuous variant: distance from the intended key's center to the actual
	/// landing point. Parity with the discrete table when the tap is dead-center
	/// (cost → 0 for the pressed key); the substitutionBase cross-key floor still separates
	/// neighbors so a centered tap never reads as ambiguous.
	static func subCost(_ intended: UInt8, typed: UInt8, tap: KeyTap?, typedFirst: Bool = false) -> Double {
		subCost(intended, typed: typed, tap: tap, vowelCost: typedFirst ? firstVowelSubstitutionCost : vowelSubstitutionCost)
	}
	static func subCost(_ intended: UInt8, typed: UInt8, tap: KeyTap?, vowelCost: Double) -> Double {
		guard let tap, let a = pos[intended], let t = pos[typed] else { return subCost(intended, typed, vowelCost: vowelCost) }
		let px = t.0 + tap.dx, py = t.1 + tap.dy
		let d2 = (a.0 - px) * (a.0 - px) + (a.1 - py) * (a.1 - py)
		let base = d2 / (2 * sigma * sigma)
		return intended == typed ? min(3.0, base)
			: min(3.0, base + substitutionBase, spellingSubstitution(intended, typed, vowelCost: vowelCost))
	}
}
