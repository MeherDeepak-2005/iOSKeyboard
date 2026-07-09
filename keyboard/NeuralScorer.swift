import Foundation
import CoreML

// NeuralScorer — Phase C of the rescoring plan. The tiny LM prior behind the
// LanguageScorer seam (see tools/lm/ for the training + export pipeline).
//
// Ships DORMANT: `NeuralScorer.bundled()` returns nil unless the exported
// `rescorer.mlpackage` (compiled to .mlmodelc) and `tokenizer.bin` are present in
// the extension bundle, in which case the engine blends it with the n-gram prior.
// Until the model files exist, this file just compiles and does nothing.
//
// Latency contract: scoring happens ONLY on the engine's background pass (the
// precomputed-autocorrect design keeps it off the space key). One batched forward
// scores all candidates: they share the context prefix, so the sequence layout is
// [ctx tokens][candidate tokens][padding], causal-masked — padding after the
// scored positions can't influence them.

// MARK: - SentencePiece unigram tokenizer (Viterbi over the exported piece table)

final class SPTokenizer {
	private var pieces: [String: (id: Int32, score: Float)] = [:]
	private var pieceByID: [String] = []
	/// Token ids whose piece begins a new word (▁-prefixed) plus </s> — together
	/// they carry the "current word ends here" probability mass the beam search
	/// uses to score a completed word.
	private(set) var boundaryIDs: [Int32] = []
	private let unkID: Int32
	private let unkScore: Float = -20
	private let maxPieceLen: Int

	/// Reads tokenizer.bin (format documented in tools/lm/export_coreml.py).
	init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 16 else { return nil }
		func u32(_ off: Int) -> Int {
			Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
		}
		guard u32(0) == 0x4B42544B, u32(4) == 1 else { return nil }    // "KBTK", v1
		let n = u32(8)
		unkID = Int32(u32(12))
		let scoresBase = 16, offsBase = scoresBase + 4 * n, blobBase = offsBase + 4 * (n + 1)
		guard blobBase <= d.count else { return nil }
		var maxLen = 1
		pieceByID.reserveCapacity(n)
		for i in 0..<n {
			let score = Float(bitPattern: UInt32(littleEndian:
				d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: scoresBase + 4 * i, as: UInt32.self) }))
			let a = blobBase + u32(offsBase + 4 * i), b = blobBase + u32(offsBase + 4 * (i + 1))
			let piece = String(decoding: d[a..<b], as: UTF8.self)
			pieces[piece] = (Int32(i), score)
			pieceByID.append(piece)
			maxLen = max(maxLen, piece.count)
		}
		maxPieceLen = min(maxLen, 24)
		boundaryIDs = pieceByID.enumerated().compactMap {
			$0.element.hasPrefix("\u{2581}") ? Int32($0.offset) : nil
		}
		if let eos = pieces["</s>"]?.id { boundaryIDs.append(eos) }
	}

	func id(of piece: String) -> Int32? { pieces[piece]?.id }
	func piece(_ id: Int32) -> String {
		let i = Int(id)
		return i >= 0 && i < pieceByID.count ? pieceByID[i] : ""
	}

	/// Unigram-LM segmentation: max-sum-of-scores path (Viterbi). SentencePiece's
	/// whitespace convention: every space becomes the ▁ prefix of the next piece.
	func encode(_ text: String) -> [Int32] {
		let s = Array("\u{2581}" + text.replacingOccurrences(of: " ", with: "\u{2581}"))
		let n = s.count
		var best = [Float](repeating: -.infinity, count: n + 1)
		var back = [(start: Int, id: Int32)](repeating: (0, unkID), count: n + 1)
		best[0] = 0
		for end in 1...n {
			for start in max(0, end - maxPieceLen)..<end {
				guard best[start] > -.infinity else { continue }
				let sub = String(s[start..<end])
				if let p = pieces[sub], best[start] + p.score > best[end] {
					best[end] = best[start] + p.score
					back[end] = (start, p.id)
				}
			}
			if best[end] == -.infinity {                       // unknown char → unk piece
				best[end] = best[end - 1] + unkScore
				back[end] = (end - 1, unkID)
			}
		}
		var out: [Int32] = []
		var i = n
		while i > 0 { out.append(back[i].id); i = back[i].start }
		return out.reversed()
	}
}

