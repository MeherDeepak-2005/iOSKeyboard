import Foundation

nonisolated enum NgramSmoothing: String, Codable, CaseIterable {
    case modifiedKneserNey, wittenBell, frequencyBackoff
}

/// iOS façade: normalization, immutable personal views and tie-order transport.
/// Counts, smoothing, context lookup, sequence scoring and merging run in C++.
final class NgramScorer {
    let backend: DecoderCoreBackend
    let smoothing: NgramSmoothing
    private let user: UserModel
    private weak var lexicon: Lexicon?
    private var native: KBNativeLanguageModel?
    private let emptyView = KBGenerationLexicon(packed: nil, base: KBMutableTrie(), supplementary: KBMutableTrie(),
        personal: KBMutableTrie(), snapshot: KBGenerationSnapshot(boosts: [:], blockedWords: []))
    private(set) var nativeScoringFailure: String?
#if DEBUG || KB_REFERENCE_DECODER_YES
    private var reference: SwiftNgramScorer?
#endif
    init(user: UserModel, backend: DecoderCoreBackend = .cpp, smoothing: NgramSmoothing = .wittenBell) {
        self.user = user; self.backend = backend; self.smoothing = smoothing
#if DEBUG || KB_REFERENCE_DECODER_YES
        if backend == .swiftReference { reference = SwiftNgramScorer(user: user, backend: .swiftReference, smoothing: smoothing) }
#endif
    }
    func attach(data: LangData?, resolveID: @escaping (String) -> Int32?, lexicon: Lexicon) {
        self.lexicon = lexicon
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { reference.attach(data: data, resolveID: resolveID, lexicon: lexicon); return }
#endif
        native = KBNativeLanguageModel(packed: data?.nativeCandidateLexicon, smoothing: smoothing.rawValue)
    }
    func makeSharedEngine(lexicon: KBGenerationLexicon, policy: [NSNumber], penalties: [String: NSNumber], profile: Bool = false) -> KBSharedEngine? {
        guard let native else { return nil }
        return KBSharedEngine(lexicon: lexicon, model: native, policy: policy, penalties: penalties, profile: profile)
    }
    func logProbs(_ candidates: [String], context: [String]) -> [Double] {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { return reference.logProbs(candidates, context: context) }
#endif
        guard let native else { return candidates.map { _ in log(0.5) } }
        let result = native.scores(forWords: candidates.map { $0.lowercased() }, context: context.map { $0.lowercased() },
            personal: user.nativeCountsSnapshot(), lexicon: lexicon?.nativeGenerationView() ?? emptyView)
        return result.withUnsafeBytes { bytes in candidates.indices.map {
            bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Double>.size, as: Double.self)
        } }
    }
    func candidateLogProbs(_ words: [String], context: [String]) -> [Double] {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference {
            var result = reference.logProbs(words, context: context)
            for i in words.indices where words[i].contains(" ") {
                result[i] = reference.sequenceLogProb(words[i].split(separator: " ").map(String.init), context: context)
            }
            return result
        }
#endif
        guard let native else { return words.map { _ in log(0.5) } }
        let result = native.scores(forPhrases: words.map { $0.lowercased() }, context: context.map { $0.lowercased() },
            personal: user.nativeCountsSnapshot(), lexicon: lexicon?.nativeGenerationView() ?? emptyView)
        return result.withUnsafeBytes { b in words.indices.map { b.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self) } }
    }
    func pairLogProb(_ a: String, _ b: String, context: [String]) -> Double {
        sequenceLogProb([a, b], context: context)
    }
    func sequenceLogProb(_ words: [String], context: [String]) -> Double {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { return reference.sequenceLogProb(words, context: context) }
#endif
        guard let native else { return Double(words.count) * log(0.5) }
        return native.sequence(forWords: words.map { $0.lowercased() }, context: context.map { $0.lowercased() },
            personal: user.nativeCountsSnapshot(), lexicon: lexicon?.nativeGenerationView() ?? emptyView)
    }
    func nextWords(context: [String], limit: Int) -> [String] {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { return reference.nextWords(context: context, limit: limit) }
#endif
        guard let native, limit > 0 else { return [] }
        let context = context.map { $0.lowercased() }, personal = user.nativeCountsSnapshot()
        let tri = native.successors(forContext: context, personal: personal, trigram: true, limit: UInt(limit))
        let bi = native.successors(forContext: context, personal: personal, trigram: false, limit: UInt(limit))
        return KBNativeLanguageModel.nextWords(withTrigramWords: tri.words, counts: tri.counts,
            bigramWords: bi.words, counts: bi.counts, limit: UInt(limit))
    }
}

