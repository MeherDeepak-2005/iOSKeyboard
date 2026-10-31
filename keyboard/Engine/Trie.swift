// IMPLEMENTED: C++ mutable storage/search and search-funding math are primary.
// Swift retains boundary records and Debug/test references for parity.
import Foundation

// Trie: weighted fuzzy search (Damerau + touch taps) + Candidate.

nonisolated struct Candidate { let word: String; let cost: Double; let logFreq: Double }

nonisolated final class PriorNode {
	fileprivate var children: [(UInt8, PriorNode)] = []
	fileprivate(set) var bonus: Double = 0
	fileprivate(set) var terminalBonus: Double = 0
	func child(_ ch: UInt8) -> PriorNode? {
		for (c, n) in children where c == ch { return n }
		return nil
	}
}

/// Context-conditioned search prior — the NN-LM-in-the-trie / Neural-Search-Space seam.
/// Built from the words the language model deems likely to come next, it grants the trie
/// walk EXTRA edit budget along the prefixes those words share, so a context-plausible word
/// just outside the base edit radius is still GENERATED (not merely re-ranked), and a
/// spatially-cheap branch that leads to no plausible word can be pruned. The likely-word
/// source is pluggable: the shipped n-gram now, the GRU's next-word distribution once its
/// Core ML model is bundled — the search is identical, only the prior improves. Budget only
/// ever RELAXES (bonus ≥ 0, capped ≈ one edit), so a nil prior reproduces today's exact
/// pure-channel search and this can never drop a candidate the fixed radius already found.
nonisolated final class TrieSearchPrior {
	fileprivate let root = PriorNode()
    private let funded: [(word: String, bonus: Double)]
	/// The LM widens the search but can never turn a spatially-absurd word into a hit.
	static let maxBonus = 1.6

	/// `words` are LM-ranked likely continuations (best first). Each lays a RANK-decayed bonus
	/// along its whole prefix path. Used by the n-gram fallback path, which has no probabilities —
	/// only an ordering — so it funds the top words generously regardless of the LM's confidence.
    convenience init(likelyWords words: [String], weight: ((Int) -> Double)? = nil) {
        let bonuses = weight.map { f in words.indices.map { min(Self.maxBonus, f($0)) } }
            ?? KBCandidateGenerator.rankFundingBonuses(withCount: UInt(words.count)).map(\.doubleValue)
        self.init(funded: zip(words, bonuses).map { ($0.0, $0.1) })
    }

	/// Absolute log-probability budget heuristic, independent of shortlist size/order.
	/// A word at or below the floor receives no extra budget. This bounded linear ramp
	/// is a tunable search policy, not a calibrated confidence estimate. Removing other
	/// words must never increase this word's funding.
	convenience init(scoredWords scored: [(word: String, logProbability: Double)],
		 logProbabilityFloor: Double = -12) {
        let bonuses = KBCandidateGenerator.probabilityFundingBonuses(
            scored.map { NSNumber(value: $0.logProbability) }, floor: logProbabilityFloor).map(\.doubleValue)
        self.init(funded: zip(scored, bonuses).map { ($0.0.word, $0.1) })
	}

	/// Lay each `(word, bonus)` along the word's whole prefix path; a shared prefix keeps the MAX
	/// bonus over the words through it, so common word-starts stay well-funded. Budget only ever
	/// RELAXES (bonus ≥ 0), so an empty list reproduces the exact pure-channel search.
	private init(funded: [(word: String, bonus: Double)]) {
        self.funded = funded.filter { $0.bonus > 0 }.map { ($0.word.lowercased(), $0.bonus) }
#if DEBUG || KB_REFERENCE_DECODER_YES
		for (word, bonus) in funded {
			guard bonus > 0 else { continue }
			var node = root
			for ch in word.lowercased().utf8 {
				let next: PriorNode
				if let existing = node.child(ch) { next = existing }
				else { let created = PriorNode(); node.children.append((ch, created)); next = created }
				next.bonus = max(next.bonus, bonus)
				node = next
			}
			node.terminalBonus = max(node.terminalBonus, bonus)
		}
#endif
	}

    /// Batched terminal funding for the neutral core. Prefix maxima are rebuilt
    /// there; terminal identity never borrows a descendant's traversal budget.
    func nativeFundingSnapshot() -> (words: [String], bonuses: [NSNumber]) {
        (funded.map(\.word), funded.map { NSNumber(value: $0.bonus) })
    }

	var isEmpty: Bool { funded.allSatisfy { $0.word.isEmpty } }
	func rootChild(_ ch: UInt8) -> PriorNode? { root.child(ch) }
}

