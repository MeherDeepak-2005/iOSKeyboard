// Glide eval harness (P5) — compiles the PRODUCTION decoder sources into a Mac CLI,
// synthesizes noisy swipes for frequency-weighted dictionary words, and grid-searches
// the rerank constants (sigma, freqWeight) plus the no-commit gate. Zero drift by
// construction: the same GlidePath.swift / LangData.swift the keyboard ships run here.
//
// Run:  cd tools/glide_eval && ./run.sh
//
// Noise model per swipe: straight segments between letter centers, corner overshoot
// (finger carries past a turn), Gaussian jitter on every sample, extra start/end
// offset. Deterministic (SplitMix64) so runs are comparable.

import Foundation
import CoreGraphics

// ---- deterministic RNG -------------------------------------------------------------

struct SplitMix64: RandomNumberGenerator {
	var state: UInt64
	init(seed: UInt64) { state = seed }
	mutating func next() -> UInt64 {
		state &+= 0x9E3779B97F4A7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
		z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
		return z ^ (z >> 31)
	}
	mutating func uniform() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
	mutating func gaussian(_ sigma: Double) -> Double {
		let u1 = max(uniform(), 1e-12), u2 = uniform()
		return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
	}
}

// ---- swipe synthesis ----------------------------------------------------------------

func gridCenter(_ ch: Character) -> CGPoint? {
	guard let g = KB.grid(for: ch) else { return nil }
	return CGPoint(x: g.0, y: g.1)
}

/// Synthesize a noisy swipe for `word` in grid space (pitch 1). Returns nil if the word
/// has non-qwerty characters.
func synthesize(_ word: String, rng: inout SplitMix64,
				jitter: Double, endJitter: Double, overshoot: Double,
				skipProb: Double = 0) -> [CGPoint]? {
	var seq: [CGPoint] = []
	var lastCh: Character? = nil
	for ch in word {                                  // collapse doubles (no signal in a swipe)
		if ch == lastCh { continue }
		if ch == "'" { continue }                     // no key on the deck — contributes no path
		guard let c = gridCenter(ch) else { return nil }
		seq.append(c); lastCh = ch
	}
	guard seq.count >= 1 else { return nil }
	// Real swipes under-reach: sometimes an interior letter is never touched (the finger
	// cuts the corner straight to the next). Drop one to simulate that.
	if seq.count >= 4, rng.uniform() < skipProb {
		seq.remove(at: 1 + Int(rng.uniform() * Double(seq.count - 2)))
	}
	if seq.count == 1 { seq.append(seq[0]) }

	var raw: [CGPoint] = []
	for i in 0..<(seq.count - 1) {
		let a = seq[i], b = seq[i + 1]
		let seg = hypot(b.x - a.x, b.y - a.y)
		let steps = max(2, Int(seg / 0.18))
		for s in 0..<steps {
			let t = CGFloat(s) / CGFloat(steps)
			raw.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
		}
		// Corner overshoot: carry past the turn along the incoming direction.
		if i + 2 < seq.count, seg > 0, rng.uniform() < 0.6 {
			let o = CGFloat(rng.uniform() * overshoot)
			raw.append(CGPoint(x: b.x + (b.x - a.x) / seg * o, y: b.y + (b.y - a.y) / seg * o))
		}
	}
	raw.append(seq[seq.count - 1])
	for i in raw.indices {
		let extra = (i == 0 || i == raw.count - 1) ? endJitter : 0
		raw[i].x += CGFloat(rng.gaussian(jitter) + rng.gaussian(extra))
		raw[i].y += CGFloat(rng.gaussian(jitter) + rng.gaussian(extra))
	}
	return raw
}

// ---- main ---------------------------------------------------------------------------

let langURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
	? CommandLine.arguments[1] : "../../keyboard/langdata.bin")
guard let lang = LangData(url: langURL), lang.hasTrie else {
	print("cannot open langdata.bin at \(langURL.path)"); exit(1)
}

