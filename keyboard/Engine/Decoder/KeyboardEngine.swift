// IMPLEMENTED: C++ owns ASCII English tap candidate generation and mutable trie search.
// Swift retains ranking/correction policy, Unicode fallback, Glide/neural algorithms,
// queues, identity and publication. See docs/decoder-platform/CPP_CANDIDATE_GENERATION.md.
// Noisy-channel engine with one versioned, asynchronously published decode contract.
//
// Pipeline:   Lexicon (trie = channel model) generates an N-best candidate list
//           → the memory-mapped n-gram model supplies one batched context prior
//           → UserModel layers on-device personalization on top.
//
// Autocorrect decisions are precomputed by background decoding while the word is
// being typed. A boundary consumes only a matching immutable snapshot; if none is
// ready, the typed word is preserved. Trie/model work never runs on the input path.
//
// Data ships as ONE binary, `langdata.bin` (built by tools/build_language_data.py),
// which is MEMORY-MAPPED at launch: the bi/tri-gram tables AND (format v3) the
// dictionary trie itself are read in place and never materialize as Swift heap
// structures. File-backed read-only pages are clean memory — the OS can evict them
// at will, so they barely count against the extension's ~60–70 MB kill limit (heap
// counts in full). Only a small dynamic trie (adopted + contact words) stays on the
// heap; a v2 file falls back to loading the full vocab into that trie as before.

final class KeyboardEngine {

	/// SERIAL, deliberately. One background pass at a time: a superseded suggestion pass
	/// bails at entry in microseconds (gen ticket), so work coalesces instead of piling up —
	/// with a concurrent queue every fast keystroke's pass ran its full trie DP
	/// simultaneously, wasting CPU inside the jetsam-limited extension.
	/// Nothing on the keystroke path waits on this queue; boundary commits consume an
	/// already-published DecodeSnapshot or leave the typed word unchanged.
	let queue = DispatchQueue(label: "keyboard.engine")
	/// Glide must not wait behind a suggestion pass. Final decodes and
	/// live previews use separate queues; the final queue has interactive priority and
	/// stale preview work cooperatively exits when the finger lifts.
	let glideQueue = DispatchQueue(label: "keyboard.engine.glide", qos: .userInteractive)
	let glidePreviewQueue = DispatchQueue(label: "keyboard.engine.glide.preview", qos: .userInitiated)
	let initializationGroup = DispatchGroup()
	let glidePreviewLock = NSLock()
	var glidePreviewGeneration = 0
	let glidePreviewCacheLock = NSLock()
	struct GlidePreviewCache {
		let key: UInt64
		let createdAt: TimeInterval
		let prediction: GlidePrediction
	}
	var glidePreviewCache: GlidePreviewCache?
	let lexicon = Lexicon()
	let user: UserModel
    let correctionPolicy: CorrectionPolicy
    let correctionObserver: ((CorrectionGateEvidence) -> Void)?
	/// Eager and immutable. Every decode in a word session uses this same model tier;
	/// memory pressure cannot silently change ranking semantics mid-word.
	let ngram: NgramScorer
    var sharedEngine: KBSharedEngine?
    var sharedDecodeToken: KBCancellationToken?
    let candidateBackend: DecoderCoreBackend
	/// The neural search space: one optional, promotion-gated streaming model (the production
	/// singleton supplies none until a checkpoint passes blind quality + device gates). It widens
	/// in-trie generation (`contextSearchPrior`) and supplies the exact complete-word scores the
	/// resulting hypotheses are ranked by (`rank`). There is no separate rescoring model.
	let searchPrior: NeuralSearchPrior?
	static let searchPriorReadyNotification = Notification.Name("KBSearchPriorReady")
	var latestSearchRequest: (request: DecodeRequest, generation: Int)?
	/// Accessed only on `queue`; one prepared neural scoring context is retained for the active word.
	var preparedNeuralSession: (id: UInt64, context: [String])?
	/// Static fuzzy-search DP columns retained for one append-only English word.
	/// Cursor edits rebuild this state; ordinary taps advance one column.
	var incrementalDecodeSession:
		(id: UInt64, layoutRevision: UInt64, radius: Double, session: IncrementalDecodeSession)?
	/// Swift initializes each static singleton once on first access. Computed accessors
	/// keep English sessions from mapping multilingual packs they never query.
	var transliterator: TenglishTransliterator { TenglishTransliterator.shared }
	var teluguLexicon: TeluguLexicon { TeluguLexicon.shared }
	let touchProfile = TouchSpatialProfile()