// Shared channel constants must also exist in Release builds.
nonisolated enum TrieChannelCosts {
	// The weighted-DP costs and first-letter policy are shared with the static mmap
	// trie in LangData — both searches must produce byte-identical costs (and the
	// Python eval harness mirrors them). Internal, not private, for that reason.
	// Fitted on the tune half of tools/evaluation/autocorrect (27 Oct 2026); must equal
	// native SpatialModel.hpp. A dropped letter is a common slip, so a deletion costs less
	// than an extra typed letter.
	static let insCost = 1.6
	static let delCost = 1.1
	/// Adjacent-letter swap ("teh" → "the") — the single most common typo class.
	/// One cheap operation (OSA / restricted Damerau) instead of two full edits.
	static let transCost = 0.65
	/// A doubled letter typed once (posess → possess) or a letter typed twice (excell → excel):
	/// native `doubledDeletionCost` / `doubledInsertionCost`. Only the same letter on both sides.
	static let doubledDelCost = 0.3, doubledInsCost = 0.6
	static let minimumDeletionCost = min(delCost, doubledDelCost)
	/// A candidate letter the user did not type, after the candidate letter `previous` (0 at the
	/// start), where the typed letter at that point is `typed` (0 before the first); native `deletionCostAt`.
	static func deletionCost(_ letter: UInt8, after previous: UInt8, typed: UInt8) -> Double {
		letter == KB.apostrophe ? KB.apostropheSkipCost
			: letter == previous && letter == typed ? doubledDelCost : delCost
	}
	/// An extra typed letter after the typed letter `previous`, where the candidate letter at that
	/// point is `candidate` (0 before the first); native `insertionCostAt`.
	static func insertionCost(_ typed: UInt8, after previous: UInt8, candidate: UInt8) -> Double {
		typed == previous && typed == candidate ? doubledInsCost : insCost
	}
	static let firstLetterPenalty = 2.0             // 5+ letters, first key not adjacent
	static let adjacentFirstLetterPenalty = 1.0     // 5+ letters, neighbouring first key
	static let spellingFirstLetterPenalty = 2.0     // 5+ letters, vowel for vowel or c/k/s/z (as other keys)
	static let swappedFirstLetterPenalty = 0.75
	static let missingFirstLetterPenalty4 = 0.2, missingFirstLetterPenalty = 1.5
	static let firstLetterPenalty3 = 0.35, firstLetterPenalty4 = 0.2
	static func firstLetterPenaltyPolicy(
		typedLength: Int,
		candidateFirst: UInt8,
		typedFirst: UInt8,
		typedSecond: UInt8 = 0,
		candidateSecond: UInt8 = 0,
		spelling: Bool = true
	) -> Double {
		guard candidateFirst != typedFirst, typedLength > 2 else { return 0 }
		let swapped = typedSecond != 0 && candidateFirst == typedSecond && candidateSecond == typedFirst
		// A dropped first letter (bove → above): the candidate's second letter is the typed first.
		if typedLength >= 4, !swapped, candidateSecond == typedFirst {
			return typedLength == 4 ? missingFirstLetterPenalty4 : missingFirstLetterPenalty
		}
		if typedLength == 3 { return firstLetterPenalty3 }
		if typedLength == 4 { return firstLetterPenalty4 }
		if swapped { return swappedFirstLetterPenalty }
		// A spelling confusion (vowel for vowel, c/k, c/s, s/z: krust → crust) pays at most
		// spellingFirstLetterPenalty; row or diagonal neighbours (squared grid distance ≤ 1.3), as native.
		let other = spelling && KB.spellingConfusion(candidateFirst, typedFirst)
			? min(firstLetterPenalty, spellingFirstLetterPenalty) : firstLetterPenalty
		return KB.neighbouringKeys(candidateFirst, typedFirst) ? min(adjacentFirstLetterPenalty, other) : other
	}

}