// Test words: frequency-weighted sample of glideable words (letters on the deck, len 3–10).
var rng = SplitMix64(seed: 42)
var pool: [(String, Int)] = []
for id in 0..<min(lang.wordCount, 6000) {
	let w = lang.word(id)
	guard w.count >= 3, w.count <= 10, w.allSatisfy({ KB.grid(for: $0) != nil }) else { continue }
	pool.append((w, lang.freq(id)))
	if pool.count >= 2500 { break }
}
var words: [String] = []
while words.count < 300 {                            // weighted-ish: earlier ids = more frequent
	let bias = rng.uniform() * rng.uniform()          // quadratic bias toward the frequent end
	words.append(pool[Int(bias * Double(pool.count - 1))].0)
}
// Contractions: geometry-free apostrophes must decode from their letter-only swipe.
let contractions = ["what's", "i'm", "don't", "that's", "can't", "it's", "you're",
					"he's", "there's", "didn't"].filter { lang.trieWordID($0) != nil }
for c in contractions { words.append(contentsOf: [c, c, c]) }

let layoutCenters: [(letter: Character, point: CGPoint)] =
	"qwertyuiopasdfghjklzxcvbnm".compactMap { ch in gridCenter(ch).map { (ch, $0) } }
let layout = GlideLayout(centers: layoutCenters, xPitch: 1, yPitch: 1)

// Synthesize once (realistic: jitter + endpoint error + corner overshoot + letter skip),
// then evaluate. Each decode combo (band, freqLambda) re-runs the beam over these swipes.
struct Case { let word: String; let raw: [CGPoint] }
var testCases: [Case] = []
for w in words {
	guard let raw = synthesize(w, rng: &rng, jitter: 0.22, endJitter: 0.07, overshoot: 0.51, skipProb: 0.15)
	else { continue }
	testCases.append(Case(word: w, raw: raw))
}

func logFreq(_ w: String) -> Double {
	guard let id = lang.trieWordID(w) else { return 0 }
	return log(Double(max(lang.freq(Int(id)), 1)) + 1)
}

// Decode all cases with a (band, freqLambda, dirWeight) combo; return per-case candidates.
func decodeAll(band: Int, freqLambda: Double, dirWeight: Double = GlideDecoder.defaultDirWeight,
			   beamWidth: Int = GlideDecoder.defaultBeamWidth,
			   seedRadius: CGFloat = GlideDecoder.defaultSeedRadius,
			   pruneWindow: Int = GlideDecoder.defaultPruneWindow)
		-> [(word: String, cands: [(word: String, cost: Double)])] {
	var out: [(String, [(word: String, cost: Double)])] = []
	for c in testCases {
		guard let g = GlidePreprocess.run(c.raw, layout: layout, spacing: 0.5) else { continue }
		out.append((c.word, GlideDecoder.decode(g, lang: lang, beamWidth: beamWidth, limit: 12,
												band: band, freqLambda: freqLambda, dirWeight: dirWeight,
												seedRadius: seedRadius, pruneWindow: pruneWindow)))
	}
	return out
}

// Score a decoded set with a (sigma, fw) rerank; return (top1%, top3%).
func score(_ decoded: [(word: String, cands: [(word: String, cost: Double)])],
		   sigma: Double, fw: Double) -> (Double, Double) {
	var t1 = 0, t3 = 0
	for (w, cands) in decoded {
		let ranked = cands.map { (word: $0.word, s: -$0.cost / sigma + fw * logFreq($0.word)) }
			.sorted { $0.s > $1.s }
		if ranked.first?.word == w { t1 += 1 }
		if ranked.prefix(3).contains(where: { $0.word == w }) { t3 += 1 }
	}
	let n = Double(decoded.count)
	return (100 * Double(t1) / n, 100 * Double(t3) / n)
}

print("cases: \(testCases.count)  (jitter .22, endpoint .07, overshoot .51, skip 15%)\n")

