import Foundation

// Noisy-channel engine, v3 — restructured for the neural rescorer (Phase A).
//
// Pipeline:   Lexicon (trie = channel model) generates an N-best candidate list
//           → a LanguageScorer supplies the context prior in ONE batched call
//             (today: bundled n-grams; later: tiny neural LM behind the same seam)
//           → UserModel layers on-device personalization on top.
//
// Autocorrect decisions are precomputed by the debounced background pass while the
// word is still being typed, so the space key only ever does an O(1) cache read —
// a neural scorer (5–20 ms) must never run synchronously on the keystroke path.
//
// Data ships as ONE binary, `langdata.bin` (built by tools/build_language_data.py),
// which is MEMORY-MAPPED at launch: the bi/tri-gram tables AND (format v3) the
// dictionary trie itself are read in place and never materialize as Swift heap
// structures. File-backed read-only pages are clean memory — the OS can evict them
// at will, so they barely count against the extension's ~60–70 MB kill limit (heap
// counts in full). Only a small dynamic trie (adopted + contact words) stays on the
// heap; a v2 file falls back to loading the full vocab into that trie as before.

// MARK: - Spatial model:  -log P(typed_key | intended_key)

/// One tap's landing point relative to the CENTER of the key that fired, in
/// key-grid units (dx: fractions of the horizontal key pitch, dy: of the row
/// pitch). Carrying the real coordinates lets the channel model score a "t" hit
/// 40% of the way toward "r" as almost equally likely to have meant "r" —
/// Gboard-style sub-key precision instead of key identity alone.
struct KeyTap {
	let dx: Double
	let dy: Double
}

private enum KB {
	static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
	static let rowOffset: [Double] = [0.0, 0.25, 0.75]
	static let sigma = 1.0
	static let pos: [UInt8: (Double, Double)] = {
		var m: [UInt8: (Double, Double)] = [:]
		for (r, row) in rows.enumerated() {
			for (c, ch) in row.utf8.enumerated() { m[ch] = (Double(c) + rowOffset[r], Double(r)) }
		}
		return m
	}()
	static func subCost(_ intended: UInt8, _ typed: UInt8) -> Double {
		if intended == typed { return 0 }
		guard let a = pos[intended], let b = pos[typed] else { return 3.0 }
		let d2 = (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)
		return min(3.0, d2 / (2 * sigma * sigma) + 0.3)
	}
	/// Continuous variant: distance from the intended key's center to the actual
	/// landing point. Parity with the discrete table when the tap is dead-center
	/// (cost → 0 for the pressed key); the 0.3 cross-key floor still separates
	/// neighbors so a centered tap never reads as ambiguous.
	static func subCost(_ intended: UInt8, typed: UInt8, tap: KeyTap?) -> Double {
		guard let tap, let a = pos[intended], let t = pos[typed] else { return subCost(intended, typed) }
		let px = t.0 + tap.dx, py = t.1 + tap.dy
		let d2 = (a.0 - px) * (a.0 - px) + (a.1 - py) * (a.1 - py)
		let base = d2 / (2 * sigma * sigma)
		return intended == typed ? min(3.0, base) : min(3.0, base + 0.3)
	}
}

