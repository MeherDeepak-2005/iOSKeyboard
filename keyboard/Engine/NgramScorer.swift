import Foundation

// NgramScorer: the shipped n-gram prior — extracted from Keyboardengine.swift.

final class NgramScorer: LanguageScorer {
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
	var isReady: Bool { true }        // mmap opens with the engine's init barrier
	var scoresArbitraryWords: Bool { false }

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
		return candidates.map { logProb($0.lowercased(), context: ctx) }
	}

	/// log P(a | ctx) + log P(b | ctx + a) — the two-word prior a split correction
	/// ("alot" → "a lot") is scored with. The n-gram counts handle word pairs
	/// natively where the single-candidate seam would floor a spaced string.
	func pairLogProb(_ a: String, _ b: String, context: [String]) -> Double {
		let ctx = context.map { $0.lowercased() }
		let la = a.lowercased()
		return logProb(la, context: ctx) + logProb(b.lowercased(), context: ctx + [la])
	}

	private func logProb(_ w: String, context: [String]) -> Double {
		let wid = resolveID(w)
		let n = context.count
		var triPersonal = 0
		if n >= 2 {
			let key = context[n - 2] + " " + context[n - 1]
			triPersonal = user.triLookup(key, w).count
			if let wid, let a = resolveID(context[n - 2]), let b = resolveID(context[n - 1]),
			   let hit = data?.trigrams(after: a, b) {
				let c = hit.entries.first(where: { $0.word == wid })?.count ?? 0
				if c > 0, hit.total > 0 {
					return log(Double(c) / Double(hit.total)) + personalBoost(triPersonal, weight: 0.28)
				}
			}
		}
		var biPersonal = 0
		if n >= 1 {
			let p = context[n - 1]
			biPersonal = user.biLookup(p, w).count
			if let wid, let a = resolveID(p), let hit = data?.bigrams(after: a) {
				let c = hit.entries.first(where: { $0.word == wid })?.count ?? 0
				if c > 0, hit.total > 0 {
					return log(0.4 * Double(c) / Double(hit.total))
						+ personalBoost(biPersonal, weight: 0.22)
						+ personalBoost(triPersonal, weight: 0.28)
				}
			}
		}
		// The corpus unigram remains the base probability. Personal usage adds only a
		// small logarithmic lift after repeated evidence; it never replaces the corpus
		// estimate with uc/userTotal, which made one-off words dominate the strip.
		let pCorpus: Double
		if let wid, let data {
			pCorpus = (Double(data.freq(Int(wid))) + 1) / corpusTotal
		} else if lexicon?.contains(w) == true {
			pCorpus = 50.0 / corpusTotal      // adopted/contact word: importSupplementaryLexicon's freq
		} else {
			pCorpus = 0.5 / corpusTotal       // true OOV: below every real word
		}
		let unigramPersonal = lexicon?.contains(w) == true ? user.uniCount(w) : 0
		return log(0.16 * pCorpus)
			+ personalBoost(unigramPersonal, weight: 0.10)
			+ personalBoost(biPersonal, weight: 0.22)
			+ personalBoost(triPersonal, weight: 0.28)
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
			let hit = (base.0 != nil && base.1 != nil) ? data?.trigrams(after: base.0!, base.1!) : nil
			appendUnique(merged(hit?.entries, user.triDist(ctx[n - 2] + " " + ctx[n - 1])))
		}
		if n >= 1, out.count < limit {
			let hit = resolveID(ctx[n - 1]).flatMap { data?.bigrams(after: $0) }
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