	// Tunables.
	/// Dynamic edit-distance budget by typed length. Short words get ~1 edit (tight —
	/// a 2-3 letter string is one slip from dozens of words, so a loose budget just adds
	/// noise); normal words ~2; long words ~3, since a longer word accumulates more
	/// independent slips before you notice. These are the weighted spatial model's costs,
	/// so they're budgets, not integer edit counts (1 substitution ≈ 0.6-1.2, 1 omission = 1.1).
	/// Broad recovery and context injection search this many times the normal radius
	/// (native `broadRecoveryFactor`, `longBroadRecoveryFactor` from 8 letters).
	static let broadRecoveryFactor = 1.6, longBroadRecoveryFactor = 1.9
	func maxCost(for length: Int) -> Double {
		switch length {
		case ...4:  return 1.6      // ≈ 1 edit: one omission (1.1) and a little slack (native shortSearchRadius)
		case 5...7: return 2.8      // ≈ 2 edits (the previous fixed value)
		default:    return 3.6      // ≈ 3 edits
		}
	}
	/// Channel-cost weight in ranking and the non-word correction gate; native `channelWeight`
	/// (fitted on tools/evaluation/autocorrect, 28 Oct 2026). Spelling distance, not word
	/// frequency, decides between candidates (recident → resident, not president).
	let channelWeight = 4.0
	/// The real-word gate (a typed dictionary word) keeps the earlier calibration; native `realWordChannelWeight`.
	let realWordChannelWeight = 1.0
	/// ... and so does a non-word whose best candidate came only from recovery; native `recoveryChannelWeight`.
	let recoveryChannelWeight = 1.0
	/// A correction to two words must still clear the earlier non-word margin; native `splitCorrectionMargin`.
	let splitCorrectionMargin = 3.0
	let lmWeight = 1.0
	/// Equals native `frequencyWeight` (fitted on tools/evaluation/autocorrect, 27 Oct 2026).
	let freqWeight = 0.1
	/// Orders rows for the pre-LM shortlist and the completion cap; native `shortlistFrequencyWeight`.
	let shortlistFreqWeight = 0.3
	/// Interpolation between the neural search model's log-prob and the n-gram's when the model is
	/// active: `neuralPriorWeight·neural + (1−neuralPriorWeight)·ngram`. Hand-set; the eventual
	/// source of truth is the softmax-ranker trainer (`tools/lm/train_ranker.py`) with its
	/// promotion gates, once it has real on-device labels — same as `lmWeight`/`freqWeight`.
	let neuralPriorWeight = 0.7
	/// Completion suggestions consider more prefix matches than the UI shows, then
	/// rerank them by context. Frequency is compressed for suggestions only so high-count
	/// function words do not drown out more specific completions.
	let completionCandidateLimit = 24
	/// When no completion exists, the bar may show correction candidates, but only
	/// cheap near-misses. This keeps partial prefixes like "con" from showing deletion
	/// corrections like "on"; space-key autocorrect still uses the wider budget.
	let suggestionCorrectionMaxCost = 1.25
	/// Commits before a non-dictionary word enters the trie (and so becomes
	/// suggestable + immune to autocorrect). 5, not 3: a word you were only testing
	/// or typo'd repeatedly shouldn't graduate into the dictionary.
	let adoptAfter = 8
	/// Keep a wide oracle funnel. The mmap n-gram scorer scans each context once for
	/// the requested IDs, so 32 rows cost little and avoid the old rank-16 ceiling.
	let nBest = 24
	let scoreCap = 32
	/// Autocorrect confidence gate: the best candidate must beat the TYPED string's
	/// blended score by this margin (natural-log units; 3 ≈ 20× more likely) before
	/// a correction fires. Genuine typos clear it by 8–15; slang/names that fit the
	/// context sit near 0 and survive uncorrected. CorrectionPolicy additionally permits
    /// calibrated close rescues with a positive typed margin and a clear runner-up gap.
	/// Broad recovery is reached only for long OOV input after the normal-radius trie
	/// fails. A ten-to-one posterior win over the literal plus a two-to-one win over
	/// an unrelated runner-up is sufficient there; requiring the normal typo margin
	/// discarded useful severe recoveries even after singleton context injection was
	/// removed.
	let severeRecoveryMargin = CorrectionPolicy.severeMargin
	/// Real-word correction (the "hoe → how", "js → is" case): a word that IS in the
	/// dictionary is only replaced when a near-neighbour real word dominates it in
	/// context by this much — far stricter than `correctionMargin`, because wrongly
	/// "correcting" a word the user meant is worse than missing one. Works on the
	/// n-gram alone (a real typed word has a genuine n-gram score, not the OOV floor).
	/// 5.0 is calibrated from the harness: legit real words in-context top out ~2.4,
	/// while genuine slips (js→is 7.0, hoe→how 5.3, od→of 9.4) clear it — a safe gap.
	/// …and the winning neighbour must be within this channel cost of the typed word
	/// (≈ one edit), so only genuine slips — not distant words — can win.
	let realWordMaxCost = 1.6
	/// Channel-dominance guard for the LOOSE candidate pools (context injection and
	/// broad recovery). Those pools exist to rescue heavily corrupted input; when the
	/// close search already found a plausible slip (cost ≤ realWordMaxCost), a loose
	/// candidate may only compete if its own cost is within this window of that best
	/// close cost (≈ one extra edit). Without it a strong bigram drags the decision to
	/// a spatially implausible word: live battery 2026-07-20 committed "you see" for
	/// "sebd" (send 0.8), "running for" for "coudl" (could 0.8) and "definitely
	/// decided" for "recieve" (receive 0.8).
	let looseCandidateWindow = 1.6
	/// A loose-pool winner must additionally beat the best UNRELATED contender by
	/// this much before the boundary commits it. Heavy rewrites where the LM cannot
	/// separate the top candidates stay in the strip instead of auto-committing a
	/// coin flip. Calibrated from evidence dumps (2026-07-20): the legit severe
	/// rescue coeevitjkn→correction leads coercion by 1.26 nats in every context,
	/// while the junk pool physician/communion/corrections (over-confident 1-count
	/// "receive …" bigrams) is separated by only 0.22.
	// CorrectionPolicy.looseGap owns this threshold for both replay and commit.
	struct RankedCandidate {
		let word: String
		let score: Double
		let spatialCost: Double
		let logFrequency: Double
		let logLanguageProbability: Double
		let neuralLogProbability: Double?
        var native: KBScoredRow {
            KBScoredRow.make(word: word, cost: spatialCost, frequency: logFrequency,
                language: logLanguageProbability, neural: neuralLogProbability.map { NSNumber(value: $0) }, score: score)
        }
        init(native: KBScoredRow) {
            word = native.word; spatialCost = native.cost; logFrequency = native.logFrequency
            logLanguageProbability = native.language; neuralLogProbability = native.neural?.doubleValue; score = native.score
        }
        init(word: String, score: Double, spatialCost: Double, logFrequency: Double,
             logLanguageProbability: Double, neuralLogProbability: Double?) {
            self.word = word; self.score = score; self.spatialCost = spatialCost; self.logFrequency = logFrequency
            self.logLanguageProbability = logLanguageProbability; self.neuralLogProbability = neuralLogProbability
        }
	}