// MARK: - Trie with weighted fuzzy search + first-letter weighting

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
		// length adds ≥ delCost to the row minimum, so beyond n + maxCost/delCost no
		// row can come back under budget and the walk provably never reaches deeper.
		let maxDepth = n + Int(maxCost / Trie.delCost) + 1
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
		var rowMin = dp[prev] + delCost
		dp[base] = rowMin
		for col in 1...n {
			let ins = dp[base + col - 1] + insCost
			let del = dp[prev + col] + delCost
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

// MARK: - LangData: the memory-mapped bundled data (see tools/build_language_data.py)

/// Zero-copy reader for `langdata.bin` (formats v2 and v3). Context lookups are O(1)
/// open-addressing hash probes over the mapped file — one splitmix64 hash plus a
/// short linear probe — nothing is parsed into heap structures. v3 adds a static
/// trie section, so fuzzy search and prefix completion also run in place (see the
/// trie MARK below). Read-only + thread-safe.
final class LangData {
	private let data: Data
	let wordCount: Int
	private let biBuckets, biEntCount, triBuckets, triEntCount: Int
	private let freqBase, offsBase, biHashBase, biEntBase, triHashBase, triEntBase, trieBase, blobBase: Int
	private let trieNodeCount: Int
	private static let empty = 0xFFFFFFFF          // empty-bucket sentinel (ids are < wordCount)
	private static let nodeSize = 14               // trie record: see the trie MARK

	init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 28 else { return nil }
		func u32(_ off: Int) -> Int {
			Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
		}
		guard u32(0) == 0x4B424C4D else { return nil }                 // magic "KBLM"
		let version = u32(4)
		guard version == 2 || version == 3 else { return nil }         // v3 = v2 + static trie
		wordCount   = u32(8)
		biBuckets   = u32(12); biEntCount  = u32(16)
		triBuckets  = u32(20); triEntCount = u32(24)
		trieNodeCount = version >= 3 ? u32(28) : 0
		freqBase    = version >= 3 ? 32 : 28
		offsBase    = freqBase    + 4 * wordCount
		biHashBase  = offsBase    + 4 * (wordCount + 1)
		biEntBase   = biHashBase  + 16 * biBuckets       // (ctx, total, entStart, entCount)
		triHashBase = biEntBase   + 8 * biEntCount
		triEntBase  = triHashBase + 20 * triBuckets      // (w1, w2, total, entStart, entCount)
		trieBase    = triEntBase  + 8 * triEntCount
		blobBase    = trieBase    + Self.nodeSize * trieNodeCount
		guard blobBase <= d.count else { return nil }
		data = d
	}

	private func u32(_ off: Int) -> Int {
		Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
	}

	func freq(_ id: Int) -> Int { u32(freqBase + 4 * id) }
	func word(_ id: Int) -> String {
		let a = blobBase + u32(offsBase + 4 * id), b = blobBase + u32(offsBase + 4 * (id + 1))
		return String(decoding: data[a..<b], as: UTF8.self)
	}
	func forEachWord(_ body: (String, Int, Int32) -> Void) {
		for id in 0..<wordCount { body(word(id), freq(id), Int32(id)) }
	}

	/// splitmix64 finalizer — must match build_language_data.mix64.
	private static func mix64(_ x: UInt64) -> UInt64 {
		var v = x
		v ^= v >> 30; v = v &* 0xBF58476D1CE4E5B9
		v ^= v >> 27; v = v &* 0x94D049BB133111EB
		v ^= v >> 31
		return v
	}

	/// Continuations of a one-word context, best first. `total` is the true
	/// (pre-truncation) context count, so ratios remain honest probabilities.
	func bigrams(after ctx: Int32) -> (total: Int, entries: [(word: Int32, count: Int)])? {
		guard biBuckets > 0 else { return nil }
		let mask = biBuckets - 1
		let key = Int(ctx)
		var b = Int(Self.mix64(UInt64(UInt32(bitPattern: ctx))) & UInt64(mask))
		while true {
			let base = biHashBase + 16 * b
			let slot = u32(base)
			if slot == Self.empty { return nil }
			if slot == key {
				let start = u32(base + 8), count = u32(base + 12)
				return (u32(base + 4), entries(biEntBase, start, start + count))
			}
			b = (b + 1) & mask
		}
	}
	func trigrams(after w1: Int32, _ w2: Int32) -> (total: Int, entries: [(word: Int32, count: Int)])? {
		guard triBuckets > 0 else { return nil }
		let mask = triBuckets - 1
		let key = (UInt64(UInt32(bitPattern: w1)) << 32) | UInt64(UInt32(bitPattern: w2))
		var b = Int(Self.mix64(key) & UInt64(mask))
		while true {
			let base = triHashBase + 20 * b
			let slot = u32(base)
			if slot == Self.empty { return nil }
			if slot == Int(w1), u32(base + 4) == Int(w2) {
				let start = u32(base + 12), count = u32(base + 16)
				return (u32(base + 8), entries(triEntBase, start, start + count))
			}
			b = (b + 1) & mask
		}
	}

	private func entries(_ base: Int, _ start: Int, _ end: Int) -> [(word: Int32, count: Int)] {
		(start..<end).map { (Int32(u32(base + 8 * $0)), u32(base + 8 * $0 + 4)) }
	}

	// MARK: Static trie (v3) — fuzzy search + completions directly over the mmap
	//
	// Node record, 14 B packed, BFS order with each node's children contiguous and
	// label-sorted (built by tools/build_language_data.py):
	//   label u8 | childCount u8 | firstChild u32 | wordID u32 (0xFFFFFFFF = none) |
	//   maxFreq u32 — max corpus frequency in the subtree, for best-first completion.
	// Node 0 is the root. Walking these records in place replaces the ~60k-word heap
	// trie that used to be rebuilt (and count as dirty memory) at every launch.

	var hasTrie: Bool { trieNodeCount > 0 }

	private func nodeByte(_ node: Int, _ off: Int) -> Int {
		Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + Self.nodeSize * node + off, as: UInt8.self) })
	}
	private func nodeU32(_ node: Int, _ off: Int) -> UInt32 {
		UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + Self.nodeSize * node + off, as: UInt32.self) })
	}

	/// Walk the exact byte path from the root; nil when it leaves the trie.
	private func trieNode(for word: [UInt8]) -> Int? {
		guard hasTrie else { return nil }
		var idx = 0
		for ch in word {
			let first = Int(nodeU32(idx, 2))
			let count = nodeByte(idx, 1)
			var next = -1
			for c in 0..<count where nodeByte(first + c, 0) == Int(ch) { next = first + c; break }
			guard next >= 0 else { return nil }
			idx = next
		}
		return idx
	}

	func trieContains(_ lw: String) -> Bool {
		guard let n = trieNode(for: Array(lw.utf8)) else { return false }
		return nodeU32(n, 6) != UInt32(Self.empty)
	}
	func trieHasPrefix(_ lw: String) -> Bool { trieNode(for: Array(lw.utf8)) != nil }
	func trieWordID(_ lw: String) -> Int32? {
		guard let n = trieNode(for: Array(lw.utf8)) else { return nil }
		let id = nodeU32(n, 6)
		return id == UInt32(Self.empty) ? nil : Int32(bitPattern: id)
	}

	/// The same weighted-DP fuzzy search as `Trie.search` — identical costs, identical
	/// first-letter policy — run in place over the mapped node records. One flat DP
	/// buffer for the whole walk; one `withUnsafeBytes` for the whole walk so the hot
	/// loop does raw unaligned loads, not per-node closures.
	func trieSearch(_ typed: String, maxCost: Double, taps: [KeyTap?]? = nil) -> [Candidate] {
		let chars = Array(typed.utf8)
		guard hasTrie, !chars.isEmpty else { return [] }
		let n = chars.count
		let tapRow: [KeyTap?]? = taps?.count == n ? taps : nil
		let maxDepth = n + Int(maxCost / Trie.delCost) + 1
		var dp = [Double](repeating: 0, count: (maxDepth + 1) * (n + 1))
		for i in 0...n { dp[i] = Double(i) * Trie.insCost }
		var hits: [(id: Int32, cost: Double)] = []
		let nodeBase = trieBase
		data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			func byte(_ node: Int, _ off: Int) -> UInt8 {
				raw.loadUnaligned(fromByteOffset: nodeBase + Self.nodeSize * node + off, as: UInt8.self)
			}
			func u32le(_ node: Int, _ off: Int) -> UInt32 {
				UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: nodeBase + Self.nodeSize * node + off, as: UInt32.self))
			}
			func recurse(_ node: Int, _ letter: UInt8, _ prevLetter: UInt8, _ depth: Int) {
				guard depth <= maxDepth else { return }
				let base = depth * (n + 1), prev = base - (n + 1)
				var rowMin = dp[prev] + Trie.delCost
				dp[base] = rowMin
				for col in 1...n {
					let ins = dp[base + col - 1] + Trie.insCost
					let del = dp[prev + col] + Trie.delCost
					var s = KB.subCost(letter, typed: chars[col - 1], tap: tapRow?[col - 1] ?? nil)
					if depth == 1, col == 1, letter != chars[0] {
						s += Trie.firstLetterPenaltyPolicy(typedLength: n, candidateFirst: letter, typedFirst: chars[0])
					}
					var v = min(ins, del, dp[prev + col - 1] + s)
					if depth >= 2, col >= 2, letter == chars[col - 2], prevLetter == chars[col - 1] {
						v = min(v, dp[prev - (n + 1) + col - 2] + Trie.transCost)
					}
					dp[base + col] = v
					if v < rowMin { rowMin = v }
				}
				let id = u32le(node, 6)
				if id != UInt32(Self.empty), dp[base + n] <= maxCost {
					hits.append((Int32(bitPattern: id), dp[base + n]))
				}
				if rowMin <= maxCost {
					let first = Int(u32le(node, 2)), count = Int(byte(node, 1))
					for c in 0..<count { recurse(first + c, byte(first + c, 0), letter, depth + 1) }
				}
			}
			let first = Int(u32le(0, 2)), count = Int(byte(0, 1))
			for c in 0..<count { recurse(first + c, byte(first + c, 0), 0, 1) }
		}
		return hits.map { Candidate(word: word(Int($0.id)), cost: $0.cost,
									logFreq: log(Double(max(freq(Int($0.id)), 1)) + 1)) }
	}

	/// Children (label byte, subtree max frequency) of the node at `prefix` — the
	/// next-character distribution that key-target resizing feeds on. Empty prefix =
	/// root = word-initial letters. A handful of clean-page reads, nothing more.
	func trieChildren(after prefix: String) -> [(label: UInt8, maxFreq: UInt32)] {
		guard let n = trieNode(for: Array(prefix.utf8)) else { return [] }
		let first = Int(nodeU32(n, 2)), count = nodeByte(n, 1)
		return (0..<count).map { (UInt8(nodeByte(first + $0, 0)), nodeU32(first + $0, 10)) }
	}

	/// Top-`limit` completions under `prefix`, best-first over the per-node subtree
	/// max frequency. A node's priority is its maxFreq; a completed word re-enters the
	/// heap as an emission entry (node == -1) at its OWN frequency, so emissions pop
	/// in exact global frequency order while only a sliver of the subtree is visited
	/// (the heap trie's collect-256-then-sort was approximate AND touched more nodes).
	func trieCompletions(prefix: String, limit: Int) -> [Candidate] {
		guard limit > 0, let start = trieNode(for: Array(prefix.utf8)) else { return [] }
		struct Entry { let priority: UInt32; let node: Int; let wordID: Int32 }
		var heap: [Entry] = []                    // max-heap by priority
		func push(_ e: Entry) {
			heap.append(e)
			var c = heap.count - 1
			while c > 0 {
				let p = (c - 1) >> 1
				if heap[p].priority >= heap[c].priority { break }
				heap.swapAt(p, c); c = p
			}
		}
		func pop() -> Entry {
			let top = heap[0]
			let last = heap.removeLast()
			if !heap.isEmpty {
				heap[0] = last
				var p = 0
				while true {
					let l = 2 * p + 1, r = l + 1
					var m = p
					if l < heap.count, heap[l].priority > heap[m].priority { m = l }
					if r < heap.count, heap[r].priority > heap[m].priority { m = r }
					if m == p { break }
					heap.swapAt(p, m); p = m
				}
			}
			return top
		}
		var out: [Candidate] = []
		push(Entry(priority: nodeU32(start, 10), node: start, wordID: -1))
		while !heap.isEmpty, out.count < limit {
			let e = pop()
			if e.node < 0 {
				let id = Int(e.wordID)
				out.append(Candidate(word: word(id), cost: 0,
									 logFreq: log(Double(max(freq(id), 1)) + 1)))
				continue
			}
			let id = nodeU32(e.node, 6)
			if id != UInt32(Self.empty) {
				let wid = Int32(bitPattern: id)
				push(Entry(priority: UInt32(clamping: freq(Int(wid))), node: -1, wordID: wid))
			}
			let first = Int(nodeU32(e.node, 2)), count = nodeByte(e.node, 1)
			for c in 0..<count { push(Entry(priority: nodeU32(first + c, 10), node: first + c, wordID: -1)) }
		}
		return out
	}
}

