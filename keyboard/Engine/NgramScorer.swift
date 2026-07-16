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
		if n >= 2 {
			let key = context[n - 2] + " " + context[n - 1]
			var (c, t) = user.triLookup(key, w)
			if let wid, let a = resolveID(context[n - 2]), let b = resolveID(context[n - 1]),
			   let hit = data?.trigrams(after: a, b) {
				t += hit.total
				c += hit.entries.first(where: { $0.word == wid })?.count ?? 0
			}
			if c > 0, t > 0 { return log(Double(c) / Double(t)) }
		}
		if n >= 1 {
			let p = context[n - 1]
			var (c, t) = user.biLookup(p, w)
			if let wid, let a = resolveID(p), let hit = data?.bigrams(after: a) {
				t += hit.total
				c += hit.entries.first(where: { $0.word == wid })?.count ?? 0
			}
			if c > 0, t > 0 { return log(0.4 * Double(c) / Double(t)) }       // backoff weight
		}
		let (uc, total, distinct) = user.uniBackoff(w)
		// OOV words (not in the corpus lexicon) must not accumulate a score from repeated
		// misspellings: "teh" typed 50 times should never outscore "the". Zero the personal
		// count for strings outside the lexicon so only corpus words get a user boost here.
		// Adopted words (dynamic trie) do pass contains() and keep their earned counts.
		let effectiveUC = (lexicon?.contains(w) == true) ? uc : 0
		// Unigram backoff = the BEST of a personal estimate and a corpus estimate.
		// The old form, 0.16·(uc+1)/(total+distinct+1), floored at 0.16 on a FRESH
		// install (empty user model) — ABOVE every real bigram hit — so unseen words
		// outscored seen ones and real-word autocorrect was inert until the personal
		// model filled in ("what's thus" kept "thus"). The personal term now carries
		// no +1 (it is zero until the user actually types the word), and the corpus
		// term is frequency-differentiated the way the eval harness always assumed.
		let pUser = Double(effectiveUC) / Double(total + distinct + 1)
		let pCorpus: Double
		if let wid, let data {
			pCorpus = (Double(data.freq(Int(wid))) + 1) / corpusTotal
		} else if lexicon?.contains(w) == true {
			pCorpus = 50.0 / corpusTotal      // adopted/contact word: importSupplementaryLexicon's freq
		} else {
			pCorpus = 0.5 / corpusTotal       // true OOV: below every real word
		}
		return log(0.16 * max(pUser, pCorpus))
	}

	/// Next-word predictions from the combined counts (trigram first, then bigram).
	/// Returns more than the bar shows so the engine can filter before truncating.
	func nextWords(context: [String], limit: Int) -> [String] {
		let ctx = context.map { $0.lowercased() }
		let n = ctx.count
		if n >= 2 {
			let base = (resolveID(ctx[n - 2]), resolveID(ctx[n - 1]))
			let hit = (base.0 != nil && base.1 != nil) ? data?.trigrams(after: base.0!, base.1!) : nil
			let top = merged(hit?.entries, user.triDist(ctx[n - 2] + " " + ctx[n - 1])).prefix(limit)
			if !top.isEmpty { return Array(top) }
		}
		if n >= 1 {
			let hit = resolveID(ctx[n - 1]).flatMap { data?.bigrams(after: $0) }
			let top = merged(hit?.entries, user.biDist(ctx[n - 1])).prefix(limit)
			if !top.isEmpty { return Array(top) }
		}
		// Filter to corpus words — same guarantee as merged(): OOV strings stay out of
		// next-word predictions even in the context-free fallback path.
		return Array(user.topUnigrams(limit * 3).filter { lexicon?.isStaticWord($0) == true }.prefix(limit))
	}
	private func merged(_ base: [(word: Int32, count: Int)]?, _ userCounts: [String: Int]) -> [String] {
		// Corpus entries are the foundation; user counts only BOOST corpus words.
		// OOV strings (typos, adopted words, contact names) are excluded — they must
		// not surface in next-word predictions just because the user typed them recently.
		var m: [String: Int] = [:]
		for e in base ?? [] { m[data?.word(Int(e.word)) ?? "", default: 0] += e.count }
		for (w, c) in userCounts where lexicon?.isStaticWord(w) == true { m[w, default: 0] += c }
		m[""] = nil
		return m.sorted { $0.value > $1.value }.map(\.key)
	}
}

