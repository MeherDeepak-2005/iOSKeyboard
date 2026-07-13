import Foundation

// NgramScorer: the shipped n-gram prior — extracted from Keyboardengine.swift.

final class NgramScorer: LanguageScorer {
	private let user: UserModel
	private var data: LangData?
	private var resolveID: (String) -> Int32? = { _ in nil }

	init(user: UserModel) { self.user = user }
	var isReady: Bool { true }        // mmap opens with the engine's init barrier
	var scoresArbitraryWords: Bool { false }

	func attach(data: LangData?, resolveID: @escaping (String) -> Int32?) {
		self.data = data
		self.resolveID = resolveID
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
		return log(0.16 * Double(uc + 1) / Double(total + distinct + 1))      // 0.4^2 backoff
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
		return user.topUnigrams(limit)
	}
	private func merged(_ base: [(word: Int32, count: Int)]?, _ userCounts: [String: Int]) -> [String] {
		var m = userCounts
		for e in base ?? [] { m[data?.word(Int(e.word)) ?? "", default: 0] += e.count }
		m[""] = nil
		return m.sorted { $0.value > $1.value }.map(\.key)
	}
}