/// Native mutable vocabulary façade. The independent Swift implementation is
/// available only to Debug/test builds and never shadows production mutations.
nonisolated final class Trie {
    let native = KBMutableTrie()
    let backend: DecoderCoreBackend
    static let insCost = TrieChannelCosts.insCost, delCost = TrieChannelCosts.delCost, transCost = TrieChannelCosts.transCost,
        firstLetterPenalty = TrieChannelCosts.firstLetterPenalty
    /// A neighbouring key typed before the word (vfell → fell); 3 = off. Native `extraLeadingKeyCost`.
    static let extraLeadingKeyCost = 1.6
    static func deletionCost(_ letter: UInt8, after previous: UInt8, typed: UInt8) -> Double {
        TrieChannelCosts.deletionCost(letter, after: previous, typed: typed)
    }
    static func insertionCost(_ typed: UInt8, after previous: UInt8, candidate: UInt8) -> Double {
        TrieChannelCosts.insertionCost(typed, after: previous, candidate: candidate)
    }
    static var minimumDeletionCost: Double { TrieChannelCosts.minimumDeletionCost }
#if DEBUG || KB_REFERENCE_DECODER_YES
    private let reference: SwiftTrie?
#endif
    init(backend: DecoderCoreBackend = .cpp) {
        self.backend = backend
#if DEBUG || KB_REFERENCE_DECODER_YES
        reference = backend == .swiftReference ? SwiftTrie() : nil
#else
        precondition(backend == .cpp, "Swift mutable reference requires a test build")
#endif
    }
    /// Mirrors native `firstLetterPenalty` (SpatialModel.cpp). Pass 0 when a letter is unknown.
    static func firstLetterPenaltyPolicy(typedLength: Int, candidateFirst: UInt8, typedFirst: UInt8,
                                         typedSecond: UInt8 = 0, candidateSecond: UInt8 = 0, spelling: Bool = true) -> Double {
        TrieChannelCosts.firstLetterPenaltyPolicy(typedLength: typedLength, candidateFirst: candidateFirst,
            typedFirst: typedFirst, typedSecond: typedSecond, candidateSecond: candidateSecond, spelling: spelling)
    }
    func insert(_ word: String, freq: Int, id: Int32 = -1) {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { reference.insert(word, freq: freq, id: id); return }
#endif
        native.insertWord(word, frequency: Int64(freq), wordID: id, characterCount: UInt(word.count))
    }
    func contains(_ word: String) -> Bool {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { return reference.contains(word) }
#endif
        return native.containsWord(word)
    }
    func hasPrefix(_ word: String) -> Bool {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { return reference.hasPrefix(word) }
#endif
        return native.hasPrefix(word)
    }
    func wordID(_ word: String) -> Int32? {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { return reference.wordID(word) }
#endif
        return native.wordID(forWord: word)?.int32Value
    }
    func logFreq(_ word: String) -> Double? {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { return reference.logFreq(word) }
#endif
        return native.logFrequency(forWord: word)?.doubleValue
    }
    func bump(_ word: String) {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { reference.bump(word); return }
#endif
        native.bumpWord(word)
    }
    func search(_ typed: String, maxCost: Double, taps: [KeyTap?]? = nil,
                prior: TrieSearchPrior? = nil) -> [Candidate] {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { return reference.search(typed, maxCost: maxCost, taps: taps, prior: prior) }
#endif
        let buffers = NativeTapBuffers(taps: taps, expectedCount: typed.utf8.count)
        let funding = prior?.nativeFundingSnapshot()
        do {
            return try native.search(word: typed, maxCost: maxCost,
                tapOffsets: buffers?.offsets, tapValidity: buffers?.validity,
                fundedWords: funding?.words, fundedBonuses: funding?.bonuses).map(Candidate.init(native:))
        } catch { return [] }
    }
    func completions(prefix: String, limit: Int) -> [Candidate] {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if let reference { return reference.completions(prefix: prefix, limit: limit) }
#endif
        guard limit > 0 else { return [] }
        return native.completions(forPrefix: prefix, limit: UInt(limit)).map(Candidate.init(native:))
    }
}