// ---- PHASE 1: start-anchoring + narrower beam. Compare the OLD wide-beam config against the
// new anchored one on BOTH accuracy and wall-clock (the whole point is ms/word). A huge
// seedRadius (99) disables anchoring, reproducing the pre-Phase-1 "seed all 26" behaviour.
func bench(_ label: String, beamWidth: Int, seedRadius: CGFloat, pruneWindow: Int = 99) {
	let t0 = Date()
	let dec = decodeAll(band: GlideDecoder.defaultBand, freqLambda: GlideDecoder.defaultFreqLambda,
						beamWidth: beamWidth, seedRadius: seedRadius, pruneWindow: pruneWindow)
	let ms = Date().timeIntervalSince(t0) * 1000 / Double(max(dec.count, 1))
	let (p1, p3) = score(dec, sigma: 0.12, fw: 0.10)
	var recall = 0
	for (w, cands) in dec where cands.contains(where: { $0.word == w }) { recall += 1 }
	let r = 100 * Double(recall) / Double(max(dec.count, 1))
	print(String(format: "%-30s top1 %.1f%%  top3 %.1f%%  recall %.1f%%   %.2f ms/word",
				 (label as NSString).utf8String!, p1, p3, r, ms))
}
print("PHASE 1 — anchoring + width (rerank σ0.12 fw0.10, pruneWindow=N):")
bench("OLD bw192 no-anchor", beamWidth: 192, seedRadius: 99)
bench("bw96 no-anchor", beamWidth: 96, seedRadius: 99)
bench("bw96 anchor r1.6", beamWidth: 96, seedRadius: 1.6)
bench("bw64 anchor r1.6", beamWidth: 64, seedRadius: 1.6)
print("")
print("PHASE 4 — bounded prune window (bw96 anchor r1.6):")
bench("window=full(N)", beamWidth: 96, seedRadius: 1.6, pruneWindow: 99)
bench("window=18", beamWidth: 96, seedRadius: 1.6, pruneWindow: 18)
bench("window=16 (PROD)", beamWidth: 96, seedRadius: 1.6, pruneWindow: 16)
bench("window=12", beamWidth: 96, seedRadius: 1.6, pruneWindow: 12)
bench("window=10", beamWidth: 96, seedRadius: 1.6, pruneWindow: 10)
print("")
print("PHASE 4b — beam width recheck WITH window=16 (does width still matter once pruning is fixed?):")
bench("bw48 window=16", beamWidth: 48, seedRadius: 1.6, pruneWindow: 16)
bench("bw64 window=16", beamWidth: 64, seedRadius: 1.6, pruneWindow: 16)
bench("bw96 window=16", beamWidth: 96, seedRadius: 1.6, pruneWindow: 16)
bench("bw128 window=16", beamWidth: 128, seedRadius: 1.6, pruneWindow: 16)
print("")

// ---- PHASE 2: endpoint (first,last)-anchor candidate augmentation. Does fetching words by
// start/end key and shape-scoring them recover recall the beam (at PROD bw64) drops? ----
func lettersNear(_ p: CGPoint, radius: Double, maxN: Int) -> [Character] {
	var ds: [(Character, Double)] = []
	for ch in "abcdefghijklmnopqrstuvwxyz" where KB.grid(for: ch) != nil {
		let g = KB.grid(for: ch)!
		ds.append((ch, hypot(g.0 - Double(p.x), g.1 - Double(p.y))))
	}
	ds.sort { $0.1 < $1.1 }
	let near = ds.filter { $0.1 <= radius }.prefix(maxN).map { $0.0 }
	return near.isEmpty ? [ds[0].0] : Array(near)     // always at least the nearest
}
func phase2(perBucket: Int, radius: Double, maxEnds: Int, augGate: Double) {
	var beamRecall = 0, augRecall = 0, beamTop1 = 0, augTop1 = 0, added = 0, n = 0
	let t0 = Date()
	for c in testCases {
		guard let g = GlidePreprocess.run(c.raw, layout: layout, spacing: 0.5),
			  let s = g.points.first, let e = g.points.last else { continue }
		n += 1
		var cands = GlideDecoder.decode(g, lang: lang, limit: 12)          // PROD defaults (bw64,win16)
		if cands.contains(where: { $0.word == c.word }) { beamRecall += 1 }
		func rank(_ cs: [(word: String, cost: Double)]) -> String? {
			cs.map { (w: $0.word, s: -$0.cost / 0.12 + 0.10 * logFreq($0.word)) }.max { $0.s < $1.s }?.w
		}
		if rank(cands) == c.word { beamTop1 += 1 }
		let have = Set(cands.map(\.word))
		let first = lettersNear(s, radius: radius, maxN: maxEnds)
		let last = lettersNear(e, radius: radius, maxN: maxEnds)
		for w in lang.glideAnchorWords(first: first, last: last, perBucket: perBucket)
		where !have.contains(w) && w.count >= 2 {
			if let sc = GlideDecoder.shapeCost(of: w, g), sc <= augGate { cands.append((w, sc)); added += 1 }
		}
		if cands.contains(where: { $0.word == c.word }) { augRecall += 1 }
		if rank(cands) == c.word { augTop1 += 1 }
	}
	let ms = Date().timeIntervalSince(t0) * 1000 / Double(max(n, 1))
	let nn = Double(max(n, 1))
	print(String(format: "  perBucket=%d r=%.1f ends=%d gate=%.2f: recall %.1f→%.1f  top1 %.1f→%.1f  (+%.1f cand/word, %.2f ms)",
				 perBucket, radius, maxEnds, augGate,
				 100 * Double(beamRecall) / nn, 100 * Double(augRecall) / nn,
				 100 * Double(beamTop1) / nn, 100 * Double(augTop1) / nn,
				 Double(added) / nn, ms))
}
print("PHASE 2 — endpoint-anchor augmentation on top of PROD beam:")
phase2(perBucket: 40, radius: 1.3, maxEnds: 3, augGate: 0.45)
phase2(perBucket: 80, radius: 1.6, maxEnds: 3, augGate: 0.45)
phase2(perBucket: 120, radius: 1.6, maxEnds: 4, augGate: 0.55)
print("")

