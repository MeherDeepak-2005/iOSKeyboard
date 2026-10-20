// MIGRATION-FILE: planned SPLIT | See CPP_IOS_MIGRATION_PLAN.md.
// IMPLEMENTED: C++ validation, packed fuzzy traversal, seed preparation and retained DP are primary.
// SWIFT_IOS owns resource/lifecycle transport; other marked reads/Glide access remain to migrate.
import Foundation

// LangData: mmap reader for langdata.bin (n-grams + static trie) — extracted from Keyboardengine.swift.

// MIGRATION: planned CPP_CORE | stage=search | target=IncrementalSearch
// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
nonisolated struct IncrementalLexiconSeed {
	let word: String
	let bytes: [UInt8]
	let logFreq: Double
}

/// Exact incremental OSA channel costs over a bounded set of static-lexicon words.
/// Appending one typed byte advances one DP column; it does not walk the trie again.
/// The seed set includes every root branch that can fit the production 3.6 normal
/// radius, so normal-radius output remains equivalent to the full mapped-trie walk.
// MIGRATION: planned SPLIT | stage=search | target=IncrementalSearch
// MIGRATION-SPLIT: CPP_CORE owns retained seed/DP state and channel candidate mathematics; SWIFT_IOS owns comparison-mode lifetime, native buffer conversion and audit diagnostics.
nonisolated final class IncrementalDecodeSession {
	private let seeds: [IncrementalLexiconSeed]
	private let offsets: [Int]
	private var previous: [Double]
	private var previousPrevious: [Double]
	private var scratch: [Double]
	private(set) var typed: [UInt8] = []
	private let nativeSearchComparison: KBIncrementalSearch?
	private let nativeSearchPrimary: KBIncrementalSearch?
	let backend: DecoderCoreBackend
	private(set) var nativeParityFailure: String?
	var hasNativeSearchComparison: Bool { nativeSearchComparison != nil }

	// MIGRATION: planned SPLIT | stage=search | target=IncrementalSearch
	// MIGRATION-SPLIT: CPP_CORE initializes native seeds/DP; SWIFT_IOS controls lifetime/transport. The Swift reference is Debug/test-only.
	init(seeds: [IncrementalLexiconSeed], compareNativeSearch: Bool = false,
        backend requestedBackend: DecoderCoreBackend = .cpp) {
#if DEBUG || KB_REFERENCE_DECODER_YES
        var primary: KBIncrementalSearch?
        var failure: String?
        if requestedBackend == .cpp, !compareNativeSearch {
            do {
                primary = try KBIncrementalSearch(words: seeds.map(\.word),
                    spellings: seeds.map { Data($0.bytes) },
                    logFrequencies: seeds.map { NSNumber(value: $0.logFreq) })
            } catch { failure = "native initialization fallback: \(error)" }
        }
        nativeSearchPrimary = primary
        backend = primary == nil ? .swiftReference : .cpp
        nativeParityFailure = failure
        // Native production never allocates duplicate Swift seed/DP buffers.
        let seeds = primary == nil ? seeds : []
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
		if compareNativeSearch {
			do {
				nativeSearchComparison = try KBIncrementalSearch(words: seeds.map(\.word),
					spellings: seeds.map { Data($0.bytes) },
					logFrequencies: seeds.map { NSNumber(value: $0.logFreq) })
			} catch {
				nativeSearchComparison = nil
				nativeParityFailure = "native init: \(error)"
			}
		} else {
			nativeSearchComparison = nil
		}
		resetRows()
#else
        let seedsInput = seeds
        precondition(requestedBackend == .cpp && !compareNativeSearch,
            "Swift reference search requires a Debug/test build")
        self.seeds = []; offsets = []
        previous = []; previousPrevious = []; scratch = []
        nativeSearchComparison = nil
        backend = .cpp
        do {
            nativeSearchPrimary = try KBIncrementalSearch(words: seedsInput.map(\.word),
                spellings: seedsInput.map { Data($0.bytes) },
                logFrequencies: seedsInput.map { NSNumber(value: $0.logFreq) })
        } catch {
            nativeSearchPrimary = nil
            nativeParityFailure = "native initialization: \(error)"
        }
#endif
	}

    init(nativeSeeds: KBIncrementalSeedSet) throws {
        nativeSearchPrimary = try KBIncrementalSearch(seedSet: nativeSeeds)
        nativeSearchComparison = nil
        backend = .cpp
        seeds = []; offsets = []
        previous = []; previousPrevious = []; scratch = []
    }

    var seedCount: Int { nativeSearchPrimary.map { Int($0.seedCount) } ?? seeds.count }

	/// Advances an append-only word in O(total seeded spelling bytes). A cursor edit,
	/// changed prefix deterministically rebuilds the retained columns. Native search
	/// reuses its existing columns for one backspace with unchanged surviving taps;
	/// further deletions or changed tap evidence use the reference rebuild path.
	@discardableResult
	// MIGRATION: planned SPLIT | stage=search | target=IncrementalSearch
	// MIGRATION-SPLIT: CPP_CORE advances/resets normalized English DP columns; SWIFT_IOS normalizes boundary input, packs optional taps and audits retained identity/result parity.
	func advance(to word: String, taps: [KeyTap?]? = nil) -> Bool {
		let normalized = word.lowercased()
        let bytes = Array(normalized.utf8)
        if let native = nativeSearchPrimary {
            do {
                let buffers = NativeTapBuffers(taps: taps, expectedCount: bytes.count)
                let accepted = try native.advanceNormalizedWord(normalized,
                    tapOffsets: buffers?.offsets, tapValidity: buffers?.validity)
                if accepted { typed = bytes }
                return accepted
            } catch {
                nativeParityFailure = "native advance: \(error)"
                return false
            }
        }
#if DEBUG || KB_REFERENCE_DECODER_YES
        var accepted = false
		defer {
			if let native = nativeSearchComparison {
				do {
					let buffers = NativeTapBuffers(taps: taps, expectedCount: bytes.count)
					let nativeAccepted = try native.advanceNormalizedWord(normalized,
						tapOffsets: buffers?.offsets, tapValidity: buffers?.validity)
					if nativeAccepted != accepted || native.typed != String(decoding: typed, as: UTF8.self) {
						nativeParityFailure = nativeParityFailure ?? "native advance/state: \(word)"
					}
				} catch { nativeParityFailure = nativeParityFailure ?? "native advance: \(error)" }
			}
		}
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
		accepted = typed == bytes
		return accepted
#else
        return false
#endif
	}

	// MIGRATION: planned SPLIT | stage=search | target=IncrementalSearch
	// MIGRATION-SPLIT: CPP_CORE applies channel/first-letter costs and emits seed-ordered candidates; SWIFT_IOS converts owned evidence and audits coverage, order and Double parity.
	func candidates(maxCost: Double) -> [Candidate] {
        if let native = nativeSearchPrimary {
            do {
                return try native.candidates(withMaxCost: maxCost).map {
                    Candidate(word: $0.word, cost: $0.cost, logFreq: $0.logFrequency)
                }
            } catch {
                nativeParityFailure = "native candidates: \(error)"
                return []
            }
        }
#if DEBUG || KB_REFERENCE_DECODER_YES
        guard !typed.isEmpty else {
			compareNativeCandidates([], maxCost: maxCost)
			return []
		}
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
		compareNativeCandidates(result, maxCost: maxCost)
		return result
#else
        return []
#endif
	}

#if DEBUG || KB_REFERENCE_DECODER_YES
	// Offline shadow audit: never substitutes native candidates into production.
	private func compareNativeCandidates(_ swift: [Candidate], maxCost: Double) {
		guard let native = nativeSearchComparison else { return }
		do {
			let cpp = try native.candidates(withMaxCost: maxCost)
			guard swift.count == cpp.count else {
				nativeParityFailure = nativeParityFailure ?? "native candidate coverage: \(typed) radius \(maxCost)"
				return
			}
			for index in swift.indices {
				if swift[index].word != cpp[index].word
					|| !NativeDecoderParity.equal(swift[index].cost, cpp[index].cost)
					|| !NativeDecoderParity.equal(swift[index].logFreq, cpp[index].logFrequency) {
					nativeParityFailure = nativeParityFailure ?? "native candidate evidence/order: \(swift[index].word)"
					return
				}
			}
		} catch { nativeParityFailure = nativeParityFailure ?? "native candidates: \(error)" }
	}

	// MIGRATION: planned CPP_CORE | stage=search | target=IncrementalSearch
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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

	// MIGRATION: planned CPP_CORE | stage=search | target=IncrementalSearch
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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
#endif
}