// MARK: - NeuralScorer

final class NeuralScorer {
	static let contextLen = 32                        // must match export_coreml.py L
	static let maxBatch = 16                          // must match export_coreml.py RangeDim(1, 16)
	/// Device-tier gate: the model is only hosted when the process has at least this much
	/// headroom before jetsam. The extension budget varies widely — older hardware / older
	/// iOS run ~60–70 MB, newer iOS 17+ devices ~180 MB. Loading a CoreML model (weights +
	/// fp16 working set + activations, ~20 MB peak) into a 68 MB budget risks a memory kill,
	/// so tight devices stay on the (excellent) n-gram engine while roomy ones use both.
	/// One model, no extra app size — the choice is made at runtime from the real budget.
	static let minAvailableMBToLoad = 90.0

	private let modelURL: URL
	private let tokenizer: SPTokenizer
	private let modeTag: Int32?                       // <en>/<te>/<xlit> token
	private let lock = NSLock()
	private var model: MLModel?
	private var loading = false
	/// Set when an MLModel load attempt fails. Every scoring call retriggers
	/// `beginLoading` while the model is absent, so without a cooldown a corrupt or
	/// unloadable model file means one full disk/compile attempt PER KEYSTROKE.
	private var lastLoadFailure: Date?
	private static let loadRetryInterval: TimeInterval = 30
	private var pressureSource: DispatchSourceMemoryPressure?

	/// nil unless the exported model + tokenizer are in the bundle.
	static func bundled() -> NeuralScorer? {
		guard let m = Bundle.main.url(forResource: "rescorer", withExtension: "mlmodelc"),
			  let t = Bundle.main.url(forResource: "tokenizer", withExtension: "bin"),
			  let tok = SPTokenizer(url: t) else { return nil }
		return NeuralScorer(modelURL: m, tokenizer: tok)
	}

	private init(modelURL: URL, tokenizer: SPTokenizer) {
		self.modelURL = modelURL
		self.tokenizer = tokenizer
		self.modeTag = tokenizer.id(of: "<en>")       // Tenglish mode swaps this later
		beginLoading()
		// Extensions die at ~60-70 MB dirty: drop the model under pressure and fall
		// back to the n-gram prior; reload lazily on the next scoring request.
		let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
		src.setEventHandler { [weak self] in
			guard let self else { return }
			let critical = (self.pressureSource?.data ?? []).contains(.critical)
			self.lock.lock(); let wasActive = self.model != nil; self.model = nil; self.lock.unlock()
			KBDiagnostics.recorder.memoryPressure(critical: critical, modelWasActive: wasActive)
		}
		src.resume()
		pressureSource = src
	}

	var isReady: Bool {
		lock.lock(); defer { lock.unlock() }
		return model != nil
	}

	private func beginLoading() {
		lock.lock()
		guard model == nil, !loading else { lock.unlock(); return }
		if let f = lastLoadFailure, Date().timeIntervalSince(f) < Self.loadRetryInterval {
			lock.unlock(); return
		}
		// Only host the model when there's comfortable headroom (see minAvailableMBToLoad).
		// availableBytes() == 0 means "couldn't measure" (e.g. simulator) → fail open.
		let availableMB = Double(KBDiagnostics.availableBytes()) / 1_048_576
		if availableMB > 0, availableMB < Self.minAvailableMBToLoad { lock.unlock(); return }
		loading = true
		lock.unlock()
		DispatchQueue.global(qos: .utility).async { [weak self] in
			guard let self else { return }
			let cfg = MLModelConfiguration()
			cfg.computeUnits = .cpuAndNeuralEngine    // benchmark: CPU-only may win at this size
			let t0 = Date()
			let m = try? MLModel(contentsOf: self.modelURL, configuration: cfg)
			let loadMs = Date().timeIntervalSince(t0) * 1000
			self.lock.lock()
			self.model = m
			self.loading = false
			self.lastLoadFailure = m == nil ? Date() : nil
			self.lock.unlock()
			if m != nil { KBDiagnostics.recorder.modelActivated(loadMs: loadMs) }
		}
	}