// ---- sweep band x freqLambda at a fixed rerank, find the best decode config ----
// (dirWeight is swept separately below — keeping it out of this 3-D grid keeps the run fast.)
print("band  fLambda   top1(fixed rerank σ0.15 fw0.25)  top3")
var bestDecode = (band: 6, fl: 0.14, dw: GlideDecoder.defaultDirWeight, t1: -1.0)
for band in [4, 6, 8] {
	for fl in [0.0, 0.10, 0.14, 0.20] {
		let dec = decodeAll(band: band, freqLambda: fl)
		let (p1, p3) = score(dec, sigma: 0.15, fw: 0.25)
		print(String(format: "%2d    %.2f      %5.1f%%                        %5.1f%%", band, fl, p1, p3))
		if p1 > bestDecode.t1 { bestDecode = (band, fl, GlideDecoder.defaultDirWeight, p1) }
	}
}
print(String(format: "\nBEST DECODE: band=%d freqLambda=%.2f dirWeight=%.2f\n", bestDecode.band, bestDecode.fl, bestDecode.dw))

// ---- direction-channel sweep (item #3), at the best (band, fLambda). Default-OFF in prod;
// this is the evidence for enabling it once real strokes are captured (#36). ----
print("dirW   top1(fixed rerank σ0.15 fw0.25)  top3")
for dw in [0.0, 0.30, 0.60] {
	let dec = decodeAll(band: bestDecode.band, freqLambda: bestDecode.fl, dirWeight: dw)
	let (p1, p3) = score(dec, sigma: 0.15, fw: 0.25)
	print(String(format: "%.2f   %5.1f%%                        %5.1f%%", dw, p1, p3))
}
print("")

// ---- at the best decode config, grid-search the rerank (sigma, fw) ----
let decoded = decodeAll(band: bestDecode.band, freqLambda: bestDecode.fl, dirWeight: bestDecode.dw)
let (sp1, sp3) = score(decoded, sigma: 1e9, fw: 0.0)   // sigma huge → shape-only order
print(String(format: "shape-only:  top1 %.1f%%  top3 %.1f%%", sp1, sp3))
print("\nsigma  fw     top1    top3")
var best = (sigma: 0.15, fw: 0.25, top1: -1.0, top3: 0.0)
for sigma in [0.10, 0.12, 0.15, 0.20, 0.30] {
	for fw in [0.0, 0.10, 0.20, 0.30, 0.45] {
		let (p1, p3) = score(decoded, sigma: sigma, fw: fw)
		print(String(format: "%.2f  %.2f   %5.1f%%  %5.1f%%", sigma, fw, p1, p3))
		if p1 > best.top1 { best = (sigma, fw, p1, p3) }
	}
}
print(String(format: "\nBEST RERANK: sigma=%.2f freqWeight=%.2f -> top1 %.1f%% top3 %.1f%%",
			 best.sigma, best.fw, best.top1, best.top3))

