// Retained incremental decode session: one search that grows with the word.
import Foundation

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
	/// Touch evidence each retained column was computed with (mirrors IncrementalSearch.cpp).
	private var appliedTaps: [KeyTap?] = []
	private let nativeSearchComparison: KBIncrementalSearch?
	private let nativeSearchPrimary: KBIncrementalSearch?
	let backend: DecoderCoreBackend
	private(set) var nativeParityFailure: String?
	var hasNativeSearchComparison: Bool { nativeSearchComparison != nil }

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
		// Reuse a retained prefix only if it was computed from the same touches; retyping
		// the same letters at new positions must not keep stale costs.
		let prefixTapsMatch = (0..<min(bytes.count, typed.count)).allSatisfy { i in
			let tap = tapRow?[i], old = appliedTaps[i]
			if let tap, let old { return tap.dx == old.dx && tap.dy == old.dy }
			return tap == nil && old == nil
		}
		if bytes.count < typed.count || !bytes.starts(with: typed) || !prefixTapsMatch {
			resetRows()
			typed.removeAll(keepingCapacity: true)
			appliedTaps.removeAll(keepingCapacity: true)
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
				candidateFirst: first, typedFirst: typed[0], typedSecond: typed.count > 1 ? typed[1] : 0,
				candidateSecond: seed.bytes.count > 1 ? seed.bytes[1] : 0)
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

	private func resetRows() {
		for (index, seed) in seeds.enumerated() {
			let offset = offsets[index]
			previous[offset] = 0
			for column in 1...seed.bytes.count {
				let skip = Trie.deletionCost(seed.bytes[column - 1], after: column >= 2 ? seed.bytes[column - 2] : 0, typed: 0)
				previous[offset + column] = previous[offset + column - 1] + skip
			}
		}
	}

	private func append(_ byte: UInt8, tap: KeyTap?) {
		let typedIndex = typed.count + 1
		let typedPrevious = typed.last ?? 0
		for (index, seed) in seeds.enumerated() {
			let offset = offsets[index]
			scratch[offset] = Double(typedIndex) * Trie.insCost
			for column in 1...seed.bytes.count {
				let candidate = seed.bytes[column - 1]
				let skip = Trie.deletionCost(candidate, after: column >= 2 ? seed.bytes[column - 2] : 0, typed: byte)
				let insertion = previous[offset + column] + Trie.insertionCost(byte, after: typedPrevious, candidate: candidate)
				let deletion = scratch[offset + column - 1] + skip
				let substitution = previous[offset + column - 1]
					+ KB.subCost(candidate, typed: byte, tap: tap, typedFirst: typedIndex == 1)
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
		appliedTaps.append(tap)
	}
#endif
}
