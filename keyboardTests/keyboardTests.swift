import Foundation
import Testing
import UIKit
@testable import keyboard

struct KeyboardTests {
    @Test func emojiBinaryContainsSearchAliases() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let cryingEmoji = try #require(store.emoji(forWord: "cry"))

        #expect(store.emoji(forWord: "sob") == cryingEmoji)
        #expect(store.emoji(forWord: "sobbing") == cryingEmoji)
        #expect(store.search("cry").first == cryingEmoji)
        #expect(store.search("sob").first == cryingEmoji)
    }

    @Test func emojiSearchAvoidsSubstringNoise() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let happyResults = store.search("happy")
        let rainResults = store.search("rain")

        #expect(happyResults.first == "😊")
        #expect(!happyResults.contains("😢"))
        #expect(!happyResults.contains("😭"))
        #expect(!rainResults.contains("🧠"))
        #expect(!rainResults.contains("🚆"))
    }

    @Test func emojiSearchUsesGeneratedUnicodeKeywords() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let umbrellaResults = store.search("umbrella")

        #expect(umbrellaResults.contains("☂️") || umbrellaResults.contains("🌂"))
        #expect(store.search("umb").contains("☂️") || store.search("umb").contains("🌂"))
    }

    @Test func emojiBinaryProvidesDisplayCatalog() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))

        #expect(store.categoryCount > 0)
        #expect(!store.name(0).isEmpty)
        #expect(!store.icon(0).isEmpty)
        #expect(store.emojiCount(0) > 0)
        #expect(!store.emoji(0, 0).isEmpty)
    }

    private func emojiBinaryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("keyboard/emoji.bin")
    }

    private func langdataURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("keyboard/langdata.bin")
    }

    // MARK: Contractions — the static trie must treat apostrophe words as first-class
    // (they're real-word-protected from autocorrect), and an OMITTED apostrophe must be
    // cheap channel noise so "whats" corrects to "what's", not "what" (stock behavior).

    @Test func contractionsAreRealWordsInStaticTrie() throws {
        let ld = try #require(LangData(url: langdataURL()))
        #expect(ld.hasTrie)
        for w in ["what's", "don't", "it's", "can't", "you're", "would've"] {
            #expect(ld.trieContains(w), "\(w) missing from static trie")
        }
        // Self-match at cost 0: a typed contraction is its own best candidate.
        let selfHit = ld.trieSearch("what's", maxCost: 2.8).first { $0.word == "what's" }
        #expect(try #require(selfHit).cost == 0)
    }

    @Test func apostropheRestorationFindsContractions() throws {
        let ld = try #require(LangData(url: langdataURL()))
        // OOV contraction-less forms restore to their contraction, most-frequent wins.
        #expect(ld.trieApostropheRestoration(of: "thats")?.word == "that's")
        #expect(ld.trieApostropheRestoration(of: "dont")?.word == "don't")
        #expect(ld.trieApostropheRestoration(of: "whats")?.word == "what's")
        #expect(ld.trieApostropheRestoration(of: "im")?.word == "i'm")
        #expect(ld.trieApostropheRestoration(of: "youre")?.word == "you're")
        #expect(ld.trieApostropheRestoration(of: "wouldnt")?.word == "wouldn't")
        // No match → nil; already-apostrophized input → nil.
        #expect(ld.trieApostropheRestoration(of: "zzzq") == nil)
        #expect(ld.trieApostropheRestoration(of: "don't") == nil)
    }

    @Test func omittedApostropheIsCheapChannelNoise() throws {
        let ld = try #require(LangData(url: langdataURL()))
        for (typed, contraction, strippedBase) in
            [("whats", "what's", "what"), ("dont", "don't", "don"), ("cant", "can't", "can")] {
            let hits = ld.trieSearch(typed, maxCost: 1.8)
            let apos = try #require(hits.first { $0.word == contraction },
                                     "\(contraction) not generated for \(typed)")
            #expect(abs(apos.cost - KB.apostropheSkipCost) < 1e-9)
            // The contraction must beat the letter-deletion neighbor on channel cost —
            // that neighbor is a full deletion (1.6) away, the contraction only 0.4.
            if let base = hits.first(where: { $0.word == strippedBase }) {
                #expect(apos.cost < base.cost)
            }
        }
    }

    // The fresh-install prior inversion: the old unigram backoff floored at
    // log(0.16) with an empty user model — ABOVE any real bigram hit — so unseen
    // continuations outscored seen ones and real-word autocorrect never fired
    // ("what's thus" kept "thus"). The corpus-differentiated backoff restores order.
    @Test func freshInstallBackoffPrefersBigramEvidence() throws {
        let ld = try #require(LangData(url: langdataURL()))
        let ng = NgramScorer(user: UserModel())
        ng.attach(data: ld, resolveID: { ld.trieWordID($0) }, lexicon: Lexicon())
        // "what's this" has bigram counts, "what's thus" has none.
        let p = ng.logProbs(["this", "thus"], context: ["what's"])
        #expect(p[0] > p[1])
        // No context at all: frequency still differentiates unseen words.
        let u = ng.logProbs(["this", "thus"], context: [])
        #expect(u[0] > u[1])
        // True OOV strings sit below every corpus word.
        let o = ng.logProbs(["thus", "zzqqx"], context: [])
        #expect(o[0] > o[1])
    }

    // OOV contractions ("when's" is not in the 60k vocab) must be recognized as
    // valid forms so autocorrect never flattens them to their base word.
    @Test func oovContractionsAreProtectedForms() {
        let lex = Lexicon()
        lex.loadFromBundle()      // test host bundles no langdata.bin → seed word list
        #expect(lex.isContractionForm("when's"))
        #expect(lex.isContractionForm("don't"))       // base "do" + n't
        #expect(!lex.isContractionForm("thi's"))      // base not a word
        #expect(!lex.isContractionForm("'s"))         // no base at all
        #expect(!lex.isContractionForm("whens"))      // no apostrophe → restoration's job
    }

    // MARK: Visual render checks — write PNGs of the emoji UI for eyeballing.
    // (The app target doesn't bundle emoji.bin, so the store is injected from the
    // repo file. PNGs land in keyboardTests/renders/, which is disposable.)

    @MainActor @Test func renderEmojiPalette() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        for dark in [false, true] {
            let theme = KeyboardTheme.system(dark: dark)
            let v = EmojiKeyboardView(theme: theme, showsGlobe: true, store: store)
            v.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
            v.backgroundColor = dark ? UIColor(hex: 0x2A2A2E) : UIColor(hex: 0xE8E6EC)
            v.layoutIfNeeded()
            try writePNG(of: v, name: dark ? "emoji_palette_dark" : "emoji_palette_light")
        }
    }

    // Atlas round trip: generate raw RGBA tiles the way the HOST APP does, map them
    // back the way the EXTENSION does, and render the grid from tiles. The PNG doubles
    // as the eyeball check for orientation/format bugs in the raw-pixel pipeline.
    @MainActor @Test func emojiAtlasRoundTripAndRender() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emoji-atlas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try #require(EmojiAtlas.generateIfNeeded(store: store, scale: 2, in: dir))
        // Pure-pixel file: whole tiles only (scale 2 → 72 px tiles).
        let bytes = try #require((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize)
        #expect(bytes > 0 && bytes % (72 * 72 * 4) == 0)
        // Second call is the fast path: same URL, no rewrite.
        #expect(EmojiAtlas.generateIfNeeded(store: store, scale: 2, in: dir) == url)

        let atlas = try #require(EmojiAtlas.load(store: store, scale: 2, in: dir))
        #expect(atlas.image(for: store.emoji(0, 0)) != nil)
        #expect(atlas.image(for: "not an emoji") == nil)
        // A mismatched scale must fail closed (falls back to text), never mis-map.
        #expect(EmojiAtlas.load(store: store, scale: 3, in: dir) == nil)

        let v = EmojiKeyboardView(theme: .system(dark: false), showsGlobe: true,
                                  store: store, atlas: atlas)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
        v.backgroundColor = UIColor(hex: 0xE8E6EC)
        v.layoutIfNeeded()
        try writePNG(of: v, name: "emoji_palette_atlas")
    }

    @MainActor @Test func renderEmojiSearchHeader() throws {
        let store = try #require(EmojiStore(url: emojiBinaryURL()))
        let theme = KeyboardTheme.system(dark: false)

        let hits = EmojiSearchHeader(theme: theme)
        hits.frame = CGRect(x: 0, y: 0, width: 390, height: EmojiSearchHeader.height)
        hits.backgroundColor = UIColor(hex: 0xE8E6EC)
        hits.update(query: "smile", results: store.search("smile"), showingRecents: false)
        hits.layoutIfNeeded()
        try writePNG(of: hits, name: "emoji_search_results")
        #expect(!store.search("smile").isEmpty)

        let miss = EmojiSearchHeader(theme: theme)
        miss.frame = hits.frame
        miss.backgroundColor = hits.backgroundColor
        miss.update(query: "zzzzqq", results: [], showingRecents: false)
        miss.layoutIfNeeded()
        try writePNG(of: miss, name: "emoji_search_empty")

        // Placeholder state: after clearing a query the caret must sit BEFORE
        // "Search emoji", not blink after the placeholder text.
        let placeholder = EmojiSearchHeader(theme: theme)
        placeholder.frame = hits.frame
        placeholder.backgroundColor = hits.backgroundColor
        placeholder.update(query: "smile", results: store.search("smile"), showingRecents: false)
        placeholder.update(query: "", results: [], showingRecents: true)
        placeholder.layoutIfNeeded()
        try writePNG(of: placeholder, name: "emoji_search_placeholder")
    }

    @MainActor private func writePNG(of view: UIView, name: String) throws {
        let img = UIGraphicsImageRenderer(bounds: view.bounds).image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("renders", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #require(img.pngData()).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
