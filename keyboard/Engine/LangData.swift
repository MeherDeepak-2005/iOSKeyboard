import Foundation

// LangData: mmap reader for langdata.bin (n-grams + static trie) — extracted from Keyboardengine.swift.

nonisolated struct IncrementalLexiconSeed {
	let word: String
	let bytes: [UInt8]
	let logFreq: Double
}

/// Exact incremental OSA channel costs over a bounded set of static-lexicon words.
/// Appending one typed byte advances one DP column; it does not walk the trie again.
/// The seed set includes every root branch that can fit the production 3.6 normal
/// radius, so normal-radius output remains equivalent to the full mapped-trie walk.
nonisolated final class IncrementalDecodeSession {
	private let seeds: [IncrementalLexiconSeed]
	private let offsets: [Int]
	private var previous: [Double]
	private var previousPrevious: [Double]
	private var scratch: [Double]
	private(set) var typed: [UInt8] = []

	init(seeds: [IncrementalLexiconSeed]) {
		self.seeds = seeds
		var offsets: [Int] = []
		offsets.reserveCapacity(seeds.count)
		var cells = 0
		for seed in seeds {
			offsets.append(cells)
			cells += seed.bytes.count + 1
		}
		self.offsets = offsets
		previous = [Double](repeating: 0, count: cells)
		previousPrevious = [Double](repeating: 0, count: cells)
		scratch = [Double](repeating: 0, count: cells)
		resetRows()
	}

	var seedCount: Int { seeds.count }

	/// Advances an append-only word in O(total seeded spelling bytes). A cursor edit,
	/// backspace, or changed prefix deterministically rebuilds the retained columns.
	@discardableResult
	func advance(to word: String, taps: [KeyTap?]? = nil) -> Bool {
		let bytes = Array(word.lowercased().utf8)
		guard !bytes.isEmpty,
			bytes.allSatisfy({ ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
				|| $0 == KB.apostrophe }) else { return false }
		let tapRow = taps?.count == bytes.count ? taps : nil
		if bytes.count < typed.count || !bytes.starts(with: typed) {
			resetRows()
			typed.removeAll(keepingCapacity: true)
		}
		for index in typed.count..<bytes.count {
			append(bytes[index], tap: tapRow?[index])
		}
		return typed == bytes
	}

	func candidates(maxCost: Double) -> [Candidate] {
		guard !typed.isEmpty else { return [] }
		var result: [Candidate] = []
		result.reserveCapacity(min(128, seeds.count))
		for (index, seed) in seeds.enumerated() {
			guard let first = seed.bytes.first else { continue }
			let penalty = Trie.firstLetterPenaltyPolicy(typedLength: typed.count,
				candidateFirst: first, typedFirst: typed[0])
			let cost = previous[offsets[index] + seed.bytes.count] + penalty
			if cost <= maxCost {
				result.append(Candidate(word: seed.word, cost: cost,
					logFreq: seed.logFreq))
			}
		}
		return result
	}

	private func resetRows() {
		for (index, seed) in seeds.enumerated() {
			let offset = offsets[index]
			previous[offset] = 0
			for column in 1...seed.bytes.count {
				let skip = seed.bytes[column - 1] == KB.apostrophe
					? KB.apostropheSkipCost : Trie.delCost
				previous[offset + column] = previous[offset + column - 1] + skip
			}
		}
	}

	private func append(_ byte: UInt8, tap: KeyTap?) {
		let typedIndex = typed.count + 1
		for (index, seed) in seeds.enumerated() {
			let offset = offsets[index]
			scratch[offset] = Double(typedIndex) * Trie.insCost
			for column in 1...seed.bytes.count {
				let candidate = seed.bytes[column - 1]
				let skip = candidate == KB.apostrophe
					? KB.apostropheSkipCost : Trie.delCost
				let insertion = previous[offset + column] + Trie.insCost
				let deletion = scratch[offset + column - 1] + skip
				let substitution = previous[offset + column - 1]
					+ KB.subCost(candidate, typed: byte, tap: tap)
				var value = min(insertion, min(deletion, substitution))
				if typedIndex >= 2, column >= 2,
					candidate == typed[typedIndex - 2],
					seed.bytes[column - 2] == byte {
					value = min(value,
						previousPrevious[offset + column - 2] + Trie.transCost)
				}
				scratch[offset + column] = value
			}
		}
		swap(&previousPrevious, &previous)
		swap(&previous, &scratch)
		typed.append(byte)
	}
}

