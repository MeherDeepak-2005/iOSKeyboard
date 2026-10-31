import Foundation

extension LangData {
	// MARK: Static trie (v3) — fuzzy search + completions directly over the mmap
	//
	// Node records are BFS ordered with each node's children contiguous and
	// label-sorted (built by tools/build_language_data.py):
	// v2-v4 and v6 use 14-byte nodes with UInt32 IDs; v5 uses 12-byte nodes with UInt16 IDs.
	// Node 0 is the root. Walking these records in place replaces the ~60k-word heap
	// trie that used to be rebuilt (and count as dirty memory) at every launch.


	func nodeByte(_ node: Int, _ off: Int) -> Int {
		Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + trieNodeSize * node + off, as: UInt8.self) })
	}
	func nodeU32(_ node: Int, _ off: Int) -> UInt32 {
		UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + trieNodeSize * node + off, as: UInt32.self) })
	}
	func nodeWordID(_ node: Int) -> UInt32 {
		if formatVersion == 5 {
			let id = u16(trieBase + trieNodeSize * node + 6)
			return id == Self.empty16 ? UInt32(Self.empty) : UInt32(id)
		}
		return nodeU32(node, 6)
	}
	func nodeMaxFreq(_ node: Int) -> UInt32 {
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
	func trieWordID(_ lw: String) -> Int32? {
		guard let n = trieNode(for: Array(lw.utf8)) else { return nil }
		let id = nodeWordID(n)
		return id == UInt32(Self.empty) ? nil : Int32(bitPattern: id)
	}

	/// Materializes only root branches that can possibly fit the normal production
	/// channel radius. For words of length five or more, a wrong-root path that avoids
	/// direct substitution already costs firstPenalty + insertion/deletion = 4.1, so
	/// this direct-substitution gate is complete for the 3.6 radius.
	/// `typedSecond` (0 = unknown) also admits words starting with it, for a swapped
	/// first pair (ocokies → cookies); mirrors native `PackedLexicon::incrementalSeeds`.
	/// `maxCost` is the search radius the seeds must cover (2.8 up to 7 letters, 3.6 from 8).
	func incrementalSeeds(typedFirst: UInt8, firstTap: KeyTap?,
		stateCap: Int = 24_000, typedSecond: UInt8 = 0, maxCost: Double = 3.6) -> [IncrementalLexiconSeed]? {
		guard hasTrie, typedFirst >= UInt8(ascii: "a"),
			typedFirst <= UInt8(ascii: "z") else { return nil }
		let maximumNormalCost = maxCost
		var allowedInitials = Set<UInt8>()
		forEachChild(ofNode: trieRootNode) { label, _ in
			// Each label at its own 5+ letter penalty (neighbouring keys pay less), as native.
			if label == typedFirst || (typedSecond != 0 && label == typedSecond)
				|| KB.seedFirstLetterCost(label, typedFirst: typedFirst, tap: firstTap) <= maximumNormalCost {
				allowedInitials.insert(label)
			}
		}

		var seeds: [IncrementalLexiconSeed] = []
		seeds.reserveCapacity(min(stateCap, wordCount / 3))
		var considered = 0   // as native: blocked words count toward the cap, but are not seeded
		for id in 0..<wordCount {
			let start = u32(offsBase + 4 * id)
			let end = u32(offsBase + 4 * (id + 1))
			guard end > start, blobBase + end <= data.count else { return nil }
			let first = data[blobBase + start]
			guard allowedInitials.contains(first) else { continue }
			if considered >= stateCap { return nil }
			considered += 1
			if isSwiftBlocked(Int32(id)) { continue }
			let bytes = Array(data[(blobBase + start)..<(blobBase + end)])
			seeds.append(IncrementalLexiconSeed(
				word: String(decoding: bytes, as: UTF8.self), bytes: bytes,
				logFreq: log(Double(max(freq(id), 1)) + 1)))
		}
		return seeds
	}


	func nativeIncrementalSeeds(typedFirst: UInt8, firstTap: KeyTap?,
		stateCap: Int = 24_000, boosts: [String: Int] = [:], typedSecond: UInt8 = 0,
		maxCost: Double = 3.6) throws -> KBIncrementalSeedSet? {
		guard let native = nativeComparison else { throw NativeReadParityError.comparisonDisabled }
		guard stateCap >= 0 else { return nil }
		        let ordered = boosts.sorted { $0.key < $1.key }
        return try native.incrementalSeeds(forTypedFirst: typedFirst, typedSecond: typedSecond,
            firstTapDX: firstTap?.dx ?? 0, firstTapDY: firstTap?.dy ?? 0,
            hasFirstTap: firstTap != nil, stateCap: UInt(stateCap),
            boostWords: ordered.map(\.key), boostCounts: ordered.map { NSNumber(value: $0.value) },
            maxCost: maxCost)
	}

	/// The same weighted-DP fuzzy search as `Trie.search` — identical costs, identical
	/// first-letter policy — run in place over the mapped node records. One flat DP
	/// buffer for the whole walk; one `withUnsafeBytes` for the whole walk so the hot
	/// loop does raw unaligned loads, not per-node closures.
	/// `missingFirstOnly` mirrors native `PackedLexicon::search(..., missingFirstOnly)`: only
	/// candidates with one extra leading letter before the typed word (bove → above). Used by
	/// the reference pool beside the retained search, which seeds only by the typed first letters.
	func trieSearch(_ typed: String, maxCost: Double, taps: [KeyTap?]? = nil,
					prior: TrieSearchPrior? = nil,
					shouldCancel: (() -> Bool)? = nil, missingFirstOnly: Bool = false,
					roots: Set<UInt8> = []) -> [Candidate] {
        if backend == .cpp, !missingFirstOnly, roots.isEmpty, let native = nativeComparison {
            do {
                let buffers = NativeTapBuffers(taps: taps, expectedCount: typed.utf8.count)
                let funding = prior?.nativeFundingSnapshot()
                return try native.search(word: typed, maxCost: maxCost,
                    tapOffsets: buffers?.offsets, tapValidity: buffers?.validity,
                    fundedWords: funding?.words, fundedBonuses: funding?.bonuses,
                    shouldCancel: shouldCancel).map {
                        Candidate(word: $0.word, cost: $0.cost, logFreq: $0.logFrequency)
                    }
            } catch {
                // Debug/test builds can recover through the independent reference.
                // Shipping retains no duplicate full-trie implementation.
                // Budget-cap fallback and normal cancellation are NOT errors.
            }
        }
#if DEBUG || KB_REFERENCE_DECODER_YES
        let chars = Array(typed.utf8)
        guard hasTrie, !chars.isEmpty else { return [] }
		let n = chars.count
		let tapRow: [KeyTap?]? = taps?.count == n ? taps : nil
		// +2 headroom: an apostrophe level adds only apostropheSkipCost (see Trie.search).
		// The context prior can relax the budget by up to maxBonus (byte-identical to
		// Trie.search), so its headroom is folded into the depth bound.
		let priorHeadroom = prior != nil ? TrieSearchPrior.maxBonus : 0
		let maxDepth = n + Int((maxCost + priorHeadroom) / Trie.minimumDeletionCost) + 2
		var dp = [Double](repeating: 0, count: (maxDepth + 1) * (n + 1))
		for i in 0...n { dp[i] = Double(i) * Trie.insCost }
		var hits: [(id: Int32, cost: Double)] = []
		var visits = 0
		var cancelled = false
		// As native: the full search leaves dropped-first-letter candidates (bove → above) to
		// the missingFirstOnly pass, so they cannot lower every first letter's root bound.
		let typedSecondLetter: UInt8 = n > 1 ? chars[1] : 0
		func penaltyOf(_ candidateFirst: UInt8, _ candidateSecond: UInt8) -> Double {
			var second = candidateSecond
			if !missingFirstOnly, second == chars[0], !(typedSecondLetter != 0 && candidateFirst == typedSecondLetter) { second = 0 }
			return Trie.firstLetterPenaltyPolicy(typedLength: n, candidateFirst: candidateFirst,
				typedFirst: chars[0], typedSecond: typedSecondLetter, candidateSecond: second)
		}
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
			// parentMin: previous row minimum (a transposition reaches back to it), as in Trie.recurse.
			func recurse(_ node: Int, _ letter: UInt8, _ prevLetter: UInt8,
				_ depth: Int, _ firstPenalty: Double, _ priorNode: PriorNode?, _ parentMin: Double) {
				guard !cancelled, depth <= maxDepth else { return }
				visits &+= 1
				if visits & 127 == 0, shouldCancel?() == true {
					cancelled = true
					return
				}
				let base = depth * (n + 1), prev = base - (n + 1)
				// Apostrophe and doubled-letter discounts — must stay byte-identical to Trie.recurse.
				var rowMin = dp[prev] + Trie.deletionCost(letter, after: prevLetter, typed: 0)
				dp[base] = rowMin
				for col in 1...n {
					let ins = dp[base + col - 1] + Trie.insertionCost(chars[col - 1], after: col >= 2 ? chars[col - 2] : 0, candidate: letter)
					let del = dp[prev + col] + Trie.deletionCost(letter, after: prevLetter, typed: chars[col - 1])
					let s = KB.subCost(letter, typed: chars[col - 1], tap: tapRow?[col - 1] ?? nil, typedFirst: col == 1)
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
				// Settle the root's provisional penalty once the candidate's second letter is known.
				let typedSecond: UInt8 = n > 1 ? chars[1] : 0
				let bound = depth == 2 ? penaltyOf(prevLetter, letter) : firstPenalty
				let settled = depth == 1 ? max(firstPenalty, Trie.firstLetterPenaltyPolicy(typedLength: n,
					candidateFirst: letter, typedFirst: chars[0], typedSecond: typedSecond)) : bound
				let finalCost = dp[base + n] + settled
				if id != UInt32(Self.empty), !isSwiftBlocked(Int32(bitPattern: id)),
					finalCost - (priorNode?.terminalBonus ?? 0) <= maxCost {
					hits.append((Int32(bitPattern: id), finalCost))
				}
				if min(rowMin, parentMin + Trie.transCost) + bound - bonus <= maxCost {
					let first = Int(u32le(node, 2)), count = Int(byte(node, 1))
					for c in 0..<count {
						let childLetter = byte(first + c, 0)
						if missingFirstOnly, depth == 1, childLetter != chars[0] { continue }
						recurse(first + c, childLetter, letter,
							depth + 1, bound, priorNode?.child(childLetter), rowMin)
					}
				}
			}
			let first = Int(u32le(0, 2)), count = Int(byte(0, 1))
			for c in 0..<count {
				let letter = byte(first + c, 0)
				// As native: typed-second-then-first is a swap (avlot → valor), already in the full search.
				if missingFirstOnly, letter == chars[0] || (typedSecondLetter != 0 && letter == typedSecondLetter) { continue }
				// As native `roots`: only candidates starting with one of these letters.
				if !roots.isEmpty, !roots.contains(letter) { continue }
				// Best case for the candidate's second letter; settled at depth 2.
				let penalty = penaltyOf(letter, chars[0])
				recurse(first + c, letter, 0, 1, penalty, prior?.rootChild(letter), 0)
			}
		}
		guard !cancelled else { return [] }
		return hits.map { Candidate(word: word(Int($0.id)), cost: $0.cost,
									logFreq: log(Double(max(freq(Int($0.id)), 1)) + 1)) }
#else
        return [] // Native failure: keep literal input; no partial static candidates.
#endif
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
        if backend == .cpp, let native = nativeComparison {
            return native.completions(forPrefix: prefix, limit: UInt(max(0, limit))).map(Candidate.init(native:))
        }
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
				// As native: blocked words are not emitted, except the typed text itself.
				if !isSwiftBlocked(e.wordID) || word(id) == prefix {
					out.append(Candidate(word: word(id), cost: 0,
										 logFreq: log(Double(max(freq(id), 1)) + 1)))
				}
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
}