// MIGRATION: planned SPLIT | stage=search | target=PackedLexicon
// MIGRATION-SPLIT: CPP_CORE owns packed validation, reads and search; SWIFT_IOS discovers/maps/retains resources and runs opt-in comparison audits.
nonisolated final class LangData {
	private let data: Data
	// Default production reader validates/shared-maps through Objective-C++.
	// The separate comparison flag opts into auditing, not native production.
	private let nativeComparison: KBPackedLexicon?
	private let compareNativeReads: Bool
	let backend: DecoderCoreBackend
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

	// MIGRATION: planned SPLIT | stage=search | target=MappedVocabulary
	// MIGRATION-SPLIT: SWIFT_IOS opens and retains one mapped backing; CPP_CORE validates bytes, offsets, versions, and initializes the reader.
	init?(url: URL, compareNativeReads: Bool = false, backend: DecoderCoreBackend = .cpp) {
		self.compareNativeReads = compareNativeReads
		self.backend = compareNativeReads ? .swiftReference : backend
		let d: Data
		let comparison: KBPackedLexicon?
		if compareNativeReads || backend == .cpp {
			// One immutable backing shared by Swift and native readers, kept alive
			// by both. Data(referencing:) avoids a second mapped corpus allocation.
			guard let backing = try? NSData(contentsOf: url, options: .alwaysMapped),
				let reader = try? KBPackedLexicon(backing: backing) else { return nil }
			d = Data(referencing: backing)
			comparison = reader
		} else {
			guard let mapped = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
			d = mapped
			comparison = nil
		}
		guard d.count >= 28 else { return nil }
		func u32(_ off: Int) -> Int {
			Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
		}
		guard u32(0) == 0x4B424C4D else { return nil }                 // magic "KBLM"
		let version = u32(4)
		guard version >= 2, version <= 6 else { return nil }
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
		nativeComparison = comparison
	}


	struct NativeReadParityReport {
		let words: Int
		let bigramContexts: Int
		let trigramContexts: Int
		let sharedBacking: Bool
	}
	enum NativeReadParityError: Error, Equatable {
		case comparisonDisabled
		case mismatch(String)
	}

	/// Explicit offline read comparison. Production retained search uses C++;
	/// this audit independently checks the reference packed-read results. Full-word arrays are released after this audit, not cached.
	func verifyNativeReadParity() throws -> NativeReadParityReport {
#if DEBUG || KB_REFERENCE_DECODER_YES
		guard compareNativeReads, let native = nativeComparison else { throw NativeReadParityError.comparisonDisabled }
		func check(_ condition: Bool, _ message: String) throws {
			if !condition { throw NativeReadParityError.mismatch(message) }
		}
		let shared = data.withUnsafeBytes { $0.baseAddress == native.backingAddress }
		try check(shared, "mapped backing address")
		try check(native.formatVersion == formatVersion && native.wordCount == wordCount, "header")
		do {
			let words = try native.allWords()
			let frequencies = try native.allFrequencies()
			try check(words.count == wordCount && frequencies.count == wordCount, "word count")
			for id in 0..<wordCount {
				try check(words[id] == word(id) && frequencies[id].intValue == freq(id), "word/frequency \(id)")
			}
		}
		for limit in [0, 1, starterCount, starterCount + 1] {
			let ids = try native.starterIDs(withLimit: UInt(limit)).map { $0.intValue }
			try check(ids == starterIDs(limit: limit), "starters \(limit)")
		}
		func compare(_ swift: (total: Int, entries: [(word: Int32, count: Int)])?,
					 _ cpp: KBNgramRead?, _ label: String) throws {
			guard let swift, let cpp else {
				try check(swift == nil && cpp == nil, label + " presence")
				return
			}
			try check(swift.total == cpp.total && swift.entries.count == cpp.wordIDs.count
				&& cpp.wordIDs.count == cpp.counts.count, label + " counts")
			for i in swift.entries.indices {
				try check(swift.entries[i].word == cpp.wordIDs[i].int32Value
					&& swift.entries[i].count == cpp.counts[i].intValue, label + " entry \(i)")
			}
		}
		for id in 0..<wordCount {
			try compare(bigrams(after: Int32(id)), native.bigrams(after: Int32(id), limit: UInt.max), "bigram \(id)")
			try compare(bigrams(after: Int32(id), limit: 1), native.bigrams(after: Int32(id), limit: 1), "bigram cap \(id)")
		}
		var contexts: [[NSNumber]] = []
		for i in 0..<triBuckets {
			let base = triHashBase + (formatVersion == 5 ? 12 : 20) * i
			let key = u32(base)
			if formatVersion < 5 && key == Self.empty { continue }
			contexts.append(formatVersion == 5
				? [NSNumber(value: key >> 16), NSNumber(value: key & 0xffff)]
				: [NSNumber(value: key), NSNumber(value: u32(base + 4))])
		}
		try check(contexts == native.trigramContexts(), "trigram context enumeration")
		for pair in contexts {
			let first = pair[0].int32Value, second = pair[1].int32Value
			try compare(trigrams(after: first, second), native.trigrams(after: first, second: second, limit: UInt.max), "trigram \(pair)")
			try compare(trigrams(after: first, second, limit: 1), native.trigrams(after: first, second: second, limit: 1), "trigram cap \(pair)")
		}
		return NativeReadParityReport(words: wordCount, bigramContexts: wordCount,
			trigramContexts: contexts.count, sharedBacking: shared)
#else
        throw NativeReadParityError.comparisonDisabled
#endif
	}

	/// Sentence-initial word ids, most frequent first (empty on v2/v3). The cold-start
	/// suggestion bar ranks by these instead of global frequency, so it surfaces openers
	/// (i, the, i'm, you) rather than mid-sentence function words (and, of, to).
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func starterIDs(limit: Int) -> [Int] {
		guard starterCount > 0 else { return [] }
		return (0..<min(limit, starterCount)).map {
			formatVersion == 5 ? u16(startersBase + starterSize * $0)
				: u32(startersBase + starterSize * $0)
		}
	}

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func u32(_ off: Int) -> Int {
		Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func u16(_ off: Int) -> Int {
		Int(UInt16(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt16.self) }))
	}

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func freq(_ id: Int) -> Int { u32(freqBase + 4 * id) }
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func word(_ id: Int) -> String {
		let a = blobBase + u32(offsBase + 4 * id), b = blobBase + u32(offsBase + 4 * (id + 1))
		return String(decoding: data[a..<b], as: UTF8.self)
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private static func anchorKey(_ first: UInt8, _ last: UInt8) -> UInt16 { UInt16(first) << 8 | UInt16(last) }

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func warmGlideAnchorIndex() {
		guard hasTrie, anchorIndex == nil else { return }
		anchorIndex = buildAnchorIndex()
	}

	/// Words whose FIRST letter ∈ `first` and LAST letter ∈ `last`, most-frequent first, capped at
	/// `perBucket` per (first,last) pair (so a common endpoint pair can't flood the pool). The
	/// endpoint-anchored candidate source (Phase 2); the caller shape-scores what comes back.
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private static func mix64(_ x: UInt64) -> UInt64 {
		var v = x
		v ^= v >> 30; v = v &* 0xBF58476D1CE4E5B9
		v ^= v >> 27; v = v &* 0x94D049BB133111EB
		v ^= v >> 31
		return v
	}

	/// Continuations of a one-word context, best first. `total` is the true
	/// (pre-truncation) context count, so ratios remain honest probabilities.
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func bigrams(after ctx: Int32, limit: Int? = nil) -> (total: Int, entries: [(word: Int32, count: Int)])? {
		guard let range = bigramRange(after: ctx) else { return nil }
		let count = min(range.count, limit ?? range.count)
		return (range.total, entries(biEntBase, range.start, range.start + count))
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func trigrams(after w1: Int32, _ w2: Int32, limit: Int? = nil) -> (total: Int, entries: [(word: Int32, count: Int)])? {
		guard let range = trigramRange(after: w1, w2) else { return nil }
		let count = min(range.count, limit ?? range.count)
		return (range.total, entries(triEntBase, range.start, range.start + count))
	}

    /// Model statistics are shared by scorers attached to this immutable pack.
    private let mknLock = NSLock()
    private var cachedMKN: ModifiedKneserNeyModel?
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
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func bigramCounts(after ctx: Int32, words: [Int32])
		-> (total: Int, types: Int, counts: [Int32: Int])? {
		guard let range = bigramRange(after: ctx) else { return nil }
		return selectedCounts(base: biEntBase, range: range, words: words)
	}

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func trigramCounts(after w1: Int32, _ w2: Int32, words: [Int32])
		-> (total: Int, types: Int, counts: [Int32: Int])? {
		guard let range = trigramRange(after: w1, w2) else { return nil }
		return selectedCounts(base: triEntBase, range: range, words: words)
	}

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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
	// v2-v4 and v6 use 14-byte nodes with UInt32 IDs; v5 uses 12-byte nodes with UInt16 IDs.
	// Node 0 is the root. Walking these records in place replaces the ~60k-word heap
	// trie that used to be rebuilt (and count as dirty memory) at every launch.

	var hasTrie: Bool { trieNodeCount > 0 }

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func nodeByte(_ node: Int, _ off: Int) -> Int {
		Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + trieNodeSize * node + off, as: UInt8.self) })
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func nodeU32(_ node: Int, _ off: Int) -> UInt32 {
		UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: trieBase + trieNodeSize * node + off, as: UInt32.self) })
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func nodeWordID(_ node: Int) -> UInt32 {
		if formatVersion == 5 {
			let id = u16(trieBase + trieNodeSize * node + 6)
			return id == Self.empty16 ? UInt32(Self.empty) : UInt32(id)
		}
		return nodeU32(node, 6)
	}
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func nodeMaxFreq(_ node: Int) -> UInt32 {
		nodeU32(node, formatVersion == 5 ? 8 : 10)
	}

	/// Walk the exact byte path from the root; nil when it leaves the trie.
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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

	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func trieHasPrefix(_ lw: String) -> Bool { trieNode(for: Array(lw.utf8)) != nil }
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func trieWordID(_ lw: String) -> Int32? {
		guard let n = trieNode(for: Array(lw.utf8)) else { return nil }
		let id = nodeWordID(n)
		return id == UInt32(Self.empty) ? nil : Int32(bitPattern: id)
	}

	/// Materializes only root branches that can possibly fit the normal production
	/// channel radius. For words of length five or more, a wrong-root path that avoids
	/// direct substitution already costs firstPenalty + insertion/deletion = 4.1, so
	/// this direct-substitution gate is complete for the 3.6 radius.
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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

	// MIGRATION: planned SPLIT | stage=search | target=PackedLexicon
	// MIGRATION-SPLIT: CPP_CORE selects immutable mapped seeds/offsets and applies boost snapshots; SWIFT_IOS supplies boundary tap/personal data and owns lifetime.
    var nativeCandidateLexicon: KBPackedLexicon? { nativeComparison }

	func nativeIncrementalSeeds(typedFirst: UInt8, firstTap: KeyTap?,
		stateCap: Int = 24_000, boosts: [String: Int] = [:]) throws -> KBIncrementalSeedSet? {
		guard let native = nativeComparison else { throw NativeReadParityError.comparisonDisabled }
		guard stateCap >= 0 else { return nil }
		        let ordered = boosts.sorted { $0.key < $1.key }
        return try native.incrementalSeeds(forTypedFirst: typedFirst,
            firstTapDX: firstTap?.dx ?? 0, firstTapDY: firstTap?.dy ?? 0,
            hasFirstTap: firstTap != nil, stateCap: UInt(stateCap),
            boostWords: ordered.map(\.key), boostCounts: ordered.map { NSNumber(value: $0.value) })
	}

	/// The same weighted-DP fuzzy search as `Trie.search` — identical costs, identical
	/// first-letter policy — run in place over the mapped node records. One flat DP
	/// buffer for the whole walk; one `withUnsafeBytes` for the whole walk so the hot
	/// loop does raw unaligned loads, not per-node closures.
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func trieSearch(_ typed: String, maxCost: Double, taps: [KeyTap?]? = nil,
					prior: TrieSearchPrior? = nil,
					shouldCancel: (() -> Bool)? = nil) -> [Candidate] {
        if backend == .cpp, let native = nativeComparison {
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
				if id != UInt32(Self.empty), finalCost - (priorNode?.terminalBonus ?? 0) <= maxCost {
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
#else
        return [] // Native failure: keep literal input; no partial static candidates.
#endif
	}

	/// Children (label byte, subtree max frequency) of the node at `prefix` — the
	/// next-character distribution that key-target resizing feeds on. Empty prefix =
	/// root = word-initial letters. A handful of clean-page reads, nothing more.
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func trieCompletions(prefix: String, limit: Int) -> [Candidate] {
		guard limit > 0, let start = trieNode(for: Array(prefix.utf8)) else { return [] }
		// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
		// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
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
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func trieChildren(ofNode node: Int) -> [(label: UInt8, node: Int)] {
		guard hasTrie else { return [] }
		let first = Int(nodeU32(node, 2)), count = nodeByte(node, 1)
		return (0..<count).map { (UInt8(nodeByte(first + $0, 0)), first + $0) }
	}
	/// Allocation-free equivalent of `trieChildren(ofNode:)`, same order. The glide beam
	/// visits every hypothesis's children at each depth, so returning a fresh array there
	/// churned the heap on the decode's hot path; this iterates in place instead.
	@inline(__always)
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func forEachChild(ofNode node: Int, _ body: (_ label: UInt8, _ node: Int) -> Void) {
		guard hasTrie else { return }
		let first = Int(nodeU32(node, 2)), count = nodeByte(node, 1)
		for i in 0..<count { body(UInt8(nodeByte(first + i, 0)), first + i) }
	}
	/// The word ending at this node, or nil if the node is a non-terminal prefix.
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func trieWord(atNode node: Int) -> String? {
		let id = nodeWordID(node)
		return id == UInt32(Self.empty) ? nil : word(Int(Int32(bitPattern: id)))
	}
	/// Max corpus frequency anywhere in this node's subtree — lets
	/// glide's beam keep frequent-but-imperfect prefixes alive so context can rescue them.
	// MIGRATION: planned CPP_CORE | stage=search | target=PackedLexicon
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	func trieMaxFreq(ofNode node: Int) -> UInt32 { nodeMaxFreq(node) }
}

/// Interpolated modified Kneser–Ney on retained pack entries. Historical context
/// totals include pruned successors, so denominators must sum retained counts.
/// No add-one or sparse-context heuristic is applied to observed vocabulary.
nonisolated struct ModifiedKneserNeyModel {
    struct Discounts {
        let values: [Double]
        init(counts: [Int]) {
            var histogram = [Int](repeating: 0, count: 5)
            for count in counts where count > 0 && count <= 4 { histogram[count] += 1 }
            self.init(histogram: histogram)
        }
        init(histogram: [Int]) {
            let n = histogram.map(Double.init)
            let y = n[1] > 0 ? n[1] / (n[1] + 2 * n[2]) : 0.75
            values = (1...3).map { k in
                // Pruned packs may lack entire frequency buckets. Use a bounded
                // absolute discount when the Chen–Goodman estimate is undefined.
                guard n[k] > 0, n[k + 1] > 0 else { return 0.75 }
                return min(Double(k), max(0, Double(k) - Double(k + 1) * y * n[k + 1] / n[k]))
            }
        }
        func discount(_ count: Int) -> Double { count > 0 ? values[min(count, 3) - 1] : 0 }
    }
    struct Context {
        let total: Int
        let discountMass: Double
        let counts: [Int32: Double]
        init(entries: [(word: Int32, count: Int)], discounts: Discounts) {
            total = entries.reduce(0) { $0 + $1.count }
            var mass = 0.0
            var prepared: [Int32: Double] = [:]
            // ID order keeps summation identical across the reference and harness.
            for entry in entries.sorted(by: { $0.word < $1.word }) where entry.count > 0 {
                let discount = discounts.discount(entry.count)
                mass += discount
                prepared[entry.word] = max(Double(entry.count) - discount, 0)
            }
            discountMass = mass
            counts = prepared
        }
    }
    let unigrams: [Int32: Int]
    let unigramTotal: Double
    let bigrams: [Int32: Context]
    let trigramDiscounts: Discounts

    init(data: LangData) {
        var uni: [Int32: Int] = [:]
        var rawBi: [Int32: [Int32: Int]] = [:]
        var continuationBi: [Int32: [Int32: Int]] = [:]
        var triHistogram = [Int](repeating: 0, count: 5)
        var hasTrigrams = false
        data.forEachTrigram { _, second, entries in
            for entry in entries where entry.count > 0 {
                hasTrigrams = true
                continuationBi[second, default: [:]][entry.word, default: 0] += 1
                if entry.count <= 4 { triHistogram[entry.count] += 1 }
            }
        }
        for id in 0..<data.wordCount {
            guard let hit = data.bigrams(after: Int32(id)) else { continue }
            for entry in hit.entries where entry.count > 0 {
                uni[entry.word, default: 0] += 1
                if !hasTrigrams { rawBi[Int32(id), default: [:]][entry.word] = entry.count }
            }
        }
        // Build discounts from histograms without retaining the full trigram corpus.
        trigramDiscounts = Discounts(histogram: triHistogram)
        let lower = hasTrigrams ? continuationBi : rawBi
        var biHistogram = [Int](repeating: 0, count: 5)
        for row in lower.values {
            for count in row.values where count > 0 && count <= 4 { biHistogram[count] += 1 }
        }
        let discounts = Discounts(histogram: biHistogram)
        bigrams = lower.mapValues { Context(entries: $0.map { (word: $0.key, count: $0.value) }, discounts: discounts) }
        unigrams = uni
        // Reserve a single unknown bucket for absent continuations and true OOVs.
        unigramTotal = Double(uni.values.reduce(0, +)) + 0.5
    }
}