// MARK: - The scorer seam

/// The context prior:  log P(candidate | left context).
///
/// Batch-first by design — a neural LM encodes the context ONCE and scores all k
/// candidates in a single forward pass, so the protocol must not force per-word
/// calls. All calls happen on the engine's queue.
protocol LanguageScorer {
	/// One log-probability per candidate, same order as the input.
	func logProbs(_ candidates: [String], context: [String]) -> [Double]
	/// False while a heavyweight scorer (Core ML model) is still loading; the
	/// engine falls back to the n-gram scorer until then.
	var isReady: Bool { get }
	/// True when the prior can assign a MEANINGFUL probability to any string,
	/// including words outside the lexicon. The neural LM can (subword tokenizer:
	/// OOV is just less probable, never impossible); n-grams can't — their OOV
	/// answer is a flat unigram floor that swings with the user-model size.
	/// Precondition for the autocorrect margin gate and prediction reranking.
	var scoresArbitraryWords: Bool { get }
	/// Debug only: the per-candidate (neural, ngram) split from the most recent
	/// logProbs call, in the same order. nil when there is no neural term — lets the
	/// ranking log show both columns without a second forward pass.
	var lastSplit: (neural: [Double], ngram: [Double])? { get }
}

extension LanguageScorer {
	var lastSplit: (neural: [Double], ngram: [Double])? { nil }
}

// MARK: - UserModel: on-device personalization

/// The user's own typing: learned bi/tri-gram counts and unigram counts. Persisted
/// as JSON in Application Support. This survives the neural upgrade — personal
/// counts get interpolated with whatever prior is active. Correction rejections
/// ("keeps") are deliberately NOT here: they live in the engine's session-scoped
/// set only, because a keep that persists across sessions slowly turns one undo
/// into a permanently protected typo. NOT thread-safe; the engine's queue guards it.
final class UserModel {
	private(set) var tri: [String: [String: Int]] = [:], triTot: [String: Int] = [:]
	private(set) var bi:  [String: [String: Int]] = [:], biTot:  [String: Int] = [:]
	private(set) var unigrams: [String: Int] = [:]
	private(set) var unigramTotal = 0

	// Growth caps. Without them every committed word adds unigram + bigram + trigram
	// entries forever, and the whole file is reloaded into dirty heap dictionaries at
	// every keyboard launch — the extension's footprint creeps up across weeks of use.
	// Halve-and-drop pruning keeps habits (high counts survive halving) and sheds the
	// one-off long tail (count-1 entries vanish), so personalization quality is kept.
	private static let maxUnigrams = 4000
	private static let maxContexts = 2000          // per table (bi, tri)
	private static let maxWordsPerContext = 8

	/// Enforce the caps. Cheap when under them (four count checks). Returns whether
	/// anything was pruned so callers can persist the shrunk model.
	@discardableResult
	func pruneIfNeeded() -> Bool {
		var pruned = false
		if unigrams.count > Self.maxUnigrams {
			unigrams = unigrams.compactMapValues { $0 >= 2 ? $0 >> 1 : nil }
			if unigrams.count > Self.maxUnigrams {          // pathological: all counts high
				unigrams = Dictionary(uniqueKeysWithValues:
					unigrams.sorted { $0.value > $1.value }.prefix(Self.maxUnigrams).map { ($0.key, $0.value) })
			}
			unigramTotal = unigrams.values.reduce(0, +)
			pruned = true
		}
		if bi.count > Self.maxContexts { prune(&bi, totals: &biTot); pruned = true }
		if tri.count > Self.maxContexts { prune(&tri, totals: &triTot); pruned = true }
		return pruned
	}

