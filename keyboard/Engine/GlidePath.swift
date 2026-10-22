// MIGRATION-FILE: planned SPLIT | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: CPP_CORE owns numerical Glide algorithms; SWIFT_IOS extracts UIKit geometry into portable buffers.
import Foundation
import CoreGraphics

// Glide path preprocessing (P2) — turns a raw swipe trajectory into the input the
// trie decoder (P3) consumes: an evenly-resampled polyline in the spatial model's
// KEY-GRID coordinates (q = (0,0), w = (1,0) … same space as KB.pos), with pivots
// marking where the finger slowed or turned — the likely intended letters.

/// A snapshot of the letter-key layout at the moment a swipe lifts, so the decoder
/// can map the swipe's VIEW-space points into grid space. Built by KeyboardView
/// (which knows the on-screen frames); consumed by the engine (which knows KB.pos).
// MIGRATION: planned SPLIT | stage=policy-glide | target=LayoutSnapshot
// MIGRATION-SPLIT: SWIFT_IOS extracts UIKit geometry; CPP_CORE receives owned numeric centers/pitches without CGPoint or CGFloat dependencies.
nonisolated struct GlideLayout {
	let centers: [(letter: Character, point: CGPoint)]   // view-space key centers
	let xPitch: CGFloat                                  // key column pitch (view units)
	let yPitch: CGFloat                                  // key row pitch (view units)
}

/// A preprocessed swipe in grid space.
// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
nonisolated struct ProcessedGlide {
	let points: [CGPoint]        // evenly spaced, grid coordinates
	let pivots: [Int]            // indices into `points` at direction turns AND velocity minima
	/// Letters the finger DWELLED on — a velocity minimum sustained near a key center (needs
	/// timestamps). These are the positive evidence for a doubled letter (#5): a swipe traces
	/// no loop for "ll", but the hand naturally lingers, so a dwell at `l` favours "hello" over
	/// "helo" where the shape alone ties. Empty when no timestamps were supplied.
	let dwellKeys: [Character]
}


