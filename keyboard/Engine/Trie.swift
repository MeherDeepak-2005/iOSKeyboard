import Foundation

// Trie: weighted fuzzy search (Damerau + touch taps) + Candidate — extracted from Keyboardengine.swift.

struct Candidate { let word: String; let cost: Double; let logFreq: Double }

final class Trie {
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
	static var firstLetterPenalty = 2.5
	static func firstLetterPenaltyPolicy(
		typedLength: Int,
		candidateFirst: UInt8,
		typedFirst: UInt8
	) -> Double {
		guard candidateFirst != typedFirst else {return 0}
		
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

	func search(_ typed: String, maxCost: Double, taps: [KeyTap?]? = nil) -> [Candidate] {
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
		// carries), so beyond this depth no row can come back under budget.
		let maxDepth = n + Int(maxCost / Trie.delCost) + 2
		var dp = [Double](repeating: 0, count: (maxDepth + 1) * (n + 1))
		for i in 0...n { dp[i] = Double(i) * Trie.insCost }
		var out: [Candidate] = []
		for (ch, child) in root.children {
			Trie.recurse(child, ch, 0, 1, chars, tapRow, &dp, maxDepth, maxCost, &out)
		}
		return out
	}

	private static func recurse(_ node: Node, _ letter: UInt8, _ prevLetter: UInt8, _ depth: Int,
								_ typed: [UInt8], _ taps: [KeyTap?]?,
								_ dp: inout [Double], _ maxDepth: Int,
								_ maxCost: Double, _ out: inout [Candidate]) {
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
			var s = KB.subCost(letter, typed: typed[col - 1], tap: taps?[col - 1] ?? nil)
			if depth == 1, col == 1, letter != typed[0] { s += firstLetterPenaltyPolicy(typedLength: n, candidateFirst: letter, typedFirst: typed[0]) }  // protect first letter
			var v = min(ins, del, dp[prev + col - 1] + s)
			// Transposition: candidate's last two letters match the typed pair swapped.
			// prev - (n+1) is the depth-2 row, valid whenever depth ≥ 2 (row 0 = init).
			if depth >= 2, col >= 2, letter == typed[col - 2], prevLetter == typed[col - 1] {
				v = min(v, dp[prev - (n + 1) + col - 2] + transCost)
			}
			dp[base + col] = v
			if v < rowMin { rowMin = v }
		}
		if let w = node.word, dp[base + n] <= maxCost {
			out.append(Candidate(word: w, cost: dp[base + n], logFreq: node.logFreq))
		}
		if rowMin <= maxCost {
			for (ch, child) in node.children { recurse(child, ch, letter, depth + 1, typed, taps, &dp, maxDepth, maxCost, &out) }
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