	/// Batched log P(candidate | context). Candidates are scored in batches of at most
	/// `maxBatch` (the model's exported Core ML batch limit) — over that, Core ML rejects
	/// the input outright, so passing the whole candidate set in one array crashes. The
	/// caller already caps to ~16, but chunking here makes the component safe for any N.
	/// Returns nil when the model isn't resident (engine falls back to n-gram).
	func scores(_ candidates: [String], context: [String]) -> [Double]? {
		lock.lock()
		let m = model
		lock.unlock()
		guard let m else { beginLoading(); return nil }
		guard !candidates.isEmpty else { return [] }

		let L = Self.contextLen
		// Shared context prefix; leave room for the longest candidate.
		var ctx: [Int32] = modeTag.map { [$0] } ?? []
		ctx += tokenizer.encode(context.joined(separator: " ").lowercased())
		let candTokens = candidates.map { tokenizer.encode(" " + $0.lowercased()) }
		let maxCand = candTokens.map(\.count).max() ?? 1
		if ctx.count + maxCand >= L {
			ctx = Array(ctx.suffix(max(0, L - maxCand - 1)))
		}
		let ctxCount = ctx.count

		var result = [Double](repeating: 0, count: candidates.count)
		var start = 0
		while start < candidates.count {
			let end = min(start + Self.maxBatch, candidates.count)
			let B = end - start
			guard let arr = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: L)], dataType: .int32)
			else { return nil }
			let p = arr.dataPointer.bindMemory(to: Int32.self, capacity: B * L)
			for b in 0..<B {
				let row = ctx + candTokens[start + b]
				for i in 0..<L { p[b * L + i] = i < row.count ? row[i] : 0 }   // pad: causally inert
			}
			guard let input = try? MLDictionaryFeatureProvider(dictionary: ["tokens": arr]),
				  let out = try? m.prediction(from: input),
				  let logits = out.featureValue(for: "logits")?.multiArrayValue,
				  logits.shape.count == 3, logits.shape[0].intValue == B else { return nil }

			// logits [B, L, V]: P(token at t | tokens < t) lives at position t-1.
			let V = logits.shape[2].intValue
			guard V > 0 else { return nil }
			// The element type MUST match logits.dataType: the exported mlprogram declares
			// FLOAT16 logits (its compute precision), and binding that buffer as Float
			// reads past its end — EXC_BAD_ACCESS halfway in. Strides likewise are
			// CoreML's choice (ANE outputs may be padded), so never assume a dense layout.
			let s0 = logits.strides[0].intValue
			let s1 = logits.strides[1].intValue
			let s2 = logits.strides[2].intValue
			func accumulate<T: BinaryFloatingPoint>(_ lp: UnsafeBufferPointer<T>) {
				func logProb(batch: Int, pos: Int, token: Int32) -> Double {
					guard pos >= 0, pos < L, token >= 0, Int(token) < V else { return 0 }  // never index OOB
					let base = batch * s0 + pos * s1
					var maxV = -Float.infinity
					for v in 0..<V { maxV = max(maxV, Float(lp[base + v * s2])) }
					var sum: Float = 0
					for v in 0..<V { sum += expf(Float(lp[base + v * s2]) - maxV) }
					return Double(Float(lp[base + Int(token) * s2]) - maxV - logf(sum))
				}
				for b in 0..<B {
					var total = 0.0
					for (i, t) in candTokens[start + b].enumerated() {
						total += logProb(batch: b, pos: ctxCount - 1 + i, token: t)
					}
					result[start + b] = total
				}
			}
			switch logits.dataType {
			case .float16: logits.withUnsafeBufferPointer(ofType: Float16.self) { accumulate($0) }
			case .float32: logits.withUnsafeBufferPointer(ofType: Float.self)   { accumulate($0) }
			case .double:  logits.withUnsafeBufferPointer(ofType: Double.self)  { accumulate($0) }
			default: return nil
			}
			start = end
		}
		return result
	}

	// MARK: Trie-constrained beam search — next-WORD prediction

	/// Predicts whole next words by beam search over subword pieces, where every
	/// partial expansion must remain a valid prefix in the caller's lexicon and
	/// only complete lexicon words are emitted — open, whole-sentence-context
	/// generation with zero hallucinated strings. (This is also the machinery a
	/// future Tenglish transliteration mode reuses with a Telugu-word trie.)
	///
	/// A word's score = logP(its pieces | ctx) + logP(next piece starts a new
	/// word), i.e. the probability the word occurs AND ends there — without the
	/// boundary term, prefixes of longer words win spuriously ("ca" pieces for
	/// "cat" vs "category"). One batched forward per step, ≤ maxPieces steps, so
	/// words of up to maxPieces−1 pieces are scored. Returns nil while the model
	/// isn't resident. Call on the engine's queue (the closures walk the trie).
	func predictWords(context: [String], limit: Int,
					  beamWidth: Int = 8, maxPieces: Int = 4,
					  isPrefix: (String) -> Bool, isWord: (String) -> Bool)
			-> [(word: String, score: Double)]? {
		lock.lock()
		let m = model
		lock.unlock()
		guard let m else { beginLoading(); return nil }

		let L = Self.contextLen
		var ctx: [Int32] = modeTag.map { [$0] } ?? []
		ctx += tokenizer.encode(context.joined(separator: " ").lowercased())
		if ctx.count + maxPieces >= L { ctx = Array(ctx.suffix(L - maxPieces - 1)) }
		guard !ctx.isEmpty else { return nil }

		struct Beam { var tokens: [Int32]; var surface: String; var lp: Double }
		var beams = [Beam(tokens: ctx, surface: "", lp: 0)]
		var found: [String: Double] = [:]

		for _ in 0..<maxPieces {
			guard let dists = lastTokenLogProbs(rows: beams.map(\.tokens), using: m)
			else { return nil }
			var expanded: [Beam] = []
			for (beam, dist) in zip(beams, dists) {
				if !beam.surface.isEmpty, isWord(beam.surface) {
					var end = -Float.infinity
					for id in tokenizer.boundaryIDs { end = logAddExp(end, dist[Int(id)]) }
					let score = beam.lp + Double(end)
					if score > (found[beam.surface] ?? -.infinity) { found[beam.surface] = score }
				}
				// Only the model's strongest continuations are worth a trie walk.
				// Partial selection: sorting the whole ~6k-entry vocab distribution per
				// beam per step cost O(V log V); the size-64 min-heap is O(V log 64).
				let top = topK(dist, 64)
				for (id, lp) in top {
					let piece = tokenizer.piece(Int32(id))
					guard !piece.isEmpty, !piece.hasPrefix("<") else { continue }  // specials + byte pieces
					let surface: String
					if beam.surface.isEmpty {
						guard piece.count > 1, piece.hasPrefix("\u{2581}") else { continue }
						surface = String(piece.dropFirst())     // new word begins after the space
					} else {
						guard !piece.hasPrefix("\u{2581}") else { continue }  // boundary — handled above
						surface = beam.surface + piece
					}
					guard isPrefix(surface) else { continue }   // the constraint: stay inside the trie
					expanded.append(Beam(tokens: beam.tokens + [Int32(id)],
										 surface: surface, lp: beam.lp + Double(lp)))
				}
			}
			beams = Array(expanded.sorted { $0.lp > $1.lp }.prefix(beamWidth))
			if beams.isEmpty { break }
		}
		return found.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }
	}

	/// One batched forward; log-softmax over the vocab at each row's last real
	/// (unpadded) position. Same dtype/stride discipline as `scores`.
	private func lastTokenLogProbs(rows: [[Int32]], using m: MLModel) -> [[Float]]? {
		let L = Self.contextLen
		let B = rows.count
		guard B > 0, B <= Self.maxBatch,
			  rows.allSatisfy({ !$0.isEmpty && $0.count <= L }) else { return nil }
		guard let arr = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: L)], dataType: .int32)
		else { return nil }
		let p = arr.dataPointer.bindMemory(to: Int32.self, capacity: B * L)
		for b in 0..<B {
			for i in 0..<L { p[b * L + i] = i < rows[b].count ? rows[b][i] : 0 }
		}
		guard let input = try? MLDictionaryFeatureProvider(dictionary: ["tokens": arr]),
			  let out = try? m.prediction(from: input),
			  let logits = out.featureValue(for: "logits")?.multiArrayValue,
			  logits.shape.count == 3, logits.shape[0].intValue == B else { return nil }
		let V = logits.shape[2].intValue
		guard V > 0 else { return nil }
		let s0 = logits.strides[0].intValue
		let s1 = logits.strides[1].intValue
		let s2 = logits.strides[2].intValue
		var result = [[Float]](repeating: [], count: B)
		func extract<T: BinaryFloatingPoint>(_ lp: UnsafeBufferPointer<T>) {
			for b in 0..<B {
				let base = b * s0 + (rows[b].count - 1) * s1
				var row = [Float](repeating: 0, count: V)
				var maxV = -Float.infinity
				for v in 0..<V { row[v] = Float(lp[base + v * s2]); maxV = max(maxV, row[v]) }
				var sum: Float = 0
				for v in 0..<V { sum += expf(row[v] - maxV) }
				let logZ = maxV + logf(sum)
				for v in 0..<V { row[v] -= logZ }
				result[b] = row
			}
		}
		switch logits.dataType {
		case .float16: logits.withUnsafeBufferPointer(ofType: Float16.self) { extract($0) }
		case .float32: logits.withUnsafeBufferPointer(ofType: Float.self)   { extract($0) }
		case .double:  logits.withUnsafeBufferPointer(ofType: Double.self)  { extract($0) }
		default: return nil
		}
		return result
	}
}

