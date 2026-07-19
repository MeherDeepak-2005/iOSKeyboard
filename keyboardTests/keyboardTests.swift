import Foundation
import Testing
import UIKit
@testable import keyboard

@MainActor
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

	// Suggestions always divide the full strip into three stable targets.
    @MainActor @Test func renderSuggestionBar() throws {
		let bar = SuggestionBar(theme: .system(dark: false))
		bar.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        bar.backgroundColor = UIColor(hex: 0xE8E6EC)
        bar.setSuggestions(["hello", "help", "hell"], typedPrefix: "hel")
        bar.layoutIfNeeded()
        try writePNG(of: bar, name: "suggestion_bar_plain")
    }

    @MainActor @Test func glideSuggestionPresentationStaysSynchronized() throws {
		let bar = SuggestionBar(theme: .system(dark: true))
		bar.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
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
		let engine = KeyboardEngine(languageDataURL: langdataURL())
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
			.compactMap { $0 as? UIButton }
			.first { $0.accessibilityIdentifier == id }
	}

	@MainActor @Test func visualLetterCentersMatchSpatialModel() throws {
		let keyboard = KeyboardView(theme: .system(dark: false), showsGlobe: false)
		keyboard.frame = CGRect(x: 0, y: 0, width: 390, height: keyboard.keyboardHeight)
		keyboard.layoutIfNeeded()
		let q = try #require(keyboard.letterCenter(for: "q"))
		let w = try #require(keyboard.letterCenter(for: "w"))
		let a = try #require(keyboard.letterCenter(for: "a"))
		let z = try #require(keyboard.letterCenter(for: "z"))
		let pitch = w.x - q.x
		#expect(abs((a.x - q.x) / pitch - CGFloat(KB.rowOffset[1])) < 0.001)
		#expect(abs((z.x - q.x) / pitch - CGFloat(KB.rowOffset[2])) < 0.001)
	}

	@Test func layoutProfilesCoverSupportedFormFactors() {
		#expect(KeyboardLayoutMetrics.resolve(width: 320, idiom: .phone).profile == .compactPhone)
		#expect(KeyboardLayoutMetrics.resolve(width: 390, idiom: .phone).profile == .phone)
		#expect(KeyboardLayoutMetrics.resolve(width: 440, idiom: .phone).profile == .largePhone)
		#expect(KeyboardLayoutMetrics.resolve(width: 700, idiom: .phone).profile == .landscapePhone)
		#expect(KeyboardLayoutMetrics.resolve(width: 700, idiom: .pad).profile == .pad)
	}

	@MainActor @Test func fieldSpecificLayoutsExposeExpectedKeys() {
		let keyboard = KeyboardView(theme: .system(dark: false), showsGlobe: false)
		keyboard.frame = CGRect(x: 0, y: 0, width: 390, height: keyboard.keyboardHeight)
		keyboard.layoutIfNeeded()

		keyboard.setInputKind(.email)
		let email = Set(keyboard.keyAccessibilityLabels())
		#expect(email.contains("@") && email.contains("."))

		keyboard.setInputKind(.url)
		let url = Set(keyboard.keyAccessibilityLabels())
		#expect(url.contains("/") && url.contains("."))

		keyboard.setInputKind(.numberPad)
		let numeric = Set(keyboard.keyAccessibilityLabels())
		#expect(numeric.contains("0") && numeric.contains("9"))
		#expect(!numeric.contains("Q"))
	}

	@Test func decodeIdentityRejectsEveryStaleRevision() {
		func request(field: UInt64 = 1, document: UInt64 = 2, word: UInt64 = 3,
					 generation: UInt64 = 4, layout: UInt64 = 5,
					 current: String = "might", context: [String] = ["they"]) -> DecodeRequest {
			DecodeRequest(fieldRevision: field, documentRevision: document,
				wordSessionID: word, generation: generation, layoutRevision: layout,
				currentWord: current, context: context, taps: nil)
		}
		let base = request()
		let snapshot = DecodeSnapshot(request: base, suggestions: ["might"], candidates: [],
			correction: nil, confidence: 0, nextCharacterPriors: [:], modelTier: .ngram,
			completedAtUptime: 1)
		#expect(snapshot.isValid(for: base))
		#expect(!snapshot.isValid(for: request(field: 2)))
		#expect(!snapshot.isValid(for: request(document: 3)))
		#expect(!snapshot.isValid(for: request(word: 4)))
		#expect(!snapshot.isValid(for: request(generation: 5)))
		#expect(!snapshot.isValid(for: request(layout: 6)))
		#expect(!snapshot.isValid(for: request(current: "night")))
		#expect(!snapshot.isValid(for: request(context: ["at"])))
	}

	@Test func firstLetterProtectionPreventsMightToNightCandidate() throws {
		let data = try #require(LangData(url: langdataURL()))
		let hits = data.trieSearch("might", maxCost: 2.8)
		#expect(hits.first(where: { $0.word == "might" })?.cost == 0)
		#expect(!hits.contains(where: { $0.word == "night" }))
		#expect(Trie.firstLetterPenaltyPolicy(typedLength: 5,
			candidateFirst: UInt8(ascii: "n"), typedFirst: UInt8(ascii: "m")) == 2.5)
	}

	@Test func broadOracleCanRecoverSevereDeviation() throws {
		let data = try #require(LangData(url: langdataURL()))
		let hits = data.trieSearch("coeevitjkn", maxCost: 7.2)
		#expect(hits.contains(where: { $0.word == "correction" }))
	}

	@Test func shippedVocabularyCoversContractionsAndCurrentRegister() throws {
		let data = try #require(LangData(url: langdataURL()))
		#expect(data.wordCount >= 60_000)
		for word in ["should've", "shouldn't've", "might've", "prolly", "idk",
					 "rizz", "doomscrolling", "situationship"] {
			#expect(data.trieContains(word), "\(word) is missing from langdata.bin")
		}
	}

	@Test func suggestionPrimaryAndCorrectionShareOneDecision() async throws {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		for (typed, context) in [("might", ["they"]), ("whats", ["you", "know"]),
								   ("teh", ["in"]), ("prolly", ["i"])] {
			let snapshot = await decode(engine, word: typed, context: context)
			if let correction = snapshot.correction {
				#expect(snapshot.suggestions.first?.caseInsensitiveCompare(correction) == .orderedSame)
			}
			#expect(snapshot.correction?.lowercased() != "night" || typed != "might")
		}
	}

	@Test func personalizationRollbackReversesExactContext() {
		let user = UserModel()
		user.learn(context: ["they", "really"], word: "might")
		#expect(user.uniCount("might") == 1)
		#expect(user.biLookup("really", "might").count == 1)
		#expect(user.triLookup("they really", "might").count == 1)
		user.demote("might")
		#expect(user.uniCount("might") == 0)
		#expect(user.biLookup("really", "might").count == 0)
		#expect(user.triLookup("they really", "might").count == 0)
	}

	@Test func personalWordsRequireExplicitAdoptionEvidence() throws {
		let lexicon = Lexicon()
		lexicon.load(from: langdataURL())
		let spelling = "qzvaxon"
		#expect(!lexicon.contains(spelling))
		lexicon.noteUse(of: spelling, timesUsed: 20, adoptAfter: 8, allowAdoption: false)
		#expect(!lexicon.contains(spelling))
		lexicon.noteUse(of: spelling, timesUsed: 8, adoptAfter: 8, allowAdoption: true)
		#expect(lexicon.contains(spelling))
	}

	@Test func userModelPersistsAndRecoversFromCorruption() throws {
		let root = FileManager.default.temporaryDirectory
		let validURL = root.appendingPathComponent("user-model-\(UUID().uuidString).json")
		let corruptURL = root.appendingPathComponent("user-model-\(UUID().uuidString).json")
		defer {
			try? FileManager.default.removeItem(at: validURL)
			try? FileManager.default.removeItem(at: corruptURL)
		}
		let writer = UserModel(storageURL: validURL)
		writer.learn(context: ["they"], word: "might")
		writer.save()
		writer.waitForPendingIO()
		let reader = UserModel(storageURL: validURL)
		reader.load()
		#expect(reader.uniCount("might") == 1)

		try Data("not-json".utf8).write(to: corruptURL)
		let corrupt = UserModel(storageURL: corruptURL)
		corrupt.load()
		#expect(corrupt.uniCount("might") == 0)
		#expect(!FileManager.default.fileExists(atPath: corruptURL.path))
	}

	@Test func glideTransformIsAffineAcrossRows() throws {
		let pitchX: CGFloat = 31
		let pitchY: CGFloat = 43
		let origin = CGPoint(x: 17, y: 9)
		let centers: [(letter: Character, point: CGPoint)] = KB.rows.joined().compactMap { letter in
			guard let grid = KB.grid(for: letter) else { return nil }
			return (letter, CGPoint(x: origin.x + CGFloat(grid.0) * pitchX,
				y: origin.y + CGFloat(grid.1) * pitchY))
		}
		let layout = GlideLayout(centers: centers, xPitch: pitchX, yPitch: pitchY)
		for sample in centers {
			let mapped = GlidePreprocess.toGrid(sample.point, layout: layout)
			let expected = try #require(KB.grid(for: sample.letter))
			#expect(abs(Double(mapped.x) - expected.0) < 1e-6)
			#expect(abs(Double(mapped.y) - expected.1) < 1e-6)
		}
		let a = GlidePreprocess.toGrid(CGPoint(x: 100, y: 80), layout: layout)
		let b = GlidePreprocess.toGrid(CGPoint(x: 100.1, y: 80.1), layout: layout)
		#expect(abs(b.x - a.x) < 0.01 && abs(b.y - a.y) < 0.01)
	}

	@Test func approvedAccentRolesMeetTextContrast() {
		for accent in KBPalette.all {
			let pair = KBCustomThemePair.defaults(accent: accent)
			for custom in [pair.light, pair.dark] {
				let theme = KeyboardTheme.custom(custom)
				#expect(KeyboardTheme.contrastRatio(theme.accentKeyText, theme.accentStart) >= 4.5)
				#expect(KeyboardTheme.contrastRatio(theme.accentKeyText, theme.accentEnd) >= 4.5)
			}
		}
	}

	@Test func emojiSkinToneVariantsUseUnicodeModifiers() {
		let variants = KBEmojiVariants.skinToneVariants(of: "👍")
		#expect(variants.count == 5)
		#expect(variants.allSatisfy { $0 != "👍" })
		#expect(KBEmojiVariants.skinToneVariants(of: "👍🏽").isEmpty)
		#expect(KBEmojiVariants.skinToneVariants(of: "🚗").isEmpty)
	}

	@Test func safetyArtifactUsesExactNormalizedMatches() throws {
		let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.deletingLastPathComponent().appendingPathComponent("keyboard/safety.kbguard")
		let safety = try #require(KBSafetyLexicon(url: url))
		#expect(safety.isBlocked("FUCK"))
		#expect(!safety.isBlocked("class"))
		#expect(KBSafetyLexicon.normalize("  It’s   Fine ") == "it's fine")
	}

	private func decode(_ engine: KeyboardEngine, word: String,
						context: [String]) async -> DecodeSnapshot {
		let request = DecodeRequest(fieldRevision: 1, documentRevision: 1,
			wordSessionID: 1, generation: 1, layoutRevision: 1,
			currentWord: word, context: context, taps: nil)
		return await withCheckedContinuation { continuation in
			engine.decode(request) { continuation.resume(returning: $0) }
		}
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