/// Numeric boundary buffers; no geometry algorithms run in these conversions.
nonisolated enum GlideBuffers {
    static func points(_ points: [CGPoint]) -> Data {
        points.flatMap { [Double($0.x), Double($0.y)] }.withUnsafeBytes { Data($0) }
    }
    static func points(_ data: Data) -> [CGPoint] {
        data.withUnsafeBytes { bytes in stride(from: 0, to: data.count, by: 16).map {
            CGPoint(x: bytes.loadUnaligned(fromByteOffset: $0, as: Double.self),
                y: bytes.loadUnaligned(fromByteOffset: $0 + 8, as: Double.self))
        } }
    }
    static func keys(_ layout: GlideLayout) -> Data { Data(layout.centers.map { $0.letter.asciiValue ?? 0 }) }
    static func letters(_ data: Data) -> [Character] { data.map { Character(UnicodeScalar($0)) } }
}
nonisolated struct IncrementalGlideResampler {
    let spacing: CGFloat
    private var state: KBNativeGlideResampler
    var samples: [CGPoint] { GlideBuffers.points(state.samples) }
    init(spacing: CGFloat = 0.5) { self.spacing = spacing; state = KBNativeGlideResampler(spacing: Double(spacing)) }
    mutating func append(_ points: ArraySlice<CGPoint>) -> [CGPoint] {
        if !isKnownUniquelyReferenced(&state) { state = state.copy() as! KBNativeGlideResampler }
        return GlideBuffers.points(state.appendPoints(GlideBuffers.points(Array(points))))
    }
}
nonisolated struct OnlineGlideCandidate {
    let word: String
    private var state: KBNativeOnlineGlide
    var ideal: [CGPoint] { GlideBuffers.points(state.ideal) }
    var sampleCount: Int { Int(state.sampleCount) }
    var prefixCost: Double { state.prefixCost }
    init?(word: String, idealPointCount: Int = 24) {
        guard idealPointCount >= 2, let state = KBNativeOnlineGlide(word: word.lowercased(), count: UInt(idealPointCount)) else { return nil }
        self.word = word; self.state = state
    }
    mutating func consume(_ samples: [CGPoint]) {
        if !isKnownUniquelyReferenced(&state) { state = state.copy() as! KBNativeOnlineGlide }
        state.consumePoints(GlideBuffers.points(samples))
    }
}
nonisolated enum GlidePreprocess {
    static func run(_ raw: [CGPoint], layout: GlideLayout, spacing: CGFloat = 0.5,
                    times: [TimeInterval]? = nil) -> ProcessedGlide? {
        let stamps = times.map { $0.withUnsafeBytes { Data($0) } }
        guard let result = KBNativeGlide.preprocess(GlideBuffers.points(raw), keys: GlideBuffers.keys(layout),
            centers: GlideBuffers.points(layout.centers.map(\.point)), xPitch: Double(layout.xPitch), yPitch: Double(layout.yPitch),
            spacing: Double(spacing), times: stamps) else { return nil }
        return ProcessedGlide(points: GlideBuffers.points(result.points), pivots: result.pivots.map(\.intValue),
            dwellKeys: GlideBuffers.letters(result.dwell))
    }
    static func gridPoints(_ points: [CGPoint], layout: GlideLayout) -> [CGPoint] {
        GlideBuffers.points(KBNativeGlide.toGrid(GlideBuffers.points(points), keys: GlideBuffers.keys(layout),
            centers: GlideBuffers.points(layout.centers.map(\.point)), xPitch: Double(layout.xPitch), yPitch: Double(layout.yPitch)))
    }
    static func toGrid(_ p: CGPoint, layout: GlideLayout) -> CGPoint { gridPoints([p], layout: layout)[0] }
    static func resample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        GlideBuffers.points(KBNativeGlide.resample(GlideBuffers.points(points), spacing: Double(spacing)))
    }
    static func pivots(_ points: [CGPoint], cosThreshold: CGFloat = 0.5) -> [Int] {
        KBNativeGlide.pivots(GlideBuffers.points(points), threshold: Double(cosThreshold)).map(\.intValue)
    }
    static func lettersNear(_ p: CGPoint, radius: CGFloat, maxN: Int) -> [Character] {
        GlideBuffers.letters(KBNativeGlide.lettersNearX(Double(p.x), y: Double(p.y), radius: Double(radius), count: UInt(max(0, maxN))))
    }
    static func nearestLetter(toGrid p: CGPoint) -> Character? {
        KBNativeGlide.nearestLetterX(Double(p.x), y: Double(p.y)).map { Character(UnicodeScalar($0.uint8Value)) }
    }
}
nonisolated enum GlideDecoder {
    static let defaultBand = 4, defaultBeamWidth = 48, defaultPruneWindow = 16
    static let defaultFreqLambda = 0.20, defaultDirWeight = 0.0
    static let defaultSeedRadius: CGFloat = 1.6
    static let seedMinKeep = 4
    static func decode(_ g: ProcessedGlide, lang: LangData, beamWidth: Int = defaultBeamWidth, limit: Int = 6,
        band: Int = defaultBand, freqLambda: Double = defaultFreqLambda, dirWeight: Double = defaultDirWeight,
        seedRadius: CGFloat = defaultSeedRadius, pruneWindow: Int = defaultPruneWindow,
        shouldCancel: (() -> Bool)? = nil) -> [(word: String, cost: Double)] {
        guard let packed = lang.nativeCandidateLexicon, beamWidth > 0, limit > 0 else { return [] }
        let all = KBNativeGlide.decode(GlideBuffers.points(g.points), packed: packed, width: UInt(beamWidth), band: Int32(band),
            frequency: freqLambda, direction: dirWeight, seedRadius: Double(seedRadius), window: UInt(max(0, pruneWindow)), shouldCancel: shouldCancel)
        // Preserve the former Swift Dictionary's equal-cost emission permutation.
        var order: [String: Double] = [:]
        for candidate in all { order[candidate.word] = candidate.cost }
        let values = order.map { KBChannelCandidate.make(word: $0.key, cost: $0.value, logFrequency: 0) }
        return KBNativeGlide.sortCandidates(values, limit: UInt(limit)).map { ($0.word, $0.cost) }
    }
    static func shapeCost(of word: String, _ g: ProcessedGlide, band: Int = defaultBand, dirWeight: Double = defaultDirWeight) -> Double? {
        KBNativeGlide.shapeCost(word.lowercased(), points: GlideBuffers.points(g.points), band: Int32(band), direction: dirWeight)?.doubleValue
    }
    static func idealPath(for word: String, pointCount: Int) -> [CGPoint]? {
        guard pointCount >= 2 else { return nil }
        return KBNativeGlide.idealPath(word.lowercased(), count: UInt(pointCount)).map(GlideBuffers.points)
    }
}

