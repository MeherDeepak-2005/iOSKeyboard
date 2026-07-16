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
	/// whitespace convention: normalized whitespace becomes the ▁ prefix of the
	/// next piece. Unknown Unicode is emitted as its UTF-8 <0xXX> pieces, matching the
	/// Python tokenizer's `byte_fallback=True` behavior instead of collapsing to <unk>.
	/// Returns the best token ID sequence and the total path log-probability.
	private func viterbi(_ text: String) -> (ids: [Int32], score: Float) {
		// SentencePiece's default NMT NFKC normalizer compatibility-composes text,
		// removes leading/trailing whitespace, and collapses internal whitespace.
		let normalized = text.precomposedStringWithCompatibilityMapping
		let words = normalized.split(whereSeparator: { $0.isWhitespace })
		guard !words.isEmpty else { return ([], 0) }
		let s = Array("\u{2581}" + words.joined(separator: "\u{2581}"))
		let n = s.count
		var best = [Float](repeating: -.infinity, count: n + 1)
		var backStart = [Int](repeating: 0, count: n + 1)
		var backIDs = [[Int32]](repeating: [unkID], count: n + 1)
		best[0] = 0
		for end in 1...n {
			for start in max(0, end - maxPieceLen)..<end {
				guard best[start] > -.infinity else { continue }
				let sub = String(s[start..<end])
				if let p = pieces[sub], best[start] + p.score > best[end] {
					best[end] = best[start] + p.score
					backStart[end] = start
					backIDs[end] = [p.id]
				}
			}
			if best[end] == -.infinity {
				let utf8 = String(s[end - 1]).utf8
				let byteIDs = utf8.compactMap { byte in
					pieces[String(format: "<0x%02X>", byte)]?.id
				}
				// A byte-fallback tokenizer has all 256 pieces. Retain <unk> support so
				// malformed/legacy tokenizer files fail safely rather than dropping text.
				backIDs[end] = byteIDs.count == utf8.count ? byteIDs : [unkID]
				best[end] = best[end - 1] + unkScore
				backStart[end] = end - 1
			}
		}
		var out: [Int32] = []
		var i = n
		while i > 0 {
			out.append(contentsOf: backIDs[i].reversed())
			i = backStart[i]
		}
		return (out.reversed(), best[n])
	}

	func encode(_ text: String) -> [Int32] { viterbi(text).ids }

	/// Sum of Viterbi piece log-probs — unigram log P(text) under the piece model.
	/// Real English words sit around -5 to -12; unk-heavy strings score near -20·len.
	func logProb(_ text: String) -> Float { viterbi(text).score }

	/// Load the tokenizer from the extension bundle without requiring the full model.
	static func fromBundle() -> SPTokenizer? {
		guard let t = Bundle.main.url(forResource: "tokenizer", withExtension: "bin") else { return nil }
		return SPTokenizer(url: t)
	}
}

// MARK: - NeuralScorer

final class NeuralScorer {
	private enum LoadError: LocalizedError {
		case incompatibleInterface(inputs: Set<String>, outputs: Set<String>)
		var errorDescription: String? {
			switch self {
			case .incompatibleInterface(let inputs, let outputs):
				return "Core ML interface is stale (inputs: \(inputs.sorted()), outputs: \(outputs.sorted())); rerun tools/lm/export_coreml.py"
			}
		}
	}
	static let contextLen = 32                        // must match export_coreml.py L
	static let maxBatch = 16                          // must match export_coreml.py RangeDim(1, 16)
	static let scoreSlots = 8                         // must match model.py/export_coreml.py K
	/// Initial safety estimate. Unlike the old 90 MB threshold this represents the
	/// model's measured incremental working set plus reserve, not the whole extension
	/// budget. Diagnostics records every gate decision so this can be calibrated on
	/// the oldest supported physical device.
	static let minAvailableMBToLoad = 35.0

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
	private var lastMemoryGate: Date?
	private static let gateRetryInterval: TimeInterval = 5
	private var pressureSource: DispatchSourceMemoryPressure?

	/// nil unless the exported model + tokenizer are in the bundle.
	static func bundled(language: KBLanguage = .english) -> NeuralScorer? {
		guard let m = Bundle.main.url(forResource: "rescorer", withExtension: "mlmodelc") else {
			KBDiagnostics.recorder.modelState("missing-model", error: "rescorer.mlmodelc is not bundled")
			return nil
		}
		guard let t = Bundle.main.url(forResource: "tokenizer", withExtension: "bin"),
			  let tok = SPTokenizer(url: t) else {
			KBDiagnostics.recorder.modelState("missing-tokenizer", error: "tokenizer.bin is missing or invalid")
			return nil
		}
		return NeuralScorer(modelURL: m, tokenizer: tok, language: language)
	}