#if DEBUG || KB_REFERENCE_DECODER_YES
final class SwiftNgramScorer {
	private let user: UserModel
	let backend: DecoderCoreBackend
    let smoothing: NgramSmoothing
    private struct Context {
        let total: Double
        let discountMass: Double
        let counts: [Int32: Double]
        init(_ context: ModifiedKneserNeyModel.Context) {
            total = Double(context.total)
            discountMass = context.discountMass
            counts = context.counts
        }
        init(total: Double, discountMass: Double, counts: [Int32: Double]) {
            self.total = total; self.discountMass = discountMass; self.counts = counts
        }
    }
	private(set) var nativeScoringFailure: String?
	private var data: LangData?
	private var resolveID: (String) -> Int32? = { _ in nil }
	/// Used to gate personal evidence and next-word candidates to known words.
	/// Weak to avoid a retain cycle (engine owns both); nil only before attach() fires.
	private weak var lexicon: Lexicon?
	/// Total distinct bigram types plus one unknown bucket. 1 until attach().
	private var corpusTotal = 1.0
    private var model: ModifiedKneserNeyModel?
	/// Personal evidence is deliberately a bounded tie-breaker. A one-off use must not
	/// turn into a near-certain unigram or context prediction.
	private let minPersonalEvidence = 3
	private let minNovelPredictionEvidence = 5
	/// A single corpus observation can refine the score of an already plausible fuzzy
	/// candidate, but is not enough evidence to inject a distant next-word candidate.
	/// Compact backoff LMs normally prune singleton continuations; enforcing that rule
	/// in the prediction funnel also protects old packs that still contain them.
	private static let minCorpusContinuationEvidence = 2

	// MIGRATION: planned CPP_CORE | stage=search | target=NgramScorer
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	init(user: UserModel, backend: DecoderCoreBackend = .cpp,
         smoothing: NgramSmoothing = .wittenBell) {
		self.user = user
		self.backend = backend
        self.smoothing = smoothing
	}
	// MIGRATION: planned SPLIT | stage=search | target=NgramModelView
	// MIGRATION-SPLIT: SWIFT_IOS supplies epoch-tagged immutable vocabulary/personalization views; CPP_CORE attaches them without per-word Swift callbacks.
	func attach(data: LangData?, resolveID: @escaping (String) -> Int32?, lexicon: Lexicon) {
		self.data = data
		self.resolveID = resolveID
		self.lexicon = lexicon
        model = smoothing == .modifiedKneserNey ? data?.modifiedKneserNey : nil
        if smoothing == .modifiedKneserNey {
            corpusTotal = model?.unigramTotal ?? 1
        } else if let data {
            corpusTotal = (0..<data.wordCount).reduce(Double(data.wordCount)) { $0 + Double(data.freq($1)) }
            if smoothing == .frequencyBackoff { corpusTotal += 0.5 }
        }

	}

	// MIGRATION: planned CPP_CORE | stage=search | target=NgramScorer
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func logProbs(_ candidates: [String], context: [String]) -> [Double] {
		let ctx = context.map { $0.lowercased() }
		return score(candidates.map { $0.lowercased() }, context: ctx)
	}

	/// log P(a | ctx) + log P(b | ctx + a) — the two-word prior a split correction
	/// ("alot" → "a lot") is scored with. The n-gram counts handle word pairs
	/// natively where the single-candidate seam would floor a spaced string.
	// MIGRATION: planned CPP_CORE | stage=search | target=NgramScorer
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func pairLogProb(_ a: String, _ b: String, context: [String]) -> Double {
		let ctx = context.map { $0.lowercased() }
		let la = a.lowercased()
		return score([la], context: ctx)[0]
			+ score([b.lowercased()], context: ctx + [la])[0]
	}

