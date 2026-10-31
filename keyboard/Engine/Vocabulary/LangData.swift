// LangData: mmap reader for langdata.bin (n-grams + static trie).
// IMPLEMENTED: C++ owns validation, packed fuzzy traversal, seed preparation and
// retained DP; Swift owns resource discovery and lifetime.
import Foundation

nonisolated final class LangData {
	let data: Data
	// Default production reader validates/shared-maps through Objective-C++.
	// The separate comparison flag opts into auditing, not native production.
	let nativeComparison: KBPackedLexicon?
	private let compareNativeReads: Bool
	let backend: DecoderCoreBackend
	let formatVersion: Int
	let wordCount: Int
	let biBuckets, biEntCount, triBuckets, triEntCount: Int
	let freqBase, offsBase, biHashBase, biEntBase, triHashBase, triEntBase, trieBase, startersBase, blobBase: Int
	private let trieNodeCount: Int
	private let starterCount: Int
	let trieNodeSize: Int
	let continuationSize: Int
	private let starterSize: Int
	static let empty = 0xFFFFFFFF          // empty-bucket sentinel (ids are < wordCount)
	static let empty16 = 0xFFFF

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
	func starterIDs(limit: Int) -> [Int] {
		guard starterCount > 0 else { return [] }
		return (0..<min(limit, starterCount)).map {
			formatVersion == 5 ? u16(startersBase + starterSize * $0)
				: u32(startersBase + starterSize * $0)
		}
	}

	func u32(_ off: Int) -> Int {
		Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
	}
	func u16(_ off: Int) -> Int {
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

	// MARK: State for GlideAnchors
	var anchorIndex: [UInt16: [Int32]]?

	// MARK: State for PackedTrie
	var hasTrie: Bool { trieNodeCount > 0 }

	// MARK: State for NodeWalk
	var trieRootNode: Int { 0 }

	// MARK: State for GlideAnchors
	//
	// A glide's two most reliable points are its START and END keys. Bucketing every dictionary
	// word by (firstChar,lastChar) lets the decoder fetch words whose endpoints match the swipe and
	// shape-score them directly — recovering a word the beam drops when a middle letter is skipped
	// (the greedy prune misaligns), WITHOUT having to traverse those middle letters. Built lazily on
	// the first glide over the mmap word blob (IDs only ≈ wordCount·4 B heap), then cached; a
	// non-gliding session never pays for it.
    let nativeMetadataLock = NSLock()
    var nativeMetadataReady = false
    /// Model statistics are shared by scorers attached to this immutable pack.
    let mknLock = NSLock()
    var cachedMKN: ModifiedKneserNeyModel?

	// MARK: State for PackedTrie
    var nativeCandidateLexicon: KBPackedLexicon? { nativeComparison }

    /// Swift mirror of the native blocked bitset (PackedLexicon::installBlocked) for the Swift
    /// searches (Debug reference and the no-native fallback): they skip these word IDs
    /// exactly where the native ones do. Installed once at load, before any search.
    private(set) var swiftBlocked = Set<Int32>()
#if DEBUG || KB_REFERENCE_DECODER_YES
    /// Reference twin of PackedLexicon::blockedTrie: the blocked dictionary words alone.
    private(set) var swiftBlockedTrie: SwiftTrie?
#endif
    func installSwiftBlocked(_ terms: [String]) {
        guard swiftBlocked.isEmpty else { return }   // once, like the native call_once
        swiftBlocked = Set(terms.compactMap(trieWordID))
#if DEBUG || KB_REFERENCE_DECODER_YES
        let trie = SwiftTrie()
        for id in swiftBlocked.sorted() { trie.insert(word(Int(id)), freq: freq(Int(id)), id: id) }
        swiftBlockedTrie = trie
#endif
    }
    func isSwiftBlocked(_ id: Int32) -> Bool { !swiftBlocked.isEmpty && swiftBlocked.contains(id) }
}
