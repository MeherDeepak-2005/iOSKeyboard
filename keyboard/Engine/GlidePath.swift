import Foundation
import CoreGraphics

// Glide path preprocessing (P2) — turns a raw swipe trajectory into the input the
// trie decoder (P3) consumes: an evenly-resampled polyline in the spatial model's
// KEY-GRID coordinates (q = (0,0), w = (1,0) … same space as KB.pos), with pivots
// marking where the finger slowed or turned — the likely intended letters.

/// A snapshot of the letter-key layout at the moment a swipe lifts, so the decoder
/// can map the swipe's VIEW-space points into grid space. Built by KeyboardView
/// (which knows the on-screen frames); consumed by the engine (which knows KB.pos).
struct GlideLayout {
	let centers: [(letter: Character, point: CGPoint)]   // view-space key centers
	let xPitch: CGFloat                                  // key column pitch (view units)
	let yPitch: CGFloat                                  // key row pitch (view units)
}

/// A preprocessed swipe in grid space.
struct ProcessedGlide {
	let points: [CGPoint]     // evenly spaced, grid coordinates
	let pivots: [Int]         // indices into `points` at velocity minima / direction turns
}

enum GlidePreprocess {

	/// View-space raw trajectory → grid space, resampled, with pivots marked.
	/// `spacing` is in grid units (fraction of a key pitch between resampled points).
	static func run(_ raw: [CGPoint], layout: GlideLayout, spacing: CGFloat = 0.5) -> ProcessedGlide? {
		guard raw.count >= 2, !layout.centers.isEmpty, layout.xPitch > 0, layout.yPitch > 0
		else { return nil }
		let grid = raw.map { toGrid($0, layout: layout) }
		let rs = resample(grid, spacing: spacing)
		guard rs.count >= 2 else { return nil }
		return ProcessedGlide(points: rs, pivots: pivots(rs))
	}

	/// Map a view point to grid space, relative to its nearest key center. The
	/// nearest-key-relative mapping absorbs the qwerty row offsets automatically.
	static func toGrid(_ p: CGPoint, layout: GlideLayout) -> CGPoint {
		var best = layout.centers[0]
		var bestD = CGFloat.greatestFiniteMagnitude
		for c in layout.centers {
			let d = (c.point.x - p.x) * (c.point.x - p.x) + (c.point.y - p.y) * (c.point.y - p.y)
			if d < bestD { bestD = d; best = c }
		}
		let g = KB.grid(for: best.letter) ?? (0, 0)
		let dx = Double((p.x - best.point.x) / layout.xPitch)
		let dy = Double((p.y - best.point.y) / layout.yPitch)
		return CGPoint(x: g.0 + dx, y: g.1 + dy)
	}