	private func prune(_ table: inout [String: [String: Int]], totals: inout [String: Int]) {
		var next: [String: [String: Int]] = [:]
		next.reserveCapacity(table.count / 2)
		for (ctx, words) in table {
			var kept = words.compactMapValues { $0 >= 2 ? $0 >> 1 : nil }
			if kept.count > Self.maxWordsPerContext {
				kept = Dictionary(uniqueKeysWithValues:
					kept.sorted { $0.value > $1.value }.prefix(Self.maxWordsPerContext).map { ($0.key, $0.value) })
			}
			if !kept.isEmpty { next[ctx] = kept }
		}
		if next.count > Self.maxContexts {                  // pathological: still over after halving
			next = Dictionary(uniqueKeysWithValues:
				next.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }
					.prefix(Self.maxContexts).map { ($0.key, $0.value) })
		}
		table = next
		totals = table.mapValues { $0.values.reduce(0, +) }
	}

	private lazy var storeURL: URL = {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("kb_model.json")
	}()
	/// Encoding + disk write run here, OFF the engine's barrier. `save()` snapshots the
	/// model under the barrier (cheap, consistent) and hands the write to this serial
	/// queue, so the space key's `autocorrection()` never blocks behind a JSON write.
	private let ioQueue = DispatchQueue(label: "keyboard.usermodel.io", qos: .utility)

	/// `context` and `word` must already be lowercased.
	func learn(context ctx: [String], word lw: String) {
		unigrams[lw, default: 0] += 1; unigramTotal += 1
		if let p = ctx.last {
			bi[p, default: [:]][lw, default: 0] += 1; biTot[p, default: 0] += 1
		}
		if ctx.count >= 2 {
			let k = ctx[ctx.count - 2] + " " + ctx[ctx.count - 1]
			tri[k, default: [:]][lw, default: 0] += 1; triTot[k, default: 0] += 1
		}
	}

	/// Walk back one learned use of a word the user actively replaced — undoing the
	/// unigram credit a mistaken commit gave it.
	func demote(_ lw: String) {
		guard let c = unigrams[lw] else { return }
		unigrams[lw] = c > 1 ? c - 1 : nil
		unigramTotal = max(0, unigramTotal - 1)
	}

	/// On-disk shape. Older files carry extra keys (`keptCounts`, `kept`) from when
	/// rejections persisted — JSONDecoder ignores unknown keys, so they load fine and
	/// the keys vanish on the next save.
	private struct Snapshot: Codable {
		var tri: [String: [String: Int]]; var bi: [String: [String: Int]]
		var uni: [String: Int]
	}
	func load() {
		guard let data = try? Data(contentsOf: storeURL),
			  let m = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
		tri = m.tri; bi = m.bi; unigrams = m.uni
		triTot = tri.mapValues { $0.values.reduce(0, +) }
		biTot  = bi.mapValues  { $0.values.reduce(0, +) }
		unigramTotal = unigrams.values.reduce(0, +)
		// Models persisted before the caps existed shrink here, once, at load — the
		// launch footprint drops immediately and the pruned file is written back.
		if pruneIfNeeded() { save() }
	}
	func save() {
		// Encode on the caller (cheap, in-memory) — the disk write is the slow, blocking
		// part, so only THAT goes to the I/O queue, keeping it off the engine barrier the
		// space key can stall behind. Serial queue = writes stay ordered, last one wins.
		let m = Snapshot(tri: tri, bi: bi, uni: unigrams)
		guard let data = try? JSONEncoder().encode(m) else { return }
		let url = storeURL
		ioQueue.async { try? data.write(to: url) }
	}
}

// MARK: - NgramScorer: the shipped prior (mmap'd counts + user counts combined)

/// Stupid-backoff trigram → bigram → unigram over the memory-mapped `langdata.bin`
/// tables, with the user's learned counts added in at each level. This is the
/// baseline implementation of the seam the neural rescorer will slot into.
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
			var c = user.tri[key]?[w] ?? 0
			var t = user.triTot[key] ?? 0
			if let wid, let a = resolveID(context[n - 2]), let b = resolveID(context[n - 1]),
			   let hit = data?.trigrams(after: a, b) {
				t += hit.total
				c += hit.entries.first(where: { $0.word == wid })?.count ?? 0
			}
			if c > 0, t > 0 { return log(Double(c) / Double(t)) }
		}
		if n >= 1 {
			let p = context[n - 1]
			var c = user.bi[p]?[w] ?? 0
			var t = user.biTot[p] ?? 0
			if let wid, let a = resolveID(p), let hit = data?.bigrams(after: a) {
				t += hit.total
				c += hit.entries.first(where: { $0.word == wid })?.count ?? 0
			}
			if c > 0, t > 0 { return log(0.4 * Double(c) / Double(t)) }       // backoff weight
		}
		let u = Double((user.unigrams[w] ?? 0) + 1)
		return log(0.16 * u / Double(user.unigramTotal + user.unigrams.count + 1))   // 0.4^2 backoff
	}

	/// Next-word predictions from the combined counts (trigram first, then bigram).
	/// Returns more than the bar shows so the engine can filter before truncating.
	func nextWords(context: [String], limit: Int) -> [String] {
		let ctx = context.map { $0.lowercased() }
		let n = ctx.count
		if n >= 2 {
			let base = (resolveID(ctx[n - 2]), resolveID(ctx[n - 1]))
			let hit = (base.0 != nil && base.1 != nil) ? data?.trigrams(after: base.0!, base.1!) : nil
			let top = merged(hit?.entries, user.tri[ctx[n - 2] + " " + ctx[n - 1]]).prefix(limit)
			if !top.isEmpty { return Array(top) }
		}
		if n >= 1 {
			let hit = resolveID(ctx[n - 1]).flatMap { data?.bigrams(after: $0) }
			let top = merged(hit?.entries, user.bi[ctx[n - 1]]).prefix(limit)
			if !top.isEmpty { return Array(top) }
		}
		return Array(user.unigrams.sorted { $0.value > $1.value }.prefix(limit).map(\.key))
	}
	private func merged(_ base: [(word: Int32, count: Int)]?, _ userCounts: [String: Int]?) -> [String] {
		var m = userCounts ?? [:]
		for e in base ?? [] { m[data?.word(Int(e.word)) ?? "", default: 0] += e.count }
		m[""] = nil
		return m.sorted { $0.value > $1.value }.map(\.key)
	}
}

// MARK: - Lexicon: the channel model + candidate generator

/// Owns the trie: vocab loading, fuzzy/prefix candidate generation, word adoption,
/// and the suggestion blocklist. This is the piece a future `TransliterationSource`
/// (Tenglish) parallels. NOT thread-safe; engine queue.
final class Lexicon {

	/// With v3 langdata the 60k-word dictionary is searched IN PLACE in the mmap'd
	/// static trie (clean, evictable pages), and this heap trie holds only adopted +
	/// contact words — dozens, not tens of thousands. With a v2 file the full vocab
	/// loads here as before.
	private let dynamicTrie = Trie()
	/// The mmap'd bundle data; also used by NgramScorer. nil in the host app / tests.
	private(set) var langData: LangData?
	/// True when langData carries the v3 static trie section.
	private var staticTrie = false
	/// Personal-use frequency lifts for STATIC words — the mmap can't be mutated the
	/// way `Trie.bump` edits heap nodes. Small: only words the user actually types,
	/// already bounded by UserModel's unigram cap.
	private var boosts: [String: Int] = [:]
	/// Highest-frequency words, for the empty-context suggestion bar on a fresh install.
	private(set) var topWords: [String] = []

	// The exact-match blocklist now lives in the bundled `safety.kbguard` binary
	// (curated LDNOOBW en + Wiktionary te, 429 terms), memory-mapped and hash-indexed —
	// see KBSafetyLexicon. nil only if the resource is missing (host app / tests).
	private let safety = KBSafetyLexicon.bundled()

	// Substrings that essentially never occur inside an innocent English word, so a
	// containment check safely blocks COMPOUNDS the exact list misses — fuckface, shithole,
	// dickhead, cocksucker, shitshow, etc. Kept in code deliberately: substring matching is
	// a different strategy than the binary's exact hash lookup, and this list is narrow —
	// roots like "ass"/"cock"/"dick"/"hell" are NOT here because they hide inside
	// class / cockpit / dickens / hello (the Scunthorpe problem).
	private let profanityRoots = [
		"fuck", "shit", "cunt", "cocksuck", "dickhead", "faggot", "jackoff", "jerkoff", "gangbang",
	]
	// Innocent words that DO contain a root above (only "cunt" has real ones here).
	private let profanityAllowlist: Set<String> = ["scunthorpe"]