#if DEBUG || KB_REFERENCE_DECODER_YES
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

// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
nonisolated enum SwiftGlideDecoder {

	private static let N = 32                        // both paths resampled to this many points
	static let defaultBand = 4                       // DTW warp window (grid-searched in glide_eval)
	static let defaultFreqLambda = 0.20              // beam frequency pull (grid-searched in glide_eval)
	/// Weight on the tangent-DIRECTION channel of the shape cost (grid-searched in glide_eval).
	/// Two words can occupy the same key neighbourhood with different stroke shapes; comparing
	/// the local heading at each aligned point separates them where pure position can't, and it
	/// shrugs off a systematic hand offset (a rotation/shift moves position, not heading).
	///
	/// DEFAULT 0 (off) deliberately: on the SYNTHETIC harness it lifts shape-only top-1 by
	/// ~5pt (65.5→70.9) but that gain washes out after the frequency rerank (top-1 flat), while
	/// a non-zero weight inflates the cost SCALE and would force a GlideProfile re-bake. It stays
	/// wired + swept so real-stroke capture (#36) can confirm the real-world gain before we ship
	/// it — the same "tune to measured reality, not synthetic noise" rule #37 follows. Enabling
	/// it means re-baking GlideProfile.baseGate + State seed to the new scale (the
	/// glide_eval "PRODUCTION CONFIG" readout prints those numbers at whatever weight you set).
	static let defaultDirWeight = 0.0

	/// Beam width. The dominant loss is RECALL — the true word never entering the candidate set
	/// (glide_eval: recall@12 ≈ 86% at width 48, the hard ceiling on top-1). Width trades recall
	/// against per-word cost: 48→192 lifts top-1 83.0→84.2 but at 2.25× the work. Phase 1 pairs a
	/// narrower beam with START-KEY seed anchoring (below) — the swipe's first point pins the first
	/// letter, so seeding ~4 letters instead of all 26 recovers the recall a narrower beam would
	/// lose, at a fraction of the cost. A glide fires ONCE per word on lift, not per keystroke.
	///
	/// Once the prune window (Phase 4) is in place, width barely moves accuracy — glide_eval
	/// bw48→128 is 86.7→87.3 top-1 — so 48 is chosen for latency: ~2.4 ms/word (4× faster than the
	/// unwindowed bw192) at 86.7 top-1 / 89.4 recall, +2.5 pp over that old config.
	static let defaultBeamWidth = 48
	/// Seed anchoring radius (grid units ≈ key pitches). The beam is seeded only from first-letters
	/// whose key center is within this far of the swipe's first point — the start key is the most
	/// reliable point of a glide, so this prunes ~26→~4 root branches (and the depth-2 explosion
	/// 26²→~4·26) with negligible recall loss. `seedMinKeep` guarantees a floor so an odd start
	/// never seeds an empty beam.
	static let defaultSeedRadius: CGFloat = 1.6
	static let seedMinKeep = 4
	/// Phase 4: the beam's per-child cost is a forward scan over the observed points to align the
	/// new letter (nearest-forward from the parent's index). Unbounded that is O(N) per expansion —
	/// the beam's real hot loop, dominating even the band-DTW at emit. Bounding it to a forward
	/// WINDOW makes each expansion O(window): the next letter's arc position is local and monotonic,
	/// so a full scan to N only ever matched a point a few segments ahead. Wide enough (≈2 letter
	/// segments) to absorb an under-reached/skipped middle letter, which is why it holds recall.
	///
	/// It also IMPROVES accuracy, not just speed: the unbounded scan let a letter match a spurious
	/// point far ahead in the swipe that happened to sit near its key, seeding the beam with badly
	/// misaligned hypotheses. Bounding the scan enforces the monotonic, arc-proportional alignment
	/// a real stroke has (glide_eval: top-1 83→87, recall 86→89). Below ~12 it turns harmful (a
	/// genuinely skipped middle letter falls outside the window): 10→78.8, 8→69.7. 16 leaves margin.
	static let defaultPruneWindow = 16

	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
	// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
	static func decode(_ g: ProcessedGlide, lang: LangData,
					   beamWidth: Int = defaultBeamWidth, limit: Int = 6,
					   band: Int = defaultBand, freqLambda: Double = defaultFreqLambda,
					   dirWeight: Double = defaultDirWeight,
					   seedRadius: CGFloat = defaultSeedRadius,
					   pruneWindow: Int = defaultPruneWindow,
					   shouldCancel: (() -> Bool)? = nil)
			-> [(word: String, cost: Double)] {
		guard lang.hasTrie, g.points.count >= 2, shouldCancel?() != true else { return [] }
		let obs = resampleN(g.points, N)             // observed swipe, fixed N points
		guard obs.count == N else { return [] }
		let obsTan = dirWeight > 0 ? tangents(obs) : []

		// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
		// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
		struct PathNode { let point: CGPoint; let parent: Int }
		var pathArena: [PathNode] = []
		pathArena.reserveCapacity(max(256, beamWidth * 20))
		var pathScratch: [CGPoint] = []
		pathScratch.reserveCapacity(22)
		func appendPath(_ point: CGPoint, parent: Int) -> Int {
			pathArena.append(PathNode(point: point, parent: parent))
			return pathArena.count - 1
		}

		var results: [String: Double] = [:]
		func emit(_ node: Int, _ pathIndex: Int) {
			guard let w = lang.trieWord(atNode: node), w.count >= 2 else { return }
			pathScratch.removeAll(keepingCapacity: true)
			var index = pathIndex
			while index >= 0 {
				let entry = pathArena[index]
				pathScratch.append(entry.point)
				index = entry.parent
			}
			pathScratch.reverse()
			let cost = shapeCost(obs, obsTan, pathScratch, band: band, dirWeight: dirWeight)
			if results[w] == nil || cost < results[w]! { results[w] = cost }
		}

		// Beam key = partial shape cost (nearest-forward, monotonic — anchors the first
		// letter, keeps letters-in-swipe-order) MINUS a frequency pull, so frequent prefixes
		// survive even when a letter was under-reached. `prune` holds the raw shape sum;
		// `key` is what we rank/prune by.
		// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
		// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
		struct Hyp { let node: Int; let j: Int; let prune: Double; let key: Double; let pathIndex: Int }
		func better(_ lhs: Hyp, than rhs: Hyp) -> Bool {
			lhs.key == rhs.key ? lhs.node < rhs.node : lhs.key < rhs.key
		}
		func siftUp(_ heap: inout [Hyp], from start: Int) {
			var child = start
			while child > 0 {
				let parent = (child - 1) / 2
				guard better(heap[parent], than: heap[child]) else { break }
				heap.swapAt(parent, child)
				child = parent
			}
		}
		func siftDown(_ heap: inout [Hyp], from start: Int) {
			var parent = start
			while true {
				let left = parent * 2 + 1
				guard left < heap.count else { return }
				let right = left + 1
				var worseChild = left
				if right < heap.count, better(heap[left], than: heap[right]) { worseChild = right }
				guard better(heap[parent], than: heap[worseChild]) else { return }
				heap.swapAt(parent, worseChild)
				parent = worseChild
			}
		}
		/// Keep the best K with a bounded max-heap. The prior implementation sorted every
		/// child at every trie depth even though all but K entries were discarded.
		func best(_ hypotheses: [Hyp]) -> [Hyp] {
			guard hypotheses.count > beamWidth else { return hypotheses }
			var heap: [Hyp] = []
			heap.reserveCapacity(beamWidth)
			for hypothesis in hypotheses {
				if heap.count < beamWidth {
					heap.append(hypothesis)
					siftUp(&heap, from: heap.count - 1)
				} else if better(hypothesis, than: heap[0]) {
					heap[0] = hypothesis
					siftDown(&heap, from: 0)
				}
			}
			return heap
		}
		func keyFor(_ prune: Double, _ node: Int) -> Double {
			prune - freqLambda * log(Double(lang.trieMaxFreq(ofNode: node)) + 1)
		}

		// Seed ONLY from first-letters near the swipe's start point (Phase 1 start anchoring).
		// Collect every root child with its start distance, then keep those within `seedRadius`
		// but never fewer than `seedMinKeep` (the nearest ones) so the beam is never empty.
		var seeds: [(node: Int, l0: CGPoint, d: Double)] = []
		lang.forEachChild(ofNode: lang.trieRootNode) { label, node in
			guard let l0 = gridCenter(label) else { return }
			seeds.append((node, l0, dist(l0, obs[0])))
		}
		seeds.sort { $0.d < $1.d }
		var beam: [Hyp] = []
		for (i, s) in seeds.enumerated() where s.d <= Double(seedRadius) || i < Self.seedMinKeep {
			let pathIndex = appendPath(s.l0, parent: -1)
			let h = Hyp(node: s.node, j: 0, prune: s.d,
				key: keyFor(s.d, s.node), pathIndex: pathIndex)
			beam.append(h); emit(s.node, h.pathIndex)
		}
		beam = best(beam)

		let maxDepth = 22
		var next: [Hyp] = []
		next.reserveCapacity(beamWidth * 12)
		for _ in 1..<maxDepth {
			if shouldCancel?() == true { return [] }
			next.removeAll(keepingCapacity: true)
			for h in beam {
				lang.forEachChild(ofNode: h.node) { label, node in
					if label == UInt8(ascii: "'") {          // geometry-free apostrophe
						let nh = Hyp(node: node, j: h.j, prune: h.prune,
							key: keyFor(h.prune, node), pathIndex: h.pathIndex)
						next.append(nh); emit(node, nh.pathIndex)
						return
					}
					guard let la = gridCenter(label) else { return }
					var bj = h.j, bd = dist(obs[h.j], la)     // may stay put (doubles need no motion)
					let hi = min(N, h.j + 1 + pruneWindow)    // Phase 4: bounded forward window, not to N
					var k = h.j + 1
					while k < hi { let d = dist(obs[k], la); if d < bd { bd = d; bj = k }; k += 1 }
					let np = h.prune + bd
					let pathIndex = appendPath(la, parent: h.pathIndex)
					let nh = Hyp(node: node, j: bj, prune: np,
						key: keyFor(np, node), pathIndex: pathIndex)
					next.append(nh); emit(node, nh.pathIndex)
				}
			}
			if next.isEmpty { break }
			beam = best(next)
		}
		return results.sorted { $0.value < $1.value }.prefix(limit).map { ($0.key, $0.value) }
	}

	/// Shape cost of a SPECIFIC word against this swipe — the same band-DTW the beam pays at
	/// emit, exposed so the engine can score a context-predicted word the beam never surfaced
	/// (#4 context-recall augmentation). Returns nil for a word with a non-deck letter.
	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
	// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
	static func shapeCost(of word: String, _ g: ProcessedGlide,
						  band: Int = defaultBand, dirWeight: Double = defaultDirWeight) -> Double? {
		guard g.points.count >= 2 else { return nil }
		let obs = resampleN(g.points, N)
		guard obs.count == N else { return nil }
		var letters: [CGPoint] = []
		for ch in word.lowercased() {
			if ch == "'" { continue }                    // geometry-free, as in the beam
			guard let c = gridCenter(ch) else { return nil }
			letters.append(c)                            // doubles kept — mirrors the beam's emit
		}
		guard letters.count >= 1 else { return nil }
		let obsTan = dirWeight > 0 ? tangents(obs) : []
		return shapeCost(obs, obsTan, letters, band: band, dirWeight: dirWeight)
	}

	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
	// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
	static func idealPath(for word: String, pointCount: Int) -> [CGPoint]? {
		guard pointCount >= 2 else { return nil }
		var letters: [CGPoint] = []
		for character in word.lowercased() {
			if character == "'" { continue }
			guard let center = gridCenter(character) else { return nil }
			letters.append(center)
		}
		guard !letters.isEmpty else { return nil }
		if letters.count == 1 { return Array(repeating: letters[0], count: pointCount) }
		return resampleN(letters, pointCount)
	}

	/// Band-limited DTW between the swipe and a word's ideal path (both resampled to N
	/// points). Each swipe point may align to an ideal point within ±band, so local
	/// distortions — a cut corner, a letter under-reached — cost locally, not globally.
	/// When `dirWeight > 0` each cell also pays for a heading mismatch between the two
	/// paths at the aligned points (the direction channel), passed pre-computed `obsTan`.
	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
	// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
	private static func shapeCost(_ obs: [CGPoint], _ obsTan: [CGPoint],
								  _ letters: [CGPoint], band: Int, dirWeight: Double) -> Double {
		let ideal = letters.count == 1 ? [CGPoint](repeating: letters[0], count: N) : resampleN(letters, N)
		guard ideal.count == N else { return .greatestFiniteMagnitude }
		let idealTan = dirWeight > 0 ? tangents(ideal) : []
		let INF = Double.greatestFiniteMagnitude
		var prev = [Double](repeating: INF, count: N + 1)
		var cur  = [Double](repeating: INF, count: N + 1)
		prev[0] = 0
		for i in 1...N {
			for k in 0...N { cur[k] = INF }
			let lo = max(1, i - band), hi = min(N, i + band)
			for j in lo...hi {
				var d = dist(obs[i - 1], ideal[j - 1])
				if dirWeight > 0 {
					let a = obsTan[i - 1], b = idealTan[j - 1]     // unit tangents (0,0 at flat ends)
					d += dirWeight * (1 - (a.x * b.x + a.y * b.y)) // 1-cos ∈ [0,2]; 0 when headings agree
				}
				cur[j] = d + min(prev[j], min(cur[j - 1], prev[j - 1]))
			}
			swap(&prev, &cur)
		}
		return prev[N] / Double(N)
	}

	/// Unit heading at each point: the normalized direction from the previous to the next
	/// point (central difference), zero where a segment has no length. Endpoints use the one
	/// neighbour they have. Consumed by the direction channel of `shapeCost`.
	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
	// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
	private static func tangents(_ pts: [CGPoint]) -> [CGPoint] {
		let n = pts.count
		guard n >= 2 else { return [CGPoint](repeating: .zero, count: n) }
		var out = [CGPoint](repeating: .zero, count: n)
		for i in 0..<n {
			let a = pts[max(i - 1, 0)], b = pts[min(i + 1, n - 1)]
			let dx = b.x - a.x, dy = b.y - a.y
			let m = hypot(dx, dy)
			if m > 1e-9 { out[i] = CGPoint(x: dx / m, y: dy / m) }
		}
		return out
	}

	/// Resample a polyline to exactly `n` points evenly spaced along its arc length.
	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
	// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
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

	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
	// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
	private static func gridCenter(_ label: UInt8) -> CGPoint? { gridCenter(Character(Unicode.Scalar(label))) }
	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
	// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
	private static func gridCenter(_ ch: Character) -> CGPoint? {
		guard let g = KB.grid(for: ch) else { return nil }
		return CGPoint(x: g.0, y: g.1)
	}
	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=GlideSearch
	// MIGRATION-NOTE: Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering.
	private static func dist(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
}

#endif
