import Foundation

extension LangData {
	// MARK: Phase 2 — endpoint (first,last)-letter anchor index for glide candidate generation
    func prepareNativeTextMetadata() {
        nativeMetadataLock.lock(); defer { nativeMetadataLock.unlock() }
        guard !nativeMetadataReady, let native = nativeComparison else { return }
        let ids = native.textMetadataIDs()
        let words = ids.map { word($0.intValue) }
        native.installTextMetadataIDs(ids, characterCounts: words.map { NSNumber(value: $0.count) },
            firstLetters: words.map { NSNumber(value: $0.first?.asciiValue.map(Int.init) ?? -1) },
            lastLetters: words.map { NSNumber(value: $0.last?.asciiValue.map(Int.init) ?? -1) })
        nativeMetadataReady = true
    }

	private static func anchorKey(_ first: UInt8, _ last: UInt8) -> UInt16 { UInt16(first) << 8 | UInt16(last) }

	private func buildAnchorIndex() -> [UInt16: [Int32]] {
		var tmp: [UInt16: [(id: Int32, f: Int)]] = [:]
        // Most corpus forms are printable ASCII. Read their endpoints directly
        // from the mapped bytes rather than constructing and segmenting a String
        // for every word during engine startup. Keep the original Character path
        // for Unicode/control bytes (including combining marks and CR/LF).
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for id in 0..<wordCount {
                let start = blobBase + u32(offsBase + 4 * id)
                let end = blobBase + u32(offsBase + 4 * (id + 1))
                guard end - start >= 2 else { continue }
                var printableASCII = true
                for position in start..<end where bytes[position] < 32 || bytes[position] >= 127 {
                    printableASCII = false
                    break
                }
                let first: UInt8, last: UInt8
                if printableASCII {
                    first = bytes[start]; last = bytes[end - 1]
                } else {
                    let w = word(id)
                    guard w.count >= 2, let a = w.first?.asciiValue, let b = w.last?.asciiValue else { continue }
                    first = a; last = b
                }
                tmp[Self.anchorKey(first, last), default: []].append((Int32(id), freq(id)))
            }
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
        if backend == .cpp, let native = nativeComparison {
            prepareNativeTextMetadata(); native.warmGlideAnchors(); return
        }
		guard hasTrie, anchorIndex == nil else { return }
		anchorIndex = buildAnchorIndex()
	}

	/// Words whose FIRST letter ∈ `first` and LAST letter ∈ `last`, most-frequent first, capped at
	/// `perBucket` per (first,last) pair (so a common endpoint pair can't flood the pool). The
	/// endpoint-anchored candidate source (Phase 2); the caller shape-scores what comes back.
	func glideAnchorWords(first: [Character], last: [Character], perBucket: Int) -> [String] {
        if backend == .cpp, let native = nativeComparison {
            prepareNativeTextMetadata()
            return native.anchorWords(withFirst: Data(first.compactMap(\.asciiValue)), last: Data(last.compactMap(\.asciiValue)), perBucket: UInt(max(0, perBucket)))
        }
		guard hasTrie else { return [] }
		if anchorIndex == nil { anchorIndex = buildAnchorIndex() }
		guard let idx = anchorIndex else { return [] }
		var ids: [Int32] = []
		var seen = Set<Int32>()
		for fc in first { guard let a = fc.asciiValue else { continue }
			for lc in last { guard let b = lc.asciiValue else { continue }
				guard let bucket = idx[Self.anchorKey(a, b)] else { continue }
				for id in bucket.prefix(perBucket) where !isSwiftBlocked(id) && seen.insert(id).inserted { ids.append(id) }
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

    var modifiedKneserNey: ModifiedKneserNeyModel {
        mknLock.lock()
        defer { mknLock.unlock() }
        if let cachedMKN { return cachedMKN }
        let model = ModifiedKneserNeyModel(data: self)
        cachedMKN = model
        return model
    }

    func forEachTrigram(_ visit: (Int32, Int32, [(word: Int32, count: Int)]) -> Void) {
        for i in 0..<triBuckets {
            let base = triHashBase + (formatVersion == 5 ? 12 : 20) * i
            let key = u32(base)
            if formatVersion < 5 && key == Self.empty { continue }
            let first = Int32(formatVersion == 5 ? key >> 16 : key)
            let second = Int32(formatVersion == 5 ? key & 0xffff : u32(base + 4))
            let totalOffset = formatVersion == 5 ? 4 : 8
            let start = u32(base + totalOffset + 4)
            let count: Int
            if formatVersion == 5 {
                let end = i + 1 < triBuckets ? u32(base + 12 + 8) : triEntCount
                count = end - start
            } else {
                count = u32(base + 16)
            }
            visit(first, second, entries(triEntBase, start, start + count))
        }
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
		if formatVersion == 6 {
			guard ctx >= 0, Int(ctx) < wordCount else { return nil }
			var lower = 0, upper = biBuckets
			while lower < upper {
				let middle = lower + (upper - lower) / 2
				if u32(biHashBase + 16 * middle) < Int(ctx) { lower = middle + 1 } else { upper = middle }
			}
			guard lower < biBuckets else { return nil }
			let base = biHashBase + 16 * lower
			guard u32(base) == Int(ctx) else { return nil }
			return (u32(base + 4), u32(base + 8), u32(base + 12))
		}
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
		if formatVersion == 6 {
			guard w1 >= 0, w2 >= 0, Int(w1) < wordCount, Int(w2) < wordCount else { return nil }
			let key = (UInt64(UInt32(w1)) << 32) | UInt64(UInt32(w2))
			var lower = 0, upper = triBuckets
			while lower < upper {
				let middle = lower + (upper - lower) / 2
				let base = triHashBase + 20 * middle
				let slot = (UInt64(u32(base)) << 32) | UInt64(u32(base + 4))
				if slot < key { lower = middle + 1 } else { upper = middle }
			}
			guard lower < triBuckets else { return nil }
			let base = triHashBase + 20 * lower
			guard u32(base) == Int(w1), u32(base + 4) == Int(w2) else { return nil }
			return (u32(base + 8), u32(base + 12), u32(base + 16))
		}
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
}
