import Foundation

enum DecodeModelTier: String, Codable, Equatable {
	case ngram
	case neuralW8
	case neuralW8A8
	case neuralGRU
}

/// Immutable identity for one decoder request. A result may be presented or committed
/// only while every revision still matches the controller's current document state.
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

struct DecodeCandidateEvidence: Equatable {
	let word: String
	let score: Double
	let spatialCost: Double
	let logFrequency: Double
	let logLanguageProbability: Double
	let neuralLogProbability: Double?
	let source: DecodeCandidateSource
	let typedWordMargin: Double

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
protocol NeuralLanguagePrior: AnyObject {
	var modelTier: DecodeModelTier { get }
	/// Readiness is sampled only between words. Once selected, a model tier is frozen
	/// for the complete word session and must not silently fall back mid-word.
	var isReady: Bool { get }
	func prepareContext(_ words: [String], wordSessionID: UInt64)
	func score(candidates: [String], wordSessionID: UInt64,
		 completion: @escaping (Result<[String: Double], Error>) -> Void)
	func discardSession(_ wordSessionID: UInt64)
	func prepareForSelection()
	func handleMemoryPressure()
}

/// One likely next-word with the LM's log-probability. The probability is what funds a word's
/// bonus in `TrieSearchPrior` (a peaked distribution funds its top word near the cap, a flat one
/// funds broadly and shallowly), so the search widens exactly as much as the LM is confident —
/// see `TrieSearchPrior(scoredWords:)`.
struct SearchPriorWord: Equatable {
	let word: String
	let logProbability: Double
}

/// A typed-prefix constraint for prefix-AWARE next-word generation. Once the user has typed a
/// few characters, the search prior can be re-warmed with the beam's start-pieces restricted to
/// those spatially compatible with the first taps — turning "context-plausible words" into
/// "context-AND-prefix-plausible words", which is exactly the recovery case Layer 2 exists for.
/// `firstLetters` is the set of first characters the first tap could plausibly be (the engine
/// owns the spatial model, so the generator stays keyboard-geometry-agnostic); `text` is the raw
/// typed prefix, used only as the cache key. nil ⇒ context-only warm (today's behavior).
struct SearchPrefix: Equatable, Hashable {
	let text: String
	let firstLetters: Set<Character>
}

/// Source of the in-trie search prior's likely-next-words (the words that fund extra edit
/// budget along their prefixes inside the trie walk — see `TrieSearchPrior`). The GRU
/// implements this so `contextSearchPrior` can be conditioned on the neural LM instead of
/// the n-gram. Both calls are cheap and synchronous on the decoder queue:
///   • `warmSearchPrior` kicks off (at most one in-flight per key) an ASYNC pass that
///     ranks the candidate pool for the context and caches it — it never blocks decode.
///   • `searchPriorWords` reads that cache, returning nil until the async pass lands, so
///     the caller transparently falls back to the n-gram pool while the GRU warms up.
/// `warmSearchPrior` GENERATES the GRU's own likely next-words (a subword beam) and unions them
/// with the supplied n-gram pool before ranking, so `searchPriorWords` returns context-plausible
/// words the n-gram never proposed — breaking the pool's recall ceiling, not merely re-ordering
/// it. Each returned word carries its LM log-probability so the trie bonus is probability-derived,
/// not rank-decayed. The `pool` argument remains the n-gram fallback/seed set; `prefix`, when
/// non-nil, constrains generation to the typed prefix (keyed separately in the cache).
protocol SearchPriorProvider: AnyObject {
	func warmSearchPrior(context: [String], prefix: SearchPrefix?, pool: [String])
	func searchPriorWords(context: [String], prefix: SearchPrefix?) -> [SearchPriorWord]?
}

/// The RECALL neural role: a streaming generator that widens in-trie candidate generation
/// (`contextSearchPrior`). Distinct from `NeuralLanguagePrior` (the PRECISION role — batched
/// P(word|context) rescoring on a fixed pool). Splitting the two means choosing a search prior
/// no longer silently evicts a rescorer, and vice versa — each slot is filled independently
/// (production fills neither). The GRU, whose cheap incremental streaming steps are structurally
/// ideal for generation, fills this slot; the transformer fills the rescorer slot.
protocol NeuralSearchPrior: SearchPriorProvider {
	var isReady: Bool { get }
	func prepareForSelection()
	func handleMemoryPressure()
}

extension NeuralLanguagePrior {
	func prepareForSelection() {}
	func handleMemoryPressure() {}
}

/// One authoritative answer for a request. `suggestions.first` is always the center
/// suggestion. If `correction` is non-nil it is also `suggestions.first`, so a boundary
/// can never commit a word different from the primary word the user just saw.
struct DecodeSnapshot: Equatable {
	let request: DecodeRequest
	let suggestions: [String]
	let candidates: [DecodeCandidateEvidence]
	let correction: String?
	let confidence: Double
	let nextCharacterPriors: [Character: Double]
	let modelTier: DecodeModelTier
	let completedAtUptime: TimeInterval

	func isValid(for current: DecodeRequest) -> Bool {
		request == current
	}
}

struct PresentedSuggestion: Equatable {
	let canonicalText: String
	let text: String
	let isExactTypedCandidate: Bool
}

/// UI-facing projection of one canonical decoder result. Taps and boundary correction
/// consume this same object, so case styling can never make the visible primary differ
/// from the text committed to the host.
struct PresentedDecodeSnapshot: Equatable {
	let canonical: DecodeSnapshot
	let suggestions: [PresentedSuggestion]
	let correction: String?

	var primaryText: String? { suggestions.first?.text }

	func isValid(for request: DecodeRequest) -> Bool {
		canonical.isValid(for: request)
	}
}

enum SuggestionCasePolicy {
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

	private static func intrinsicEnglishCase(_ value: String) -> String {
		let lower = value.lowercased()
		guard isIForm(lower) else { return value }
		return "I" + lower.dropFirst()
	}

	private static func isIForm(_ value: String) -> Bool {
		let lower = value.lowercased()
		return lower == "i" || lower == "i'm" || lower == "i'll"
			|| lower == "i've" || lower == "i'd"
	}

	private static func initialCapital(_ value: String) -> String {
		guard let first = value.first else { return value }
		return first.uppercased() + value.dropFirst()
	}
}
