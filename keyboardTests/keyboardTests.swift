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

	private func keyboardResourceURL(_ name: String) -> URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("keyboard/\(name)")
	}

	@Test func bundledLanguageDataUsesWideV6() throws {
		let url = langdataURL()
		let data = try #require(LangData(url: url))
		let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
		#expect(data.formatVersion == 6)
		#expect(bytes <= 20_000_000)
		#expect(data.wordCount == 114_283)
	}

	@Test func languagePackHealthReportsConcreteFailureReasons() throws {
		let resources = LanguagePackResourceSet(
			manifestURL: keyboardResourceURL("telugu_pack_manifest.json"),
			layoutURL: keyboardResourceURL("telugu_layout.kbpack"),
			teluguLanguageDataURL: keyboardResourceURL("telugu_langdata.bin"),
			tenglishLexiconURL: keyboardResourceURL("tenglish_lexicon.bin"))
		#expect(LanguagePackHealthInspector.inspect(mode: .telugu,
			resources: resources).state == .ready)
		#expect(LanguagePackHealthInspector.inspect(mode: .tenglishToTelugu,
			resources: resources).state == .ready)
		#expect(LanguagePackHealthInspector.inspect(mode: .romanTelugu,
			resources: resources).state == .ready)
		let transliterationOnly = LanguagePackResourceSet(
			manifestURL: resources.manifestURL, layoutURL: resources.layoutURL,
			teluguLanguageDataURL: nil,
			tenglishLexiconURL: resources.tenglishLexiconURL)
		#expect(LanguagePackHealthInspector.inspect(mode: .tenglishToTelugu,
			resources: transliterationOnly).state == .missingResource)
		#expect(LanguagePackHealthInspector.inspect(mode: .romanTelugu,
			resources: transliterationOnly).state == .ready)

		let missing = LanguagePackResourceSet(manifestURL: nil, layoutURL: nil,
			teluguLanguageDataURL: nil, tenglishLexiconURL: nil)
		#expect(LanguagePackHealthInspector.inspect(mode: .telugu,
			resources: missing).state == .missingResource)

		let temporary = FileManager.default.temporaryDirectory
			.appendingPathComponent("language-health-\(UUID().uuidString)",
				isDirectory: true)
		try FileManager.default.createDirectory(at: temporary,
			withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: temporary) }
		let invalidManifest = temporary.appendingPathComponent("manifest.json")
		try Data("{}".utf8).write(to: invalidManifest)
		let invalid = LanguagePackResourceSet(manifestURL: invalidManifest,
			layoutURL: resources.layoutURL,
			teluguLanguageDataURL: resources.teluguLanguageDataURL,
			tenglishLexiconURL: resources.tenglishLexiconURL)
		#expect(LanguagePackHealthInspector.inspect(mode: .telugu,
			resources: invalid).state == .invalidSchemaOrHeader)

		let tamperedLayout = temporary.appendingPathComponent("telugu_layout.kbpack")
		try Data("tampered".utf8).write(to: tamperedLayout)
		let tampered = LanguagePackResourceSet(manifestURL: resources.manifestURL,
			layoutURL: tamperedLayout,
			teluguLanguageDataURL: resources.teluguLanguageDataURL,
			tenglishLexiconURL: resources.tenglishLexiconURL)
		#expect(LanguagePackHealthInspector.inspect(mode: .telugu,
			resources: tampered).state == .hashMismatch)
	}

	@Test func languageHealthReconciliationPreservesPreferenceAndSurfacesExtensionFailure() {
		let local = LanguagePackHealth(languageMode: .telugu, state: .ready,
			detail: "ready", marketingVersion: "1.0", buildVersion: "7",
			packIdentifier: "te", packVersion: 1, resourceHashes: ["layout": "abc"])
		#expect(KBSettings.reconciledLanguagePackHealth(local: local,
			extensionReport: nil, hasUsedKeyboard: false) == local)
		#expect(KBSettings.reconciledLanguagePackHealth(local: local,
			extensionReport: nil, hasUsedKeyboard: true).state
			== .appExtensionBuildMismatch)

		let failed = local.replacingState(.invalidSchemaOrHeader,
			detail: "Telugu layout rejected: invalid header")
		let failedReport = KeyboardExtensionLanguageReport(observedAt: .now,
			marketingVersion: "1.0", buildVersion: "7",
			healthByLanguage: [KBLanguageMode.telugu.rawValue: failed])
		#expect(KBSettings.reconciledLanguagePackHealth(local: local,
			extensionReport: failedReport, hasUsedKeyboard: true) == failed)

		let oldReport = KeyboardExtensionLanguageReport(observedAt: .now,
			marketingVersion: "1.0", buildVersion: "6",
			healthByLanguage: [KBLanguageMode.telugu.rawValue: local])
		#expect(KBSettings.reconciledLanguagePackHealth(local: local,
			extensionReport: oldReport, hasUsedKeyboard: true).state
			== .appExtensionBuildMismatch)

		let localFailure = local.replacingState(.hashMismatch, detail: "bad hash")
		#expect(KBSettings.reconciledLanguagePackHealth(local: localFailure,
			extensionReport: nil, hasUsedKeyboard: true) == localFailure)
	}

	@Test func suggestionCasePolicyOwnsDisplayTapAndCorrectionText() throws {
		func present(typed: String, suggestions: [String], correction: String?,
			sentenceStart: Bool = false) -> PresentedDecodeSnapshot {
			let request = DecodeRequest(fieldRevision: 1, documentRevision: 1,
				wordSessionID: 1, generation: 1, layoutRevision: 1,
				currentWord: typed, context: [], taps: nil)
			let snapshot = DecodeSnapshot(request: request, suggestions: suggestions,
				candidates: [], correction: correction, confidence: 1,
				nextCharacterPriors: [:], modelTier: .ngram, completedAtUptime: 1)
			return SuggestionCasePolicy.present(snapshot, sentenceStart: sentenceStart)
		}

		for (typed, expected) in [("mgiht", "might"), ("Mgiht", "Might"),
			("MGIHT", "MIGHT")] {
			let result = present(typed: typed, suggestions: ["might", "night"],
				correction: "might")
			#expect(result.primaryText == expected)
			#expect(result.correction == expected)
		}
		let mixed = present(typed: "McDonald", suggestions: ["mcdonald"],
			correction: nil)
		#expect(mixed.primaryText == "McDonald")
		#expect(mixed.suggestions.first?.isExactTypedCandidate == true)

		let sentence = present(typed: "", suggestions: ["hello", "i'm", "i'll"],
			correction: nil, sentenceStart: true)
		#expect(sentence.suggestions.map(\.text) == ["Hello", "I'm", "I'll"])
		let pronoun = present(typed: "i", suggestions: ["i"], correction: nil)
		#expect(pronoun.primaryText == "I")
	}

	@MainActor @Test func suggestionPassThroughBoundaryDoesNotMoveKeyGeometry() throws {
		for width: CGFloat in [320, 390, 440] {
			let bar = SuggestionBar(theme: .system(dark: true))
			bar.frame = CGRect(x: 0, y: 0, width: width, height: 44)
			bar.setSuggestions(["one", "two", "three"], highlightPrimary: true)
			bar.layoutIfNeeded()
			#expect(bar.point(inside: CGPoint(x: width / 2, y: 37.9), with: nil))
			#expect(!bar.point(inside: CGPoint(x: width / 2, y: 38), with: nil))
			let primary = try #require(suggestionButton("suggestion.primary", in: bar))
			#expect(primary.frame.minY == -3)
			#expect(primary.frame.height == 44)
			let highlight = try #require(bar.subviews.first {
				!($0 is UIButton) && $0.layer.borderWidth > 0
			})
			#expect(highlight.frame.minY == 1)
		}
	}

	@Test func klipyRequestContainsOnlyExplicitMediaQuery() throws {
		let url = try #require(KlipyClient.requestURL(apiKey: "test-key_1", kind: .gifs,
			query: "  Telugu reaction  ", page: 2))
		let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
		let fields = Dictionary(uniqueKeysWithValues:
			(components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
		#expect(url.scheme == "https")
		#expect(url.path == "/api/v1/test-key_1/gifs/search")
		#expect(fields == ["page": "2", "per_page": "20", "q": "Telugu reaction"])
		// No query (or blank) → the trending feed so the panel shows content on open,
		// with no `q` parameter. A malformed key is still rejected.
		let trending = try #require(KlipyClient.requestURL(apiKey: "key", kind: .gifs, query: nil, page: 1))
		#expect(trending.path == "/api/v1/key/gifs/trending")
		let trendingFields = Dictionary(uniqueKeysWithValues:
			(URLComponents(url: trending, resolvingAgainstBaseURL: false)?.queryItems ?? [])
				.map { ($0.name, $0.value ?? "") })
		#expect(trendingFields == ["page": "1", "per_page": "20"])
		#expect(KlipyClient.requestURL(apiKey: "key", kind: .stickers, query: " ", page: 1)?.path
			== "/api/v1/key/stickers/trending")
		#expect(KlipyClient.requestURL(apiKey: "bad/key", kind: .gifs, query: "hi", page: 1) == nil)
	}

	@Test func klipyParserRejectsUnsafeAndMalformedMedia() throws {
		let json = """
		{"data":{"has_next":true,"data":[
		 {"id":7,"title":"Hello","file":{"sm":{
		   "webp":{"url":"https://cdn.example/preview.webp","width":240,"height":180},
		   "gif":{"url":"https://cdn.example/send.gif","width":240,"height":180}}}},
		 {"id":8,"title":"Unsafe","file":{"sm":{
		   "webp":{"url":"http://cdn.example/preview.webp","width":240,"height":180},
		   "gif":{"url":"http://cdn.example/send.gif","width":240,"height":180}}}}
		]}}
		"""
		let parsed = KlipyClient.parse(Data(json.utf8))
		#expect(parsed.0.count == 1)
		#expect(parsed.0.first?.id == "7")
		#expect(parsed.0.first?.sendURL.scheme == "https")
		#expect(parsed.1)
		#expect(KlipyClient.parse(Data("not-json".utf8)).0.isEmpty)
	}

	@MainActor @Test func mediaPanelLoadsTrendingOnOpen() {
		// Opening the panel (no query) now loads the trending feed instead of waiting for
		// an explicit search, so content shows immediately. Without Full Access it shows
		// the access gate — never the old "Search … to browse" prompt.
		let panel = MediaPanelView(theme: .system(dark: true), showsGlobe: false,
			hasFullAccess: false, kind: .gifs)
		let labels = recursiveSubviews(panel).compactMap { ($0 as? UILabel)?.text }
		#expect(labels.contains(where: { $0.contains("Full Access is required") }))
		#expect(!labels.contains(where: { $0.contains("Search GIFs to browse") }))
	}

	@MainActor @Test func mediaPanelDeniesSearchedMediaWithoutFullAccess() {
		let panel = MediaPanelView(theme: .system(dark: true), showsGlobe: false,
			hasFullAccess: false, kind: .gifs, query: "reaction")
		let labels = recursiveSubviews(panel).compactMap { ($0 as? UILabel)?.text }
		#expect(labels.contains(where: { $0.contains("Full Access") }))
	}

	@Test func progressAccountingIsDeterministicAndProvisionalGlideCanCancel() throws {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
		let first = try #require(calendar.date(from: DateComponents(
			year: 2026, month: 7, day: 18, hour: 12)))
		let second = try #require(calendar.date(byAdding: .day, value: 1, to: first))
		var data = KBStatsData()
		KBStats.apply(words: 2, glided: false, on: &data, date: first, calendar: calendar)
		KBStats.apply(words: 1, glided: true, on: &data, date: second, calendar: calendar)
		#expect(data.totalTyped == 2)
		#expect(data.totalGlided == 1)
		#expect(data.currentStreak == 2)
		let pending = KBStats.noteProvisional(glided: true)
		#if DEBUG
		#expect(KBStats.isProvisionalForTesting(pending))
		#endif
		KBStats.cancel(pending)
		#if DEBUG
		#expect(!KBStats.isProvisionalForTesting(pending))
		#endif
	}

	@MainActor private func recursiveSubviews(_ view: UIView) -> [UIView] {
		view.subviews + view.subviews.flatMap(recursiveSubviews)
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

		bar.setGlidePreview("More", alternatives: ["Move", "Mode"])
		#expect(left.title(for: .normal) == "Move")
		#expect(primary.title(for: .normal) == "More")
		#expect(right.title(for: .normal) == "Mode")
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

	@Test func incrementalGlideResamplingIsChunkInvariant() {
		let raw = [
			CGPoint(x: 0, y: 0), CGPoint(x: 0.4, y: 0.1),
			CGPoint(x: 1.2, y: 0.2), CGPoint(x: 2.1, y: 0.8),
			CGPoint(x: 2.8, y: 1.1),
		]
		var whole = IncrementalGlideResampler(spacing: 0.35)
		_ = whole.append(raw[...])
		var chunked = IncrementalGlideResampler(spacing: 0.35)
		_ = chunked.append(raw[0...1])
		_ = chunked.append(raw[2...])
		#expect(chunked.samples.count == whole.samples.count)
		for (lhs, rhs) in zip(chunked.samples, whole.samples) {
			#expect(abs(lhs.x - rhs.x) < 0.000_001)
			#expect(abs(lhs.y - rhs.y) < 0.000_001)
		}
	}

	@MainActor @Test func streamingGlideUsesMonotonicSessionAndOneFinalRanking() async throws {
		let centers: [(letter: Character, point: CGPoint)] =
			"qwertyuiopasdfghjklzxcvbnm".compactMap { character in
				KB.grid(for: character).map { (character, CGPoint(x: $0.0, y: $0.1)) }
			}
		let layout = GlideLayout(centers: centers, xPitch: 1, yPitch: 1)
		let captureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.deletingLastPathComponent().appendingPathComponent("tools/glide_capture.jsonl")
		let firstLine = try #require(try String(contentsOf: captureURL, encoding: .utf8)
			.split(separator: "\n").first)
		let record = try #require(try JSONSerialization.jsonObject(
			with: Data(firstLine.utf8)) as? [String: Any])
		let path = try #require(record["path"] as? [[Double]]).compactMap { point -> CGPoint? in
			guard point.count == 2 else { return nil }
			return CGPoint(x: point[0], y: point[1])
		}
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let session = engine.beginGlideSession(context: [])
		let midpoint = max(2, path.count / 2)
		let first = await withCheckedContinuation { continuation in
			engine.updateGlideSession(session, path: Array(path.prefix(midpoint)), times: [],
				layout: layout) { continuation.resume(returning: $0) }
		}
		let second = await withCheckedContinuation { continuation in
			engine.updateGlideSession(session, path: path, times: [], layout: layout) {
				continuation.resume(returning: $0)
			}
		}
		let firstUpdate = try #require(first)
		let finalUpdate = try #require(second)
		#expect(finalUpdate.sessionID == firstUpdate.sessionID)
		#expect(finalUpdate.revision > firstUpdate.revision)

		let final = await withCheckedContinuation { continuation in
			engine.finishGlideSession(session, path: path, times: [], layout: layout) { word, alternatives in
				continuation.resume(returning: (word, alternatives))
			}
		}
		#expect(final.0 == finalUpdate.prediction.word)
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
					 current: String = "might", context: [String] = ["they"],
					 language: KBLanguageMode = .english,
					 tier: DecodeModelTier = .ngram) -> DecodeRequest {
			DecodeRequest(fieldRevision: field, documentRevision: document,
				wordSessionID: word, generation: generation, layoutRevision: layout,
				currentWord: current, context: context, taps: nil,
				languageMode: language, requestedModelTier: tier)
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
		#expect(!snapshot.isValid(for: request(language: .tenglishToTelugu)))
		#expect(!snapshot.isValid(for: request(tier: .neuralW8)))
	}

	@Test func internalNeuralTierIsEnglishOnlyAndPublishesOneRanking() async throws {
		let prior = TestNeuralPrior(tier: .neuralW8)
		let engine = KeyboardEngine(languageDataURL: langdataURL(), rescorer: prior)
		#expect(engine.preferredModelTier(for: .english) == .neuralW8)
		#expect(engine.preferredModelTier(for: .tenglishToTelugu) == .ngram)
		#expect(engine.preferredModelTier(for: .romanTelugu) == .ngram)
		#expect(engine.preferredModelTier(for: .telugu) == .ngram)

		func request(word: String, generation: UInt64) -> DecodeRequest {
			DecodeRequest(fieldRevision: 1, documentRevision: generation,
				wordSessionID: 41, generation: generation, layoutRevision: 1,
				currentWord: word, context: ["they"], taps: nil,
				languageMode: .english, requestedModelTier: .neuralW8)
		}
		func run(_ request: DecodeRequest) async -> DecodeSnapshot {
			await withCheckedContinuation { continuation in
				engine.decode(request) { continuation.resume(returning: $0) }
			}
		}

		let first = await run(request(word: "migh", generation: 1))
		let second = await run(request(word: "might", generation: 2))
		#expect(first.modelTier == .neuralW8)
		#expect(second.modelTier == .neuralW8)
		#expect(!first.candidates.isEmpty)
		#expect(first.candidates.allSatisfy { $0.neuralLogProbability != nil })
		#expect(prior.preparedSessions == [41])
		#expect(prior.scoredSessions == [41, 41])
	}

	// The GRU search prior conforms to the same NeuralLanguagePrior seam, so the engine
	// must select the .neuralGRU tier, prepare context once, score the candidate pool, and
	// fold a neural log-prob into every candidate — the wiring the real Core ML GRU rides.
	@Test func gruSearchPriorTierBlendsIntoRanking() async throws {
		let prior = TestNeuralPrior(tier: .neuralGRU)
		let engine = KeyboardEngine(languageDataURL: langdataURL(), rescorer: prior)
		#expect(engine.preferredModelTier(for: .english) == .neuralGRU)
		#expect(engine.preferredModelTier(for: .telugu) == .ngram)

		let request = DecodeRequest(fieldRevision: 1, documentRevision: 1,
			wordSessionID: 7, generation: 1, layoutRevision: 1,
			currentWord: "migh", context: ["they"], taps: nil,
			languageMode: .english, requestedModelTier: .neuralGRU)
		let snapshot = await withCheckedContinuation { continuation in
			engine.decode(request) { continuation.resume(returning: $0) }
		}
		#expect(snapshot.modelTier == .neuralGRU)
		#expect(!snapshot.candidates.isEmpty)
		#expect(snapshot.candidates.allSatisfy { $0.neuralLogProbability != nil })
		#expect(prior.preparedSessions == [7])
		#expect(!prior.scoredSessions.isEmpty)
		#expect(prior.scoredSessions.allSatisfy { $0 == 7 })
	}

	@Test func multiwordSearchPreservesThreeWordPathsAndBoundarySubstitutions() {
		let dictionary = Set(["i", "am", "here", "hello", "world"])
		func paths(_ text: String) -> [MultiwordSearch.Hypothesis] {
			let search = MultiwordSearch(typed: text, taps: nil) { segment, _ in
				dictionary.contains(segment) ? [Candidate(word: segment, cost: 0, logFreq: 1)] : []
			}
			var frontier = [search.root], completed: [MultiwordSearch.Hypothesis] = []
			for _ in 0..<MultiwordSearch.maximumWords {
				let expanded = search.expand(frontier, shouldCancel: { false })
				completed += expanded.filter { $0.offset == search.inputCount }
				frontier = expanded.filter { $0.offset < search.inputCount }
			}
			return completed
		}
		#expect(paths("iamhere").contains { $0.words == ["i", "am", "here"] && abs($0.cost - 2.2) < 0.001 })
		#expect(paths("hellovworld").contains { $0.words == ["hello", "world"] && abs($0.cost - 0.72) < 0.001 })
		let cancelled = MultiwordSearch(typed: "helloworld", taps: nil) { _, _ in
			Issue.record("cancelled search must not request lexicon candidates"); return []
		}
		#expect(cancelled.expand([cancelled.root], shouldCancel: { true }).isEmpty)
	}

	// Optional generated plumbing fixture, intentionally outside release resources.
	nonisolated private static let gruFixtureDirectory = URL(fileURLWithPath:
		ProcessInfo.processInfo.environment["GRU_TEST_FIXTURE_DIR"] ?? "/tmp/ioskeyboard-gru-test-fixture")
	@Test(.enabled(if: FileManager.default.fileExists(atPath:
		gruFixtureDirectory.appendingPathComponent("fixture.json").path)))
	func tinyGRUStreamingAndBatchCoverWholePoolAndPressureReset() async throws {
		struct Fixture: Decodable { let context: [String]; let scores: [String: Double] }
		let directory = Self.gruFixtureDirectory
		let reference = try JSONDecoder().decode(Fixture.self,
			from: Data(contentsOf: directory.appendingPathComponent("fixture.json")))
		try #require(reference.scores.count > 32)
		for batched in [false, true] {
			let prior = GRULanguagePrior(compiledURL: nil,
				packageURL: directory.appendingPathComponent("gru.mlpackage"),
				tokenizerURL: directory.appendingPathComponent("gru_tokenizer.bin"),
				scorePackageURL: batched ? directory.appendingPathComponent("gru_score.mlpackage") : nil,
				layers: 2, hidden: 8)
			var waited = 0.0
			while !prior.isReady, waited < 60 {
				try await Task.sleep(nanoseconds: 200_000_000); waited += 0.2
			}
			try #require(prior.isReady)
			#expect(prior.usesBatchedScorer == batched)
			prior.prepareContext(reference.context, wordSessionID: 101)
			let scores: [String: Double] = try await withCheckedThrowingContinuation { continuation in
				prior.score(candidates: Array(reference.scores.keys), wordSessionID: 101) {
					continuation.resume(with: $0)
				}
			}
			#expect(Set(scores.keys) == Set(reference.scores.keys))
			for (word, expected) in reference.scores {
				let actual = try #require(scores[word])
				#expect(actual.isFinite && abs(actual - expected) < 0.02,
					"\(word): batch=\(batched), actual=\(actual), reference=\(expected)")
			}
			prior.handleMemoryPressure()
			#expect(!prior.isReady)
			prior.prepareForSelection()
			#expect(!prior.isReady, "pressure cooldown must prevent immediate reloading")
			#expect(prior.searchPriorWords(SearchPriorQuery(context: reference.context, prefix: nil, pool: [])) == nil)
		}
	}

	#if INTERNAL_GRU
	private struct GRUReference: Decodable {
		let score_version: Int
		let checkpoint_sha256: String
		let tokenizer_sha256: String
		let context: [String]
		let scores: [String: Double]
	}
	private struct GRUManifest: Decodable {
		let checkpoint_sha256: String
		let tokenizer_sha256: String
	}
	private func loadGRUReference(dataDir: URL, name: String) throws -> GRUReference {
		let decoder = JSONDecoder()
		let reference = try decoder.decode(GRUReference.self,
			from: Data(contentsOf: dataDir.appendingPathComponent(name + ".goldens.json")))
		let manifest = try decoder.decode(GRUManifest.self,
			from: Data(contentsOf: dataDir.appendingPathComponent(name + ".manifest.json")))
		try #require(reference.score_version == 2, "reference must include word-boundary probability")
		try #require(reference.checkpoint_sha256 == manifest.checkpoint_sha256)
		try #require(reference.tokenizer_sha256 == manifest.tokenizer_sha256)
		return reference
	}
	// End-to-end PLUMBING parity: the REAL Core ML GRU (compiled from gru.mlpackage) scored through
	// the Swift GRULanguagePrior must match the PyTorch reference (tools/lm) within fp16 tolerance.
	// This is exactly what the mock wiring test above CANNOT check — MLMultiArray shapes, the
	// token/state_in/logits/state_out feature names, the persisted state threading, and that
	// gru_tokenizer.bin matches qwen_spm.model — all executing on the simulator's Core ML runtime.
	// Goldens computed by tools/lm (PyTorch fp32); a broken shape/name/threading bug is off by nats
	// or NaN, not the < 1 fp16 drift this allows. Artifacts are read from the repo via #filePath.
	@Test func gruCoreMLScoresMatchPyTorchReference() async throws {
		let dataDir = URL(fileURLWithPath: #filePath)      // …/keyboardTests/keyboardTests.swift
			.deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("tools/lm/data")
		let packageURL = dataDir.appendingPathComponent("gru.mlpackage")
		let tokenizerURL = dataDir.appendingPathComponent("gru_tokenizer.bin")
		try #require(FileManager.default.fileExists(atPath: packageURL.path),
			"gru.mlpackage unreachable at \(packageURL.path) — run export_gru_coreml.py")
		try #require(FileManager.default.fileExists(atPath: tokenizerURL.path),
			"gru_tokenizer.bin unreachable at \(tokenizerURL.path) — run export_coreml.py --part tokenizer")

		let prior = GRULanguagePrior(compiledURL: nil, packageURL: packageURL,
			tokenizerURL: tokenizerURL)
		var waited = 0.0                                   // mlpackage compiles + loads async
		while !prior.isReady, waited < 60 {
			try await Task.sleep(nanoseconds: 200_000_000); waited += 0.2
		}
		try #require(prior.isReady, "GRU model did not become ready within 60s")

		let reference = try loadGRUReference(dataDir: dataDir, name: "gru")
		prior.prepareContext(reference.context, wordSessionID: 1)
		let goldens = reference.scores
		let scores: [String: Double] = try await withCheckedThrowingContinuation { continuation in
			prior.score(candidates: Array(goldens.keys), wordSessionID: 1) { result in
				continuation.resume(with: result)
			}
		}
		for (word, golden) in goldens {
			let got = try #require(scores[word], "Core ML returned no score for \(word)")
			#expect(got.isFinite && abs(got - golden) < 1.0,
				"\(word): Core ML \(got) vs PyTorch \(golden) (Δ=\(abs(got - golden)))")
		}
	}

	// Same parity check, but through the BATCHED scorer (gru_score.mlpackage): one [B,T] Core ML
	// call for the whole pool must match the same PyTorch reference. Verifies the batched export's
	// runtime path — the buffer fill ([prev, w…]/targets/mask), the state broadcast across the batch,
	// and log_probs read — end-to-end on the simulator's Core ML runtime (coremltools' in-process
	// predict crashes on this graph, so this IS its runtime verification).
	@Test func gruBatchedCoreMLScoresMatchReference() async throws {
		let dataDir = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("tools/lm/data")
		let packageURL = dataDir.appendingPathComponent("gru.mlpackage")
		let tokenizerURL = dataDir.appendingPathComponent("gru_tokenizer.bin")
		let scorePackageURL = dataDir.appendingPathComponent("gru_score.mlpackage")
		try #require(FileManager.default.fileExists(atPath: packageURL.path))
		try #require(FileManager.default.fileExists(atPath: tokenizerURL.path))
		try #require(FileManager.default.fileExists(atPath: scorePackageURL.path),
			"gru_score.mlpackage unreachable — run export_gru_score_coreml.py")

		let prior = GRULanguagePrior(compiledURL: nil, packageURL: packageURL,
			tokenizerURL: tokenizerURL, scorePackageURL: scorePackageURL)
		var waited = 0.0
		while !prior.isReady, waited < 60 {
			try await Task.sleep(nanoseconds: 200_000_000); waited += 0.2
		}
		try #require(prior.isReady, "GRU model did not become ready within 60s")
		try #require(prior.usesBatchedScorer, "batched scorer did not load; test would not exercise it")

		let reference = try loadGRUReference(dataDir: dataDir, name: "gru_score")
		prior.prepareContext(reference.context, wordSessionID: 2)
		let goldens = reference.scores
		let scores: [String: Double] = try await withCheckedThrowingContinuation { continuation in
			prior.score(candidates: Array(goldens.keys), wordSessionID: 2) { result in
				continuation.resume(with: result)
			}
		}
		for (word, golden) in goldens {
			let got = try #require(scores[word], "batched Core ML returned no score for \(word)")
			#expect(got.isFinite && abs(got - golden) < 1.0,
				"\(word): batched Core ML \(got) vs PyTorch \(golden) (Δ=\(abs(got - golden)))")
		}
	}
	#endif

	@Test func teluguBinaryPacksAreVersionedAndAvailable() throws {
		let layoutPack = TeluguLanguagePack(url:
			keyboardResourceURL("telugu_layout.kbpack"))
		let lexicon = TeluguLexicon(url:
			keyboardResourceURL("telugu_langdata.bin"))
		let transliterator = TenglishTransliterator(url:
			keyboardResourceURL("tenglish_lexicon.bin"))

		let metadata = try #require(layoutPack.metadata)
		#expect(layoutPack.isAvailable)
		#expect(metadata.identifier == "te-IN-apple-mobile")
		#expect(metadata.version == 2)
		#expect(metadata.normalization == "NFC")
		#expect(metadata.releaseStatus == "beta")
		#expect(!metadata.nativeSpeakerReviewed)
		#expect(lexicon.isAvailable)
		#expect(lexicon.vocabularyCount == 22_000)
		#expect(transliterator.isAvailable)
		#expect(transliterator.keyCount == 12_000)
		#expect(KBLanguageMode(rawValue: "tenglish") == .tenglishToTelugu)
		#expect(KBLanguageMode.tenglishToTelugu.isRuntimeAvailable)
		#expect(KBLanguageMode.romanTelugu.isRuntimeAvailable)
		#expect(KBLanguageMode.telugu.isRuntimeAvailable)
	}

	@Test func teluguComposerUsesAppendOnlyHostEdits() throws {
		let rules = try #require(TeluguLanguagePack(url:
			keyboardResourceURL("telugu_layout.kbpack")).composition)
		let consonant = TeluguComposer.edit(for: .teluguConsonant("క"),
			contextBeforeInput: "", rules: rules)
		#expect(consonant == TeluguHostEdit(deleteBackwardCount: 0, insertion: "క"))

		let dependentVowel = TeluguComposer.edit(for: .teluguDependentVowel("ా"),
			contextBeforeInput: "క", rules: rules)
		#expect(dependentVowel == TeluguHostEdit(deleteBackwardCount: 0, insertion: "ా"))
		#expect(("క" + dependentVowel.insertion) == "కా")
		#expect(TeluguComposer.edit(for: .teluguDependentVowel("ా"),
			contextBeforeInput: "", rules: rules).insertion.isEmpty)
		let contextualVowel = TeluguComposer.edit(
			for: .teluguVowel(independent: "ఆ", dependent: "ా"),
			contextBeforeInput: "క", rules: rules)
		#expect(contextualVowel.insertion == "ా")
		#expect(TeluguComposer.edit(
			for: .teluguVowel(independent: "ఆ", dependent: "ా"),
			contextBeforeInput: "", rules: rules).insertion == "ఆ")

		let virama = TeluguComposer.edit(for: .teluguVirama("్"),
			contextBeforeInput: "క", rules: rules)
		#expect(virama == TeluguHostEdit(deleteBackwardCount: 0, insertion: "్"))
		let conjunct = TeluguComposer.edit(for: .teluguConsonant("ష"),
			contextBeforeInput: "క్", rules: rules)
		#expect(conjunct == TeluguHostEdit(deleteBackwardCount: 0, insertion: "ష"))
		#expect(("క్" + conjunct.insertion) == "క్ష")
	}

	@Test func teluguAmmaSequenceDoesNotDuplicateTheFinalConsonant() throws {
		let rules = try #require(TeluguLanguagePack(url:
			keyboardResourceURL("telugu_layout.kbpack")).composition)
		let inputs: [KeyOutput] = [
			.text("అ"), .teluguConsonant("మ"),
			.teluguVirama("్"), .teluguConsonant("మ"),
		]
		var host = ""
		for input in inputs {
			let edit = TeluguComposer.edit(for: input,
				contextBeforeInput: host, rules: rules)
			#expect(edit.deleteBackwardCount == 0)
			host.append(contentsOf: edit.insertion)
		}
		#expect(host == "అమ్మ")
		#expect(host == host.precomposedStringWithCanonicalMapping)
	}

	@Test func teluguLayoutMatchesTheExternalAppleMobilePages() throws {
		let pack = TeluguLanguagePack(url:
			keyboardResourceURL("telugu_layout.kbpack"))
		let layout = try #require(pack.layout)
		let primary = layout.primary.rows.flatMap { $0 }
		#expect(layout.primary.rows.map(\.count) == [10, 10, 10, 10, 9])
		#expect(layout.alternate == nil)
		#expect(primary.contains(where: { $0.label == "క"
			&& $0.output == .teluguConsonant("క") }))
		#expect(layout.bottomKeys.contains(where: { $0.output == .teluguVirama("్")
			&& $0.alternatives == ["అ", "్‌", "్‍"] }))
		#expect(primary.contains(where: { $0.label == "అ"
			&& $0.output == .teluguVowel(independent: "అ", dependent: nil) }))
		#expect(primary.contains(where: { $0.label == "ఖ"
			&& $0.output == .teluguConsonant("ఖ") }))
		#expect(primary.allSatisfy { !$0.accessibilityLabel.isEmpty })
		#expect(layout.numbers.rows[0].map(\.label) ==
			["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
		#expect(layout.numbers.rows[0].map { $0.alternatives.first ?? "" } ==
			["౧", "౨", "౩", "౪", "౫", "౬", "౭", "౮", "౯", "౦"])
	}

	@Test func everyExternalTeluguOutputIsNFC() throws {
		let pack = TeluguLanguagePack(url:
			keyboardResourceURL("telugu_layout.kbpack"))
		let layout = try #require(pack.layout)
		let keys = layout.primary.rows.flatMap { $0 }
			+ (layout.alternate?.rows.flatMap { $0 } ?? [])
			+ layout.numbers.rows.flatMap { $0 } + layout.bottomKeys
		for key in keys {
			#expect(key.output.literal
				== key.output.literal.precomposedStringWithCanonicalMapping)
			#expect(key.alternatives.allSatisfy {
				$0 == $0.precomposedStringWithCanonicalMapping
			})
		}
	}

	@Test func swiftBackspaceRemovesACompleteTeluguCluster() {
		var conjunct = "క్ష"
		conjunct.removeLast()
		#expect(conjunct.isEmpty)
	}

	@Test func suffixReplacementStopsAtTheSamePrefixForGraphemeAndScalarHosts() throws {
		let original = "Before అంతే "
		let plan = try #require(HostSuffixReplacementPlan(
			contextBeforeInput: original, suffix: "అంతే ", replacement: "anthe"))
		#expect(plan.prefix == "Before ")

		var graphemeHost = original
		var graphemeDeletes = 0
		while plan.state(for: graphemeHost) == .deleteBackward {
			graphemeHost.removeLast()
			graphemeDeletes += 1
		}
		#expect(plan.state(for: graphemeHost) == .readyToInsert)
		#expect(graphemeHost + plan.replacement == "Before anthe")
		#expect(graphemeDeletes < plan.maximumDeleteCount)

		var scalarHost = original
		var scalarDeletes = 0
		while plan.state(for: scalarHost) == .deleteBackward {
			var scalars = scalarHost.unicodeScalars
			scalars.removeLast()
			scalarHost = String(scalars)
			scalarDeletes += 1
			#expect(scalarDeletes <= plan.maximumDeleteCount)
		}
		#expect(plan.state(for: scalarHost) == .readyToInsert)
		#expect(scalarHost + plan.replacement == "Before anthe")
	}

	/// A UITextDocumentProxy-shaped host: deleting the last character reports the new
	/// context before the cursor, and an EMPTY field reports nil (as UIKit does).
	private func applyPlan(_ plan: HostSuffixReplacementPlan, host: String)
		-> (ok: Bool, host: String) {
		var host = host
		let ok = plan.apply(initialContext: host,
			deleteBackward: {
				host.removeLast()
				return host.isEmpty ? nil : host
			},
			insert: { host += $0 })
		return (ok, host)
	}

	// Picking a suggestion for the FIRST word (or undoing its correction) empties the
	// field on the last deletion; the host then reports a nil context. Regression: the
	// old loop treated that nil as a failure, so it deleted the word and inserted nothing.
	@Test func suffixReplacementCompletesWhenTheFieldEmptiesForAFirstWord() throws {
		// First-word pick: "Helo" -> "Hello ".
		let pick = try #require(HostSuffixReplacementPlan(
			contextBeforeInput: "Helo", suffix: "Helo", replacement: "Hello "))
		#expect(pick.prefix == "")
		let picked = applyPlan(pick, host: "Helo")
		#expect(picked.ok)
		#expect(picked.host == "Hello ")

		// First-word correction-undo on backspace: "Hello " -> "Helo".
		let undo = try #require(HostSuffixReplacementPlan(
			contextBeforeInput: "Hello ", suffix: "Hello ", replacement: "Helo"))
		#expect(undo.prefix == "")
		let reverted = applyPlan(undo, host: "Hello ")
		#expect(reverted.ok)
		#expect(reverted.host == "Helo")
	}

	// A word that is NOT first keeps a non-empty prefix, so the host never empties — the
	// path that always worked must keep working after the first-word fix.
	@Test func suffixReplacementStillReplacesAWordThatFollowsOtherText() throws {
		let plan = try #require(HostSuffixReplacementPlan(
			contextBeforeInput: "foo helo", suffix: "helo", replacement: "hello "))
		#expect(plan.prefix == "foo ")
		let result = applyPlan(plan, host: "foo helo")
		#expect(result.ok)
		#expect(result.host == "foo hello ")
	}

	// The diagnostics Snapshot is persisted to the shared App Group and read across the app,
	// the extension, and app upgrades. A decode regression would silently wipe it, so pin
	// both backward compatibility and the benchmark ratio math derived from the counters.
	@Test func diagnosticsSnapshotDecodesLegacyDataAndComputesBenchmarkRatios() throws {
		// A snapshot written before the benchmark metrics existed must still decode, with
		// every new counter absent (nil) rather than throwing.
		let legacy = #"{"updated":0,"warningCount":2,"criticalCount":0,"peakFootprintMB":18.5,"minAvailableMB":40,"limitMB":58.5}"#
		let old = try JSONDecoder().decode(KBDiagnostics.Snapshot.self, from: Data(legacy.utf8))
		#expect(old.warningCount == 2)
		#expect(old.peakFootprintMB == 18.5)
		#expect(old.wordsCommitted == nil)
		#expect(old.physicalTaps == nil)
		#expect(old.peakCPUPercent == nil)
		#expect(old.initLatencyBins == nil)

		var snap = KBDiagnostics.Snapshot()
		snap.wordsCommitted = 100
		snap.wordsModified = 7
		snap.wordsAutocorrected = 22
		snap.correctionsReverted = 3
		snap.nwpOpportunities = 40
		snap.nwpHits = 18
		snap.activeTypingMs = 120_000        // 2 active minutes
		snap.committedChars = 520
		snap.physicalTaps = 430
		snap.peakCPUPercent = 63.5
		snap.initLatencyBins = [0, 1, 2, 3]
		let round = try JSONDecoder().decode(KBDiagnostics.Snapshot.self,
			from: JSONEncoder().encode(snap))
		#expect(round.wordsCommitted == 100)
		#expect(round.nwpHits == 18)
		#expect(round.physicalTaps == 430)
		#expect(round.peakCPUPercent == 63.5)
		#expect(round.initLatencyBins == [0, 1, 2, 3])

		// The published ratios (mirrors DiagnosticsView): WMR, NWP hit rate, WPM, KPC.
		#expect(abs(Double(round.wordsModified!) / Double(round.wordsCommitted!) - 0.07) < 1e-9)
		#expect(abs(Double(round.nwpHits!) / Double(round.nwpOpportunities!) - 0.45) < 1e-9)
		#expect(abs(Double(round.wordsCommitted!) / (round.activeTypingMs! / 60_000) - 50) < 1e-9)
		#expect(Double(round.physicalTaps!) / Double(round.committedChars!) < 1.0)   // taps < chars
	}

	@MainActor @Test func nativeTeluguKeyboardDoesNotReuseQwertyGeometry() {
		let keyboard = KeyboardView(theme: .system(dark: false), showsGlobe: false,
			languageMode: .telugu)
		keyboard.frame = CGRect(x: 0, y: 0, width: 390, height: keyboard.keyboardHeight)
		keyboard.layoutIfNeeded()
		let labels = Set(keyboard.keyAccessibilityLabels())
		#expect(labels.contains("Telugu ka"))
		#expect(labels.contains("Telugu ha"))
		#expect(!labels.contains("Q"))
	}

	@MainActor @Test func nativeTeluguKeysFitSupportedPhoneWidths() {
		for width: CGFloat in [320, 375, 390, 430, 568] {
			let keyboard = KeyboardView(theme: .system(dark: false), showsGlobe: false,
				languageMode: .telugu)
			keyboard.frame = CGRect(x: 0, y: 0, width: width, height: 400)
			keyboard.frame.size.height = keyboard.keyboardHeight
			keyboard.layoutIfNeeded()
			let frames = keyboard.keyFramesForTesting()
			#expect(!frames.isEmpty)
			#expect(frames.allSatisfy { frame in
				frame.width > 0 && frame.height > 0 && frame.minX >= -0.5
					&& frame.maxX <= width + 0.5 && frame.minY >= -0.5
					&& frame.maxY <= keyboard.bounds.height + 0.5
			})
		}
	}

	@Test func nativeTeluguDecodeNeverAutocorrectsWithEnglish() async throws {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let request = DecodeRequest(fieldRevision: 1, documentRevision: 1,
			wordSessionID: 1, generation: 1, layoutRevision: 1,
			currentWord: "మీ", context: [], taps: nil, languageMode: .telugu)
		let snapshot = await withCheckedContinuation { continuation in
			engine.decode(request) { continuation.resume(returning: $0) }
		}
		#expect(snapshot.correction == nil)
		#expect(snapshot.suggestions.contains(where: { $0.hasPrefix("మీ") }))
		#expect(snapshot.candidates.allSatisfy { $0.neuralLogProbability == nil })
	}

	@Test func commercialPolicyRejectsCashRewardedAdsAndUnsafeClicks() throws {
		let rewardedCash = CommercialCampaign(id: "cash-ad", title: "Cash",
			subtitle: "", merchantID: nil, interest: nil, source: .rewardedAd,
			reward: .cashback, destination: nil)
		#expect(!rewardedCash.isPolicyCompatible)

		let affiliate = CommercialCampaign(id: "merchant-offer", title: "Offer",
			subtitle: "", merchantID: "merchant", interest: .shopping,
			source: .affiliate, reward: .cashback, destination: nil)
		#expect(affiliate.isPolicyCompatible)
		let valid = AuthenticatedOfferClick(campaignID: affiliate.id,
			merchantID: "merchant",
			oneTimeToken: "one-time", destination: URL(string: "https://merchant.example")!,
			expiresAt: .now.addingTimeInterval(60))
		#expect(try valid.validated(for: affiliate).scheme == "https")

		let unsafe = AuthenticatedOfferClick(campaignID: affiliate.id,
			merchantID: "merchant",
			oneTimeToken: "one-time", destination: URL(string: "http://merchant.example")!,
			expiresAt: .now.addingTimeInterval(60))
		#expect(throws: CommercialPolicyError.self) { try unsafe.validated(for: affiliate) }
	}

	@Test func tenglishUsesReviewedFormsAndDoesNotTrustUnknownNames() throws {
		let transliterator = TenglishTransliterator(url:
			keyboardResourceURL("tenglish_lexicon.bin"))
		let known = try #require(transliterator.candidates(for: "meeru", context: [] ).first)
		#expect(known.text == "మీరు")
		#expect(known.fromLexicon)
		#expect(known.confidence >= 0.90)

		#expect(transliterator.candidates(for: "meher", context: []).isEmpty)
	}

	@Test func tenglishSupportsFirstLetterPrefixesAndReviewedAnthe() throws {
		let transliterator = TenglishTransliterator(url:
			keyboardResourceURL("tenglish_lexicon.bin"))
		#expect(!transliterator.candidates(for: "a", context: []).isEmpty)
		let anthe = try #require(transliterator.candidates(
			for: "anthe", context: [], limit: 8).first)
		#expect(anthe.text == "అంతే")
		#expect(anthe.confidence >= 0.90)
	}

	@Test func tenglishDecodeKeepsSuggestionAndCommitAuthorityTogether() async throws {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let request = DecodeRequest(fieldRevision: 1, documentRevision: 1,
			wordSessionID: 1, generation: 1, layoutRevision: 1,
			currentWord: "nenu", context: [], taps: nil,
			languageMode: .tenglishToTelugu)
		let snapshot = await withCheckedContinuation { continuation in
			engine.decode(request) { continuation.resume(returning: $0) }
		}
		#expect(snapshot.correction == "నేను")
		#expect(snapshot.suggestions.first == snapshot.correction)
		#expect(snapshot.request.languageMode == .tenglishToTelugu)
		let boundary = try #require(engine.immediateBoundarySnapshot(request))
		#expect(boundary.correction == snapshot.correction)
		#expect(boundary.suggestions == snapshot.suggestions)
	}

	@Test func tenglishIdhiCentersTeluguAndKeepsRomanOnTheLeft() async throws {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let snapshot = await decode(engine, word: "idhi", context: [],
			language: .tenglishToTelugu)
		#expect(snapshot.suggestions.first == "ఇది")
		#expect(snapshot.suggestions.dropFirst().first == "idhi")
		#expect(snapshot.correction == "ఇది")
	}

	@Test func romanTeluguNeverEmitsTeluguScript() async throws {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let snapshot = await decode(engine, word: "idhi", context: [],
			language: .romanTelugu)
		#expect(snapshot.suggestions.first == "idhi")
		#expect(snapshot.correction == nil)
		#expect(snapshot.suggestions.allSatisfy { value in
			value.unicodeScalars.allSatisfy(\.isASCII)
		})
	}

	@Test func romanTeluguUsesItsOwnMemoryMappedContextModel() async throws {
		let transliterator = TenglishTransliterator(url:
			keyboardResourceURL("tenglish_lexicon.bin"))
		#expect(transliterator.romanContextBonus(
			for: "oka", context: ["idhi"]) > 0)
		#expect(transliterator.romanPredictions(
			context: ["idhi"], limit: 3).first?.text == "oka")

		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let snapshot = await decode(engine, word: "", context: ["idhi"],
			language: .romanTelugu)
		#expect(snapshot.suggestions.first == "oka")
		#expect(snapshot.suggestions.allSatisfy { value in
			value.unicodeScalars.allSatisfy(\.isASCII)
		})
	}

	@Test func TeluguModesDoNotLeaveTheStripEmptyBetweenWords() async throws {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let converted = await decode(engine, word: "", context: [],
			language: .tenglishToTelugu)
		#expect(!converted.suggestions.isEmpty)
		#expect(converted.suggestions.allSatisfy { value in
			value.unicodeScalars.contains { (0x0C00...0x0C7F).contains($0.value) }
		})

		let roman = await decode(engine, word: "", context: ["unknown"],
			language: .romanTelugu)
		#expect(!roman.suggestions.isEmpty)
		#expect(roman.suggestions.allSatisfy { value in
			value.unicodeScalars.allSatisfy(\.isASCII)
		})
	}

	@Test func firstLetterProtectionPreventsMightToNightCandidate() throws {
		let data = try #require(LangData(url: langdataURL()))
		let hits = data.trieSearch("might", maxCost: 2.8)
		#expect(hits.first(where: { $0.word == "might" })?.cost == 0)
		#expect(!hits.contains(where: { $0.word == "night" }))
		#expect(Trie.firstLetterPenaltyPolicy(typedLength: 5,
			candidateFirst: UInt8(ascii: "n"), typedFirst: UInt8(ascii: "m")) == 2.5)
	}

	@Test func touchProfileLearnsBoundedRowOffsetsWithoutRawHistory() throws {
		let suite = "touch-profile-tests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let profile = TouchSpatialProfile(defaults: defaults)
		let sample = KeyTap(dx: 0.18, dy: -0.12)
		for _ in 0..<8 {
			profile.observe(word: "asdf", taps: Array(repeating: sample, count: 4),
				defaults: defaults)
		}
		let adjusted = try #require(profile.adjusted([Optional(sample)], typed: "a"))
		let value = try #require(adjusted[0])
		#expect(abs(value.dx) < 0.02)
		#expect(abs(value.dy) < 0.02)
		profile.reset(defaults: defaults)
		let reset = try #require(profile.adjusted([Optional(sample)], typed: "a"))
		#expect(reset[0] == sample)
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
					 "rizz", "doomscrolling", "situationship", "haptic"] {
			#expect(data.trieContains(word), "\(word) is missing from langdata.bin")
		}
	}

	@Test func expandedEnglishFormsReachTrieAndGlideAnchors() throws {
		let data = try #require(LangData(url: langdataURL()))
		for word in ["colour", "favourite", "organise", "travelling", "cancelled",
			"reproducibility", "epistemology", "hermeneutics", "unsubscribed",
			"screenshots", "livestreaming", "brb", "ttyl", "tysm", "covid",
			"passkeys", "prepone", "bengaluru"] {
			#expect(data.trieContains(word), "expanded vocabulary missing: \(word)")
			let completions = data.trieCompletions(prefix: word, limit: 100)
			#expect(completions.contains { $0.word == word })
			let anchors = data.glideAnchorWords(first: [word.first!], last: [word.last!], perBucket: data.wordCount)
			#expect(anchors.contains(word), "Glide anchor omitted: \(word)")
		}
		for word in ["dont", "im", "youre", "cant"] {
			#expect(!data.trieContains(word))
		}
	}

	@Test func expandedEnglishLiteralWordsAreNotDestructivelyCorrected() async {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		for word in ["colour", "favourite", "organise", "brb", "ttyl", "tysm",
			"screenshots", "passkeys", "epistemology", "bengaluru"] {
			let snapshot = await decode(engine, word: word, context: [])
			#expect(snapshot.correction == nil || snapshot.correction == word,
				"\(word) replaced by \(snapshot.correction ?? "nil")")
			#expect(snapshot.suggestions.contains(word), "literal missing: \(word)")
		}
	}

	@Test func coldStartDoesNotSurfaceCorpusCharacterNames() async {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let snapshot = await decode(engine, word: "", context: [])
		#expect(!snapshot.suggestions.map { $0.lowercased() }.contains("tom"))
	}

	@Test func multiwordAndSevereGoldensUseOneAuthoritativeRanking() async {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let split = await decode(engine, word: "thisbis", context: [])
		#expect(split.suggestions.first == "this is")
		#expect(split.correction == "this is")
		let severe = await decode(engine, word: "coeevitjkn", context: [])
		#expect(severe.suggestions.first == "correction")
		#expect(severe.correction == "correction")
	}

	@Test func incrementalSearchMatchesFullTrieAndRetainsSevereCandidate() throws {
		let data = try #require(LangData(url: langdataURL()))
		let seeds = try #require(data.incrementalSeeds(
			typedFirst: UInt8(ascii: "c"), firstTap: nil))
		let session = IncrementalDecodeSession(seeds: seeds)
		#expect(session.seedCount > 5_000)

		let near = "correcgion"
		#expect(session.advance(to: near))
		let incremental = Dictionary(uniqueKeysWithValues:
			session.candidates(maxCost: 3.6).map { ($0.word, $0.cost) })
		let full = Dictionary(uniqueKeysWithValues:
			data.trieSearch(near, maxCost: 3.6).map { ($0.word, $0.cost) })
		#expect(incremental.keys == full.keys)
		for (word, cost) in full {
			#expect(abs((incremental[word] ?? .infinity) - cost) < 1e-9)
		}

		#expect(session.advance(to: "coeevitjkn"))
		#expect(session.candidates(maxCost: 7.2).contains { $0.word == "correction" })
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

	@MainActor @Test func emojiCategoryHighlightFollowsEveryTap() async throws {
		let store = try #require(EmojiStore(url: emojiBinaryURL()))
		let palette = EmojiKeyboardView(theme: .system(dark: true), showsGlobe: false,
			store: store)
		palette.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
		palette.layoutIfNeeded()
		let tabs = recursiveSubviews(palette).compactMap { view -> (Int, UIButton)? in
			guard let button = view as? UIButton,
				  let identifier = button.accessibilityIdentifier,
				  identifier.hasPrefix("emoji.category."),
				  let index = Int(identifier.dropFirst("emoji.category.".count)) else { return nil }
			return (index, button)
		}.sorted { $0.0 < $1.0 }
		#expect(tabs.count >= 3)
		#expect(tabs.allSatisfy { $0.1.buttonType == .custom })

		for target in [2, 1] {
			tabs[target].1.sendActions(for: .touchUpInside)
			#expect(tabs[target].1.accessibilityTraits.contains(.selected))
			await Task.yield()
			palette.layoutIfNeeded()
			#expect(tabs[target].1.isSelected)
			#expect((tabs[target].1.backgroundColor?.cgColor.alpha ?? 0) <= 0.08)
			for (index, button) in tabs where index != target {
				#expect(!button.isSelected)
				#expect(!button.accessibilityTraits.contains(.selected))
			}
		}
	}

	/// The re-added clipboard store (afda5b4 UX) with its P0 hardening: dedupe-resurface,
	/// pin/unpinned caps, sensitive-content rejection (OTP / Luhn card numbers), and a
	/// retention TTL that expires unpinned items on disk while pins survive.
	@Test func clipboardStoreDedupesCapsAndHardensPrivacy() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("clip-\(UUID().uuidString).json")
		defer { try? FileManager.default.removeItem(at: url) }

		// Basic add + dedupe-resurface (re-adding moves to front, keeps one copy).
		#expect(KBClipboard.add("hello", at: url))
		#expect(KBClipboard.add("world", at: url))
		#expect(KBClipboard.add("hello", at: url))
		let items = KBClipboard.all(at: url)
		#expect(items.map(\.text) == ["hello", "world"])

		// Row formatting: newlines / indentation / padding collapse to one clean line
		// for display (insertion still uses the raw text).
		#expect(ClipboardPanelView.displayText("line one\n\tline two\n\n  line three  ")
			== "line one line two line three")

		// Sensitive content is never stored: OTP-shaped codes and Luhn-valid cards.
		#expect(!KBClipboard.isSensitive("hello world"))
		#expect(KBClipboard.isSensitive("123456"))              // 6-digit OTP
		#expect(KBClipboard.isSensitive("4242 4242 4242 4242")) // Luhn-valid test card
		#expect(!KBClipboard.isSensitive("4242 4242 4242 4241"))// fails Luhn -> kept
		#expect(!KBClipboard.add("008041", at: url))            // OTP rejected by add
		#expect(!KBClipboard.all(at: url).contains { $0.text == "008041" })

		// Retention TTL: an unpinned item older than the window is pruned on read; a
		// pinned item of the same age survives.
		let old = Date().addingTimeInterval(-(KBClipboard.retentionInterval + 60))
		let seeded = [KBClipboardItem(text: "stale", pinned: false, date: old),
					  KBClipboardItem(text: "kept", pinned: true, date: old)]
		try JSONEncoder().encode(seeded).write(to: url)
		let live = KBClipboard.all(at: url)
		#expect(live.map(\.text) == ["kept"])
		// Prune persisted: a fresh read of the file no longer contains the stale item.
		let reencoded = try JSONDecoder().decode([KBClipboardItem].self,
			from: Data(contentsOf: url))
		#expect(!reencoded.contains { $0.text == "stale" })

		// Unpinned cap holds; pins ride above it.
		for i in 0..<(KBClipboard.maxItems + 20) { KBClipboard.add("row\(i)", at: url) }
		let capped = KBClipboard.all(at: url)
		#expect(capped.filter { !$0.pinned }.count <= KBClipboard.maxItems)
		#expect(capped.contains { $0.text == "kept" && $0.pinned })
	}

	@Test func safetyArtifactUsesExactNormalizedMatches() throws {
		let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.deletingLastPathComponent().appendingPathComponent("keyboard/safety.kbguard")
		let safety = try #require(KBSafetyLexicon(url: url))
		#expect(safety.entryCount == 997)
		#expect(safety.isBlocked("FUCK"))
		#expect(safety.isBlocked("5H1T"))
		#expect(safety.isBlocked("  2 GIRLS   1 CUP "))
		#expect(safety.isBlocked("XXX"))
		#expect(safety.isBlocked("దెంగు"))
		#expect(safety.language(for: "దెంగు") == .telugu)
		#expect(safety.action(for: "కుక్క") == .demote)
		#expect(safety.language(for: "కుక్క") == .telugu)
		#expect(!safety.isBlocked("కుక్క"))
		#expect(!safety.isBlocked("class"))
		#expect(!safety.isBlocked("Meher"))
		#expect(!safety.isBlocked("Telangana"))
		#expect(!safety.isBlocked("prolly"))
		#expect(safety.action(for: "kukka") == .allow)
		#expect(KBSafetyLexicon.normalize("  It’s   Fine ") == "it's fine")
	}

	/// Legal-risk guarantee, at the runtime layer the end user actually hits: every term on
	/// the requested Google profanity list (Shidouuu/Google-profanity-words) resolves to a
	/// blocked action through KBSafetyLexicon — as typed AND upper-cased, since the lookup
	/// case-folds — so none can ever be surfaced as a suggestion or autocorrect target.
	@Test func everyRequestedProfanityTermIsBlockedAtRuntime() throws {
		let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.deletingLastPathComponent()
		let safety = try #require(KBSafetyLexicon(
			url: root.appendingPathComponent("keyboard/safety.kbguard")))
		let list = try String(contentsOf:
			root.appendingPathComponent("tools/data/google_profanity_shidouuu_en.txt"),
			encoding: .utf8)
		let words = list.split(whereSeparator: \.isNewline)
			.map(String.init).filter { !$0.isEmpty }
		#expect(words.count == 451)
		let unblocked = words.filter { !(safety.isBlocked($0) && safety.isBlocked($0.uppercased())) }
		#expect(unblocked.count == 0, "\(unblocked.count) requested profanity terms are not blocked")
	}

	/// One-off "receive …" corpus successors are singleton evidence and must not
	/// hijack broad lexical recovery. The compact LM keeps those records for legacy
	/// compatibility, but the runtime backs off before ranking or context injection.
	@Test func singletonContextCannotHijackSevereRecovery() async {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let s = await decode(engine, word: "coeevitjkn", context: ["possibly", "receive"])
		#expect(s.correction == "correction",
			"singleton context changed recovery: \(s.correction ?? "nil") sugg=\(s.suggestions)")
		#expect(s.suggestions.first == "correction")
		#expect(!s.suggestions.contains("physician"))
		#expect(!s.suggestions.contains("communion"))
	}

	/// Reproduces the exact live simulator battery misses (2026-07-20): context-injected
	/// candidates outranked near-perfect channel matches. Asserts the channel-dominance
	/// guard: when a close (≤ realWordMaxCost) correction exists, loose candidates
	/// (context injection / broad recovery) far outside it cannot win the boundary
	/// decision or the primary slot.
	@Test func looseCandidatesCannotBeatCloseChannelMatches() async {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let cases: [(typed: String, context: [String], want: String)] = [
			("sebd", ["can", "you"], "send"),
			("coudl", ["this", "work", "running"], "could"),
			("recieve", ["running", "for", "definitely"], "receive"),
		]
		for c in cases {
			let s = await decode(engine, word: c.typed, context: c.context)
			#expect(s.correction == c.want,
				"\(c.typed) after \(c.context): correction=\(s.correction ?? "nil") sugg=\(s.suggestions)")
			#expect(s.suggestions.first == c.want,
				"\(c.typed) after \(c.context): primary=\(s.suggestions.first ?? "nil")")
		}
		// The severe golden must keep working: no close candidate exists, so the loose
		// pool still rescues and commits, context or not.
		let severe = await decode(engine, word: "coeevitjkn",
			context: ["for", "definitely", "decided"])
		#expect(severe.suggestions.first == "correction",
			"severe: sugg=\(severe.suggestions)")
		#expect(severe.correction == "correction",
			"severe: correction=\(severe.correction ?? "nil")")
		let liveContext = await decode(engine, word: "coeevitjkn",
			context: ["could", "definitely", "receive"])
		let liveEvidence = liveContext.candidates.map {
			"\($0.word){\($0.source.rawValue),s=\($0.score),c=\($0.spatialCost),lm=\($0.logLanguageProbability)}"
		}.joined(separator: ", ")
		#expect(liveContext.suggestions.first == "correction",
			"live severe context: sugg=\(liveContext.suggestions); candidates=\(liveEvidence)")
		#expect(liveContext.correction == "correction",
			"live severe context: correction=\(liveContext.correction ?? "nil"); candidates=\(liveEvidence)")
	}

	// LM-in-the-trie: a context prior must GENERATE a plausible word that sits just outside
	// the base edit radius (the recall win), without lowering its channel cost, and without
	// fabricating words whose prefix the prior never funded.
	@Test func trieSearchPriorExpandsContextPlausibleWords() {
		let trie = Trie()
		trie.insert("go", freq: 100)
		trie.insert("got", freq: 50)
		// "got" is one insertion (1.6) beyond "go" — outside a tight 1.0 budget.
		let base = trie.search("go", maxCost: 1.0)
		#expect(base.contains { $0.word == "go" })
		#expect(!base.contains { $0.word == "got" }, "got is outside the base radius")
		// With the LM saying "got" is a likely continuation, the search reaches and emits it.
		let guided = trie.search("go", maxCost: 1.0, prior: TrieSearchPrior(likelyWords: ["got"]))
		#expect(guided.contains { $0.word == "got" }, "prior must expand the search to got")
		#expect((guided.first { $0.word == "got" }?.cost ?? 0) > 1.0,
			"reported channel cost is unchanged — only the search budget widened")
		// An unrelated prior funds a different prefix, so it must NOT conjure "got".
		let off = trie.search("go", maxCost: 1.0, prior: TrieSearchPrior(likelyWords: ["xyz"]))
		#expect(!off.contains { $0.word == "got" })
	}

	// The neural prior funds the trie by PROBABILITY, not rank: a confident context widens the
	// search narrowly and deeply toward its one likely word; an unsure context funds its top
	// candidates broadly. Both "got" and "gob" sit one insertion (1.6) beyond a tight 1.0 budget.
	@Test func trieSearchPriorProbabilityWeightingFundsByConfidence() {
		let trie = Trie()
		trie.insert("go", freq: 100)
		trie.insert("got", freq: 50)
		trie.insert("gob", freq: 50)
		// PEAKED: the LM is almost certain the next word is "got" — fund it to the cap, starve "gob".
		let peaked = trie.search("go", maxCost: 1.0,
			prior: TrieSearchPrior(scoredWords: [("got", -0.1), ("gob", -8.0)]))
		#expect(peaked.contains { $0.word == "got" }, "the confident leader is reached")
		#expect(!peaked.contains { $0.word == "gob" }, "the starved tail stays outside the radius")
		// FLAT: the LM can't separate "got" and "gob" — fund both shallowly, and both are reached.
		let flat = trie.search("go", maxCost: 1.0,
			prior: TrieSearchPrior(scoredWords: [("got", -1.0), ("gob", -1.05)]))
		#expect(flat.contains { $0.word == "got" } && flat.contains { $0.word == "gob" },
			"an unsure context funds its top candidates broadly")
	}

	@Test func neuralFundingRetainsAbsoluteProbabilityAndTerminalIdentity() {
		let trie = Trie()
		trie.insert("got", freq: 10)
		let high = trie.search("go", maxCost: 1,
			prior: TrieSearchPrior(scoredWords: [("got", -0.1)]))
		let low = trie.search("go", maxCost: 1,
			prior: TrieSearchPrior(scoredWords: [("got", -100)]))
		#expect(high.contains { $0.word == "got" })
		#expect(low.isEmpty)
		let singleton = TrieSearchPrior(scoredWords: [("got", -6)])
		let shortlist = TrieSearchPrior(scoredWords: [("got", -6), ("xyz", -9)])
		#expect(singleton.rootChild(UInt8(ascii: "g"))?.bonus
			== shortlist.rootChild(UInt8(ascii: "g"))?.bonus)
		let shifted = TrieSearchPrior(scoredWords: [("got", -9)])
		#expect((shifted.rootChild(UInt8(ascii: "g"))?.bonus ?? 0)
			< (singleton.rootChild(UInt8(ascii: "g"))?.bonus ?? 0))
		trie.insert("car", freq: 10)
		trie.insert("cart", freq: 10)
		let funded = trie.search("ca", maxCost: 1,
			prior: TrieSearchPrior(likelyWords: ["cart"]))
		#expect(!funded.contains { $0.word == "car" })
	}

	@Test func broadRecoveryUsesFullRadiusDespiteRetainedNormalSearch() async throws {
		let data = try #require(LangData(url: langdataURL()))
		let seeds = try #require(data.incrementalSeeds(typedFirst: UInt8(ascii: "q"), firstTap: nil))
		let retained = IncrementalDecodeSession(seeds: seeds)
		#expect(retained.advance(to: "qorrection"))
		#expect(!retained.candidates(maxCost: 7.2).contains { $0.word == "correction" })
		#expect(data.trieSearch("qorrection", maxCost: 7.2).contains { $0.word == "correction" })
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		let result = await decode(engine, word: "qorrection", context: [])
		#expect(result.candidates.contains { $0.word == "correction" && $0.source == .broadRecovery })
	}

	@Test func readySearchPriorGeneratesAndScoresWithoutTransformer() async throws {
		// Six input characters have a 2.8 narrow / 5.6 broad budget.
		// Four missing q characters cost 6.4; retain the final w to avoid
		// putting the path exactly on the maximum-funded radius.
		let target = "qqqqqqqqqw"
		let prior = TestSearchPrior(words: [SearchPriorWord(word: target, logProbability: -0.1)])
		let engine = KeyboardEngine(languageDataURL: langdataURL(), searchPrior: prior)
		engine.importSupplementaryLexicon([target])
		#expect(engine.preferredModelTier(for: .english) == .neuralGRU)
		#expect(engine.preferredModelTier(for: .telugu) == .ngram)
		let snapshot = await decode(engine, word: "qqqqqw", context: ["fixture"], tier: .neuralGRU)
		let candidate = try #require(snapshot.candidates.first { $0.word == target })
		#expect(candidate.neuralLogProbability == -0.1)
		#expect(candidate.spatialCost > 5.6 && candidate.spatialCost <= 7.2)
		#expect(snapshot.modelTier == .neuralGRU)
		#expect(snapshot.correction == target)
		#expect(snapshot.suggestions.first == target)
		for available in [false, true] {
			let empty = TestSearchPrior(words: [], ready: available)
			let fallback = KeyboardEngine(languageDataURL: langdataURL(), searchPrior: empty)
			fallback.importSupplementaryLexicon([target])
			let result = await decode(fallback, word: "qqqqqw", context: ["fixture"])
			#expect(!result.candidates.contains { $0.word == target })
		}
	}

	@Test func searchCacheIdentityIncludesConstraintsSeedsAndVocabularyEpoch() {
		let base = SearchPriorQuery(context: ["On", "MY"],
			prefix: SearchPrefix(text: "wa", firstLetters: ["w"]), pool: ["way", "way"])
		#expect(base == SearchPriorQuery(context: ["on", "my"],
			prefix: SearchPrefix(text: "wa", firstLetters: ["w"]), pool: ["way"]))
		#expect(base != SearchPriorQuery(context: base.context,
			prefix: SearchPrefix(text: "wa", firstLetters: ["e"]), pool: ["way"]))
		#expect(base != SearchPriorQuery(context: base.context, prefix: base.prefix, pool: ["work"]))
		#expect(base != SearchPriorQuery(context: base.context, prefix: base.prefix,
			pool: base.pool, vocabularyRevision: 1))
	}

	@Test func beamFiltersLegalTokensBeforeTakingTopK() {
		let values = (0..<12).map { -Float($0) }
		#expect(GRULanguagePrior.topIndices(values, count: 8, allowed: { $0 >= 9 }) == [9, 10, 11])
	}

	@Test func contractionCorrectionsPreserveTypedForms() async {
		let engine = KeyboardEngine(languageDataURL: langdataURL())
		// Typo + missing apostrophe: exact restoration fails, but the typed trailing 's'
		// means "that's", not the bare base "that" that would drop it.
		let thads = await decode(engine, word: "thads", context: [])
		#expect(thads.correction == "that's",
			"thads: correction=\(thads.correction ?? "nil") sugg=\(thads.suggestions)")
		// "id" is a kept dictionary word; it must restore to "I'd" at a sentence start
		// and must never be "corrected" to the generic neighbour "is".
		let idStart = await decode(engine, word: "id", context: [])
		#expect(idStart.correction == "i'd",
			"id at start: correction=\(idStart.correction ?? "nil")")
		let idNoun = await decode(engine, word: "id", context: ["send", "your"])
		#expect(idNoun.correction != "is",
			"id after determiner must not become is: correction=\(idNoun.correction ?? "nil")")
		// Overwhelming context wins: after "this", the LM must correct "id" to "is".
		let idContext = await decode(engine, word: "id", context: ["this"])
		#expect(idContext.correction == "is",
			"id after 'this' should be context-corrected to is: correction=\(idContext.correction ?? "nil")")
	}

	private func decode(_ engine: KeyboardEngine, word: String,
						context: [String], language: KBLanguageMode = .english,
						tier: DecodeModelTier = .ngram)
		async -> DecodeSnapshot {
		let request = DecodeRequest(fieldRevision: 1, documentRevision: 1,
			wordSessionID: 1, generation: 1, layoutRevision: 1,
			currentWord: word, context: context, taps: nil, languageMode: language, requestedModelTier: tier)
		return await withCheckedContinuation { continuation in
			engine.decode(request) { continuation.resume(returning: $0) }
		}
	}

	// MARK: Visual render checks — write PNGs of the emoji UI for eyeballing.
	// Tests inject the repository store and atlas so they do not depend on a test-host
	// bundle or App Group. PNGs land in keyboardTests/renders/, which is disposable.

	@MainActor @Test func emojiAtlasRoundTripAndRender() throws {
		let store = try #require(EmojiStore(url: emojiBinaryURL()))
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("emoji-atlas-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let url = try #require(EmojiAtlas.generateIfNeeded(store: store, scale: 2, in: directory))
		let bytes = try #require((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize)
		#expect(bytes > 0 && bytes % (72 * 72 * 4) == 0)
		#expect(EmojiAtlas.generateIfNeeded(store: store, scale: 2, in: directory) == url)

		let atlas = try #require(EmojiAtlas.load(store: store, scale: 2, in: directory))
		#expect(atlas.image(for: store.emoji(0, 0)) != nil)
		#expect(atlas.image(for: "not an emoji") == nil)
		#expect(EmojiAtlas.load(store: store, scale: 1, in: directory) == nil)

		let palette = EmojiKeyboardView(theme: .system(dark: false), showsGlobe: true,
			store: store, atlas: atlas)
		palette.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
		palette.backgroundColor = UIColor(hex: 0xE8E6EC)
		palette.layoutIfNeeded()
		try writePNG(of: palette, name: "emoji_palette_atlas")
	}

	/// The re-added clipboard panel builds and lays out its Pinned/Recent sections,
	/// per-row delete accessories, and bottom bar with injected items (no App Group or
	/// Full Access needed). Renders both appearances for eyeballing.
	@MainActor @Test func renderClipboardPanel() throws {
		let items = [
			KBClipboardItem(text: "meeting at 3pm tomorrow", pinned: true, date: Date()),
			KBClipboardItem(text: "https://example.com/very/long/link/that/wraps", pinned: false, date: Date()),
			KBClipboardItem(text: "call the dentist", pinned: false, date: Date()),
		]
		for dark in [false, true] {
			let theme = KeyboardTheme.system(dark: dark)
			let panel = ClipboardPanelView(theme: theme, showsGlobe: true,
				hasFullAccess: true, items: items)
			panel.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
			panel.backgroundColor = dark ? UIColor(hex: 0x2A2A2E) : UIColor(hex: 0xE8E6EC)
			panel.layoutIfNeeded()
			try writePNG(of: panel, name: dark ? "clipboard_panel_dark" : "clipboard_panel_light")
		}
		// Empty + no-access state renders its guidance instead of rows.
		let empty = ClipboardPanelView(theme: .system(dark: false), showsGlobe: true,
			hasFullAccess: false, items: [])
		empty.frame = CGRect(x: 0, y: 0, width: 390, height: 259)
		empty.backgroundColor = UIColor(hex: 0xE8E6EC)
		empty.layoutIfNeeded()
		try writePNG(of: empty, name: "clipboard_panel_empty")
	}

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

private final class TestNeuralPrior: NeuralLanguagePrior {
	let modelTier: DecodeModelTier
	let isReady = true
	private let lock = NSLock()
	private var prepared: [UInt64] = []
	private var scored: [UInt64] = []

	init(tier: DecodeModelTier) { modelTier = tier }

	var preparedSessions: [UInt64] {
		lock.lock(); defer { lock.unlock() }
		return prepared
	}

	var scoredSessions: [UInt64] {
		lock.lock(); defer { lock.unlock() }
		return scored
	}

	func prepareContext(_ words: [String], wordSessionID: UInt64) {
		lock.lock(); prepared.append(wordSessionID); lock.unlock()
	}

	func score(candidates: [String], wordSessionID: UInt64,
		completion: @escaping (Result<[String: Double], Error>) -> Void) {
		lock.lock(); scored.append(wordSessionID); lock.unlock()
		completion(.success(Dictionary(uniqueKeysWithValues: candidates.enumerated().map {
			($0.element, $0.element == "might" ? 0 : -Double($0.offset + 1))
		})))
	}

	func discardSession(_ wordSessionID: UInt64) {}
}

private final class TestSearchPrior: NeuralSearchPrior {
    let modelTier: DecodeModelTier = .neuralGRU
    let isReady: Bool
    let words: [SearchPriorWord]
    var onSearchPriorReady: ((SearchPriorQuery) -> Void)?
    init(words: [SearchPriorWord], ready: Bool = true) { self.words = words; isReady = ready }
    func warmSearchPrior(_ query: SearchPriorQuery, isKnownWord: @escaping (String) -> Bool) {}
    func searchPriorWords(_ query: SearchPriorQuery) -> [SearchPriorWord]? { isReady ? words : nil }
    func prepareContext(_ words: [String], wordSessionID: UInt64) {}
    func discardSession(_ wordSessionID: UInt64) {}
    func score(candidates: [String], wordSessionID: UInt64,
        completion: @escaping (Result<[String: Double], Error>) -> Void) {
        let expected = Dictionary(uniqueKeysWithValues: words.map { ($0.word, $0.logProbability) })
        completion(.success(Dictionary(uniqueKeysWithValues: candidates.map { ($0, expected[$0] ?? -25) })))
    }
}