private func logAddExp(_ a: Float, _ b: Float) -> Float {
	let m = max(a, b)
	guard m > -.infinity else { return m }
	return m + logf(expf(a - m) + expf(b - m))
}

/// The k largest values with their indices, descending. A size-k min-heap over one
/// pass: heap root = smallest of the current top k, evicted whenever a larger value
/// arrives.
private func topK(_ values: [Float], _ k: Int) -> [(index: Int, value: Float)] {
	guard values.count > k else {
		return values.enumerated().map { ($0.offset, $0.element) }.sorted { $0.value > $1.value }
	}
	var heap: [(index: Int, value: Float)] = []
	heap.reserveCapacity(k)
	for (i, v) in values.enumerated() {
		if heap.count < k {
			heap.append((i, v))
			var c = heap.count - 1
			while c > 0 {
				let p = (c - 1) >> 1
				if heap[p].value <= heap[c].value { break }
				heap.swapAt(p, c); c = p
			}
		} else if v > heap[0].value {
			heap[0] = (i, v)
			var p = 0
			while true {
				let l = 2 * p + 1, r = l + 1
				var m = p
				if l < k, heap[l].value < heap[m].value { m = l }
				if r < k, heap[r].value < heap[m].value { m = r }
				if m == p { break }
				heap.swapAt(p, m); p = m
			}
		}
	}
	return heap.sorted { $0.value > $1.value }
}

