import Foundation
import Testing
@testable import keyboard

@MainActor
struct NativeCandidateGenerationTests {
    private var pack: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("keyboard/langdata.bin")
    }

    private func equal(_ expected: [Candidate], _ actual: [Candidate]) {
        #expect(expected.map(\.word) == actual.map(\.word))
        guard expected.count == actual.count else { return }
        for index in expected.indices {
            #expect(NativeDecoderParity.equal(expected[index].cost, actual[index].cost))
            #expect(NativeDecoderParity.equal(expected[index].logFreq, actual[index].logFreq))
        }
    }

    @Test func mutableTrieMatchesIndependentSwiftReference() {
        let reference = Trie(backend: .swiftReference), native = Trie()
        let words = ["the", "hello", "help", "hell", "can't", "can", "correction", "coercion", "meher", "café"]
        for (index, word) in words.enumerated() {
            reference.insert(word, freq: 20 + index, id: Int32(index))
            native.insert(word, freq: 20 + index, id: Int32(index))
        }
        for trie in [reference, native] {
            trie.insert("help", freq: 200, id: 40)
            trie.bump("hello")
            trie.bump("absent")
        }
        for word in words + ["absent", "hel", ""] {
            #expect(native.contains(word) == reference.contains(word))
            #expect(native.hasPrefix(word) == reference.hasPrefix(word))
            #expect(native.wordID(word) == reference.wordID(word))
            #expect(native.logFreq(word) == reference.logFreq(word))
            equal(reference.completions(prefix: word, limit: 24), native.completions(prefix: word, limit: 24))
        }
        for word in ["teh", "helo", "cant", "coeevitjkn", "meher", "café", ""] {
            let taps: [KeyTap?] = word.utf8.enumerated().map {
                $0.offset % 2 == 0 ? KeyTap(dx: 0.1, dy: -0.08) : nil
            }
            for radius in [0.0, 1.8, 3.6, 7.2] {
                for prior in [nil, TrieSearchPrior(likelyWords: ["correction", "hello"])] {
                    equal(reference.search(word, maxCost: radius, taps: taps, prior: prior),
                          native.search(word, maxCost: radius, taps: taps, prior: prior))
                }
            }
        }
    }

    @Test func packedCompletionsAndGeneratorPoolsMatchReference() throws {
        let lexicon = Lexicon()
        lexicon.load(from: pack)
        lexicon.insert("meherdeepak", freq: 10)
        for word in ["", "c", "co", "corr", "correction", "teh", "dont", "cant", "its", "alot", "avlot", "coeevitjkn"] {
            let pool = try lexicon.generateEnglishCandidates(typed: word, taps: nil,
                successors: ["correction", "coercion"], prior: nil, retainedStatic: nil,
                gruTier: false, shouldCancel: { false })
            if word.isEmpty { #expect(pool.close.isEmpty); continue }
            equal(lexicon.completions(prefix: word, limit: 24), pool.completions.map(Candidate.init(native:)))
            let cost = word.count <= 4 ? 1.8 : word.count <= 7 ? 2.8 : 3.6
            equal(lexicon.corrections(for: word, maxCost: cost), pool.close.map(Candidate.init(native:)))
        }
        let cancelled = try lexicon.generateEnglishCandidates(typed: "coeevitjkn", taps: nil,
            successors: [], prior: nil, retainedStatic: nil, gruTier: false, shouldCancel: { true })
        #expect(cancelled.cancelled && cancelled.close.isEmpty && cancelled.broad.isEmpty)
    }

    @Test func nativeSnapshotsRetainOldVocabularyAcrossLearningAndReset() throws {
        let base = KBMutableTrie(), supplementary = KBMutableTrie(), personal = KBMutableTrie()
        base.insertWord("hello", frequency: 20, wordID: 1)
        let snapshot = KBGenerationSnapshot(boosts: [:], blockedWords: [])
        let old = KBGenerationLexicon(packed: nil, base: base, supplementary: supplementary,
            personal: personal, snapshot: snapshot)
        base.insertWord("help", frequency: 100, wordID: 2)
        base.bumpWord("hello")
        personal.insertWord("helmeher", frequency: 8, wordID: -1)
        let current = KBGenerationLexicon(packed: nil, base: base, supplementary: supplementary,
            personal: personal, snapshot: snapshot)
        func generate(_ view: KBGenerationLexicon) throws -> [Candidate] {
            try KBCandidateGenerator.generateWord("hel", lexicon: view,
                tapOffsets: nil, tapValidity: nil, contextSuccessors: [], successorLengths: [], successorFirst: [], successorLast: [], characterOffsets: [0, 1, 2, 3],
                fundedWords: nil, fundedBonuses: nil, retainedStatic: nil,
                gruTier: false, shouldCancel: nil).completions.map(Candidate.init(native:))
        }
        #expect(try generate(old).map(\.word) == ["hello"])
        #expect(try generate(old).first?.logFreq == log(21))
        #expect(try generate(current).map(\.word) == ["help", "hello", "helmeher"])

        let lexicon = Lexicon()
        lexicon.load(from: pack)
        func generateLearned() throws -> [Candidate] {
            try lexicon.generateEnglishCandidates(typed: "hello", taps: nil, successors: [],
                prior: nil, retainedStatic: nil, gruTier: false, shouldCancel: { false })
                .completions.map(Candidate.init(native:))
        }
        let before = try #require(generateLearned().first { $0.word == "hello" })
        lexicon.noteUse(of: "hello", timesUsed: 9, adoptAfter: 8)
        let learned = try #require(generateLearned().first { $0.word == "hello" })
        #expect(NativeDecoderParity.equal(learned.logFreq, log(exp(before.logFreq) + 1)))
        lexicon.resetPersonalization()
        let reset = try #require(generateLearned().first { $0.word == "hello" })
        #expect(reset.logFreq == before.logFreq)
    }

    @Test func wholeDecodeMatchesSwiftGenerationAcrossContextsAndEdits() async throws {
        try #require(ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == "1",
            "Run with the shared scheme's deterministic test environment")
        func make(_ backend: DecoderCoreBackend) -> KeyboardEngine {
            KeyboardEngine(languageDataURL: pack, userModel: UserModel(storageURL:
                FileManager.default.temporaryDirectory.appendingPathComponent("candidate-parity-\(UUID()).json")),
                candidateBackend: backend)
        }
        let native = make(.cpp), reference = make(.swiftReference)
        let contexts: [[String]] = [[], ["auto"], ["possibly", "receive"],
            ["for", "definitely", "decided"], ["could", "definitely", "receive"]]
        let words = ["", "t", "te", "teh", "the", "hell", "hello", "hell", "helo", "h", "hello",
            "corr", "coeevitjkn", "correcgion", "cant", "dont", "its", "id", "alot", "avlot", "whens", "café"]
        var generation: UInt64 = 0
        for (session, context) in contexts.enumerated() {
            for word in words {
                generation += 1
                let taps: [KeyTap?]? = generation % 2 == 0 ? word.utf8.enumerated().map {
                    $0.offset % 2 == 0 ? KeyTap(dx: 0.08, dy: -0.04) : nil
                } : nil
                let request = DecodeRequest(fieldRevision: 1, documentRevision: generation,
                    wordSessionID: UInt64(session + 1), generation: generation, layoutRevision: 1,
                    currentWord: word, context: context, taps: taps)
                let expected = await withCheckedContinuation { continuation in
                    reference.decode(request) { continuation.resume(returning: $0) }
                }
                let actual = await withCheckedContinuation { continuation in
                    native.decode(request) { continuation.resume(returning: $0) }
                }
                #expect(actual.suggestions == expected.suggestions, "\(word), context=\(context)")
                #expect(actual.correction == expected.correction, "\(word), context=\(context)")
                #expect(actual.modelTier == expected.modelTier)
                #expect(actual.candidates.map(\.word) == expected.candidates.map(\.word), "\(word), context=\(context)")
                for (a, b) in zip(actual.candidates, expected.candidates) {
                    #expect(a.source == b.source)
                    #expect(NativeDecoderParity.equal(a.spatialCost, b.spatialCost))
                    #expect(NativeDecoderParity.equal(a.score, b.score))
                    #expect(NativeDecoderParity.equal(a.logFrequency, b.logFrequency))
                    #expect(NativeDecoderParity.equal(a.logLanguageProbability, b.logLanguageProbability))
                }
            }
        }
    }
}