	/// Even arc-length resampling (the $1-recognizer step): the raw touch stream bunches
	/// at corners and thins on fast strokes, which would bias any shape comparison.
	static func resample(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {
		guard pts.count >= 2, spacing > 0 else { return pts }
		var out = [pts[0]]
		var prev = pts[0]
		var i = 1
		var dist: CGFloat = 0
		while i < pts.count {
			let d = hypot(pts[i].x - prev.x, pts[i].y - prev.y)
			if d > 0, dist + d >= spacing {
				let t = (spacing - dist) / d
				let np = CGPoint(x: prev.x + (pts[i].x - prev.x) * t,
								 y: prev.y + (pts[i].y - prev.y) * t)
				out.append(np)
				prev = np
				dist = 0
			} else {
				dist += d
				prev = pts[i]
				i += 1
			}
		}
		if let last = pts.last, out.last.map({ hypot($0.x - last.x, $0.y - last.y) > 1e-6 }) ?? true {
			out.append(last)
		}
		return out
	}

	/// Pivots = the start, the end, and interior points where the path turns sharply.
	/// Because the input is evenly spaced, speed is ~constant, so a direction change is
	/// the signal a letter sits here (the finger rounds a corner at an intended key).
	static func pivots(_ pts: [CGPoint], cosThreshold: CGFloat = 0.5) -> [Int] {
		guard pts.count >= 3 else { return Array(pts.indices) }
		var out = [0]
		for i in 1..<(pts.count - 1) {
			let a = pts[i - 1], b = pts[i], c = pts[i + 1]
			let v1 = CGPoint(x: b.x - a.x, y: b.y - a.y)
			let v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
			let m1 = hypot(v1.x, v1.y), m2 = hypot(v2.x, v2.y)
			guard m1 > 0, m2 > 0 else { continue }
			let cosang = (v1.x * v2.x + v1.y * v2.y) / (m1 * m2)
			if cosang < cosThreshold { out.append(i) }   // > 60° turn → likely a letter
		}
		out.append(pts.count - 1)
		return out
	}

	/// The nearest letter to a grid point — for logging/debugging which keys the pivots
	/// land on before the full decoder exists.
	static func nearestLetter(toGrid p: CGPoint) -> Character? {
		var best: Character?
		var bestD = Double.greatestFiniteMagnitude
		for (r, row) in KB.rows.enumerated() {
			for (c, ch) in row.enumerated() {
				let gx = Double(c) + KB.rowOffset[r], gy = Double(r)
				let d = (gx - Double(p.x)) * (gx - Double(p.x)) + (gy - Double(p.y)) * (gy - Double(p.y))
				if d < bestD { bestD = d; best = ch }
			}
		}
		return best
	}
}

// MARK: - Glide decoder (P3): beam search over the trie, constrained by the swipe path
//
// The word you meant is the dictionary word whose IDEAL path (the polyline through its
// letters) best matches the swipe. We beam-search the mmap trie and score complete words
// by BAND-DTW between the two resampled paths — a warp of up to ±band points, so a cut
// corner or an under-reached letter (which shifts arc length locally) is absorbed locally
// instead of throwing off every later point (index-locked comparison's failure). The beam
// keeps prefixes that are EITHER good-shape-so-far OR high-frequency (subtree maxFreq), so
// a frequent word you swiped sloppily ("wat" → "what") still reaches the LM rerank. Only
// real words emit (trie constraint); doubles cost nothing (path needn't move); the ' is a
// geometry-free letter so contractions ride their apostrophe-less swipe.

enum GlideDecoder {

	private static let N = 32                        // both paths resampled to this many points
	static let defaultBand = 4                       // DTW warp window (grid-searched in glide_eval)
	static let defaultFreqLambda = 0.20              // beam frequency pull (grid-searched in glide_eval)

	static func decode(_ g: ProcessedGlide, lang: LangData,
					   beamWidth: Int = 48, limit: Int = 6,
					   band: Int = defaultBand, freqLambda: Double = defaultFreqLambda)
			-> [(word: String, cost: Double)] {
		guard lang.hasTrie, g.points.count >= 2 else { return [] }
		let obs = resampleN(g.points, N)             // observed swipe, fixed N points
		guard obs.count == N else { return [] }

		var results: [String: Double] = [:]
		func emit(_ node: Int, _ letters: [CGPoint]) {
			guard let w = lang.trieWord(atNode: node), w.count >= 2 else { return }
			let cost = shapeCost(obs, letters, band: band)
			if results[w] == nil || cost < results[w]! { results[w] = cost }
		}

		// Beam key = partial shape cost (nearest-forward, monotonic — anchors the first
		// letter, keeps letters-in-swipe-order) MINUS a frequency pull, so frequent prefixes
		// survive even when a letter was under-reached. `prune` holds the raw shape sum;
		// `key` is what we rank/prune by.
		struct Hyp { let node: Int; let j: Int; let prune: Double; let key: Double; let letters: [CGPoint] }
		func best(_ hs: [Hyp]) -> [Hyp] { hs.count <= beamWidth ? hs : Array(hs.sorted { $0.key < $1.key }.prefix(beamWidth)) }
		func keyFor(_ prune: Double, _ node: Int) -> Double {
			prune - freqLambda * log(Double(lang.trieMaxFreq(ofNode: node)) + 1)
		}

		var beam: [Hyp] = []
		lang.forEachChild(ofNode: lang.trieRootNode) { label, node in
			guard let l0 = gridCenter(label) else { return }
			let p = dist(l0, obs[0])
			let h = Hyp(node: node, j: 0, prune: p, key: keyFor(p, node), letters: [l0])
			beam.append(h); emit(node, h.letters)
		}
		beam = best(beam)

		let maxDepth = 22
		for _ in 1..<maxDepth {
			var next: [Hyp] = []
			for h in beam {
				lang.forEachChild(ofNode: h.node) { label, node in
					if label == UInt8(ascii: "'") {          // geometry-free apostrophe
						let nh = Hyp(node: node, j: h.j, prune: h.prune, key: keyFor(h.prune, node), letters: h.letters)
						next.append(nh); emit(node, nh.letters)
						return
					}
					guard let la = gridCenter(label) else { return }
					var bj = h.j, bd = dist(obs[h.j], la)
					var k = h.j + 1
					while k < N { let d = dist(obs[k], la); if d < bd { bd = d; bj = k }; k += 1 }
					let np = h.prune + bd
					let nh = Hyp(node: node, j: bj, prune: np, key: keyFor(np, node), letters: h.letters + [la])
					next.append(nh); emit(node, nh.letters)
				}
			}
			if next.isEmpty { break }
			beam = best(next)
		}
		return results.sorted { $0.value < $1.value }.prefix(limit).map { ($0.key, $0.value) }
	}