	func isProfane(_ w: String) -> Bool {
		let lw = w.lowercased()
		if profanityAllowlist.contains(lw) { return false }
		if safety?.isBlocked(lw) == true { return true }        // exact-match binary blocklist
		return profanityRoots.contains { lw.contains($0) }      // substring compounds
	}

	func contains(_ lw: String) -> Bool {
		(staticTrie && langData?.trieContains(lw) == true) || dynamicTrie.contains(lw)
	}
	func isPrefix(_ lw: String) -> Bool {
		(staticTrie && langData?.trieHasPrefix(lw) == true) || dynamicTrie.hasPrefix(lw)
	}
	func insert(_ lw: String, freq: Int) { dynamicTrie.insert(lw, freq: freq) }
	func wordID(_ lw: String) -> Int32? {
		staticTrie ? langData?.trieWordID(lw) : dynamicTrie.wordID(lw)
	}
	func corrections(for lw: String, maxCost: Double, taps: [KeyTap?]? = nil) -> [Candidate] {
		var out = dynamicTrie.search(lw, maxCost: maxCost, taps: taps)
		if staticTrie, let ld = langData {
			out += ld.trieSearch(lw, maxCost: maxCost, taps: taps).map(boosted)
		}
		return out
	}

	/// Next-character priors under the current prefix, for key-target resizing:
	/// log-scaled subtree max frequency, normalized to [0, 1] of the strongest child.
	/// Read straight off the mmap trie — no heap tables, no language-model call.
	func nextCharPriors(prefix lw: String) -> [Character: Double] {
		guard staticTrie, let ld = langData else { return [:] }
		let kids = ld.trieChildren(after: lw)
		guard let top = kids.map(\.maxFreq).max(), top > 0 else { return [:] }
		let denom = log(Double(top) + 1)
		var out: [Character: Double] = [:]
		out.reserveCapacity(kids.count)
		for (label, f) in kids where f > 0 {
			out[Character(UnicodeScalar(label))] = log(Double(f) + 1) / denom
		}
		return out
	}

	/// The frequency term a word carries in ranking (nil when unknown).
	func logFreq(of lw: String) -> Double? {
		if staticTrie, let ld = langData, let id = ld.trieWordID(lw) {
			let base = log(Double(max(ld.freq(Int(id)), 1)) + 1)
			guard let b = boosts[lw] else { return base }
			return log(exp(base) + Double(b))
		}
		return dynamicTrie.logFreq(lw)
	}
	func completions(prefix lw: String, limit: Int) -> [Candidate] {
		var out = dynamicTrie.completions(prefix: lw, limit: limit)
		if staticTrie, let ld = langData {
			out += ld.trieCompletions(prefix: lw, limit: limit).map(boosted)
		}
		return Array(out.sorted { $0.logFreq > $1.logFreq }.prefix(limit))
	}

	/// Personal-use lift on a static word's frequency term — mirrors what `Trie.bump`
	/// does to heap nodes: each use adds one effective count.
	private func boosted(_ c: Candidate) -> Candidate {
		guard let b = boosts[c.word] else { return c }
		return Candidate(word: c.word, cost: c.cost, logFreq: log(exp(c.logFreq) + Double(b)))
	}

	/// Adoption: known words get their frequency bumped; unknown words enter the
	/// dynamic trie once the user has typed them `adoptAfter` times.
	func noteUse(of lw: String, timesUsed: Int, adoptAfter: Int) {
		if staticTrie, langData?.trieContains(lw) == true {
			boosts[lw] = min((boosts[lw] ?? 0) + 1, 100)
		} else if dynamicTrie.contains(lw) {
			dynamicTrie.bump(lw)
		} else if timesUsed >= adoptAfter {
			dynamicTrie.insert(lw, freq: timesUsed)
		}
	}

	func loadFromBundle() {
		if let url = Bundle.main.url(forResource: "langdata", withExtension: "bin"),
		   let ld = LangData(url: url) {
			langData = ld
			if ld.hasTrie {
				// v3: the dictionary is searched in place — nothing to copy to the heap.
				// Top words for the fresh-install bar: scan the freq array (ints only),
				// materialize just the winners.
				staticTrie = true
				var top: [(id: Int, f: Int)] = []
				for id in 0..<ld.wordCount {
					let f = ld.freq(id)
					if top.count < 32 {
						top.append((id, f))
						if top.count == 32 { top.sort { $0.f > $1.f } }
					} else if f > top[top.count - 1].f {
						top[top.count - 1] = (id, f)
						var i = top.count - 1
						while i > 0, top[i].f > top[i - 1].f { top.swapAt(i, i - 1); i -= 1 }
					}
				}
				topWords = Array(top.map { ld.word($0.id) }.filter { !isProfane($0) }.prefix(8))
			} else {
				// v2 fallback: materialize the vocab into the heap trie as before.
				var top: [(String, Int)] = []
				ld.forEachWord { word, freq, id in
					dynamicTrie.insert(word, freq: freq, id: id)
					if !isProfane(word) {
						top.append((word, freq))
						if top.count > 32 { top.sort { $0.1 > $1.1 }; top.removeLast(16) }
					}
				}
				topWords = top.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
			}
		} else {
			let seed = "the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us is are was word".split(separator: " ")
			for (i, w) in seed.enumerated() { dynamicTrie.insert(String(w), freq: seed.count - i) }
			topWords = seed.prefix(8).map(String.init)
		}
	}
}

// MARK: - Engine: the orchestrator (generate → batch-score → blend → rank)

final class KeyboardEngine {

	private let queue = DispatchQueue(label: "keyboard.engine", attributes: .concurrent)
	private let lexicon = Lexicon()
	private let user = UserModel()
	private lazy var ngram = NgramScorer(user: user)
	/// The active prior. When the neural rescorer lands it replaces (or blends with)
	/// `ngram` here — nothing else in the engine changes.
	private lazy var scorer: LanguageScorer = ngram
	/// Direct handle for capabilities beyond the scorer seam (trie-constrained
	/// beam-search prediction). nil when the model files aren't bundled.
	private var neuralLM: NeuralScorer?