nonisolated final class LangData {
	private let data: Data
	let formatVersion: Int
	let wordCount: Int
	private let biBuckets, biEntCount, triBuckets, triEntCount: Int
	private let freqBase, offsBase, biHashBase, biEntBase, triHashBase, triEntBase, trieBase, startersBase, blobBase: Int
	private let trieNodeCount: Int
	private let starterCount: Int
	private let trieNodeSize: Int
	private let continuationSize: Int
	private let starterSize: Int
	private static let empty = 0xFFFFFFFF          // empty-bucket sentinel (ids are < wordCount)
	private static let empty16 = 0xFFFF

	init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 28 else { return nil }
		func u32(_ off: Int) -> Int {
			Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
		}
		guard u32(0) == 0x4B424C4D else { return nil }                 // magic "KBLM"
		let version = u32(4)
		guard version >= 2, version <= 5 else { return nil }
		let headerSize = version >= 4 ? 36 : (version >= 3 ? 32 : 28)
		guard d.count >= headerSize else { return nil }
		formatVersion = version
		wordCount   = u32(8)
		if version == 5, wordCount >= Self.empty16 { return nil }
		biBuckets   = u32(12); biEntCount  = u32(16)
		triBuckets  = u32(20); triEntCount = u32(24)
		trieNodeCount = version >= 3 ? u32(28) : 0
		starterCount  = version >= 4 ? u32(32) : 0
		trieNodeSize = version == 5 ? 12 : 14
		continuationSize = version == 5 ? 6 : 8
		starterSize = version == 5 ? 6 : 8
		freqBase    = headerSize
		offsBase    = freqBase    + 4 * wordCount
		biHashBase  = offsBase    + 4 * (wordCount + 1)
		biEntBase   = biHashBase  + (version == 5 ? 12 : 16) * biBuckets
		triHashBase = biEntBase   + continuationSize * biEntCount
		triEntBase  = triHashBase + (version == 5 ? 12 : 20) * triBuckets
		trieBase    = triEntBase  + continuationSize * triEntCount
		startersBase = trieBase   + trieNodeSize * trieNodeCount
		blobBase    = startersBase + starterSize * starterCount
		guard blobBase <= d.count else { return nil }
		data = d
	}

	/// Sentence-initial word ids, most frequent first (empty on v2/v3). The cold-start
	/// suggestion bar ranks by these instead of global frequency, so it surfaces openers
	/// (i, the, i'm, you) rather than mid-sentence function words (and, of, to).
	func starterIDs(limit: Int) -> [Int] {
		guard starterCount > 0 else { return [] }
		return (0..<min(limit, starterCount)).map {
			formatVersion == 5 ? u16(startersBase + starterSize * $0)
				: u32(startersBase + starterSize * $0)
		}
	}

	private func u32(_ off: Int) -> Int {
		Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
	}
	private func u16(_ off: Int) -> Int {
		Int(UInt16(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt16.self) }))
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
	func bigrams(after ctx: Int32, limit: Int? = nil) -> (total: Int, entries: [(word: Int32, count: Int)])? {
		guard let range = bigramRange(after: ctx) else { return nil }
		let count = min(range.count, limit ?? range.count)
		return (range.total, entries(biEntBase, range.start, range.start + count))
	}
	func trigrams(after w1: Int32, _ w2: Int32, limit: Int? = nil) -> (total: Int, entries: [(word: Int32, count: Int)])? {
		guard let range = trigramRange(after: w1, w2) else { return nil }
		let count = min(range.count, limit ?? range.count)
		return (range.total, entries(triEntBase, range.start, range.start + count))
	}

	/// Batch lookup for scorer candidates. The mmap range is scanned once and only
	/// matching IDs are retained, avoiding one full array allocation per candidate.
	func bigramCounts(after ctx: Int32, words: [Int32])
		-> (total: Int, types: Int, counts: [Int32: Int])? {
		guard let range = bigramRange(after: ctx) else { return nil }
		return selectedCounts(base: biEntBase, range: range, words: words)
	}

	func trigramCounts(after w1: Int32, _ w2: Int32, words: [Int32])
		-> (total: Int, types: Int, counts: [Int32: Int])? {
		guard let range = trigramRange(after: w1, w2) else { return nil }
		return selectedCounts(base: triEntBase, range: range, words: words)
	}

	private func bigramRange(after ctx: Int32) -> (total: Int, start: Int, count: Int)? {
		guard biBuckets > 0 else { return nil }
		if formatVersion == 5 {
			let key = Int(ctx)
			guard key >= 0, key < Self.empty16 else { return nil }
			var lower = 0, upper = biBuckets
			while lower < upper {
				let middle = lower + (upper - lower) / 2
				let slot = u16(biHashBase + 12 * middle)
				if slot < key { lower = middle + 1 } else { upper = middle }
			}
			guard lower < biBuckets else { return nil }
			let base = biHashBase + 12 * lower
			guard u16(base) == key else { return nil }
			return (u32(base + 4), u32(base + 8), u16(base + 2))
		}
		let mask = biBuckets - 1
		let key = Int(ctx)
		var bucket = Int(Self.mix64(UInt64(UInt32(bitPattern: ctx))) & UInt64(mask))
		while true {
			let base = biHashBase + 16 * bucket
			let slot = u32(base)
			if slot == Self.empty { return nil }
			if slot == key { return (u32(base + 4), u32(base + 8), u32(base + 12)) }
			bucket = (bucket + 1) & mask
		}
	}

	private func trigramRange(after w1: Int32, _ w2: Int32)
		-> (total: Int, start: Int, count: Int)? {
		guard triBuckets > 0 else { return nil }
		if formatVersion == 5 {
			guard w1 >= 0, w2 >= 0,
				w1 < Int32(Self.empty16), w2 < Int32(Self.empty16) else { return nil }
			let key = (UInt32(w1) << 16) | UInt32(w2)
			var lower = 0, upper = triBuckets
			while lower < upper {
				let middle = lower + (upper - lower) / 2
				let slot = UInt32(u32(triHashBase + 12 * middle))
				if slot < key { lower = middle + 1 } else { upper = middle }
			}
			guard lower < triBuckets else { return nil }
			let base = triHashBase + 12 * lower
			guard UInt32(u32(base)) == key else { return nil }
			let start = u32(base + 8)
			let end = lower + 1 < triBuckets
				? u32(triHashBase + 12 * (lower + 1) + 8) : triEntCount
			guard end >= start else { return nil }
			return (u32(base + 4), start, end - start)
		}
		let mask = triBuckets - 1
		let key = (UInt64(UInt32(bitPattern: w1)) << 32) | UInt64(UInt32(bitPattern: w2))
		var bucket = Int(Self.mix64(key) & UInt64(mask))
		while true {
			let base = triHashBase + 20 * bucket
			let slot = u32(base)
			if slot == Self.empty { return nil }
			if slot == Int(w1), u32(base + 4) == Int(w2) {
				return (u32(base + 8), u32(base + 12), u32(base + 16))
			}
			bucket = (bucket + 1) & mask
		}
	}

	private func selectedCounts(base: Int, range: (total: Int, start: Int, count: Int),
									words: [Int32]) -> (total: Int, types: Int, counts: [Int32: Int]) {
		let wanted = Set(words)
		var found: [Int32: Int] = [:]
		found.reserveCapacity(min(wanted.count, range.count))
		guard !wanted.isEmpty else { return (range.total, range.count, found) }
		for index in range.start..<(range.start + range.count) {
			let offset = base + continuationSize * index
			let word = Int32(formatVersion == 5 ? u16(offset) : u32(offset))
			let countOffset = formatVersion == 5 ? 2 : 4
			if wanted.contains(word) { found[word] = u32(offset + countOffset) }
		}
		return (range.total, range.count, found)
	}

	private func entries(_ base: Int, _ start: Int, _ end: Int) -> [(word: Int32, count: Int)] {
		(start..<end).map {
			let offset = base + continuationSize * $0
			return (Int32(formatVersion == 5 ? u16(offset) : u32(offset)),
				u32(offset + (formatVersion == 5 ? 2 : 4)))
		}
	}

	// MARK: Static trie (v3) — fuzzy search + completions directly over the mmap
	//
	// Node records are BFS ordered with each node's children contiguous and
	// label-sorted (built by tools/build_language_data.py):
	// v2-v4 use a 14-byte UInt32 word ID; v5 uses a 12-byte UInt16 word ID.
	// Node 0 is the root. Walking these records in place replaces the ~60k-word heap
	// trie that used to be rebuilt (and count as dirty memory) at every launch.

	var hasTrie: Bool { trieNodeCount > 0 }

	private func nodeByte(_ node: Int, _ off: Int) -> Int {
		Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + trieNodeSize * node + off, as: UInt8.self) })
	}
	private func nodeU32(_ node: Int, _ off: Int) -> UInt32 {
		UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + trieNodeSize * node + off, as: UInt32.self) })
	}
	private func nodeWordID(_ node: Int) -> UInt32 {
		if formatVersion == 5 {
			let id = u16(trieBase + trieNodeSize * node + 6)
			return id == Self.empty16 ? UInt32(Self.empty) : UInt32(id)
		}
		return nodeU32(node, 6)
	}
	private func nodeMaxFreq(_ node: Int) -> UInt32 {
		nodeU32(node, formatVersion == 5 ? 8 : 10)
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
		return nodeWordID(n) != UInt32(Self.empty)
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
			let id = nodeWordID(n)
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
		let id = nodeWordID(n)
		return id == UInt32(Self.empty) ? nil : Int32(bitPattern: id)
	}

	/// Materializes only root branches that can possibly fit the normal production
	/// channel radius. For words of length five or more, a wrong-root path that avoids
	/// direct substitution already costs firstPenalty + insertion/deletion = 4.1, so
	/// this direct-substitution gate is complete for the 3.6 radius.
	func incrementalSeeds(typedFirst: UInt8, firstTap: KeyTap?,
		stateCap: Int = 24_000) -> [IncrementalLexiconSeed]? {
		guard hasTrie, typedFirst >= UInt8(ascii: "a"),
			typedFirst <= UInt8(ascii: "z") else { return nil }
		let maximumNormalCost = 3.6
		let longWordPenalty = Trie.firstLetterPenaltyPolicy(typedLength: 8,
			candidateFirst: UInt8(ascii: "z"), typedFirst: typedFirst)
		var allowedInitials = Set<UInt8>()
		forEachChild(ofNode: trieRootNode) { label, _ in
			if label == typedFirst
				|| longWordPenalty + KB.subCost(label, typed: typedFirst,
					tap: firstTap) <= maximumNormalCost {
				allowedInitials.insert(label)
			}
		}

		var seeds: [IncrementalLexiconSeed] = []
		seeds.reserveCapacity(min(stateCap, wordCount / 3))
		for id in 0..<wordCount {
			let start = u32(offsBase + 4 * id)
			let end = u32(offsBase + 4 * (id + 1))
			guard end > start, blobBase + end <= data.count else { return nil }
			let first = data[blobBase + start]
			guard allowedInitials.contains(first) else { continue }
			if seeds.count >= stateCap { return nil }
			let bytes = Array(data[(blobBase + start)..<(blobBase + end)])
			seeds.append(IncrementalLexiconSeed(
				word: String(decoding: bytes, as: UTF8.self), bytes: bytes,
				logFreq: log(Double(max(freq(id), 1)) + 1)))
		}
		return seeds
	}

	/// The same weighted-DP fuzzy search as `Trie.search` — identical costs, identical
	/// first-letter policy — run in place over the mapped node records. One flat DP
	/// buffer for the whole walk; one `withUnsafeBytes` for the whole walk so the hot
	/// loop does raw unaligned loads, not per-node closures.
	func trieSearch(_ typed: String, maxCost: Double, taps: [KeyTap?]? = nil,
					prior: TrieSearchPrior? = nil,
					shouldCancel: (() -> Bool)? = nil) -> [Candidate] {
		let chars = Array(typed.utf8)
		guard hasTrie, !chars.isEmpty else { return [] }
		let n = chars.count
		let tapRow: [KeyTap?]? = taps?.count == n ? taps : nil
		// +2 headroom: an apostrophe level adds only apostropheSkipCost (see Trie.search).
		// The context prior can relax the budget by up to maxBonus (byte-identical to
		// Trie.search), so its headroom is folded into the depth bound.
		let priorHeadroom = prior != nil ? TrieSearchPrior.maxBonus : 0
		let maxDepth = n + Int((maxCost + priorHeadroom) / Trie.delCost) + 2
		var dp = [Double](repeating: 0, count: (maxDepth + 1) * (n + 1))
		for i in 0...n { dp[i] = Double(i) * Trie.insCost }
		var hits: [(id: Int32, cost: Double)] = []
		var visits = 0
		var cancelled = false
		let nodeBase = trieBase
		let nodeSize = trieNodeSize
		let compactWordIDs = formatVersion == 5
		data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
			func byte(_ node: Int, _ off: Int) -> UInt8 {
				raw.loadUnaligned(fromByteOffset: nodeBase + nodeSize * node + off, as: UInt8.self)
			}
			func u32le(_ node: Int, _ off: Int) -> UInt32 {
				UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: nodeBase + nodeSize * node + off, as: UInt32.self))
			}
			func wordID(_ node: Int) -> UInt32 {
				guard compactWordIDs else { return u32le(node, 6) }
				let id = UInt16(littleEndian: raw.loadUnaligned(
					fromByteOffset: nodeBase + nodeSize * node + 6, as: UInt16.self))
				return id == UInt16(Self.empty16) ? UInt32(Self.empty) : UInt32(id)
			}
			func recurse(_ node: Int, _ letter: UInt8, _ prevLetter: UInt8,
				_ depth: Int, _ firstPenalty: Double, _ priorNode: PriorNode?) {
				guard !cancelled, depth <= maxDepth else { return }
				visits &+= 1
				if visits & 127 == 0, shouldCancel?() == true {
					cancelled = true
					return
				}
				let base = depth * (n + 1), prev = base - (n + 1)
				// Omitted-apostrophe discount — must stay byte-identical to Trie.recurse.
				let skip = letter == KB.apostrophe ? KB.apostropheSkipCost : Trie.delCost
				var rowMin = dp[prev] + skip
				dp[base] = rowMin
				for col in 1...n {
					let ins = dp[base + col - 1] + Trie.insCost
					let del = dp[prev + col] + skip
					let s = KB.subCost(letter, typed: chars[col - 1], tap: tapRow?[col - 1] ?? nil)
					var v = min(ins, del, dp[prev + col - 1] + s)
					if depth >= 2, col >= 2, letter == chars[col - 2], prevLetter == chars[col - 1] {
						v = min(v, dp[prev - (n + 1) + col - 2] + Trie.transCost)
					}
					dp[base + col] = v
					if v < rowMin { rowMin = v }
				}
				// Context bonus for this prefix — see Trie.recurse. Reported cost stays the
				// pure channel cost; only the search budget widens for plausible word-starts.
				let bonus = priorNode?.bonus ?? 0
				let id = wordID(node)
				let finalCost = dp[base + n] + firstPenalty
				if id != UInt32(Self.empty), finalCost - bonus <= maxCost {
					hits.append((Int32(bitPattern: id), finalCost))
				}
				if rowMin + firstPenalty - bonus <= maxCost {
					let first = Int(u32le(node, 2)), count = Int(byte(node, 1))
					for c in 0..<count {
						let childLetter = byte(first + c, 0)
						recurse(first + c, childLetter, letter,
							depth + 1, firstPenalty, priorNode?.child(childLetter))
					}
				}
			}
			let first = Int(u32le(0, 2)), count = Int(byte(0, 1))
			for c in 0..<count {
				let letter = byte(first + c, 0)
				let penalty = Trie.firstLetterPenaltyPolicy(typedLength: n,
					candidateFirst: letter, typedFirst: chars[0])
				recurse(first + c, letter, 0, 1, penalty, prior?.rootChild(letter))
			}
		}
		guard !cancelled else { return [] }
		return hits.map { Candidate(word: word(Int($0.id)), cost: $0.cost,
									logFreq: log(Double(max(freq(Int($0.id)), 1)) + 1)) }
	}

	/// Children (label byte, subtree max frequency) of the node at `prefix` — the
	/// next-character distribution that key-target resizing feeds on. Empty prefix =
	/// root = word-initial letters. A handful of clean-page reads, nothing more.
	func trieChildren(after prefix: String) -> [(label: UInt8, maxFreq: UInt32)] {
		guard let n = trieNode(for: Array(prefix.utf8)) else { return [] }
		let first = Int(nodeU32(n, 2)), count = nodeByte(n, 1)
		return (0..<count).map { (UInt8(nodeByte(first + $0, 0)), nodeMaxFreq(first + $0)) }
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
		push(Entry(priority: nodeMaxFreq(start), node: start, wordID: -1))
		while !heap.isEmpty, out.count < limit {
			let e = pop()
			if e.node < 0 {
				let id = Int(e.wordID)
				out.append(Candidate(word: word(id), cost: 0,
									 logFreq: log(Double(max(freq(id), 1)) + 1)))
				continue
			}
			let id = nodeWordID(e.node)
			if id != UInt32(Self.empty) {
				let wid = Int32(bitPattern: id)
				push(Entry(priority: UInt32(clamping: freq(Int(wid))), node: -1, wordID: wid))
			}
			let first = Int(nodeU32(e.node, 2)), count = nodeByte(e.node, 1)
			for c in 0..<count { push(Entry(priority: nodeMaxFreq(first + c), node: first + c, wordID: -1)) }
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
		let id = nodeWordID(node)
		return id == UInt32(Self.empty) ? nil : word(Int(Int32(bitPattern: id)))
	}
	/// Max corpus frequency anywhere in this node's subtree — lets
	/// glide's beam keep frequent-but-imperfect prefixes alive so context can rescue them.
	func trieMaxFreq(ofNode node: Int) -> UInt32 { nodeMaxFreq(node) }
}