extension Candidate {
    init(native: KBChannelCandidate) {
        self.init(word: native.word, cost: native.cost, logFreq: native.logFrequency)
    }
    var native: KBChannelCandidate {
        KBChannelCandidate.make(word: word, cost: cost, logFrequency: logFreq)
    }
}

#if DEBUG || KB_REFERENCE_DECODER_YES
nonisolated final class SwiftTrie {
	private final class Node {
		// Compact child storage: a tiny inline-sorted array beats a Dictionary here —
		// ≤27 children means linear scan wins, and it saves ~100B of hashed-storage
		// overhead per node (~180k nodes → tens of MB across the whole trie).
		var children: [(UInt8, Node)] = []
		var word: String?
		var wordID: Int32 = -1          // index into LangData's vocab; -1 = user-adopted
		var logFreq: Double = 0
		func child(_ ch: UInt8) -> Node? {
			for (c, n) in children where c == ch { return n }
			return nil
		}
	}
	private let root = Node()

	func insert(_ word: String, freq: Int, id: Int32 = -1) {
		var node = root
		for ch in word.utf8 {
			if let next = node.child(ch) { node = next }
			else { let n = Node(); node.children.append((ch, n)); node = n }
		}
		node.word = word
		node.wordID = id
		node.logFreq = log(Double(max(freq, 1)) + 1)
	}
	private func node(for word: String) -> Node? {
		var node = root
		for ch in word.utf8 { guard let next = node.child(ch) else { return nil }; node = next }
		return node
	}
	func contains(_ word: String) -> Bool { node(for: word)?.word != nil }
	func hasPrefix(_ prefix: String) -> Bool { node(for: prefix) != nil }
	func wordID(_ word: String) -> Int32? {
		guard let n = node(for: word), n.word != nil, n.wordID >= 0 else { return nil }
		return n.wordID
	}
	func bump(_ word: String) {
		guard let n = node(for: word), n.word != nil else { return }
		n.logFreq = log(exp(n.logFreq) + 1)
	}
	func logFreq(_ word: String) -> Double? {
		guard let n = node(for: word), n.word != nil else { return nil }
		return n.logFreq
	}

	func search(_ typed: String, maxCost: Double, taps: [KeyTap?]? = nil,
				prior: TrieSearchPrior? = nil) -> [Candidate] {
		let chars = Array(typed.utf8)
		guard !chars.isEmpty else { return [] }
		let n = chars.count
		// Taps only apply when they align 1:1 with the typed characters (cursor moves
		// and edits desync them — the controller already length-guards, this re-guards).
		let tapRow: [KeyTap?]? = taps?.count == n ? taps : nil
		// ONE flat DP buffer for the whole walk, rows indexed by depth — the previous
		// version allocated a fresh [Double] row per trie node visited (thousands of
		// transient arrays per keystroke). Depth is bounded: every row past the typed
		// length adds ≥ TrieChannelCosts.delCost to the row minimum (an apostrophe level adds only
		// apostropheSkipCost — the +2 headroom covers the one apostrophe a real word
		// carries), so beyond this depth no row can come back under budget. The prior can
		// relax the budget by up to maxBonus, so its headroom is added to the depth bound.
		let priorHeadroom = prior != nil ? TrieSearchPrior.maxBonus : 0
		let maxDepth = n + Int((maxCost + priorHeadroom) / TrieChannelCosts.minimumDeletionCost) + 2
		var dp = [Double](repeating: 0, count: (maxDepth + 1) * (n + 1))
		for i in 0...n { dp[i] = Double(i) * TrieChannelCosts.insCost }
		var out: [Candidate] = []
		for (ch, child) in root.children {
			// Best case for the candidate's second letter; settled in recurse at depth 2.
			let firstPenalty = TrieChannelCosts.firstLetterPenaltyPolicy(typedLength: n,
				candidateFirst: ch, typedFirst: chars[0], typedSecond: n > 1 ? chars[1] : 0,
				candidateSecond: chars[0])
			SwiftTrie.recurse(child, ch, 0, 1, firstPenalty, chars, tapRow,
				&dp, maxDepth, maxCost, prior?.rootChild(ch), 0, &out)
		}
		return out
	}

	/// `parentMin` is the previous DP row's minimum: a transposition reaches back to it, so a
	/// branch may only be pruned when min(rowMin, parentMin + TrieChannelCosts.transCost) is over budget.
	private static func recurse(_ node: Node, _ letter: UInt8, _ prevLetter: UInt8,
								_ depth: Int, _ firstPenalty: Double,
								_ typed: [UInt8], _ taps: [KeyTap?]?,
								_ dp: inout [Double], _ maxDepth: Int,
								_ maxCost: Double, _ priorNode: PriorNode?,
								_ parentMin: Double,
								_ out: inout [Candidate]) {
		guard depth <= maxDepth else { return }
		let n = typed.count
		let base = depth * (n + 1), prev = base - (n + 1)
		// Advancing past a candidate letter the typed string omitted: cheap for an
		// apostrophe (see KB.apostropheSkipCost) or a doubled letter, a full deletion otherwise.
		var rowMin = dp[prev] + TrieChannelCosts.deletionCost(letter, after: prevLetter, typed: 0)
		dp[base] = rowMin
		for col in 1...n {
			let ins = dp[base + col - 1] + TrieChannelCosts.insertionCost(typed[col - 1], after: col >= 2 ? typed[col - 2] : 0, candidate: letter)
			let del = dp[prev + col] + TrieChannelCosts.deletionCost(letter, after: prevLetter, typed: typed[col - 1])
			let s = KB.subCost(letter, typed: typed[col - 1], tap: taps?[col - 1] ?? nil, typedFirst: col == 1)
			var v = min(ins, del, dp[prev + col - 1] + s)
			// Transposition: candidate's last two letters match the typed pair swapped.
			// prev - (n+1) is the depth-2 row, valid whenever depth ≥ 2 (row 0 = init).
			if depth >= 2, col >= 2, letter == typed[col - 2], prevLetter == typed[col - 1] {
				v = min(v, dp[prev - (n + 1) + col - 2] + TrieChannelCosts.transCost)
			}
			dp[base + col] = v
			if v < rowMin { rowMin = v }
		}
		// Context bonus for THIS prefix: an LM-plausible word-start earns extra edit budget,
		// so a plausible word just outside the base radius is generated (its reported cost
		// stays the pure channel cost — ranking still owns the LM/frequency decision).
		let bonus = priorNode?.bonus ?? 0
		// Settle the root's provisional penalty once the candidate's second letter is known.
		let typedSecond: UInt8 = n > 1 ? typed[1] : 0
		let bound = depth == 2 ? TrieChannelCosts.firstLetterPenaltyPolicy(typedLength: n, candidateFirst: prevLetter,
			typedFirst: typed[0], typedSecond: typedSecond, candidateSecond: letter) : firstPenalty
		let settled = depth == 1 ? max(firstPenalty, TrieChannelCosts.firstLetterPenaltyPolicy(typedLength: n,
			candidateFirst: letter, typedFirst: typed[0], typedSecond: typedSecond)) : bound
		let finalCost = dp[base + n] + settled
		if let w = node.word, finalCost - (priorNode?.terminalBonus ?? 0) <= maxCost {
			out.append(Candidate(word: w, cost: finalCost, logFreq: node.logFreq))
		}
		if min(rowMin, parentMin + TrieChannelCosts.transCost) + bound - bonus <= maxCost {
			for (ch, child) in node.children {
				recurse(child, ch, letter, depth + 1, bound, typed, taps,
					&dp, maxDepth, maxCost, priorNode?.child(ch), rowMin, &out)
			}
		}
	}

	func completions(prefix: String, limit: Int) -> [Candidate] {
		guard let node = node(for: prefix) else { return [] }
		var out: [Candidate] = []
		collect(node, &out, cap: 256)
		return Array(out.sorted { $0.logFreq > $1.logFreq }.prefix(limit))
	}
	private func collect(_ node: Node, _ out: inout [Candidate], cap: Int) {
		if out.count >= cap { return }
		if let w = node.word { out.append(Candidate(word: w, cost: 0, logFreq: node.logFreq)) }
		for (_, child) in node.children { collect(child, &out, cap: cap) }
	}
}

#endif