// ---- no-commit gate at the best config ----
var correctShapeCosts: [Double] = []
for (w, cands) in decoded { if let hit = cands.first(where: { $0.word == w }) { correctShapeCosts.append(hit.cost) } }
correctShapeCosts.sort()
let p95 = correctShapeCosts.isEmpty ? 0 : correctShapeCosts[Int(0.95 * Double(correctShapeCosts.count - 1))]
var scribbleBest: [Double] = []
for _ in 0..<80 {
	var pts: [CGPoint] = []
	var p = CGPoint(x: rng.uniform() * 9, y: rng.uniform() * 2)
	for _ in 0..<25 {
		p.x += CGFloat(rng.gaussian(0.8)); p.y += CGFloat(rng.gaussian(0.8))
		p.x = max(0, min(9, p.x)); p.y = max(0, min(2, p.y))
		pts.append(p)
	}
	if let g = GlidePreprocess.run(pts, layout: layout, spacing: 0.5),
	   let c = GlideDecoder.decode(g, lang: lang, limit: 1, band: bestDecode.band, freqLambda: bestDecode.fl, dirWeight: bestDecode.dw).first {
		scribbleBest.append(c.cost)
	}
}
scribbleBest.sort()
let scribbleP10 = scribbleBest.isEmpty ? 999 : scribbleBest[Int(0.10 * Double(scribbleBest.count - 1))]
print(String(format: "\ngate: correct p95 = %.3f; scribble best p10 = %.3f -> glideMaxCost ~ %.2f",
			 p95, scribbleP10, (p95 + scribbleP10) / 2))

// ---- production-config readout (the baked defaults the KEYBOARD actually ships) ----
// GlideProfile seeds its EWMA and clamps off the correct-cost distribution AT THIS EXACT
// config; whenever the decoder's cost SCALE moves (e.g. adding the direction channel) these
// numbers must be re-baked into GlideProfile so a fresh install starts calibrated (#37).
let prod = decodeAll(band: GlideDecoder.defaultBand,
					 freqLambda: GlideDecoder.defaultFreqLambda,
					 dirWeight: GlideDecoder.defaultDirWeight)
var prodCosts: [Double] = []
for (w, cands) in prod { if let hit = cands.first(where: { $0.word == w }) { prodCosts.append(hit.cost) } }
let cMean = prodCosts.reduce(0, +) / Double(max(prodCosts.count, 1))
let cVar  = prodCosts.reduce(0) { $0 + ($1 - cMean) * ($1 - cMean) } / Double(max(prodCosts.count, 1))
prodCosts.sort()
let cP95 = prodCosts.isEmpty ? 0 : prodCosts[Int(0.95 * Double(prodCosts.count - 1))]
var prodScribble: [Double] = []
for _ in 0..<80 {
	var pts: [CGPoint] = []
	var p = CGPoint(x: rng.uniform() * 9, y: rng.uniform() * 2)
	for _ in 0..<25 {
		p.x += CGFloat(rng.gaussian(0.8)); p.y += CGFloat(rng.gaussian(0.8))
		p.x = max(0, min(9, p.x)); p.y = max(0, min(2, p.y))
		pts.append(p)
	}
	if let g = GlidePreprocess.run(pts, layout: layout, spacing: 0.5),
	   let c = GlideDecoder.decode(g, lang: lang, limit: 1, band: GlideDecoder.defaultBand,
								   freqLambda: GlideDecoder.defaultFreqLambda,
								   dirWeight: GlideDecoder.defaultDirWeight).first { prodScribble.append(c.cost) }
}
prodScribble.sort()
let sP10 = prodScribble.isEmpty ? 999 : prodScribble[Int(0.10 * Double(prodScribble.count - 1))]
print(String(format: "\nPRODUCTION CONFIG (band=%d fLambda=%.2f dirW=%.2f) — GlideProfile re-bake numbers:",
			 GlideDecoder.defaultBand, GlideDecoder.defaultFreqLambda, GlideDecoder.defaultDirWeight))
print(String(format: "  correct cost: mean=%.3f var=%.4f p95=%.3f   scribble p10=%.3f",
			 cMean, cVar, cP95, sP10))
print(String(format: "  -> baseGate ~ %.2f (mid p95/scribble),  seed mean=%.2f var=%.3f",
			 (cP95 + sP10) / 2, cMean, cVar))
for sg in [0.10, 0.12, 0.15] {
	let (p1, p3) = score(prod, sigma: sg, fw: GlideDecoder.defaultFreqLambda == 0.20 ? 0.10 : 0.10)
	print(String(format: "  rerank σ=%.2f fw=0.10 -> top1 %.1f%% top3 %.1f%%", sg, p1, p3))
}
