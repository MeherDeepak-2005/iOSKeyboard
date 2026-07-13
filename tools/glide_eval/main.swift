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

// Decode all cases with a (band, freqLambda) combo; return per-case candidates.
func decodeAll(band: Int, freqLambda: Double) -> [(word: String, cands: [(word: String, cost: Double)])] {
	var out: [(String, [(word: String, cost: Double)])] = []
	for c in testCases {
		guard let g = GlidePreprocess.run(c.raw, layout: layout, spacing: 0.5) else { continue }
		out.append((c.word, GlideDecoder.decode(g, lang: lang, limit: 12, band: band, freqLambda: freqLambda)))
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

// ---- sweep band x freqLambda at a fixed rerank, find the best decode config ----
print("band  fLambda   top1(fixed rerank σ0.15 fw0.25)  top3")
var bestDecode = (band: 6, fl: 0.14, t1: -1.0)
for band in [4, 6, 8] {
	for fl in [0.0, 0.10, 0.14, 0.20] {
		let dec = decodeAll(band: band, freqLambda: fl)
		let (p1, p3) = score(dec, sigma: 0.15, fw: 0.25)
		print(String(format: "%2d    %.2f      %5.1f%%                        %5.1f%%", band, fl, p1, p3))
		if p1 > bestDecode.t1 { bestDecode = (band, fl, p1) }
	}
}
print(String(format: "\nBEST DECODE: band=%d freqLambda=%.2f\n", bestDecode.band, bestDecode.fl))

// ---- at the best decode config, grid-search the rerank (sigma, fw) ----
let decoded = decodeAll(band: bestDecode.band, freqLambda: bestDecode.fl)
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
	   let c = GlideDecoder.decode(g, lang: lang, limit: 1, band: bestDecode.band, freqLambda: bestDecode.fl).first {
		scribbleBest.append(c.cost)
	}
}
scribbleBest.sort()
let scribbleP10 = scribbleBest.isEmpty ? 999 : scribbleBest[Int(0.10 * Double(scribbleBest.count - 1))]
print(String(format: "\ngate: correct p95 = %.3f; scribble best p10 = %.3f -> glideMaxCost ~ %.2f",
			 p95, scribbleP10, (p95 + scribbleP10) / 2))