	/// Session-only autocorrect rejections. Every access is serialized on `queue`;
	/// the controller never reads this set on the input path.
	// Session keep/undo state lives in native Personalization.
	func isKept(_ word: String) -> Bool { user.isKept(word) }

	/// Learning fires on every committed word, and `user.save()` re-encodes the WHOLE
	/// personal model to JSON — O(model) work and a matching transient allocation on
	/// the engine barrier, per word typed. Coalesce to one save per 2 s typing burst.
	/// Rare, signal-bearing events (kept words, undo healing) still save immediately;
	/// losing ≤2 s of ordinary counts to a jetsam kill is an acceptable trade.
	private var savePending = false
	func scheduleSave() {
		guard !savePending else { return }
		savePending = true
		queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
			guard let self else { return }
			self.savePending = false
			self.user.save()
		}
	}

	/// Process-wide engine: iOS may prewarm more than one controller, while language
	/// data and personalization should be loaded exactly once per extension process.
	///
	/// English decodes with the bundled word-level neural search space (tools/nss); a build
	/// without the model (NSS_ENABLED=NO) keeps the n-gram decoder. Internal GRU builds
	/// (`INTERNAL_GRU`) install the GRU search space instead.
	static let shared: KeyboardEngine = {
		#if INTERNAL_GRU
		return KeyboardEngine(searchPrior: GRULanguagePrior.bundled())
		#else
		return KeyboardEngine(neuralWordModelURL: Bundle.main.url(forResource: "nss-english", withExtension: "nsslm"))
		#endif
	}()

	/// The word-level neural search space model (tools/nss), mapped on `queue` at startup.
	/// Nil (no bundled model) keeps the n-gram tier.
	private let neuralWordModelURL: URL?
	var neuralWordModel: KBNeuralWordModel?
	private let neuralTierLock = NSLock()
	private var neuralTierReady = false
	/// True once the shared engine decodes the "nss" tier; read on the main thread when a
	/// word session picks its tier.
	var neuralSearchSpaceReady: Bool {
		neuralTierLock.lock(); defer { neuralTierLock.unlock() }
		return neuralTierReady
	}
	func makeSharedEngine() -> KBSharedEngine? {
		let engine = ngram.makeSharedEngine(lexicon: lexicon.nativeGenerationView(), policy: correctionPolicy.nativeValues,
			safety: lexicon.nativeSafety, neural: neuralWordModel)
		neuralTierLock.lock(); neuralTierReady = engine?.supportsNeuralSearchSpace == true; neuralTierLock.unlock()
		return engine
	}

	init(languageDataURL: URL? = nil, searchPrior: NeuralSearchPrior? = nil, neuralWordModelURL: URL? = nil,
         correctionPolicy: CorrectionPolicy = .baseline, userModel: UserModel? = nil,
         smoothing: NgramSmoothing = .wittenBell,
         candidateBackend: DecoderCoreBackend = .cpp,
         correctionObserver: ((CorrectionGateEvidence) -> Void)? = nil) {
        let personal = userModel ?? UserModel()
        self.user = personal
        self.candidateBackend = candidateBackend
        self.correctionPolicy = correctionPolicy
        self.correctionObserver = correctionObserver
		let ng = NgramScorer(user: personal, backend: candidateBackend, smoothing: smoothing)
		ngram = ng
		self.searchPrior = searchPrior
		self.neuralWordModelURL = neuralWordModelURL
		searchPrior?.onSearchPriorReady = { [weak self] query in
			guard let self else { return }
			self.queue.async {
				guard let latest = self.latestSearchRequest, self.isLatest(latest.generation),
					latest.request.languageMode == .english,
					latest.request.context.map({ $0.lowercased() }) == query.context,
					query.vocabularyRevision == self.lexicon.vocabularyRevision,
					query.prefix == nil || query.prefix?.text == latest.request.currentWord.lowercased()
				else { return }
				DispatchQueue.main.async {
					NotificationCenter.default.post(name: Self.searchPriorReadyNotification,
						object: self, userInfo: ["request": latest.request])
				}
			}
		}
		initializationGroup.enter()
		let ready = initializationGroup
		queue.async { [weak self] in
			defer { ready.leave() }
			guard let self else { return }
			if let languageDataURL { self.lexicon.load(from: languageDataURL) }
			else { self.lexicon.loadFromBundle() }
			let languageData = self.lexicon.languageDataSnapshot()
			self.ngram.attach(data: languageData,
							  resolveID: { [lexicon = self.lexicon] in lexicon.wordID($0) },
							  lexicon: self.lexicon)
			self.user.load()
			self.glideProfile.load()          // #37: restore this user's adapted glide σ / gate
			languageData?.warmGlideAnchorIndex()   // Phase 2: prebuild the endpoint index off the first-glide path
			self.applyLearned()
			if let url = self.neuralWordModelURL {
				do { self.neuralWordModel = try KBNeuralWordModel(url: url) }
				catch { KBDiagnostics.recorder.storageFailure(operation: "nss-model-load") }
			}
            if self.candidateBackend == .cpp { self.sharedEngine = self.makeSharedEngine() }
			KBPersonalData.acknowledgeReset(epoch: KBPersonalData.currentEpoch)
		}
	}

	/// Called by the controller only when a new word session begins. English sessions take
	/// the "nss" tier whenever a model is bundled, including the words typed while the
	/// engine is still starting: every decode queues behind initialization on `queue`, so
	/// it runs once the model is mapped. Only a model that fails to load downgrades those
	/// first sessions (their results are dropped as a tier mismatch); later sessions then
	/// see the engine without NSS and take n-gram.
	func preferredModelTier(for languageMode: KBLanguageMode) -> DecodeModelTier {
		guard languageMode == .english else { return .ngram }
		if neuralSearchSpaceReady { return .neuralSearchSpace }
		if neuralWordModelURL != nil, candidateBackend == .cpp,
		   initializationGroup.wait(timeout: .now()) == .timedOut { return .neuralSearchSpace }
		guard let searchPrior else { return .ngram }
		searchPrior.prepareForSelection()
		return searchPrior.isReady ? searchPrior.modelTier : .ngram
	}

	func handleMemoryPressure() {
		searchPrior?.handleMemoryPressure()
        queue.async { [weak self] in self?.sharedEngine?.memoryPressure() }
	}

	func discardModelSession(_ wordSessionID: UInt64) {
		queue.async { [weak self] in
			guard let self else { return }
			if self.preparedNeuralSession?.id == wordSessionID {
				self.preparedNeuralSession = nil
			}
			if self.incrementalDecodeSession?.id == wordSessionID {
				self.incrementalDecodeSession = nil
			}
			self.searchPrior?.discardSession(wordSessionID)
		}
	}
	private func applyLearned() {
		// Kept words deliberately do NOT enter the trie: keeping means "stop
		// correcting this", not "suggest this". They still adopt organically below
		// once typed adoptAfter times. Snapshot (COW) so no lock is held across the loop.
		for (w, c) in user.unigramsSnapshot() {
			let count = min(c, 50)
			lexicon.noteUse(of: w, timesUsed: count, adoptAfter: adoptAfter,
				allowAdoption: allowsPersonalAdoption(of: w, count: count))
		}
	}

	/// Applies an app-initiated personal-data reset to the already-running extension.
	/// Generation tickets are invalidated synchronously; mutable model state is cleared
	/// on the engine queue after initialization so no decoder observes a half-reset state.
	func resetPersonalization(to epoch: UInt64 = KBPersonalData.currentEpoch) {
		cancelSuggestions()
		cancelGlidePreviews()
		glideLock.lock()
		lastGlideOutcome = nil
		glideLock.unlock()
		glidePreviewCacheLock.lock()
		glidePreviewCache = nil
		glidePreviewCacheLock.unlock()

		queue.async { [weak self] in
			guard let self else { return }
			self.initializationGroup.wait()
			if let session = self.preparedNeuralSession {
				self.searchPrior?.discardSession(session.id)
				self.preparedNeuralSession = nil
			}
			// Drop any cached neural next-word predictions from the reset personalization epoch.
			self.searchPrior?.handleMemoryPressure()
			self.savePending = false
			self.user.reset(to: epoch)
			self.lexicon.resetPersonalization()
			self.glideProfile.reset(to: epoch)
			self.touchProfile.reset()
			KBPersonalData.acknowledgeReset(epoch: epoch)
		}
	}

	// MARK: Glide tuning and session state
	// Behaviour lives in KeyboardEngine+Glide.swift; stored state must stay on the class.

	// Glide decode → commit blend. Shape is the dominant signal (it IS the input);
	// dividing by σ converts grid-distance into nats so the LM prior can arbitrate only
	// genuinely close shapes ("helo" vs "hello", "morning" vs "mourning"). σ and the
	// frequency weight are TUNED, not guessed — tools/glide_eval grid-searches them on
	// synthetic noisy swipes decoded by this exact production code (see WORKLOG).
	let glideLMWeight = 0.6
	let glideFreqWeight = 0.10
	/// Shape candidates handed to the prior. The wider funnel lets a
	/// frequent-but-sloppily-swiped word survives shape ranking for the LM/context to rescue.
	let glideCandidates = 16
	/// #4 context-recall augmentation: how many n-gram-predicted next words to fold into the
	/// rerank pool. Recovers a context-obvious word the beam missed (the recall ceiling is what
	/// caps glide top-1) — but ONLY when its own shape still fits the swipe (bounded by the gate),
	/// so context can rescue a dropped word, never override what the finger actually traced.
	let glideContextAugment = 16
	/// Phase 2 endpoint-anchor augmentation. Fetch words whose first/last letter sit within
	/// `glideAnchorRadius` grid units of the swipe's start/end (up to `glideAnchorEnds` letters
	/// each end), `glideAnchorPerBucket` most-frequent per (first,last) pair, then shape-score them.
	/// glide_eval sweet spot: recovers the 48-wide beam's skip-case misses (recall 89→93,
	/// top-1 87→90) for
	/// ~2 surviving candidates/word; larger values just add candidates the gate then rejects.
	let glideAnchorRadius: CGFloat = 1.3
	let glideAnchorEnds = 3
	let glideAnchorPerBucket = 40
	/// #5 doubled-letter dwell bonus: a swipe traces no loop for "ll", so "hello"/"helo" tie on
	/// shape; a sustained dwell on `l` (velocity minimum near the key) is the positive evidence
	/// that breaks the tie toward the double. Small — it only arbitrates near-ties, and is 0
	/// whenever the stroke carried no timestamps (dwellKeys empty).
	let glideDoubleBonus = 0.35
	/// σ (rerank temperature) and the SHAPE gate (best candidate's cost must clear it or
	/// nothing commits — an accidental smear types nothing, not a random word) are NOT fixed
	/// constants anymore: the baked grid-searched values (σ 0.10, gate 0.43 — the correct-word
	/// p95 / scribble p10 midpoint) live in `GlideProfile` as the defaults, and #37 nudges
	/// them per user only from explicit alternative selections. See `GlideProfile`.
	let glideProfile = GlideProfile()
	let glideSessionIDLock = NSLock()
	var nextGlideSessionID: UInt64 = 0

	/// Live streaming sessions, accessed only on `glidePreviewQueue`.
	var glideSessions: [GlideSessionID: StreamingGlideSession] = [:]

	/// Last committed glide, held until the user's verdict arrives (see KeyboardEngine+Glide.swift).
	let glideLock = NSLock()
	struct GlideOutcome {
		let id: String
		let winner: String
		let shapeCostByWord: [String: Double]
	}
	var lastGlideOutcome: GlideOutcome?

	// MARK: Suggestion pass state

	/// Fast typing queues several passes on the serial engine queue; without a ticket each
	/// would run its full search even when a newer keystroke had already superseded it
	/// (staleness was only detected in the main-thread callback, after the work was spent).
	/// Ticket outside, check inside: a pass that is no longer the newest returns before
	/// doing anything — this coalescing is WHY the queue can stay serial without backlog.
	/// NSLock, not the engine queue, guards the counter — the increment happens on the
	/// caller's thread.
	let genLock = NSLock()
	var suggestGen = 0
}