	// MIGRATION: planned CPP_CORE | stage=search | target=NgramScorer
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func sequenceLogProb(_ words: [String], context: [String]) -> Double {
		var ctx = context.map { $0.lowercased() }
		var total = 0.0
		for word in words {
			let lower = word.lowercased()
			total += score([lower], context: ctx)[0]
			ctx.append(lower)
		}
		return total
	}

	// MIGRATION: planned CPP_CORE | stage=search | target=NgramScorer
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func score(_ words: [String], context: [String]) -> [Double] {
		let ids = words.map(resolveID)
        let n = context.count
        let biStats: Context? = n >= 1 ? resolveID(context[n - 1]).flatMap { previous in
            if smoothing == .modifiedKneserNey { return model?.bigrams[previous].map(Context.init) }
            return prepare(data?.bigrams(after: previous))
        } : nil
        let triStats: Context? = {
            guard n >= 2, let first = resolveID(context[n - 2]),
                  let second = resolveID(context[n - 1]),
                  let hit = data?.trigrams(after: first, second) else { return nil }
            if smoothing == .modifiedKneserNey, let model {
                return Context(ModifiedKneserNeyModel.Context(entries: hit.entries, discounts: model.trigramDiscounts))
            }
            return prepare(hit)
        }()


        if backend == .cpp {
            var rows: [Double] = []
            rows.reserveCapacity(words.count * 6)
            for (index, word) in words.enumerated() {
                let id = ids[index]
                let known = lexicon?.contains(word) == true
                let mass: Double
                mass = unigramMass(id)
                rows.append(contentsOf: [mass,
                    Double(id.flatMap { biStats?.counts[$0] } ?? 0),
                    Double(id.flatMap { triStats?.counts[$0] } ?? 0),
                    Double(known ? user.uniCount(word) : 0),
                    Double(n >= 1 ? user.biLookup(context[n - 1], word).count : 0),
                    Double(n >= 2 ? user.triLookup(context[n - 2] + " " + context[n - 1], word).count : 0)])
            }
            do {
                let buffer = rows.withUnsafeBytes { Data($0) }
                let scores = try KBLanguageScorer.scores(forRows: buffer, corpusTotal: corpusTotal,
                    bigramTotal: Double(biStats?.total ?? 0), bigramDiscountMass: biStats?.discountMass ?? 0,
                    trigramTotal: Double(triStats?.total ?? 0), trigramDiscountMass: triStats?.discountMass ?? 0)
                guard scores.count == words.count * MemoryLayout<Double>.size else {
                    nativeScoringFailure = "native score shape mismatch"
                    return referenceScores(words, context: context, ids: ids, biStats: biStats, triStats: triStats)
                }
                return scores.withUnsafeBytes { bytes in words.indices.map {
                    bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Double>.size, as: Double.self)
                } }
            } catch { nativeScoringFailure = "native scoring fallback: \(error)" }
        }
        return referenceScores(words, context: context, ids: ids, biStats: biStats, triStats: triStats)
    }

    private func referenceScores(_ words: [String], context: [String], ids: [Int32?],
        biStats: Context?, triStats: Context?) -> [Double] {
        let n = context.count

        // Prepared evidence includes the selected estimator's interpolation weights.
        return words.enumerated().map { index, word in
            let id = ids[index]
            let unigram = unigramMass(id) / corpusTotal
			var probability = unigram
			if let biStats {
				probability = interpolate(total: biStats.total, discountMass: biStats.discountMass,
					count: id.flatMap { biStats.counts[$0] } ?? 0, backoff: probability)
			}
			if let triStats {
				probability = interpolate(total: triStats.total, discountMass: triStats.discountMass,
					count: id.flatMap { triStats.counts[$0] } ?? 0, backoff: probability)
			}
			let unigramPersonal = lexicon?.contains(word) == true ? user.uniCount(word) : 0
			let biPersonal = n >= 1 ? user.biLookup(context[n - 1], word).count : 0
			let triPersonal = n >= 2
				? user.triLookup(context[n - 2] + " " + context[n - 1], word).count
				: 0
			return log(max(probability, Double.leastNonzeroMagnitude))
				+ personalBoost(unigramPersonal, weight: 0.10)
				+ personalBoost(biPersonal, weight: 0.22)
				+ personalBoost(triPersonal, weight: 0.28)
		}
	}

    private func unigramMass(_ id: Int32?) -> Double {
        if smoothing == .modifiedKneserNey {
            return id.flatMap { model?.unigrams[$0] }.map(Double.init) ?? 0.5
        }
        guard let id, let data else { return 0.5 }
        return Double(data.freq(Int(id))) + 1
    }

    /// All three estimators use the same native interpolation transport. For WB,
    /// prepared counts incorporate its original sparse-context floor of eight.
    private func prepare(_ hit: (total: Int, entries: [(word: Int32, count: Int)])?) -> Context? {
        guard let hit, hit.total > 0, !hit.entries.isEmpty else { return nil }
        if smoothing == .wittenBell {
            let n = Double(hit.total), t = Double(hit.entries.count)
            let weight = n / (n + t) * n / (n + 8)
            // Pruned contexts send their unretained mass to the backoff (matches LanguageModel.cpp).
            let retained = Double(min(hit.entries.reduce(0) { $0 + $1.count }, hit.total))
            return Context(total: n, discountMass: n - weight * retained,
                counts: Dictionary(uniqueKeysWithValues: hit.entries.map { ($0.word, weight * Double($0.count)) }))
        }
        // Fixed prototype strength=8; no fitting against validation outcomes.
        let n = hit.entries.reduce(0.0) { $0 + Double($1.count) }
        let prior = Double(hit.entries.count) + 8
        return Context(total: n + prior, discountMass: prior,
            counts: Dictionary(uniqueKeysWithValues: hit.entries.map { ($0.word, Double($0.count)) }))
    }

    private func interpolate(total: Double, discountMass: Double,
                             count: Double, backoff: Double) -> Double {
        guard total > 0 else { return backoff }
        return count / Double(total) + discountMass / Double(total) * backoff
    }

	// MIGRATION: planned CPP_CORE | stage=search | target=NgramScorer
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func personalBoost(_ count: Int, weight: Double) -> Double {
		guard count >= minPersonalEvidence else { return 0 }
		return weight * log1p(Double(count - minPersonalEvidence + 1))
	}

	/// Next-word predictions from the combined counts (trigram first, then bigram).
	/// Returns more than the bar shows so the engine can filter before truncating.
	// MIGRATION: planned CPP_CORE | stage=search | target=NgramScorer
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func nextWords(context: [String], limit: Int) -> [String] {
		let ctx = context.map { $0.lowercased() }
		let n = ctx.count
		var out: [String] = []
		func appendUnique(_ words: [String]) {
			for word in words where !out.contains(word) {
				out.append(word)
				if out.count == limit { return }
			}
		}
		if n >= 2 {
			let base = (resolveID(ctx[n - 2]), resolveID(ctx[n - 1]))
			let hit = (base.0 != nil && base.1 != nil)
				? data?.trigrams(after: base.0!, base.1!, limit: max(64, limit * 4)) : nil
			appendUnique(merged(hit?.entries, user.triDist(ctx[n - 2] + " " + ctx[n - 1])))
		}
		if n >= 1, out.count < limit {
			let hit = resolveID(ctx[n - 1]).flatMap {
				data?.bigrams(after: $0, limit: max(64, limit * 4))
			}
			appendUnique(merged(hit?.entries, user.biDist(ctx[n - 1])))
		}
		return Array(out.prefix(limit))
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=NgramScorer
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func merged(_ base: [(word: Int32, count: Int)]?, _ userCounts: [String: Int]) -> [String] {
		// Corpus entries are the foundation; user counts only BOOST corpus words.
		// OOV strings (typos, adopted words, contact names) are excluded — they must
		// not surface in next-word predictions just because the user typed them recently.
		var m: [String: Int] = [:]
		for e in base ?? [] where e.count >= Self.minCorpusContinuationEvidence {
			m[data?.word(Int(e.word)) ?? "", default: 0] += e.count
		}
		for (w, c) in userCounts where lexicon?.isStaticWord(w) == true {
			if m[w] != nil, c >= minPersonalEvidence {
				m[w, default: 0] += min(c - minPersonalEvidence + 1, 8)
			} else if c >= minNovelPredictionEvidence {
				m[w] = min(c - minNovelPredictionEvidence + 1, 8)
			}
		}
		m[""] = nil
		return m.sorted { $0.value == $1.value ? $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) : $0.value > $1.value }.map(\.key)
	}
}

#endif