	private init(modelURL: URL, tokenizer: SPTokenizer, language: KBLanguage) {
		self.modelURL = modelURL
		self.tokenizer = tokenizer
		self.modeTag = tokenizer.id(of: language.modelTag)
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
		if let g = lastMemoryGate, Date().timeIntervalSince(g) < Self.gateRetryInterval {
			lock.unlock(); return
		}
		// Only host the model when there's comfortable headroom (see minAvailableMBToLoad).
		// availableBytes() == 0 means "couldn't measure" (e.g. simulator) → fail open.
		let availableMB = Double(KBDiagnostics.availableBytes()) / 1_048_576
		if availableMB > 0, availableMB < Self.minAvailableMBToLoad {
			lastMemoryGate = Date()
			lock.unlock()
			KBDiagnostics.recorder.modelState("memory-gated", availableMB: availableMB)
			return
		}
		loading = true
		lock.unlock()
		KBDiagnostics.recorder.modelState("loading")
		DispatchQueue.global(qos: .utility).async { [weak self] in
			guard let self else { return }
			let cfg = MLModelConfiguration()
			cfg.computeUnits = .cpuAndNeuralEngine    // benchmark: CPU-only may win at this size
			let t0 = Date()
			let result: Result<MLModel, Error>
			do {
				let loaded = try MLModel(contentsOf: self.modelURL, configuration: cfg)
				let inputs = Set(loaded.modelDescription.inputDescriptionsByName.keys)
				let outputs = Set(loaded.modelDescription.outputDescriptionsByName.keys)
				let requiredInputs: Set<String> = ["tokens", "score_positions", "target_ids", "score_mask", "next_positions"]
				let requiredOutputs: Set<String> = ["candidate_log_probs", "next_logits"]
				guard requiredInputs.isSubset(of: inputs), requiredOutputs.isSubset(of: outputs) else {
					throw LoadError.incompatibleInterface(inputs: inputs, outputs: outputs)
				}
				result = .success(loaded)
			}
			catch { result = .failure(error) }
			let loadMs = Date().timeIntervalSince(t0) * 1000
			let m = try? result.get()
			self.lock.lock()
			self.model = m
			self.loading = false
			self.lastLoadFailure = m == nil ? Date() : nil
			self.lock.unlock()
			switch result {
			case .success:
				KBDiagnostics.recorder.modelActivated(loadMs: loadMs)
			case .failure(let error):
				KBDiagnostics.recorder.modelState("load-failed", error: error.localizedDescription)
			}
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
		guard maxCand < L else { return nil }
		if ctx.count + maxCand >= L {
			ctx = Array(ctx.suffix(max(0, L - maxCand - 1)))
		}
		let ctxCount = ctx.count

		var result = [Double](repeating: 0, count: candidates.count)
		var start = 0
		while start < candidates.count {
			let end = min(start + Self.maxBatch, candidates.count)
			let B = end - start
			guard let tokens = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: L)], dataType: .int32)
			else { return nil }
			let p = tokens.dataPointer.bindMemory(to: Int32.self, capacity: B * L)
			for b in 0..<B {
				let row = ctx + candTokens[start + b]
				for i in 0..<L { p[b * L + i] = i < row.count ? row[i] : 0 }   // pad: causally inert
			}
			// Score in groups of K target positions. Unusually fragmented words remain
			// exact; they cost an extra forward instead of being silently truncated.
			for slotBase in stride(from: 0, to: maxCand, by: Self.scoreSlots) {
				guard let positions = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: Self.scoreSlots)], dataType: .int32),
					  let targets = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: Self.scoreSlots)], dataType: .int32),
					  let mask = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: Self.scoreSlots)], dataType: .float32),
					  let next = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: 1)], dataType: .int32)
				else { return nil }
				let pp = positions.dataPointer.bindMemory(to: Int32.self, capacity: B * Self.scoreSlots)
				let tp = targets.dataPointer.bindMemory(to: Int32.self, capacity: B * Self.scoreSlots)
				let mp = mask.dataPointer.bindMemory(to: Float.self, capacity: B * Self.scoreSlots)
				let np = next.dataPointer.bindMemory(to: Int32.self, capacity: B)
				for b in 0..<B {
					let candidate = candTokens[start + b]
					np[b] = Int32(ctxCount + candidate.count - 1)
					for slot in 0..<Self.scoreSlots {
						let i = slotBase + slot
						let o = b * Self.scoreSlots + slot
						pp[o] = i < candidate.count ? Int32(ctxCount - 1 + i) : 0
						tp[o] = i < candidate.count ? candidate[i] : 0
						mp[o] = i < candidate.count ? 1 : 0
					}
				}
				guard let input = try? MLDictionaryFeatureProvider(dictionary: [
					"tokens": tokens, "score_positions": positions, "target_ids": targets,
					"score_mask": mask, "next_positions": next
				]), let out = try? m.prediction(from: input),
				   let scores = out.featureValue(for: "candidate_log_probs")?.multiArrayValue,
				   let values = readVector(scores, count: B) else { return nil }
				for b in 0..<B { result[start + b] += values[b] }
			}
			start = end
		}
		return result
	}

	/// Batched log P(word | contexts[i]) — the n-1 rescue's forward-evidence term.
	/// Same layout discipline as `scores`, but each batch row carries ITS OWN context
	/// (the alternative previous words), so every alternative rides one Core ML
	/// dispatch instead of one prediction call per context. Rows are trimmed
	/// individually so each context + the shared candidate fits in L.
	/// Returns nil when the model isn't resident (caller falls back to n-gram).
	func scores(of word: String, underContexts contexts: [[String]]) -> [Double]? {
		lock.lock()
		let m = model
		lock.unlock()
		guard let m else { beginLoading(); return nil }
		guard !contexts.isEmpty else { return [] }

		let L = Self.contextLen
		let candidate = tokenizer.encode(" " + word.lowercased())
		guard !candidate.isEmpty, candidate.count < L else { return nil }
		let tag: [Int32] = modeTag.map { [$0] } ?? []
		let ctxRows: [[Int32]] = contexts.map { ctx in
			var t = tag + tokenizer.encode(ctx.joined(separator: " ").lowercased())
			if t.count + candidate.count >= L {
				t = Array(t.suffix(max(0, L - candidate.count - 1)))
			}
			return t
		}
		guard ctxRows.allSatisfy({ !$0.isEmpty }) else { return nil }   // position ctxCount-1 must exist

		var result = [Double](repeating: 0, count: contexts.count)
		var start = 0
		while start < contexts.count {
			let end = min(start + Self.maxBatch, contexts.count)
			let B = end - start
			guard let tokens = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: L)], dataType: .int32)
			else { return nil }
			let p = tokens.dataPointer.bindMemory(to: Int32.self, capacity: B * L)
			for b in 0..<B {
				let row = ctxRows[start + b] + candidate
				for i in 0..<L { p[b * L + i] = i < row.count ? row[i] : 0 }   // pad: causally inert
			}
			for slotBase in stride(from: 0, to: candidate.count, by: Self.scoreSlots) {
				guard let positions = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: Self.scoreSlots)], dataType: .int32),
					  let targets = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: Self.scoreSlots)], dataType: .int32),
					  let mask = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: Self.scoreSlots)], dataType: .float32),
					  let next = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: 1)], dataType: .int32)
				else { return nil }
				let pp = positions.dataPointer.bindMemory(to: Int32.self, capacity: B * Self.scoreSlots)
				let tp = targets.dataPointer.bindMemory(to: Int32.self, capacity: B * Self.scoreSlots)
				let mp = mask.dataPointer.bindMemory(to: Float.self, capacity: B * Self.scoreSlots)
				let np = next.dataPointer.bindMemory(to: Int32.self, capacity: B)
				for b in 0..<B {
					let ctxCount = ctxRows[start + b].count            // per-row, unlike `scores`
					np[b] = Int32(ctxCount + candidate.count - 1)
					for slot in 0..<Self.scoreSlots {
						let i = slotBase + slot
						let o = b * Self.scoreSlots + slot
						pp[o] = i < candidate.count ? Int32(ctxCount - 1 + i) : 0
						tp[o] = i < candidate.count ? candidate[i] : 0
						mp[o] = i < candidate.count ? 1 : 0
					}
				}
				guard let input = try? MLDictionaryFeatureProvider(dictionary: [
					"tokens": tokens, "score_positions": positions, "target_ids": targets,
					"score_mask": mask, "next_positions": next
				]), let out = try? m.prediction(from: input),
				   let scores = out.featureValue(for: "candidate_log_probs")?.multiArrayValue,
				   let values = readVector(scores, count: B) else { return nil }
				for b in 0..<B { result[start + b] += values[b] }
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
		guard let arr = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: L)], dataType: .int32),
			  let positions = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: Self.scoreSlots)], dataType: .int32),
			  let targets = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: Self.scoreSlots)], dataType: .int32),
			  let mask = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: Self.scoreSlots)], dataType: .float32),
			  let next = try? MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: 1)], dataType: .int32)
		else { return nil }
		let p = arr.dataPointer.bindMemory(to: Int32.self, capacity: B * L)
		for b in 0..<B {
			for i in 0..<L { p[b * L + i] = i < rows[b].count ? rows[b][i] : 0 }
		}
		memset(positions.dataPointer, 0, positions.count * MemoryLayout<Int32>.size)
		memset(targets.dataPointer, 0, targets.count * MemoryLayout<Int32>.size)
		memset(mask.dataPointer, 0, mask.count * MemoryLayout<Float>.size)
		let np = next.dataPointer.bindMemory(to: Int32.self, capacity: B)
		for b in 0..<B { np[b] = Int32(rows[b].count - 1) }
		guard let input = try? MLDictionaryFeatureProvider(dictionary: [
				"tokens": arr, "score_positions": positions, "target_ids": targets,
				"score_mask": mask, "next_positions": next
			]),
			  let out = try? m.prediction(from: input),
			  let logits = out.featureValue(for: "next_logits")?.multiArrayValue,
			  logits.shape.count == 2, logits.shape[0].intValue == B else { return nil }
		let V = logits.shape[1].intValue
		guard V > 0 else { return nil }
		let s0 = logits.strides[0].intValue
		let s1 = logits.strides[1].intValue
		var result = [[Float]](repeating: [], count: B)
		func extract<T: BinaryFloatingPoint>(_ lp: UnsafeBufferPointer<T>) {
			for b in 0..<B {
				let base = b * s0
				var row = [Float](repeating: 0, count: V)
				var maxV = -Float.infinity
				for v in 0..<V { row[v] = Float(lp[base + v * s1]); maxV = max(maxV, row[v]) }
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

/// Read a rank-1 Core ML output without assuming FP16/FP32 or dense element size.
private func readVector(_ array: MLMultiArray, count: Int) -> [Double]? {
	guard array.shape.count == 1, array.shape[0].intValue == count else { return nil }
	let stride = array.strides[0].intValue
	var result = [Double](repeating: 0, count: count)
	func copy<T: BinaryFloatingPoint>(_ values: UnsafeBufferPointer<T>) {
		for i in 0..<count { result[i] = Double(values[i * stride]) }
	}
	switch array.dataType {
	case .float16: array.withUnsafeBufferPointer(ofType: Float16.self) { copy($0) }
	case .float32: array.withUnsafeBufferPointer(ofType: Float.self) { copy($0) }
	case .double:  array.withUnsafeBufferPointer(ofType: Double.self) { copy($0) }
	default: return nil
	}
	return result
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

	/// The n-1 rescue's forward term, batched: all alternative contexts ride ONE
	/// Core ML dispatch (vs the default protocol implementation's call-per-context).
	/// N-gram lookups stay per-context — they're microseconds. Degrades to pure
	/// n-gram when the model isn't resident, same as `logProbs`. `lastSplit` is
	/// deliberately untouched: it belongs to the candidate-table logging in rank().
	func logProbs(of word: String, underContexts contexts: [[String]]) -> [Double] {
		let g = contexts.map { ngram.logProbs([word], context: $0).first ?? -.infinity }
		guard let n = neural.scores(of: word, underContexts: contexts) else { return g }
		return zip(n, g).map { wNeural * $0 + wNgram * $1 }
	}
}

// MARK: - UnigramScorer: tokenizer + n-gram prior (Tier 1)

/// Lightweight language prior using SentencePiece piece scores blended with the n-gram
/// — no CoreML, no model weights resident in memory (~200 KB tokenizer piece table).
///
/// Sets `scoresArbitraryWords = true`, enabling the autocorrect margin gate on every
/// device including iPhone 13: OOV strings receive a meaningful log-probability
/// from the Viterbi piece sum instead of the n-gram's flat OOV floor, so slang and
/// names survive correction without needing to be in the lexicon.
///
/// The n-gram component provides a weak context signal (corpus bigrams/trigrams +
/// user personal bigrams/trigrams) that improves suggestion ranking on Tier 1 devices.
/// The feedback-loop fix lives in NgramScorer: its unigram backoff now zeros personal
/// counts for OOV strings, so frequently-mistyped words outside the corpus lexicon
/// can no longer accumulate a score that suppresses their own autocorrection.
///
/// Features that require STRONG contextual scoring (prev-word rescue, next-word beam
/// search) must still gate on `neuralLM?.isReady`, not on `scorer.scoresArbitraryWords`.
final class UnigramScorer: LanguageScorer {
	private let tokenizer: SPTokenizer
	private let ngram: NgramScorer
	private let wUni: Double
	private let wNgram: Double

	var isReady: Bool { true }
	var scoresArbitraryWords: Bool { true }

	init(tokenizer: SPTokenizer, ngram: NgramScorer, uniWeight: Double = 0.25, ngramWeight: Double = 0.75) {
		self.tokenizer = tokenizer
		self.ngram = ngram
		self.wUni = uniWeight
		self.wNgram = ngramWeight
	}

	func logProbs(_ candidates: [String], context: [String]) -> [Double] {
		let g = ngram.logProbs(candidates, context: context)
		return candidates.enumerated().map { i, word in
			let u = Double(tokenizer.logProb(word.lowercased()))
			return wUni * u + wNgram * g[i]
		}
	}
}
