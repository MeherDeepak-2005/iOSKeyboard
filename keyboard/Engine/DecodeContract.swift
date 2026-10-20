// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import Foundation

// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
enum DecodeModelTier: String, Codable, Equatable {
	case ngram
	case neuralW8
	case neuralW8A8
	case neuralGRU
}

/// Immutable identity for one decoder request. A result may be presented or committed
/// only while every revision still matches the controller's current document state.
// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
// MIGRATION-NOTE: Planned portable DecodeInput mirrors every revision/session ID, UTF-8 word/context, optional Double taps, language/model tier and vocabulary/personalization epochs; controller APIs retain Swift records.
struct DecodeRequest: Equatable {
	let fieldRevision: UInt64
	let documentRevision: UInt64
	let wordSessionID: UInt64
	let generation: UInt64
	let layoutRevision: UInt64
	let currentWord: String
	let context: [String]
	let taps: [KeyTap?]?
	let languageMode: KBLanguageMode
	/// Chosen only at a word boundary and frozen in this request's word session.
	let requestedModelTier: DecodeModelTier

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	init(fieldRevision: UInt64, documentRevision: UInt64, wordSessionID: UInt64,
		 generation: UInt64, layoutRevision: UInt64, currentWord: String,
		 context: [String], taps: [KeyTap?]?, languageMode: KBLanguageMode = .english,
		 requestedModelTier: DecodeModelTier = .ngram) {
		self.fieldRevision = fieldRevision
		self.documentRevision = documentRevision
		self.wordSessionID = wordSessionID
		self.generation = generation
		self.layoutRevision = layoutRevision
		self.currentWord = currentWord
		self.context = context
		self.taps = taps
		self.languageMode = languageMode
		self.requestedModelTier = requestedModelTier
	}
}

// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
enum DecodeCandidateSource: String, Codable, Equatable {
	case typed
	case fuzzyLexicon
	case completion
	case contextInjection
	case broadRecovery
	case splitCorrection
	case transliterationLexicon
	case transliterationComposition
}

// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
// MIGRATION-NOTE: Planned portable RankedEvidence mirrors every score, channel cost, source and margin; bridge results own strings/buffers and Swift retains casing/publication.
struct DecodeCandidateEvidence: Equatable {
	let word: String
	let score: Double
	let spatialCost: Double
	let logFrequency: Double
	let logLanguageProbability: Double
	let neuralLogProbability: Double?
	let source: DecodeCandidateSource
	let typedWordMargin: Double

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	init(word: String, score: Double, spatialCost: Double, logFrequency: Double,
		 logLanguageProbability: Double, neuralLogProbability: Double? = nil,
		 source: DecodeCandidateSource = .fuzzyLexicon, typedWordMargin: Double = 0) {
		self.word = word
		self.score = score
		self.spatialCost = spatialCost
		self.logFrequency = logFrequency
		self.logLanguageProbability = logLanguageProbability
		self.neuralLogProbability = neuralLogProbability
		self.source = source
		self.typedWordMargin = typedWordMargin
	}
}

/// Runtime seam for an iOS 18 stateful model. Implementations must score only the
/// supplied bounded continuation set, never perform full neural beam search on the
/// host-insertion path, and must return on their own queue.
// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
protocol NeuralLanguagePrior: AnyObject {
	var modelTier: DecodeModelTier { get }
	/// Readiness is sampled only between words. Once selected, a model tier is frozen
	/// for the complete word session and must not silently fall back mid-word.
	var isReady: Bool { get }
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func prepareContext(_ words: [String], wordSessionID: UInt64)
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func score(candidates: [String], wordSessionID: UInt64,
		 completion: @escaping (Result<[String: Double], Error>) -> Void)
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func discardSession(_ wordSessionID: UInt64)
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func prepareForSelection()
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func handleMemoryPressure()
}

/// An exact complete-word log probability, including the word-ending event.
// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
struct SearchPriorWord: Equatable {
	let word: String
	let logProbability: Double
}

/// A first-letter spatial constraint. The remaining text identifies the typed word;
/// it does not imply that subword generation is constrained to an exact prefix.
// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
struct SearchPrefix: Equatable, Hashable {
	let text: String
	let firstLetters: Set<Character>
}

/// Every value affecting generation participates in cache identity. Vocabulary
/// revision changes when personal/supplementary words are added or reset.
// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
struct SearchPriorQuery: Equatable, Hashable {
	let context: [String]
	let prefix: SearchPrefix?
	let pool: [String]
	let vocabularyRevision: UInt64

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	init(context: [String], prefix: SearchPrefix?, pool: [String], vocabularyRevision: UInt64 = 0) {
		self.context = context.suffix(8).map { $0.lowercased() }
		self.prefix = prefix.map { SearchPrefix(text: $0.text.lowercased(), firstLetters: $0.firstLetters) }
		self.pool = Array(Set(pool.map { $0.lowercased() })).sorted()
		self.vocabularyRevision = vocabularyRevision
	}

