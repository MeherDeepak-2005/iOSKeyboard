import Foundation
import Testing
@testable import keyboard

struct NativeSearchParityTests {
    @Test func packedNativeTraversalMatchesReferenceFundingAndCancellation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("keyboard/langdata.bin")
        let reference = try #require(LangData(url: url, backend: .swiftReference))
        let production = try #require(LangData(url: url))
        let backing = try NSData(contentsOf: url, options: .alwaysMapped)
        let native = try KBPackedLexicon(backing: backing)
        let priors: [TrieSearchPrior?] = [nil, TrieSearchPrior(likelyWords: []),
            TrieSearchPrior(likelyWords: ["correction", "coercion", "hello", "kindly"]),
            TrieSearchPrior(scoredWords: [("correction", -2), ("hello", -6)])]
        for word in ["", "a", "id", "teh", "dont", "hellp", "colpur", "coeevitjkn", "correcgion", "café"] {
            for prior in priors {
                for radius in [0.0, 1.6, 3.6, 7.2] {
                    let taps: [KeyTap?] = word.utf8.enumerated().map { index, _ in
                        index % 2 == 0 ? KeyTap(dx: 0.1, dy: -0.08) : nil
                    }
                    let expected = reference.trieSearch(word, maxCost: radius, taps: taps, prior: prior)
                    let funding = prior?.nativeFundingSnapshot()
                    let buffers = NativeTapBuffers(taps: taps, expectedCount: word.utf8.count)
                    let actual = try native.search(word: word, maxCost: radius,
                        tapOffsets: buffers?.offsets, tapValidity: buffers?.validity,
                        fundedWords: funding?.words, fundedBonuses: funding?.bonuses, shouldCancel: nil)
                    try NativePerformanceHarness.requireParity(expected, actual)
                    let defaultResult = production.trieSearch(word, maxCost: radius, taps: taps, prior: prior)
                    #expect(defaultResult.map(\.word) == expected.map(\.word))
                }
            }
        }
        #expect(try native.search(word: "coeevitjkn", maxCost: 7.2,
            tapOffsets: nil, tapValidity: nil, fundedWords: nil, fundedBonuses: nil,
            shouldCancel: { true }).isEmpty)
        #expect(reference.trieSearch("coeevitjkn", maxCost: 7.2, shouldCancel: { true }).isEmpty)
    }

    @Test func modifiedKneserNeyDiscountsAndMassMatchGoldenValues() {
        let discounts = ModifiedKneserNeyModel.Discounts(histogram: [0, 8, 4, 2, 1])
        #expect(discounts.values == [0.5, 1.25, 2.0])
        #expect(discounts.discount(0) == 0)
        #expect(discounts.discount(9) == 2)
        let row = ModifiedKneserNeyModel.Context(
            entries: [(word: 0, count: 1), (word: 1, count: 2), (word: 2, count: 4)],
            discounts: discounts)
        #expect(row.total == 7)
        #expect(row.discountMass == 3.75)
        #expect(row.counts == [0: 0.5, 1: 0.75, 2: 2.0])
        #expect(row.counts.values.reduce(0, +) + row.discountMass == Double(row.total))
        let sparse = ModifiedKneserNeyModel.Discounts(counts: [5, 100])
        #expect(sparse.values == [0.75, 0.75, 0.75])
    }

    @MainActor @Test func nativeLanguageScoresMatchReferenceWithPersonalAndOOVEvidence() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let lexicon = Lexicon()
        lexicon.load(from: root.appendingPathComponent("keyboard/langdata.bin"))
        let data = try #require(lexicon.languageDataSnapshot())
        let user = UserModel(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("native-score-\(UUID().uuidString).json"))
        for _ in 0..<7 { user.learn(context: ["possibly", "receive"], word: "correction") }
        let native = NgramScorer(user: user)
        let reference = NgramScorer(user: user, backend: .swiftReference)
        native.attach(data: data, resolveID: { lexicon.wordID($0) }, lexicon: lexicon)
        reference.attach(data: data, resolveID: { lexicon.wordID($0) }, lexicon: lexicon)
        #expect(native.backend == .cpp)
        let words = ["correction", "coeevitjkn", "colour", "brb", "can't", "physician", "xyzunknown"]
        for context in [[], ["auto"], ["possibly", "receive"], ["definitely", "decided"], ["unknowncontextxyz"]] {
            let actual = native.logProbs(words, context: context)
            let expected = reference.logProbs(words, context: context)
            #expect(actual.count == expected.count)
            for index in actual.indices {
                #expect(NativeDecoderParity.equal(actual[index], expected[index]))
            }
        }
        #expect(native.logProbs([], context: []).isEmpty)
        #expect(native.nativeScoringFailure == nil)
        #expect(throws: (any Error).self) {
            try KBLanguageScorer.scores(forRows: Data([1]), corpusTotal: 1,
                bigramTotal: 0, bigramDiscountMass: 0, trigramTotal: 0, trigramDiscountMass: 0)
        }
    }

    @MainActor @Test func lexiconCreatesNativeProductionSessionWithoutOptIn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let lexicon = Lexicon()
        lexicon.load(from: root.appendingPathComponent("keyboard/langdata.bin"))
        let session = try #require(lexicon.makeIncrementalDecodeSession(
            typedFirst: UInt8(ascii: "c"), firstTap: nil))
        #expect(session.backend == .cpp)
        #expect(!session.hasNativeSearchComparison)
        #expect(session.advance(to: "coeevitjkn"))
        #expect(session.candidates(maxCost: 7.2).contains { $0.word == "correction" })
    }

    @Test func nativeProductionPersonalizationMatchesIndependentSwiftReference() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reader = try #require(LangData(url: root.appendingPathComponent("keyboard/langdata.bin")))
        let boosts = ["correction": 37, "coercion": 11, "can't": 5, "notincorpusxyz": 9]
        let original = try #require(reader.incrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil))
        let adjusted = original.map { seed in
            IncrementalLexiconSeed(word: seed.word, bytes: seed.bytes,
                logFreq: boosts[seed.word].map { log(exp(seed.logFreq) + Double($0)) } ?? seed.logFreq)
        }
        let reference = IncrementalDecodeSession(seeds: adjusted, backend: .swiftReference)
        let mapped = try #require(try reader.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"),
            firstTap: nil, boosts: boosts))
        let production = try IncrementalDecodeSession(nativeSeeds: mapped)
        #expect(production.backend == .cpp)
        #expect(!production.hasNativeSearchComparison)
        #expect(production.seedCount == original.count)
        for word in ["c", "cor", "correcgion", "coeevitjkn", "can't", "cant", "correction"] {
            #expect(production.advance(to: word) == reference.advance(to: word))
            #expect(production.typed == reference.typed)
            for radius in [0.0, 3.6, 7.2, Double.infinity] {
                let expected = reference.candidates(maxCost: radius)
                let actual = production.candidates(maxCost: radius)
                #expect(actual.map(\.word) == expected.map(\.word))
                for index in actual.indices {
                    #expect(NativeDecoderParity.equal(actual[index].cost, expected[index].cost))
                    #expect(NativeDecoderParity.equal(actual[index].logFreq, expected[index].logFreq))
                }
            }
        }
        #expect(!production.advance(to: "café"))
        #expect(production.typed == reference.typed)
        #expect(production.nativeParityFailure == nil)
        #expect(throws: (any Error).self) {
            try reader.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil,
                boosts: ["correction": -1])
        }
    }

    @Test func mappedSeedSelectionMatchesEveryRootTouchAndCap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try #require(LangData(url: root.appendingPathComponent("keyboard/langdata.bin"), compareNativeReads: true))
        let taps: [KeyTap?] = [nil, KeyTap(dx: 0.18, dy: -0.1), KeyTap(dx: -0.8, dy: 0.6),
                               KeyTap(dx: .infinity, dy: 0), KeyTap(dx: .nan, dy: 0)]
        for first in UInt8(ascii: "a")...UInt8(ascii: "z") {
            for tap in taps {
                try autoreleasepool {
                    let baseline = data.incrementalSeeds(typedFirst: first, firstTap: tap)
                    let selected = try data.nativeIncrementalSeeds(typedFirst: first, firstTap: tap)
                    #expect((baseline == nil) == (selected == nil))
                    // Some roots exceed the production cap. Verify that fallback,
                    // then compare their complete coverage at an explicit larger cap.
                    let swiftSeeds = try #require(baseline ?? data.incrementalSeeds(
                        typedFirst: first, firstTap: tap, stateCap: data.wordCount))
                    let expanded = selected == nil ? try data.nativeIncrementalSeeds(
                        typedFirst: first, firstTap: tap, stateCap: data.wordCount) : selected
                    let nativeSeeds = try #require(expanded)
                    #expect(nativeSeeds.seedCount == UInt(swiftSeeds.count))
                    #expect(nativeSeeds.cellCount == UInt(swiftSeeds.reduce(0) { $0 + $1.bytes.count + 1 }))
                    // All seeds are emitted in ID order at infinity, including short
                    // words outside the normal radius. This checks coverage and log-freq.
                    let swift = IncrementalDecodeSession(seeds: swiftSeeds, backend: .swiftReference)
                    let cpp = try KBIncrementalSearch(seedSet: nativeSeeds)
                    let word = String(UnicodeScalar(first))
                    let row: [KeyTap?] = [tap]
                    let buffers = try #require(NativeTapBuffers(taps: row, expectedCount: 1))
                    #expect(swift.advance(to: word, taps: row))
                    #expect(try cpp.advanceNormalizedWord(word, tapOffsets: buffers.offsets, tapValidity: buffers.validity))
                    try NativePerformanceHarness.requireParity(swift.candidates(maxCost: .infinity),
                        cpp.candidates(withMaxCost: .infinity))
                }
            }
        }
        let count = try #require(data.incrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil)).count
        for cap in [0, count - 1, count, 24_000] {
            let swift = data.incrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil, stateCap: cap)
            let cpp = try data.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil, stateCap: cap)
            #expect((swift == nil) == (cpp == nil))
            #expect(swift?.count == cpp.map { Int($0.seedCount) })
        }
        #expect(try data.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "C"), firstTap: nil) == nil)
        #expect(try data.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil, stateCap: -1) == nil)
    }

    @Test func mappedSessionsRetainBackingAndHaveIndependentState() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var reader = LangData(url: root.appendingPathComponent("keyboard/langdata.bin"), compareNativeReads: true)
        let swiftSeeds = try #require(reader?.incrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil))
        var seeds = try reader?.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil)
        let first = try KBIncrementalSearch(seedSet: #require(seeds))
        let second = try KBIncrementalSearch(seedSet: #require(seeds))
        reader = nil; seeds = nil // Sessions must keep the mapped bytes alive.
        let swift = IncrementalDecodeSession(seeds: swiftSeeds, backend: .swiftReference)
        for word in ["c", "co", "coeevitjkn", "cor", "correction", "can't", "cant"] {
            #expect(swift.advance(to: word))
            #expect(try first.advanceNormalizedWord(word, tapOffsets: nil, tapValidity: nil))
            for radius in [0.0, 3.6, 7.2] {
                try NativePerformanceHarness.requireParity(swift.candidates(maxCost: radius),
                    first.candidates(withMaxCost: radius))
            }
            #expect(second.typed.isEmpty)
        }
        #expect(try second.advanceNormalizedWord("coeevitjkn", tapOffsets: nil, tapValidity: nil))
        #expect(second.typed == "coeevitjkn" && first.typed == "cant")
        #expect(try second.candidates(withMaxCost: 7.2).contains { $0.word == "correction" })
    }

    @Test func spatialCostsMatchAllBytePairsAndContinuousTouches() throws {
        func audit(_ keys: [UInt8], _ tap: KeyTap?) throws {
            var intended = Data(), typed = Data(), expected: [Double] = [], taps: [KeyTap?] = []
            for a in keys {
                for b in keys {
                    intended.append(a); typed.append(b); taps.append(tap)
                    expected.append(KB.subCost(a, typed: b, tap: tap))
                }
            }
            let buffers = try #require(NativeTapBuffers(taps: taps, expectedCount: taps.count))
            let actual = try KBSpatialAudit.substitutionCosts(forIntended: intended, typed: typed,
                tapOffsets: buffers.offsets, tapValidity: buffers.validity)
            #expect(actual.count == expected.count * MemoryLayout<Double>.size)
            actual.withUnsafeBytes { bytes in
                for i in expected.indices {
                    let value = bytes.loadUnaligned(fromByteOffset: i * MemoryLayout<Double>.size, as: Double.self)
                    #expect(NativeDecoderParity.equal(value, expected[i]))
                }
            }
        }
        try audit(Array(UInt8.min...UInt8.max), nil)
        let keys = Array("qwertyuiopasdfghjklzxcvbnm'".utf8) + [0, 255]
        for tap in [KeyTap(dx: 0, dy: 0), KeyTap(dx: 0.22, dy: -0.18),
                    KeyTap(dx: -0.8, dy: 0.6), KeyTap(dx: 100, dy: -100),
                    KeyTap(dx: .infinity, dy: 0), KeyTap(dx: .nan, dy: 0)] {
            try audit(keys, tap)
        }
        for length in 0...12 {
            for candidate in keys {
                for typed in keys {
                    #expect(KBSpatialAudit.firstLetterPenalty(forLength: UInt(length), candidate: candidate, typed: typed)
                        == Trie.firstLetterPenaltyPolicy(typedLength: length, candidateFirst: candidate, typedFirst: typed))
                }
            }
        }
    }

    @Test func retainedDPMatchesAppendBackspaceEditsAndInvalidInput() throws {
        let words = ["the", "teh", "then", "their", "don't", "cant", "can't", "would've",
                     "correction", "coercion", "mynewword"]
        let seeds = words.enumerated().map { index, word in
            IncrementalLexiconSeed(word: word, bytes: Array(word.utf8), logFreq: Double(index) + 0.25)
        }
        let session = IncrementalDecodeSession(seeds: seeds, compareNativeSearch: true)
        #expect(session.hasNativeSearchComparison)
        #expect(session.candidates(maxCost: 3.6).isEmpty)
        let requests = ["", "t", "te", "teh", "th", "the", "the", "thee", "th", "dont", "don't", "don",
                        "cant", "can't", "wouldve", "COEEVITJKN", "co", "correction", "mynewword",
                        "mynewword", "x", "'", "123", "తెలుగు", "İ", "", "K", "the"]
        for (index, word) in requests.enumerated() {
            let count = word.lowercased().utf8.count
            let taps: [KeyTap?]? = index % 3 == 0 ? nil : (0..<count).map {
                $0 % 2 == 0 ? KeyTap(dx: 0.12, dy: -0.08) : nil
            }
            _ = session.advance(to: word, taps: taps)
            for radius in [-1.0, 0, 0.8, 2.8, 3.6, 7.2, .infinity, .nan] {
                _ = session.candidates(maxCost: radius)
                #expect(session.nativeParityFailure == nil, "\(session.nativeParityFailure ?? "") word=\(word)")
            }
        }
        // Mismatched taps fall back exactly as before, including append-only reuse.
        _ = session.advance(to: "then", taps: [KeyTap(dx: 0.2, dy: 0.1)])
        _ = session.candidates(maxCost: 3.6)
        #expect(session.nativeParityFailure == nil)
        let empty = IncrementalDecodeSession(seeds: [], compareNativeSearch: true)
        #expect(empty.hasNativeSearchComparison)
        #expect(empty.advance(to: "the"))
        #expect(empty.candidates(maxCost: 7.2).isEmpty)
        #expect(!empty.advance(to: ""))
        #expect(empty.nativeParityFailure == nil)
    }

    @Test func retainedCorpusSeedsMatchIncludingSevereRecoveryAndTaps() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try #require(LangData(url: root.appendingPathComponent("keyboard/langdata.bin")))
        let seeds = try #require(data.incrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil))
        let session = IncrementalDecodeSession(seeds: seeds, compareNativeSearch: true)
        #expect(session.hasNativeSearchComparison)
        for word in ["c", "co", "cor", "corr", "correct", "correction", "cor", "coeevitjkn", "can't", "cant"] {
            #expect(session.advance(to: word))
            for radius in [0.0, 2.8, 3.6, 7.2] {
                _ = session.candidates(maxCost: radius)
                #expect(session.nativeParityFailure == nil, "\(session.nativeParityFailure ?? "") word=\(word)")
            }
            if word == "coeevitjkn" {
                #expect(session.candidates(maxCost: 7.2).contains { $0.word == "correction" })
            }
        }
        _ = session.advance(to: "coeevitjkn", taps: (0..<9).map { $0 == 0 ? KeyTap(dx: 0.18, dy: -0.1) : nil })
        _ = session.candidates(maxCost: 7.2)
        #expect(session.nativeParityFailure == nil)
        print("Native retained DP parity: \(seeds.count) production seeds; append, edit, backspace, taps and severe recovery checked")
    }

    @Test func bridgeRejectsMalformedNumericBuffersAndProductionUsesCpp() throws {
        #expect(throws: (any Error).self) {
            try KBSpatialAudit.substitutionCosts(forIntended: Data([97]), typed: Data(),
                tapOffsets: Data(), tapValidity: Data())
        }
        #expect(throws: (any Error).self) {
            try KBSpatialAudit.substitutionCosts(forIntended: Data([97]), typed: Data([97]),
                tapOffsets: Data(count: 16), tapValidity: Data([2]))
        }
        let seed = IncrementalLexiconSeed(word: "the", bytes: Array("the".utf8), logFreq: 1)
        let production = IncrementalDecodeSession(seeds: [seed])
        #expect(!production.hasNativeSearchComparison)
        #expect(production.backend == .cpp)
        #expect(production.advance(to: "teh"))
        #expect(production.candidates(maxCost: 1).first?.word == "the")
        #expect(production.nativeParityFailure == nil)
    }
}
