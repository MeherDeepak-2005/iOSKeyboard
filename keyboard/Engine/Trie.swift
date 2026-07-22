import Foundation

// Trie: weighted fuzzy search (Damerau + touch taps) + Candidate — extracted from Keyboardengine.swift.

nonisolated struct Candidate { let word: String; let cost: Double; let logFreq: Double }

nonisolated final class PriorNode {
	fileprivate var children: [(UInt8, PriorNode)] = []
	fileprivate(set) var bonus: Double = 0
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
	/// The LM widens the search but can never turn a spatially-absurd word into a hit.
	static let maxBonus = 1.6

	/// `words` are LM-ranked likely continuations (best first). Each lays a rank-decayed
	/// bonus along its whole prefix path; a shared prefix keeps the MAX over the words
	/// through it, so common word-starts stay well-funded.
	init(likelyWords words: [String],
		 weight: (Int) -> Double = { 1.5 * pow(0.82, Double($0)) }) {
		for (rank, word) in words.enumerated() {
			let bonus = min(Self.maxBonus, weight(rank))
			guard bonus > 0 else { continue }
			var node = root
			for ch in word.lowercased().utf8 {
				let next: PriorNode
				if let existing = node.child(ch) { next = existing }
				else { let created = PriorNode(); node.children.append((ch, created)); next = created }
				next.bonus = max(next.bonus, bonus)
				node = next
			}
		}
	}

	var isEmpty: Bool { root.children.isEmpty }
	func rootChild(_ ch: UInt8) -> PriorNode? { root.child(ch) }
}

nonisolated final class Trie {
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
	// The weighted-DP costs and first-letter policy are shared with the static mmap
	// trie in LangData — both searches must produce byte-identical costs (and the
	// Python eval harness mirrors them). Internal, not private, for that reason.
	static let insCost = 1.6
	static let delCost = 1.6
	/// Adjacent-letter swap ("teh" → "the") — the single most common typo class.
	/// One cheap operation (OSA / restricted Damerau) instead of two full edits.
	static let transCost = 0.8
	static let firstLetterPenalty = 2.5
	static func firstLetterPenaltyPolicy(
		typedLength: Int,
		candidateFirst: UInt8,
		typedFirst: UInt8
	) -> Double {
		guard candidateFirst != typedFirst else { return 0 }
		
		switch typedLength {
		case 0, 1, 2:
			return 0.0
		case 3:
			return 0.35
		case 4:
			return 0.75
		default:
			return firstLetterPenalty
		}
	}
	
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
		// length adds ≥ delCost to the row minimum (an apostrophe level adds only
		// apostropheSkipCost — the +2 headroom covers the one apostrophe a real word
		// carries), so beyond this depth no row can come back under budget. The prior can
		// relax the budget by up to maxBonus, so its headroom is added to the depth bound.
		let priorHeadroom = prior != nil ? TrieSearchPrior.maxBonus : 0
		let maxDepth = n + Int((maxCost + priorHeadroom) / Trie.delCost) + 2
		var dp = [Double](repeating: 0, count: (maxDepth + 1) * (n + 1))
		for i in 0...n { dp[i] = Double(i) * Trie.insCost }
		var out: [Candidate] = []
		for (ch, child) in root.children {
			let firstPenalty = Trie.firstLetterPenaltyPolicy(typedLength: n,
				candidateFirst: ch, typedFirst: chars[0])
			Trie.recurse(child, ch, 0, 1, firstPenalty, chars, tapRow,
				&dp, maxDepth, maxCost, prior?.rootChild(ch), &out)
		}
		return out
	}

	private static func recurse(_ node: Node, _ letter: UInt8, _ prevLetter: UInt8,
								_ depth: Int, _ firstPenalty: Double,
								_ typed: [UInt8], _ taps: [KeyTap?]?,
								_ dp: inout [Double], _ maxDepth: Int,
								_ maxCost: Double, _ priorNode: PriorNode?,
								_ out: inout [Candidate]) {
		guard depth <= maxDepth else { return }
		let n = typed.count
		let base = depth * (n + 1), prev = base - (n + 1)
		// Advancing past a candidate letter the typed string omitted: cheap for an
		// apostrophe (see KB.apostropheSkipCost), a full deletion otherwise.
		let skip = letter == KB.apostrophe ? KB.apostropheSkipCost : delCost
		var rowMin = dp[prev] + skip
		dp[base] = rowMin
		for col in 1...n {
			let ins = dp[base + col - 1] + insCost
			let del = dp[prev + col] + skip
			let s = KB.subCost(letter, typed: typed[col - 1], tap: taps?[col - 1] ?? nil)
			var v = min(ins, del, dp[prev + col - 1] + s)
			// Transposition: candidate's last two letters match the typed pair swapped.
			// prev - (n+1) is the depth-2 row, valid whenever depth ≥ 2 (row 0 = init).
			if depth >= 2, col >= 2, letter == typed[col - 2], prevLetter == typed[col - 1] {
				v = min(v, dp[prev - (n + 1) + col - 2] + transCost)
			}
			dp[base + col] = v
			if v < rowMin { rowMin = v }
		}
		// Context bonus for THIS prefix: an LM-plausible word-start earns extra edit budget,
		// so a plausible word just outside the base radius is generated (its reported cost
		// stays the pure channel cost — ranking still owns the LM/frequency decision).
		let bonus = priorNode?.bonus ?? 0
		let finalCost = dp[base + n] + firstPenalty
		if let w = node.word, finalCost - bonus <= maxCost {
			out.append(Candidate(word: w, cost: finalCost, logFreq: node.logFreq))
		}
		if rowMin + firstPenalty - bonus <= maxCost {
			for (ch, child) in node.children {
				recurse(child, ch, letter, depth + 1, firstPenalty, typed, taps,
					&dp, maxDepth, maxCost, priorNode?.child(ch), &out)
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
