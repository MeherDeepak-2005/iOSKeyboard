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

    @Test func oneOffPersonalUseDoesNotHijackThePrior() throws {
        let ld = try #require(LangData(url: langdataURL()))
        let user = UserModel()
        let ng = NgramScorer(user: user)
        ng.attach(data: ld, resolveID: { ld.trieWordID($0) }, lexicon: Lexicon())
        let context = ["private-context"]
        let baseline = ng.logProbs(["might"], context: context)[0]

        user.learn(context: context, word: "might")
        let oneUse = ng.logProbs(["might"], context: context)[0]
        #expect(abs(oneUse - baseline) < 1e-12)

        user.learn(context: context, word: "might")
        user.learn(context: context, word: "might")
        let repeated = ng.logProbs(["might"], context: context)[0]
        #expect(repeated > oneUse)
        #expect(repeated - oneUse < 0.5) // personalization remains a tie-breaker
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

    // Contractions MISSING from the 60k vocab can't be restored by trie lookup
    // ("whens" → "when's" has no entry to validate against — it autocorrected to
    // "when"). Synthesis covers the closed-class bases; open-class stays off so
    // plurals never become possessives.
    @Test func syntheticContractionRestoration() {
        #expect(Lexicon.syntheticContraction(of: "whens") == "when's")
        #expect(Lexicon.syntheticContraction(of: "theres") == "there's")
        #expect(Lexicon.syntheticContraction(of: "mustnt") == "mustn't")
        #expect(Lexicon.syntheticContraction(of: "cars") == nil)        // plural, not possessive
        #expect(Lexicon.syntheticContraction(of: "lexicons") == nil)    // OOV plural stays put
        #expect(Lexicon.syntheticContraction(of: "when's") == nil)      // already has its '
        #expect(Lexicon.syntheticContraction(of: "wasnt") == nil)       // corpus word → trie's job
    }

    @Test func clipboardStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        KBClipboard.add("hello", at: url)
        KBClipboard.add("world", at: url)
        KBClipboard.add("hello", at: url)              // dedupe → resurfaces to front
        #expect(KBClipboard.all(at: url).map(\.text) == ["hello", "world"])
        KBClipboard.togglePin("world", at: url)
        KBClipboard.clearUnpinned(at: url)             // pins survive the broom
        let items = KBClipboard.all(at: url)
        #expect(items.map(\.text) == ["world"] && items[0].pinned)
        KBClipboard.remove("world", at: url)
        #expect(KBClipboard.all(at: url).isEmpty)
        KBClipboard.add("  \n ", at: url)              // whitespace-only never saves
        #expect(KBClipboard.all(at: url).isEmpty)
    }

    @MainActor @Test func renderClipboardPanel() throws {
        let items = [
            KBClipboardItem(text: "hello@example.com", pinned: true, date: Date()),
            KBClipboardItem(text: "The quick brown fox jumps over the lazy dog — a longer clip that should truncate at two lines in the panel row.", pinned: false, date: Date()),
            KBClipboardItem(text: "4021 7789", pinned: false, date: Date()),
        ]
        let v = ClipboardPanelView(theme: .system(dark: false), showsGlobe: true,
                                   hasFullAccess: true, items: items)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
        v.backgroundColor = UIColor(hex: 0xE8E6EC)
        v.layoutIfNeeded()
        try writePNG(of: v, name: "clipboard_panel")

        let empty = ClipboardPanelView(theme: .system(dark: false), showsGlobe: true,
                                       hasFullAccess: false, items: [])
        empty.frame = v.frame
        empty.backgroundColor = v.backgroundColor
        empty.layoutIfNeeded()
        try writePNG(of: empty, name: "clipboard_panel_empty")
    }

    // KLIPY response parsing: preview picks the smallest animated variant that can
    // fill the 256 px decoder target; send still picks the biggest GIF.
    @Test func klipyParsePicksLeanPreviewAndFullSend() throws {
        let json: [String: Any] = ["result": true, "data": ["has_next": true, "data": [[
            "id": 42, "slug": "hello-wave", "title": "Hello",
            "file": [
                "hd": ["gif": ["url": "https://x.test/hd.gif", "width": 480, "height": 360, "size": 2_400_000]],
                "md": ["webp": ["url": "https://x.test/md.webp", "width": 320, "height": 240, "size": 180_000]],
                "sm": ["gif": ["url": "https://x.test/sm.gif", "width": 200, "height": 150, "size": 300_000]],
                "xs": ["webp": ["url": "https://x.test/xs.webp", "width": 120, "height": 90, "size": 60_000],
                       "gif":  ["url": "https://x.test/xs.gif",  "width": 120, "height": 90, "size": 150_000]],
            ],
        ]]]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let (items, hasNext) = KlipyClient.parse(data)
        #expect(hasNext)
        let item = try #require(items.first)
        #expect(item.id == "42")
        #expect(item.previewURL.absoluteString == "https://x.test/md.webp")   // first source at decoder target
        #expect(item.sendURL.absoluteString == "https://x.test/hd.gif")       // biggest gif
        // Garbage in → empty out, never a crash.
        #expect(KlipyClient.parse(Data("nonsense".utf8)).0.isEmpty)
    }

    @MainActor @Test func renderMediaPanelHintState() throws {
        // No injected items + no API key → the panel must show its key hint and
        // make zero network calls (deterministic offline render).
        let v = MediaPanelView(theme: .system(dark: false), showsGlobe: true,
                               hasFullAccess: true, kind: .gifs)
        v.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
        v.backgroundColor = UIColor(hex: 0xE8E6EC)
        v.layoutIfNeeded()
        try writePNG(of: v, name: "media_panel_hint")
    }

    // The strip is ONLY suggestions + the clipboard icon: no paste chip ever takes a
    // suggestion slot (clipboard content lives in the panel).
    @MainActor @Test func renderSuggestionBar() throws {
        let bar = SuggestionBar(theme: .system(dark: false))
        bar.frame = CGRect(x: 0, y: 0, width: 390, height: 34)
        bar.backgroundColor = UIColor(hex: 0xE8E6EC)
        bar.setSuggestions(["hello", "help", "hell"], typedPrefix: "hel")
        bar.layoutIfNeeded()
        try writePNG(of: bar, name: "suggestion_bar_plain")
    }

    @MainActor @Test func glideSuggestionPresentationStaysSynchronized() throws {
        let bar = SuggestionBar(theme: .system(dark: true))
        bar.frame = CGRect(x: 0, y: 0, width: 390, height: 34)
        bar.setSuggestions(["this", "thus", "might"])
        bar.setGlideResult("Might", alternatives: ["Night", "Right", "Light"])

        let left = try #require(suggestionButton("suggestion.left", in: bar))
        let primary = try #require(suggestionButton("suggestion.primary", in: bar))
        let right = try #require(suggestionButton("suggestion.right", in: bar))
        #expect(left.title(for: .normal) == "Night")
        #expect(primary.title(for: .normal) == "Might")
        #expect(right.title(for: .normal) == "Right")
        #expect(!primary.isEnabled)

        bar.setGlidePreview("More")
        #expect(primary.title(for: .normal) == "More")
        bar.setGlidePreview(nil)
        #expect(left.title(for: .normal) == "Night")
        #expect(primary.title(for: .normal) == "Might")
        #expect(right.title(for: .normal) == "Right")
    }

    @Test func glideDisplayCaseCapitalizesOnlyWhenRequested() {
        #expect(KBWordCase.sentenceDisplay("might", capitalized: true) == "Might")
        #expect(KBWordCase.sentenceDisplay("might", capitalized: false) == "might")
        #expect(KBWordCase.sentenceDisplay("i'm", capitalized: true) == "I'm")
        #expect(KBWordCase.sentenceDisplay("", capitalized: true).isEmpty)
    }

    @MainActor @Test func exactGlidePreviewCommitsSynchronouslyWithSameWinner() async throws {
        let centers: [(letter: Character, point: CGPoint)] =
            "qwertyuiopasdfghjklzxcvbnm".compactMap { character in
                KB.grid(for: character).map { (character, CGPoint(x: $0.0, y: $0.1)) }
            }
        let layout = GlideLayout(centers: centers, xPitch: 1, yPitch: 1)
		let captureURL = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("tools/glide_capture.jsonl")
		let firstLine = try #require(try String(contentsOf: captureURL, encoding: .utf8).split(separator: "\n").first)
		let record = try #require(try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
		let coordinates = try #require(record["path"] as? [[Double]])
		let path = coordinates.compactMap { point -> CGPoint? in
			guard point.count == 2 else { return nil }
			return CGPoint(x: point[0], y: point[1])
		}
		#expect(path.count == coordinates.count)
		let times: [TimeInterval] = []
		let engine = KeyboardEngine(languageDataURL: langdataURL(), loadsNeuralModel: false)
        let preview = await withCheckedContinuation { continuation in
            engine.glidePreview(path: path, times: times, layout: layout, context: []) {
                continuation.resume(returning: $0)
            }
        }
        let live = try #require(preview)

        var methodReturned = false
        var deliveredInline = false
        var finalWord: String?
        engine.glide(path: path, times: times, layout: layout, context: []) { word, _ in
            deliveredInline = !methodReturned
            finalWord = word
        }
        methodReturned = true

        #expect(deliveredInline)
        #expect(finalWord == live.word)
    }

    @MainActor private func suggestionButton(_ id: String, in bar: SuggestionBar) -> UIButton? {
        bar.subviews
            .compactMap { $0 as? UIStackView }
            .flatMap(\.arrangedSubviews)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == id }
    }

    // The browsing overlays (emoji grid, GIF/sticker panel) get extra height; the
    // typing deck and the clipboard list must stay at the normal height — an
    // expansion leaking into .letters is what puts empty space under the keys.
    @MainActor @Test func onlyBrowsingOverlaysExpandHeight() throws {
        let kb = KeyboardView(theme: .system(dark: false), showsGlobe: true)
        let base = kb.keyboardHeight
        #expect(base > 200 && base < 300)          // sane letters-deck height
        kb.showClipboard(hasFullAccess: true)
        #expect(kb.keyboardHeight == base)         // list panel: no expansion
        kb.dismissOverlaysIfActive()
        #expect(kb.keyboardHeight == base)         // and it returns cleanly
    }

    // Gamification math: streaks, leagues, trophies, pruning — pure KBStats.apply.
    @Test func statsStreaksLeaguesAndTrophies() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents(year: 2026, month: 7, day: 10, hour: 12)
        comps.timeZone = cal.timeZone
        let day1 = cal.date(from: comps)!
        let day2 = cal.date(byAdding: .day, value: 1, to: day1)!
        let day4 = cal.date(byAdding: .day, value: 3, to: day1)!   // gap breaks the streak

        var s = KBStatsData()
        KBStats.apply(words: 60, glided: false, on: &s, date: day1, calendar: cal)
        KBStats.apply(words: 40, glided: true, on: &s, date: day1, calendar: cal)
        #expect(s.total == 100 && s.totalGlided == 40 && s.bestDay == 100)
        #expect(s.currentStreak == 1)

        KBStats.apply(words: 10, glided: false, on: &s, date: day2, calendar: cal)
        #expect(s.currentStreak == 2 && s.bestStreak == 2)         // consecutive day

        KBStats.apply(words: 10, glided: false, on: &s, date: day4, calendar: cal)
        #expect(s.currentStreak == 1 && s.bestStreak == 2)         // gap → reset, best kept

        // Leagues: floors and progress.
        #expect(KBLeague.league(for: 0) == .bronze)
        #expect(KBLeague.league(for: 5_000) == .silver)
        #expect(KBLeague.league(for: 99_999) == .gold)
        #expect(KBLeague.league(for: 100_000) == .diamond)
        #expect(KBLeague.progress(for: 100_000) == 1)

        // Trophies: 120 total words earns First Steps; glide + streak ones track.
        let earned = Set(KBStats.trophies.filter { $0.isEarned(s) }.map(\.id))
        #expect(earned.contains("first-steps"))
        #expect(earned.contains("lift-off"))                       // 40 glided ≥ 10
        #expect(!earned.contains("chatterbox"))                    // 120 < 1,000
        #expect(!earned.contains("warming-up"))                    // best streak 2 < 3

        // Day map prunes to keepDays without touching lifetime totals.
        var big = KBStatsData()
        for i in 0..<(KBStats.keepDays + 20) {
            let d = cal.date(byAdding: .day, value: i, to: day1)!
            KBStats.apply(words: 1, glided: false, on: &big, date: d, calendar: cal)
        }
        #expect(big.days.count == KBStats.keepDays)
        #expect(big.total == KBStats.keepDays + 20)
        #expect(big.currentStreak == KBStats.keepDays + 20)
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