	// Tunables.
	/// Dynamic edit-distance budget by typed length. Short words get ~1 edit (tight —
	/// a 2-3 letter string is one slip from dozens of words, so a loose budget just adds
	/// noise); normal words ~2; long words ~3, since a longer word accumulates more
	/// independent slips before you notice. These are the weighted spatial model's costs,
	/// so they're budgets, not integer edit counts (1 substitution ≈ 0.3-1.1, 1 ins/del = 1.6).
	private func maxCost(for length: Int) -> Double {
		switch length {
		case ...4:  return 1.8      // ≈ 1 edit
		case 5...7: return 2.8      // ≈ 2 edits (the previous fixed value)
		default:    return 3.6      // ≈ 3 edits
		}
	}
	private let lmWeight = 1.0
	private let freqWeight = 0.3
	/// Commits before a non-dictionary word enters the trie (and so becomes
	/// suggestable + immune to autocorrect). 5, not 3: a word you were only testing
	/// or typo'd repeatedly shouldn't graduate into the dictionary.
	private let adoptAfter = 5
	/// Candidates that survive to rescoring. Deliberately wider than the 3 shown:
	/// a neural rescorer's value is promoting words the crude score ranked 4th–12th.
	private let nBest = 12
	/// Max candidates handed to the prior in one call. Must be ≤ the neural model's
	/// exported Core ML batch limit (RangeDim(1, 16) in tools/lm/export_coreml.py) — over
	/// that, Core ML rejects the input. 16 comfortably covers the 12 kept.
	private let scoreCap = 16
	/// Autocorrect confidence gate: the best candidate must beat the TYPED string's
	/// blended score by this margin (natural-log units; 3 ≈ 20× more likely) before
	/// a correction fires. Genuine typos clear it by 8–15; slang/names that fit the
	/// context sit near 0 and survive uncorrected — no lexicon entry needed. Active
	/// only while the neural model is resident (`scorer.scoresArbitraryWords`).
	private let correctionMargin = 3.0
	/// Real-word correction (the "hoe → how", "js → is" case): a word that IS in the
	/// dictionary is only replaced when a near-neighbour real word dominates it in
	/// context by this much — far stricter than `correctionMargin`, because wrongly
	/// "correcting" a word the user meant is worse than missing one. Works on the
	/// n-gram alone (a real typed word has a genuine n-gram score, not the OOV floor).
	/// 5.0 is calibrated from the harness: legit real words in-context top out ~2.4,
	/// while genuine slips (js→is 7.0, hoe→how 5.3, od→of 9.4) clear it — a safe gap.
	private let realWordMargin = 5.0
	/// …and the winning neighbour must be within this channel cost of the typed word
	/// (≈ one edit), so only genuine slips — not distant words — can win.
	private let realWordMaxCost = 1.6

	/// The precomputed autocorrect decision for the word currently being typed,
	/// refreshed by the (debounced, background) suggestion pass. The space key reads
	/// it O(1) instead of running a search — mandatory once scoring involves a
	/// neural forward pass. Guarded by `queue`.
	private struct PendingCorrection { let word: String; let correction: String? }
	private var pending: PendingCorrection?

	/// Correction rejections from THIS session. Suppresses re-correction immediately
	/// (so the keyboard never fights the user) and deliberately does NOT persist:
	/// stock-style, a fresh session starts with a clean slate — cross-session keeps
	/// turned one undo into a permanently protected typo.
	private var sessionKept = Set<String>()

	/// Learning fires on every committed word, and `user.save()` re-encodes the WHOLE
	/// personal model to JSON — O(model) work and a matching transient allocation on
	/// the engine barrier, per word typed. Coalesce to one save per 2 s typing burst.
	/// Rare, signal-bearing events (kept words, undo healing) still save immediately;
	/// losing ≤2 s of ordinary counts to a jetsam kill is an acceptable trade.
	private var savePending = false
	private func scheduleSave() {
		guard !savePending else { return }
		savePending = true
		queue.asyncAfter(deadline: .now() + 2.0, flags: .barrier) { [weak self] in
			guard let self else { return }
			self.savePending = false
			self.user.save()
		}
	}

