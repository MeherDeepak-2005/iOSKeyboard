import Foundation

// NgramScorer: the shipped n-gram prior — extracted from Keyboardengine.swift.

final class NgramScorer {
	private let user: UserModel
	private var data: LangData?
	private var resolveID: (String) -> Int32? = { _ in nil }
	/// Used in the unigram fallback to distinguish corpus words from true OOV strings.
	/// Weak to avoid a retain cycle (engine owns both); nil only before attach() fires.
	private weak var lexicon: Lexicon?
	/// Σ corpus freq + V (add-one smoothing mass), for the unigram backoff. 1 until
	/// attach() so the pre-attach fallback stays a finite constant, never log(0).
	private var corpusTotal = 1.0
	/// Personal evidence is deliberately a bounded tie-breaker. A one-off use must not
	/// turn into a near-certain unigram or context prediction.
	private let minPersonalEvidence = 3
	private let minNovelPredictionEvidence = 5

	init(user: UserModel) { self.user = user }
	func attach(data: LangData?, resolveID: @escaping (String) -> Int32?, lexicon: Lexicon) {
		self.data = data
		self.resolveID = resolveID
		self.lexicon = lexicon
		if let data {
			var sum = 0.0
			for id in 0..<data.wordCount { sum += Double(data.freq(id)) }
			corpusTotal = sum + Double(data.wordCount)
		}
	}

	func logProbs(_ candidates: [String], context: [String]) -> [Double] {
		let ctx = context.map { $0.lowercased() }
		return score(candidates.map { $0.lowercased() }, context: ctx)
	}

	/// log P(a | ctx) + log P(b | ctx + a) — the two-word prior a split correction
	/// ("alot" → "a lot") is scored with. The n-gram counts handle word pairs
	/// natively where the single-candidate seam would floor a spaced string.
	func pairLogProb(_ a: String, _ b: String, context: [String]) -> Double {
		let ctx = context.map { $0.lowercased() }
		let la = a.lowercased()
		return score([la], context: ctx)[0]
			+ score([b.lowercased()], context: ctx + [la])[0]
	}

	private func score(_ words: [String], context: [String]) -> [Double] {
		let ids = words.map(resolveID)
		let requestedIDs = ids.compactMap { $0 }
		let n = context.count
		let biStats = n >= 1
			? resolveID(context[n - 1]).flatMap { data?.bigramCounts(after: $0, words: requestedIDs) }
			: nil
		let triStats: (total: Int, types: Int, counts: [Int32: Int])? = {
			guard n >= 2, let first = resolveID(context[n - 2]),
				  let second = resolveID(context[n - 1]) else { return nil }
			return data?.trigramCounts(after: first, second, words: requestedIDs)
		}()

		// Witten-Bell interpolation. Every order contributes continuously instead of
		// the old 1.0/0.4/0.16 branch constants abruptly discarding the backoff model.
		// With complete successor tables, T is the true number of observed types.
		return words.enumerated().map { index, word in
			let id = ids[index]
			let unigram: Double
			if let id, let data {
				unigram = (Double(data.freq(Int(id))) + 1) / corpusTotal
			} else if lexicon?.contains(word) == true {
				unigram = 50.0 / corpusTotal
			} else {
				unigram = 0.5 / corpusTotal
			}
			// Interpolate every row that is scored in a known context — including OOV
			// rows (id == nil, count 0). eval_harness.py's logprob() has always done
			// this ("including when the target continuation was not observed"), and the
			// correction margins were calibrated there. Skipping the discount for OOV
			// rows left the typed string on a context-FREE floor while every unseen
			// candidate paid the Witten-Bell (1-w) discount, so rescue margins shrank
			// exactly when context was known: live 2026-07-20, "coeevitjkn" fired with
			// empty context but stalled below the 3.0 gate after "definitely decided".
			var probability = unigram
			if let biStats {
				probability = interpolate(total: biStats.total, types: biStats.types,
					count: id.flatMap { biStats.counts[$0] } ?? 0, backoff: probability)
			}
			if let triStats {
				probability = interpolate(total: triStats.total, types: triStats.types,
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

	private func interpolate(total rawTotal: Int, types rawTypes: Int,
							 count rawCount: Int, backoff: Double) -> Double {
		let total = Double(rawTotal)
		let types = Double(rawTypes)
		guard total > 0, types > 0 else { return backoff }
		let count = Double(rawCount)
		let observedWeight = total / (total + types)
		return observedWeight * (count / total) + (1 - observedWeight) * backoff
	}

	private func personalBoost(_ count: Int, weight: Double) -> Double {
		guard count >= minPersonalEvidence else { return 0 }
		return weight * log1p(Double(count - minPersonalEvidence + 1))
	}

	/// Next-word predictions from the combined counts (trigram first, then bigram).
	/// Returns more than the bar shows so the engine can filter before truncating.
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
	private func merged(_ base: [(word: Int32, count: Int)]?, _ userCounts: [String: Int]) -> [String] {
		// Corpus entries are the foundation; user counts only BOOST corpus words.
		// OOV strings (typos, adopted words, contact names) are excluded — they must
		// not surface in next-word predictions just because the user typed them recently.
		var m: [String: Int] = [:]
		for e in base ?? [] { m[data?.word(Int(e.word)) ?? "", default: 0] += e.count }
		for (w, c) in userCounts where lexicon?.isStaticWord(w) == true {
			if m[w] != nil, c >= minPersonalEvidence {
				m[w, default: 0] += min(c - minPersonalEvidence + 1, 8)
			} else if c >= minNovelPredictionEvidence {
				m[w] = min(c - minNovelPredictionEvidence + 1, 8)
			}
		}
		m[""] = nil
		return m.sorted { $0.value > $1.value }.map(\.key)
	}
}