	/// Band-limited DTW between the swipe and a word's ideal path (both resampled to N
	/// points). Each swipe point may align to an ideal point within ±band, so local
	/// distortions — a cut corner, a letter under-reached — cost locally, not globally.
	private static func shapeCost(_ obs: [CGPoint], _ letters: [CGPoint], band: Int) -> Double {
		let ideal = letters.count == 1 ? [CGPoint](repeating: letters[0], count: N) : resampleN(letters, N)
		guard ideal.count == N else { return .greatestFiniteMagnitude }
		let INF = Double.greatestFiniteMagnitude
		var prev = [Double](repeating: INF, count: N + 1)
		var cur  = [Double](repeating: INF, count: N + 1)
		prev[0] = 0
		for i in 1...N {
			for k in 0...N { cur[k] = INF }
			let lo = max(1, i - band), hi = min(N, i + band)
			for j in lo...hi {
				let d = dist(obs[i - 1], ideal[j - 1])
				cur[j] = d + min(prev[j], min(cur[j - 1], prev[j - 1]))
			}
			swap(&prev, &cur)
		}
		return prev[N] / Double(N)
	}

	/// Resample a polyline to exactly `n` points evenly spaced along its arc length.
	private static func resampleN(_ pts: [CGPoint], _ n: Int) -> [CGPoint] {
		guard pts.count >= 2, n >= 2 else { return pts }
		var length = 0.0
		for i in 1..<pts.count { length += dist(pts[i - 1], pts[i]) }
		guard length > 0 else { return [CGPoint](repeating: pts[0], count: n) }
		let step = length / Double(n - 1)
		var out = [pts[0]]
		var i = 1, acc = 0.0
		var prev = pts[0]
		while out.count < n - 1, i < pts.count {
			let d = dist(prev, pts[i])
			if acc + d >= step, d > 0 {
				let t = (step - acc) / d
				let np = CGPoint(x: prev.x + (pts[i].x - prev.x) * t, y: prev.y + (pts[i].y - prev.y) * t)
				out.append(np); prev = np; acc = 0
			} else { acc += d; prev = pts[i]; i += 1 }
		}
		while out.count < n { out.append(pts[pts.count - 1]) }
		return out
	}

	private static func gridCenter(_ label: UInt8) -> CGPoint? { gridCenter(Character(Unicode.Scalar(label))) }
	private static func gridCenter(_ ch: Character) -> CGPoint? {
		guard let g = KB.grid(for: ch) else { return nil }
		return CGPoint(x: g.0, y: g.1)
	}
	private static func dist(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
}