	init() {
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.lexicon.loadFromBundle()
			self.ngram.attach(data: self.lexicon.langData,
							  resolveID: { [lexicon = self.lexicon] in lexicon.wordID($0) })
			self.user.load()
			self.applyLearned()
			// Phase C: if the exported model ships in the bundle, blend it with the
			// n-gram prior. Absent model = pure n-gram, no other differences.
			if let neural = NeuralScorer.bundled() {
				self.neuralLM = neural
				self.scorer = BlendedScorer(neural: neural, ngram: self.ngram)
			}
		}
	}
	private func applyLearned() {
		// Kept words deliberately do NOT enter the trie: keeping means "stop
		// correcting this", not "suggest this". They still adopt organically below
		// once typed adoptAfter times.
		for (w, c) in user.unigrams {
			lexicon.noteUse(of: w, timesUsed: min(c, 50), adoptAfter: adoptAfter)
		}
	}

	// MARK: Autocorrect (O(1) cache read on the word boundary)

	/// Bare lowercase "i" and its contractions — stock always capitalizes these.
	/// They sit beneath the ≥3-char gate the fuzzy path uses, so they're special-cased.
	private static let iForms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]

	func autocorrection(for word: String, context: [String], taps: [KeyTap?]? = nil) -> String? {
		let lw = word.lowercased()
		return queue.sync {
			guard !sessionKept.contains(lw) else { return nil }
			if word == lw, Self.iForms.contains(lw) { return "I" + word.dropFirst() }
			// ≥2: real 2-char words can be corrected via the strict real-word path below;
			// 2-char OOV strings are still filtered out inside `correction(from:)`.
			guard word.count >= 2 else { return nil }
			let correction: String?
			if let p = pending, p.word == lw { correction = p.correction }
			// Typed faster than the debounce → compute now, but in `fast` mode: this
			// runs synchronously under the space key, where a Core ML forward pass
			// (5–20 ms) must never happen. Fast mode scores with the n-gram only.
			else { correction = computeCorrection(lw, context: context, taps: taps, fast: true) }
			return correction.map { matchCase(of: word, to: $0) }
		}
	}

	/// Must run on `queue`.
	private func computeCorrection(_ lw: String, context: [String], taps: [KeyTap?]? = nil, fast: Bool = false) -> String? {
		correction(from: lexicon.corrections(for: lw, maxCost: maxCost(for: lw.count), taps: taps), typed: lw, context: context, fast: fast)
	}

	/// The autocorrect decision from an ALREADY-computed correction set — lets the
	/// suggestion pass reuse its one fuzzy search instead of running the trie DP twice
	/// per keystroke. Must run on `queue`. `fast` = the synchronous space-key fallback:
	/// every ranking below goes n-gram-only, and the OOV margin gate (which is only
	/// meaningful on the neural prior) yields to the legacy always-correct rule —
	/// the same behavior as when the model isn't resident.
	private func correction(from corrections: [Candidate], typed lw: String, context: [String], fast: Bool = false) -> String? {
		guard !sessionKept.contains(lw) else { return nil }

		// Real dictionary words (js, hoe, form) are normally immune to autocorrect — that
		// immunity is why "js" showed "is" in the bar but never applied it. Correct one
		// only when a near-neighbour real word dominates it in context by realWordMargin
		// (the iOS-17 "hoe → how" behaviour). Allowed down to 2 chars because the strict
		// margin + single-edit requirement make it safe there; runs on the n-gram too.
		if lexicon.contains(lw) {
			guard lw.count >= 2 else { return nil }
			let typed = Candidate(word: lw, cost: 0, logFreq: log(Double(user.unigrams[lw] ?? 0) + 1))
			let ranked = rank(corrections, including: typed, context: context, log: "realword '\(lw)'", ngramOnly: fast)
			guard let best = ranked.first, best.word != lw, lexicon.contains(best.word),
				  let cand = corrections.first(where: { $0.word == best.word }), cand.cost <= realWordMaxCost
			else { return nil }
			let typedScore = ranked.first(where: { $0.word == lw })?.score ?? 0
			let margin = best.score - typedScore
			let fire = margin > realWordMargin
			KBDiagnostics.logDecision(typed: lw, best: best.word, margin: margin,
									  threshold: realWordMargin, corrected: fire)
			return fire ? best.word : nil
		}

		guard lw.count >= 3 else { return nil }
		// Missing-space split ("alot" → "a lot"): rides the same gates as single-word
		// candidates. The neural batch scores the spaced string natively (subword
		// tokenizer); the pure-n-gram path scores it with the PAIR probability below,
		// because the single-candidate seam floors multi-word strings.
		let split = splitCandidate(of: lw)
		// Margin gate (the iOS-17 "slang survives" mechanism). Pre-gate, OOV meant
		// probability zero → forced replacement. The neural LM can score ANY string
		// via subwords, so the typed word rides the SAME batched forward pass as the
		// candidates (one extra row, spatial cost 0 by definition) and a correction
		// fires only when the best candidate beats it by `correctionMargin`. In a
		// register where the typed word is plausible ("lol im finna…") the margin
		// collapses and we stay silent. Repeated personal use raises the typed row's
		// logFreq term, reinforcing the keep. Without the neural model resident, the
		// n-gram OOV floor is meaningless, so keep the legacy always-correct rule.
		if !fast, scorer.scoresArbitraryWords {
			let typed = Candidate(word: lw, cost: 0,
								  logFreq: log(Double(user.unigrams[lw] ?? 0) + 1))
			var cands = corrections
			if let split { cands.append(split.candidate) }
			let ranked = rank(cands, including: typed, context: context, log: "autocorrect")
			let best = ranked.first
			let typedScore = ranked.first(where: { $0.word == lw })?.score ?? 0
			let margin = (best?.score ?? 0) - typedScore
			let fire = best != nil && best!.word != lw && margin > correctionMargin
			KBDiagnostics.logDecision(typed: lw, best: best?.word, margin: margin,
									  threshold: correctionMargin, corrected: fire)
			return fire ? best!.word : nil
		}
		let ranked = rank(corrections, context: context, log: "autocorrect", ngramOnly: fast)
		var bestWord = ranked.first?.word
		var bestScore = ranked.first?.score ?? -.infinity
		if let split {
			let s = -split.candidate.cost + freqWeight * split.candidate.logFreq
				+ lmWeight * ngram.pairLogProb(split.a, split.b, context: context)
			if s > bestScore { bestWord = split.candidate.word; bestScore = s }
		}
		guard let bestWord, bestWord != lw else { return nil }
		return bestWord
	}

	/// Best "missing space" split of an OOV string into two real words, or nil.
	/// Channel cost is one skipped space (just under one insertion). Single-letter
	/// halves are only "a"/"i" — anything else is a typo fragment, not a word.
	private static let splitCost = 1.1
	private func splitCandidate(of lw: String) -> (candidate: Candidate, a: String, b: String)? {
		guard lw.count >= 4 else { return nil }
		var best: (Candidate, String, String)?
		var bestFreq = -Double.infinity
		for i in 1...(lw.count - 1) {
			let a = String(lw.prefix(i)), b = String(lw.dropFirst(i))
			guard a.count >= 2 || a == "a" || a == "i",
				  b.count >= 2 || b == "a" || b == "i",
				  lexicon.contains(a), lexicon.contains(b),
				  !lexicon.isProfane(a), !lexicon.isProfane(b),
				  let fa = lexicon.logFreq(of: a), let fb = lexicon.logFreq(of: b) else { continue }
			let lf = min(fa, fb)      // the pair is only as strong as its rarer half
			if lf > bestFreq {
				bestFreq = lf
				best = (Candidate(word: a + " " + b, cost: Self.splitCost, logFreq: lf), a, b)
			}
		}
		guard let best else { return nil }
		return (best.0, best.1, best.2)
	}

	func dontCorrect(_ word: String) {
		let lw = word.lowercased()
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.sessionKept.insert(lw)                          // protect now, THIS session only
			if self.pending?.word == lw { self.pending = nil }   // stale decision must not re-fire
		}
	}

	/// The user let an autocorrect of `original` stand (typed on instead of undoing).
	/// Acceptance is counter-evidence against an earlier rejection this session —
	/// lift the keep so correction resumes. Nothing persists; keeps are session-scoped.
	func correctionStood(_ original: String) {
		let lw = original.lowercased()
		queue.async(flags: .barrier) { [weak self] in
			self?.sessionKept.remove(lw)
		}
	}

	/// The user actively replaced `original` with a different word (picked a suggestion
	/// over their typed word, undid a correction back out of `original`, or erased it
	/// and retyped something else by hand). Strong evidence `original` was a mistake:
	/// lift its session keep — so autocorrect resumes immediately — and walk back one
	/// learned use, so repeated hand-fixes keep it from adopting into the dictionary.
	func wordReplaced(original: String, with replacement: String) {
		let lw = original.lowercased()
		guard lw != replacement.lowercased() else { return }
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.sessionKept.remove(lw)
			self.user.demote(lw)
			if self.pending?.word == lw { self.pending = nil }
			self.scheduleSave()
		}
	}

	// MARK: Suggestions (background; also precomputes the autocorrect decision)

	/// Fast typing queues several barrier passes; each used to run its full search even
	/// when a newer keystroke had already superseded it (staleness was only detected in
	/// the main-thread callback, after the work was spent). Ticket outside, check inside:
	/// a pass that is no longer the newest returns before doing anything. NSLock, not the
	/// engine queue, guards the counter — the increment happens on the caller's thread.
	private let genLock = NSLock()
	private var suggestGen = 0

	/// The exact-match word→emoji table riding in emoji.bin (nil when not bundled).
	private let emojiStore = EmojiStore.bundled

	func suggestions(currentWord: String, context: [String], taps: [KeyTap?]? = nil,
					 completion: @escaping ([String], [Character: Double]) -> Void) {
		genLock.lock(); suggestGen &+= 1; let gen = suggestGen; genLock.unlock()
		// Barrier: this pass writes `pending` (and is the only frequent writer).
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.genLock.lock(); let latest = self.suggestGen; self.genLock.unlock()
			guard gen == latest else { return }   // superseded — the newest pass delivers
			KBDiagnostics.recorder.sample()   // cheap footprint/headroom probe, background only
			let lw = currentWord.lowercased()
			var result: [String]
			if currentWord.isEmpty {
				self.pending = nil
				result = self.nextWords(context: context)
			} else {
				// One fuzzy search per keystroke: the corrections feed BOTH the suggestion
				// ranking and the precomputed autocorrect decision below (previously the
				// trie DP ran twice — once here, once inside computeCorrection).
				let corrections = self.lexicon.corrections(for: lw, maxCost: self.maxCost(for: lw.count), taps: taps)
				let completions = self.lexicon.completions(prefix: lw, limit: 12)
				let ranked = self.rank(completions + corrections, context: context, log: "suggest '\(lw)'").prefix(self.nBest)
				result = ranked.prefix(3).map { matchCase(of: currentWord, to: $0.word) }
				// SwiftKey-style emoji candidate: an exact word→emoji hit takes the last
				// slot; picking it replaces the word (stock QuickType behavior).
				if let e = self.emojiStore?.emoji(forWord: lw) {
					if result.count >= 3 { result[2] = e } else { result.append(e) }
				}
				// Precompute "what happens if the user commits this word right now" so the
				// space key is an O(1) cache read, reusing the corrections just computed.
				self.pending = PendingCorrection(word: lw,
					correction: self.correction(from: corrections, typed: lw, context: context))
			}
			// Next-character priors for key-target resizing, straight off the mmap trie
			// for the CURRENT prefix (root when the word is empty = sentence starts).
			// Never the neural model: this must stay microseconds, every pass.
			let priors = self.lexicon.nextCharPriors(prefix: lw)
			DispatchQueue.main.async { completion(result, priors) }
		}
	}

	/// iOS supplementary lexicon (contact names, text-replacement shortcuts): make
	/// these words first-class citizens — suggestable and immune to autocorrect —
	/// exactly how stock stops "mangling" names. Modest frequency: context counts,
	/// not the freq term, should surface them.
	func importSupplementaryLexicon(_ words: [String]) {
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			for w in words {
				let lw = w.lowercased()
				guard lw.count >= 2, lw.allSatisfy({ $0.isLetter || $0 == "'" }),
					  !self.lexicon.contains(lw), !self.lexicon.isProfane(lw) else { continue }
				self.lexicon.insert(lw, freq: 50)
			}
		}
	}

	func learn(context: [String], word: String) {
		let lw = word.lowercased()
		guard lw.count >= 1, lw.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
		if lexicon.isProfane(lw) { return }        // never learn/adopt blocked words
		let ctx = context.map { $0.lowercased() }
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.user.learn(context: ctx, word: lw)
			self.user.pruneIfNeeded()
			self.lexicon.noteUse(of: lw, timesUsed: self.user.unigrams[lw] ?? 0, adoptAfter: self.adoptAfter)
			self.scheduleSave()
		}
	}

	// MARK: Ranking — the blend of channel, prior, personalization, and frequency

	/// Dedupes (keeping each word's cheapest channel cost), drops blocked words, then
	/// blends one batched prior call with the channel cost and lexicon frequency:
	///   final = -spatialCost + lmWeight·logP(w|ctx) + freqWeight·logFreq
	/// Must run on `queue`. `extra` (the margin gate's typed-word row) is exempt
	/// from the profanity filter and the cap: it must always come back scored.
	private func rank(_ cands: [Candidate], including extra: Candidate? = nil,
					  context: [String], log label: String? = nil,
					  ngramOnly: Bool = false) -> [(word: String, score: Double)] {
		var best: [String: Candidate] = [:]
		for c in cands where !lexicon.isProfane(c.word) {
			if let cur = best[c.word], cur.cost <= c.cost { continue }
			best[c.word] = c
		}
		guard !best.isEmpty else { return [] }
		var list = Array(best.values)
		// A fuzzy search can return dozens of candidates, but the prior (esp. the neural
		// model, whose Core ML batch is capped at `scoreCap`) should only rescore the
		// strongest handful. Pre-rank cheaply on channel + frequency and keep the top
		// `scoreCap`: a candidate the crude score ranks below that never climbs into the
		// shown top 3 after rescoring, and this bounds the prior to a single batch.
		// With an `extra` row, keep one slot free so the batch still fits in one pass.
		let cap = extra == nil ? scoreCap : scoreCap - 1
		if list.count > cap {
			list.sort { (-$0.cost + freqWeight * $0.logFreq) > (-$1.cost + freqWeight * $1.logFreq) }
			list = Array(list.prefix(cap))
		}
		if let extra, !list.contains(where: { $0.word == extra.word }) { list.append(extra) }
		let doLog = label != nil && KBDiagnostics.verbose
		let t0 = doLog ? Date() : nil
		let prior: LanguageScorer = ngramOnly ? ngram : scorer
		let priors = prior.logProbs(list.map(\.word), context: context)
		let scored = zip(list, priors)
			.map { (word: $0.word, score: -$0.cost + lmWeight * $1 + freqWeight * $0.logFreq) }
			.sorted { $0.score > $1.score }
		if doLog, let label {
			let ms = t0.map { Date().timeIntervalSince($0) * 1000 } ?? 0
			let split = prior.lastSplit
			var rows: [KBDiagnostics.RankRow] = []
			for (i, c) in list.enumerated() {
				rows.append(.init(word: c.word, cost: c.cost, logFreq: c.logFreq,
								  neural: split?.neural[i] ?? Double.nan,
								  ngram: split?.ngram[i] ?? priors[i],
								  prior: priors[i],
								  score: -c.cost + lmWeight * priors[i] + freqWeight * c.logFreq))
			}
			rows.sort { $0.score > $1.score }
			KBDiagnostics.logRanking(label: label, context: context, rows: rows,
									 modelActive: prior.scoresArbitraryWords, ms: ms)
		}
		return scored
	}

	/// Must run on `queue`.
	private func nextWords(context: [String]) -> [String] {
		// Trie-constrained beam search when the LM is resident: the model proposes
		// subword pieces, every partial expansion must stay a valid trie prefix, and
		// only complete trie words score — open, whole-sentence-context generation
		// with zero hallucinated strings (prediction is where the neural model
		// measurably beats the n-gram). The n-gram list — which carries the user's
		// personal counts — fills remaining slots, and is the whole answer while
		// the model loads. Background queue only.
		// Never re-offer the word that was just committed — "the the" reads as a bug,
		// and stock never does it. (Legit doubles are rare and still typeable.)
		let last = context.last?.lowercased()
		var out: [String] = []
		if !context.isEmpty, let preds = neuralLM?.predictWords(
			context: context, limit: 8,
			isPrefix: { [lexicon] in lexicon.isPrefix($0) },
			isWord: { [lexicon] in lexicon.contains($0) }) {
			out = preds.map(\.word).filter { $0 != last && !lexicon.isProfane($0) }
		}
		let beamCount = out.count
		for w in ngram.nextWords(context: context, limit: 8)
			where w != last && !out.contains(w) && !lexicon.isProfane(w) { out.append(w) }
		if out.isEmpty { out = lexicon.topWords }   // fresh install, no context: top dictionary words
		let final = Array(out.prefix(3).map(displayCase))
		KBDiagnostics.logPredict(context: context, words: final, beam: beamCount, ngram: out.count - beamCount)
		return final
	}
	/// Bare "i" / "i'm" from lowercased corpora read wrong on the suggestion bar.
	private func displayCase(_ w: String) -> String {
		if w == "i" { return "I" }
		if w.hasPrefix("i'") { return "I" + w.dropFirst() }
		return w
	}
}

private func matchCase(of source: String, to target: String) -> String {
	// ALL-CAPS input stays ALL-CAPS ("HELLO" → "HELP!", not "Help"). Multi-char only:
	// a single capital (sentence-start letter, bare "I") means capitalize, not shout.
	if source.count > 1, source == source.uppercased(), source != source.lowercased() {
		return target.uppercased()
	}
	guard let f = source.first, f.isUppercase else { return target }
	return target.prefix(1).uppercased() + target.dropFirst()
}