// MARK: - BlendedScorer: neural + n-gram behind the same seam

/// The production prior: `wN·neural + wG·ngram`, degrading to pure n-gram whenever
/// the model isn't resident (still loading, or dropped under memory pressure).
/// Personalization is untouched — the user's counts live inside the ngram term.
final class BlendedScorer: LanguageScorer {
	private let neural: NeuralScorer
	private let ngram: NgramScorer
	private let wNeural: Double
	private let wNgram: Double

	init(neural: NeuralScorer, ngram: NgramScorer, neuralWeight: Double = 0.7, ngramWeight: Double = 0.3) {
		self.neural = neural
		self.ngram = ngram
		self.wNeural = neuralWeight
		self.wNgram = ngramWeight
	}

	var isReady: Bool { true }        // n-gram fallback means we can always answer
	/// Tracks the model's residency: gate features degrade to legacy behavior the
	/// moment memory pressure drops the model, and come back when it reloads.
	var scoresArbitraryWords: Bool { neural.isReady }

	private(set) var lastSplit: (neural: [Double], ngram: [Double])?

	func logProbs(_ candidates: [String], context: [String]) -> [Double] {
		let g = ngram.logProbs(candidates, context: context)
		guard let n = neural.scores(candidates, context: context) else { lastSplit = nil; return g }
		lastSplit = (n, g)
		return zip(n, g).map { wNeural * $0 + wNgram * $1 }
	}
}
