import Foundation

// LangData: mmap reader for langdata.bin (n-grams + static trie) — extracted from Keyboardengine.swift.

final class LangData {
	private let data: Data
	let wordCount: Int
	private let biBuckets, biEntCount, triBuckets, triEntCount: Int
	private let freqBase, offsBase, biHashBase, biEntBase, triHashBase, triEntBase, trieBase, startersBase, blobBase: Int
	private let trieNodeCount: Int
	private let starterCount: Int
	private static let empty = 0xFFFFFFFF          // empty-bucket sentinel (ids are < wordCount)
	private static let nodeSize = 14               // trie record: see the trie MARK

	init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 28 else { return nil }
		func u32(_ off: Int) -> Int {
			Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
		}
		guard u32(0) == 0x4B424C4D else { return nil }                 // magic "KBLM"
		let version = u32(4)
		guard version >= 2, version <= 4 else { return nil }           // v3 = +trie, v4 = +starters
		wordCount   = u32(8)
		biBuckets   = u32(12); biEntCount  = u32(16)
		triBuckets  = u32(20); triEntCount = u32(24)
		trieNodeCount = version >= 3 ? u32(28) : 0
		starterCount  = version >= 4 ? u32(32) : 0
		freqBase    = version >= 4 ? 36 : (version >= 3 ? 32 : 28)
		offsBase    = freqBase    + 4 * wordCount
		biHashBase  = offsBase    + 4 * (wordCount + 1)
		biEntBase   = biHashBase  + 16 * biBuckets       // (ctx, total, entStart, entCount)
		triHashBase = biEntBase   + 8 * biEntCount
		triEntBase  = triHashBase + 20 * triBuckets      // (w1, w2, total, entStart, entCount)
		trieBase    = triEntBase  + 8 * triEntCount
		startersBase = trieBase   + Self.nodeSize * trieNodeCount   // (wordId, count) x starterCount
		blobBase    = startersBase + 8 * starterCount
		guard blobBase <= d.count else { return nil }
		data = d
	}

	/// Sentence-initial word ids, most frequent first (empty on v2/v3). The cold-start
	/// suggestion bar ranks by these instead of global frequency, so it surfaces openers
	/// (i, the, i'm, you) rather than mid-sentence function words (and, of, to).
	func starterIDs(limit: Int) -> [Int] {
		guard starterCount > 0 else { return [] }
		return (0..<min(limit, starterCount)).map { u32(startersBase + 8 * $0) }
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

	// MARK: Phase 2 — endpoint (first,last)-letter anchor index for glide candidate generation
	//
	// A glide's two most reliable points are its START and END keys. Bucketing every dictionary
	// word by (firstChar,lastChar) lets the decoder fetch words whose endpoints match the swipe and
	// shape-score them directly — recovering a word the beam drops when a middle letter is skipped
	// (the greedy prune misaligns), WITHOUT having to traverse those middle letters. Built lazily on
	// the first glide over the mmap word blob (IDs only ≈ wordCount·4 B heap), then cached; a
	// non-gliding session never pays for it.
	private var anchorIndex: [UInt16: [Int32]]?
	private static func anchorKey(_ first: UInt8, _ last: UInt8) -> UInt16 { UInt16(first) << 8 | UInt16(last) }

	private func buildAnchorIndex() -> [UInt16: [Int32]] {
		var tmp: [UInt16: [(id: Int32, f: Int)]] = [:]
		forEachWord { w, f, id in
			guard w.count >= 2, let a = w.first?.asciiValue, let b = w.last?.asciiValue else { return }
			tmp[Self.anchorKey(a, b), default: []].append((id, f))
		}
		var out: [UInt16: [Int32]] = [:]
		out.reserveCapacity(tmp.count)
		for (k, v) in tmp { out[k] = v.sorted { $0.f > $1.f }.map(\.id) }   // most-frequent first
		return out
	}

	/// Build the anchor index now (idempotent) so the FIRST glide of a session doesn't pay for it
	/// inline. Called on the engine's background init queue — a one-time vocab pass, off any
	/// interactive path.
	func warmGlideAnchorIndex() {
		guard hasTrie, anchorIndex == nil else { return }
		anchorIndex = buildAnchorIndex()
	}

	/// Words whose FIRST letter ∈ `first` and LAST letter ∈ `last`, most-frequent first, capped at
	/// `perBucket` per (first,last) pair (so a common endpoint pair can't flood the pool). The
	/// endpoint-anchored candidate source (Phase 2); the caller shape-scores what comes back.
	func glideAnchorWords(first: [Character], last: [Character], perBucket: Int) -> [String] {
		guard hasTrie else { return [] }
		if anchorIndex == nil { anchorIndex = buildAnchorIndex() }
		guard let idx = anchorIndex else { return [] }
		var ids: [Int32] = []
		var seen = Set<Int32>()
		for fc in first { guard let a = fc.asciiValue else { continue }
			for lc in last { guard let b = lc.asciiValue else { continue }
				guard let bucket = idx[Self.anchorKey(a, b)] else { continue }
				for id in bucket.prefix(perBucket) where seen.insert(id).inserted { ids.append(id) }
			}
		}
		return ids.map { word(Int($0)) }
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

	/// The most frequent dictionary word formed by inserting ONE apostrophe into an
	/// apostrophe-less string: "dont" → "don't", "im" → "i'm", "whats" → "what's".
	/// nil when no insertion position yields a vocab word. The letters page has no
	/// ' key, so an omitted apostrophe is an unrepresentable keystroke, not a typo —
	/// the engine corrects these directly (stock's contraction pairs, computed from
	/// the lexicon instead of hardcoded).
	func trieApostropheRestoration(of lw: String) -> (word: String, freq: Int)? {
		guard hasTrie, lw.count >= 2, !lw.contains("'") else { return nil }
		let bytes = Array(lw.utf8)
		var best: (word: String, freq: Int)?
		for i in 1..<bytes.count {
			var cand = bytes
			cand.insert(UInt8(ascii: "'"), at: i)
			guard let n = trieNode(for: cand) else { continue }
			let id = nodeU32(n, 6)
			guard id != UInt32(Self.empty) else { continue }
			let f = freq(Int(Int32(bitPattern: id)))
			if best == nil || f > best!.freq {
				best = (String(decoding: cand, as: UTF8.self), f)
			}
		}
		return best
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
		// +2 headroom: an apostrophe level adds only apostropheSkipCost (see Trie.search).
		let maxDepth = n + Int(maxCost / Trie.delCost) + 2
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
				// Omitted-apostrophe discount — must stay byte-identical to Trie.recurse.
				let skip = letter == KB.apostrophe ? KB.apostropheSkipCost : Trie.delCost
				var rowMin = dp[prev] + skip
				dp[base] = rowMin
				for col in 1...n {
					let ins = dp[base + col - 1] + Trie.insCost
					let del = dp[prev + col] + skip
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

	// MARK: Node-handle trie walk (for glide beam search — O(1) per step, no re-walk)

	var trieRootNode: Int { 0 }
	/// (label byte, child node index) for a node's children, label-sorted.
	func trieChildren(ofNode node: Int) -> [(label: UInt8, node: Int)] {
		guard hasTrie else { return [] }
		let first = Int(nodeU32(node, 2)), count = nodeByte(node, 1)
		return (0..<count).map { (UInt8(nodeByte(first + $0, 0)), first + $0) }
	}
	/// Allocation-free equivalent of `trieChildren(ofNode:)`, same order. The glide beam
	/// visits every hypothesis's children at each depth, so returning a fresh array there
	/// churned the heap on the decode's hot path; this iterates in place instead.
	@inline(__always)
	func forEachChild(ofNode node: Int, _ body: (_ label: UInt8, _ node: Int) -> Void) {
		guard hasTrie else { return }
		let first = Int(nodeU32(node, 2)), count = nodeByte(node, 1)
		for i in 0..<count { body(UInt8(nodeByte(first + i, 0)), first + i) }
	}
	/// The word ending at this node, or nil if the node is a non-terminal prefix.
	func trieWord(atNode node: Int) -> String? {
		let id = nodeU32(node, 6)
		return id == UInt32(Self.empty) ? nil : word(Int(Int32(bitPattern: id)))
	}
	/// Max corpus frequency anywhere in this node's subtree (packed at offset 10) — lets
	/// glide's beam keep frequent-but-imperfect prefixes alive so context can rescue them.
	func trieMaxFreq(ofNode node: Int) -> UInt32 { nodeU32(node, 10) }
}

