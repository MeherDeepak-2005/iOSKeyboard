import Foundation
import Testing
@testable import keyboard

struct NativePackedLexiconTests {
    @Test func packedReadsMatchSwiftOverEntireEnglishCorpus() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reader = try #require(LangData(url: root.appendingPathComponent("keyboard/langdata.bin"), compareNativeReads: true))
        let report = try reader.verifyNativeReadParity()
        #expect(report.words == reader.wordCount)
        #expect(report.bigramContexts == reader.wordCount)
        #expect(report.trigramContexts > 0)
        #expect(report.sharedBacking)
        print("Native packed parity: \(report.words) words / \(report.bigramContexts) bigram queries / \(report.trigramContexts) trigram contexts; shared mapping verified")
    }

    @Test func mappedGlideAnchorsMatchCharacterReference() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reader = try #require(LangData(url: root.appendingPathComponent("keyboard/langdata.bin")))
        var expected: [UInt16: [(id: Int32, frequency: Int)]] = [:]
        reader.forEachWord { word, frequency, id in
            guard word.count >= 2, let first = word.first?.asciiValue,
                  let last = word.last?.asciiValue else { return }
            expected[UInt16(first) << 8 | UInt16(last), default: []].append((id, frequency))
        }
        reader.warmGlideAnchorIndex()
        reader.warmGlideAnchorIndex() // idempotent; same endpoint ordering
        for (key, entries) in expected {
            let first = Character(UnicodeScalar(UInt8(key >> 8)))
            let last = Character(UnicodeScalar(UInt8(key & 255)))
            let words = entries.sorted { $0.frequency > $1.frequency }.map { reader.word(Int($0.id)) }
            #expect(reader.glideAnchorWords(first: [first], last: [last], perBucket: Int.max) == words)
        }
        #expect(reader.glideAnchorWords(first: ["☃"], last: ["a"], perBucket: 8).isEmpty)
    }

    @Test func mappedGlideAnchorsPreserveUnicodeAndControlBoundaries() throws {
        let words = ["ab", "a", "a\u{301}b", "caféx", "a\r\nb", "\r\nb", "a\r\n", "a🇮🇳z"]
        var bytes = Data()
        func put(_ value: UInt32, width: Int = 4) {
            for shift in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
        }
        for value: UInt32 in [0x4B424C4D, 3, UInt32(words.count), 0, 0, 0, 0, 1] { put(value) }
        for _ in words { put(1) }
        var offset: UInt32 = 0
        put(offset)
        for word in words { offset += UInt32(word.utf8.count); put(offset) }
        put(0, width: 1); put(0, width: 1); put(0); put(UInt32.max); put(0) // empty root
        for word in words { bytes.append(contentsOf: word.utf8) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anchor-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(LangData(url: url))
        #expect(reader.glideAnchorWords(first: ["a"], last: ["b"], perBucket: 20) == ["ab", "a\r\nb"])
        #expect(reader.glideAnchorWords(first: ["c"], last: ["x"], perBucket: 20) == ["caféx"])
        #expect(reader.glideAnchorWords(first: ["a"], last: ["z"], perBucket: 20) == ["a🇮🇳z"])
        // Preserve Swift Character endpoint behavior for control sequences;
        // do not substitute byte endpoints for CR/LF or assume its segmentation.
        for (first, last): (Character, Character) in [("\r", "b"), ("a", "\n")] {
            let expected = words.filter { word in
                word.count >= 2 && word.first?.asciiValue == first.asciiValue
                    && word.last?.asciiValue == last.asciiValue
            }
            #expect(reader.glideAnchorWords(first: [first], last: [last], perBucket: 20) == expected)
        }
    }

    @Test func coreV4StoredFormsHaveWideTrieIDs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reader = try #require(LangData(url: root.appendingPathComponent("keyboard/langdata.bin")))
        for word in ["accommodative", "acetylcholine", "café", "naïve", "wi-fi"] {
            let id = try #require(reader.trieWordID(word))
            #expect(reader.word(Int(id)) == word)
            #expect(reader.freq(Int(id)) == 1)
        }
        var highID: Int32?
        reader.forEachWord { word, _, id in
            if id > 65_535 && word == "wi-fi" { highID = id }
        }
        #expect(highID != nil)
        for excluded in ["cant", "im", "lets", "wont"] {
            #expect(reader.trieWordID(excluded) == nil)
        }
    }

    @Test func productionDefaultDoesNotEnableComparison() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let reader = try #require(LangData(url: root.appendingPathComponent("keyboard/langdata.bin")))
        #expect(reader.backend == .cpp)
        #expect(throws: LangData.NativeReadParityError.comparisonDisabled) {
            try reader.verifyNativeReadParity()
        }
    }

    @Test func bridgeRejectsMutableAndTruncatedBackingAndOwnsResults() throws {
        var bytes = Data()
        for value: UInt32 in [0x4B424C4D, 2, 1, 0, 0, 0, 0, 19, 0, 1] {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(UInt8(ascii: "x"))
        let backing = NSData(data: bytes)
        var bridge: KBPackedLexicon? = try KBPackedLexicon(backing: backing)
        let words = try #require(bridge).allWords()
        let frequencies = try #require(bridge).allFrequencies()
        bridge = nil
        #expect(words == ["x"])
        #expect(frequencies.map { $0.intValue } == [19])
        #expect(throws: (any Error).self) {
            try KBPackedLexicon(backing: NSMutableData(data: bytes))
        }
        #expect(throws: (any Error).self) {
            try KBPackedLexicon(backing: NSData(data: bytes.prefix(17)))
        }
    }

}