	var withoutPrefix: SearchPriorQuery {
		SearchPriorQuery(context: context, prefix: nil, pool: pool, vocabularyRevision: vocabularyRevision)
	}
}

// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
protocol SearchPriorProvider: AnyObject {
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func warmSearchPrior(_ query: SearchPriorQuery, isKnownWord: @escaping (String) -> Bool)
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func searchPriorWords(_ query: SearchPriorQuery) -> [SearchPriorWord]?
}

/// One model supplies both generation and exact candidate scoring. A separate
/// transformer rescorer remains optional; the GRU must work without it.
// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
protocol NeuralSearchPrior: SearchPriorProvider, NeuralLanguagePrior {
	var onSearchPriorReady: ((SearchPriorQuery) -> Void)? { get set }
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func cancelPendingSearch()
}

extension NeuralSearchPrior {
	var onSearchPriorReady: ((SearchPriorQuery) -> Void)? { get { nil } set {} }
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func cancelPendingSearch() {}
}

extension NeuralLanguagePrior {
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func prepareForSelection() {}
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func handleMemoryPressure() {}
}

/// One authoritative answer for a request. `suggestions.first` is always the center
/// suggestion. If `correction` is non-nil it is also `suggestions.first`, so a boundary
/// can never commit a word different from the primary word the user just saw.
// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
struct DecodeSnapshot: Equatable {
	let request: DecodeRequest
	let suggestions: [String]
	let candidates: [DecodeCandidateEvidence]
	let correction: String?
	let confidence: Double
	let nextCharacterPriors: [Character: Double]
	let modelTier: DecodeModelTier
	let completedAtUptime: TimeInterval

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func isValid(for current: DecodeRequest) -> Bool {
		request == current
	}
}

// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
struct PresentedSuggestion: Equatable {
	let canonicalText: String
	let text: String
	let isExactTypedCandidate: Bool
}

/// UI-facing projection of one canonical decoder result. Taps and boundary correction
/// consume this same object, so case styling can never make the visible primary differ
/// from the text committed to the host.
// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
struct PresentedDecodeSnapshot: Equatable {
	let canonical: DecodeSnapshot
	let suggestions: [PresentedSuggestion]
	let correction: String?

	var primaryText: String? { suggestions.first?.text }

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func isValid(for request: DecodeRequest) -> Bool {
		canonical.isValid(for: request)
	}
}

// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
enum SuggestionCasePolicy {
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	static func present(_ snapshot: DecodeSnapshot, sentenceStart: Bool)
		-> PresentedDecodeSnapshot {
		let typed = snapshot.request.currentWord
		let suggestions = snapshot.suggestions.map { candidate in
			let exact = !typed.isEmpty
				&& candidate.caseInsensitiveCompare(typed) == .orderedSame
			return PresentedSuggestion(canonicalText: candidate,
				text: display(candidate, typedWord: typed, sentenceStart: sentenceStart,
					languageMode: snapshot.request.languageMode),
				isExactTypedCandidate: exact)
		}
		let correction = snapshot.correction.map { canonical -> String in
			if let displayed = suggestions.first(where: {
				$0.canonicalText.caseInsensitiveCompare(canonical) == .orderedSame
			})?.text {
				return displayed
			}
			return display(canonical, typedWord: typed, sentenceStart: sentenceStart,
				languageMode: snapshot.request.languageMode)
		}
		return PresentedDecodeSnapshot(canonical: snapshot, suggestions: suggestions,
			correction: correction)
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	static func display(_ candidate: String, typedWord: String? = nil,
		sentenceStart: Bool, languageMode: KBLanguageMode = .english) -> String {
		guard languageMode == .english else { return candidate }
		let intrinsic = intrinsicEnglishCase(candidate)
		guard let typedWord, !typedWord.isEmpty else {
			return sentenceStart ? initialCapital(intrinsic) : intrinsic
		}
		if candidate.caseInsensitiveCompare(typedWord) == .orderedSame {
			// Exact input remains exact except English's standalone pronoun forms.
			return isIForm(candidate) ? intrinsic : typedWord
		}
		let letters = typedWord.filter(\.isLetter)
		if letters.count > 1, letters.allSatisfy(\.isUppercase) {
			return intrinsic.uppercased()
		}
		if let first = letters.first, first.isUppercase,
			letters.dropFirst().allSatisfy(\.isLowercase) {
			return initialCapital(intrinsic)
		}
		if letters.allSatisfy(\.isLowercase) { return intrinsic }
		return intrinsic
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private static func intrinsicEnglishCase(_ value: String) -> String {
		let lower = value.lowercased()
		guard isIForm(lower) else { return value }
		return "I" + lower.dropFirst()
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private static func isIForm(_ value: String) -> Bool {
		let lower = value.lowercased()
		return lower == "i" || lower == "i'm" || lower == "i'll"
			|| lower == "i've" || lower == "i'd"
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private static func initialCapital(_ value: String) -> String {
		guard let first = value.first else { return value }
		return first.uppercased() + value.dropFirst()
	}
}
