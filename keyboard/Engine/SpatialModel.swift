// MIGRATION-FILE: planned SPLIT | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: CPP_CORE owns spatial/statistical math; SWIFT_IOS owns boundary values and stored profile lifecycle.
import Foundation

// Spatial model + per-tap coordinates — extracted from Keyboardengine.swift.

// MIGRATION: planned SWIFT_IOS | stage=platform | target=DecodeBoundary
// MIGRATION-NOTE: Keep the Swift boundary value; mirror dx/dy as Double in the portable request.
nonisolated struct KeyTap: Equatable {
	let dx: Double
	let dy: Double
}

/// Bounded on-device personalization of tap-center means and diagonal covariance.
/// Only aggregate sufficient statistics are persisted; no text or raw touch sequence
/// leaves the decoder. Three row clusters provide enough data to adapt without the
/// severe overfitting of one model per key.
// MIGRATION: planned SPLIT | stage=search | target=TouchProfile
// MIGRATION-SPLIT: CPP_CORE owns tap-adjustment/statistics math; SWIFT_IOS owns loading, serialization, defaults and reset coordination.
final class TouchSpatialProfile {
	// MIGRATION: planned CPP_CORE | stage=search | target=SpatialModel
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private struct Bucket: Codable, Equatable {
		var count = 0
		var meanX = 0.0
		var meanY = 0.0
		var m2X = 0.0
		var m2Y = 0.0

		// MIGRATION: planned CPP_CORE | stage=search | target=SpatialModel
		// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
		mutating func observe(_ tap: KeyTap) {
			count += 1
			let dx = tap.dx - meanX
			let dy = tap.dy - meanY
			meanX += dx / Double(count)
			meanY += dy / Double(count)
			m2X += dx * (tap.dx - meanX)
			m2Y += dy * (tap.dy - meanY)
			if count > 2_000 {
				count /= 2
				m2X *= 0.5
				m2Y *= 0.5
			}
		}
	}

	// MIGRATION: planned SPLIT | stage=search | target=TouchProfile
	// MIGRATION-SPLIT: CPP_CORE owns tap-adjustment/statistics math; SWIFT_IOS owns loading, serialization, defaults and reset coordination.
	private struct Stored: Codable, Equatable {
		var version = 1
		var rows = [Bucket(), Bucket(), Bucket()]
	}

	private static let key = "kb.touchprofile"
	private static let minimumSamples = 32
	private static let referenceDeviation = 0.28
	private var stored: Stored
	private var unsavedSamples = 0

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=TouchProfileStorage
	init(defaults: UserDefaults = KBSettings.sharedDefaults) {
		if let data = defaults.data(forKey: Self.key),
		   let decoded = try? JSONDecoder().decode(Stored.self, from: data),
		   decoded.version == 1, decoded.rows.count == 3 {
			stored = decoded
		} else {
			stored = Stored()
		}
	}

	// MIGRATION: planned CPP_CORE | stage=search | target=SpatialModel
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func adjusted(_ taps: [KeyTap?]?, typed: String) -> [KeyTap?]? {
		guard let taps, taps.count == typed.utf8.count else { return taps }
		return zip(typed.utf8, taps).map { letter, tap in
			guard let tap, let row = rowIndex(for: letter) else { return tap }
			let bucket = stored.rows[row]
			guard bucket.count >= Self.minimumSamples else { return tap }
			let denominator = Double(max(1, bucket.count - 1))
			let sigmaX = sqrt(max(bucket.m2X / denominator, 0.01))
			let sigmaY = sqrt(max(bucket.m2Y / denominator, 0.01))
			let centerX = min(max(bucket.meanX, -0.22), 0.22)
			let centerY = min(max(bucket.meanY, -0.22), 0.22)
			// Covariance scaling is deliberately capped: personalization refines an
			// ambiguous edge tap and can never make a distant key look exact.
			let scaleX = min(max(Self.referenceDeviation / sigmaX, 0.75), 1.25)
			let scaleY = min(max(Self.referenceDeviation / sigmaY, 0.75), 1.25)
			return KeyTap(dx: (tap.dx - centerX) * scaleX,
				dy: (tap.dy - centerY) * scaleY)
		}
	}

	// MIGRATION: planned SPLIT | stage=search | target=TouchProfile
	// MIGRATION-SPLIT: CPP_CORE updates bucket statistics; SWIFT_IOS owns unsaved-sample bookkeeping and save scheduling.
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

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=TouchProfileStorage
	func save(defaults: UserDefaults = KBSettings.sharedDefaults) {
		guard unsavedSamples > 0, let data = try? JSONEncoder().encode(stored) else { return }
		defaults.set(data, forKey: Self.key)
		unsavedSamples = 0
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=TouchProfileStorage
	func reset(defaults: UserDefaults = KBSettings.sharedDefaults) {
		stored = Stored()
		unsavedSamples = 0
		defaults.removeObject(forKey: Self.key)
	}

	// MIGRATION: planned CPP_CORE | stage=search | target=SpatialModel
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func rowIndex(for letter: UInt8) -> Int? {
		guard let y = KB.pos[letter]?.1 else { return nil }
		return Int(y)
	}
}

// MIGRATION: planned CPP_CORE | stage=search | target=SpatialModel
// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
nonisolated enum KB {
	static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
	/// Normalized visual center offsets in key pitches. The UIKit deck centers the
	/// nine-key home row by half a pitch; shift places Z one-and-a-half pitches after Q.
	/// These values are shared by tap scoring and Glide decoding, so changing layout
	/// without changing this table is a systematic input error, not a cosmetic issue.
	static let rowOffset: [Double] = [0.0, 0.5, 1.5]
	static let sigma = 1.0
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
	// MIGRATION: planned CPP_CORE | stage=search | target=SpatialModel
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	static func subCost(_ intended: UInt8, _ typed: UInt8) -> Double {
		if intended == typed { return 0 }
		guard let a = pos[intended], let b = pos[typed] else { return 3.0 }
		let d2 = (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)
		return min(3.0, d2 / (2 * sigma * sigma) + 0.3)
	}
	/// Grid position of a letter (col+rowOffset, row) — the coordinate space glide
	/// decoding maps the swipe trajectory into.
	// MIGRATION: planned CPP_CORE | stage=search | target=SpatialModel
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	static func grid(for letter: Character) -> (Double, Double)? {
		guard let a = letter.asciiValue else { return nil }
		return pos[a]
	}
	/// Continuous variant: distance from the intended key's center to the actual
	/// landing point. Parity with the discrete table when the tap is dead-center
	/// (cost → 0 for the pressed key); the 0.3 cross-key floor still separates
	/// neighbors so a centered tap never reads as ambiguous.
	// MIGRATION: planned CPP_CORE | stage=search | target=SpatialModel
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	static func subCost(_ intended: UInt8, typed: UInt8, tap: KeyTap?) -> Double {
		guard let tap, let a = pos[intended], let t = pos[typed] else { return subCost(intended, typed) }
		let px = t.0 + tap.dx, py = t.1 + tap.dy
		let d2 = (a.0 - px) * (a.0 - px) + (a.1 - py) * (a.1 - py)
		let base = d2 / (2 * sigma * sigma)
		return intended == typed ? min(3.0, base) : min(3.0, base + 0.3)
	}
}
