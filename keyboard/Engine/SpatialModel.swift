import Foundation

// Spatial model + per-tap coordinates — extracted from Keyboardengine.swift.

struct KeyTap {
	let dx: Double
	let dy: Double
}

enum KB {
	static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
	static let rowOffset: [Double] = [0.0, 0.25, 0.75]
	static let sigma = 1.0
	static let pos: [UInt8: (Double, Double)] = {
		var m: [UInt8: (Double, Double)] = [:]
		for (r, row) in rows.enumerated() {
			for (c, ch) in row.utf8.enumerated() { m[ch] = (Double(c) + rowOffset[r], Double(r)) }
		}
		return m
	}()
	static func subCost(_ intended: UInt8, _ typed: UInt8) -> Double {
		if intended == typed { return 0 }
		guard let a = pos[intended], let b = pos[typed] else { return 3.0 }
		let d2 = (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)
		return min(3.0, d2 / (2 * sigma * sigma) + 0.3)
	}
	/// Continuous variant: distance from the intended key's center to the actual
	/// landing point. Parity with the discrete table when the tap is dead-center
	/// (cost → 0 for the pressed key); the 0.3 cross-key floor still separates
	/// neighbors so a centered tap never reads as ambiguous.
	static func subCost(_ intended: UInt8, typed: UInt8, tap: KeyTap?) -> Double {
		guard let tap, let a = pos[intended], let t = pos[typed] else { return subCost(intended, typed) }
		let px = t.0 + tap.dx, py = t.1 + tap.dy
		let d2 = (a.0 - px) * (a.0 - px) + (a.1 - py) * (a.1 - py)
		let base = d2 / (2 * sigma * sigma)
		return intended == typed ? min(3.0, base) : min(3.0, base + 0.3)
	}
}

