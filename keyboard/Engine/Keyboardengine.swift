import Foundation

nonisolated struct GlidePrediction {
	let word: String
	let alternatives: [String]
	let shapeCostByWord: [String: Double]
	let margin: Double
}

nonisolated struct GlideSessionID: Hashable, Sendable {
	let rawValue: UInt64
}

nonisolated struct GlideUpdate {
	let sessionID: GlideSessionID
	let revision: UInt64
	let prediction: GlidePrediction
}

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
	private let queue = DispatchQueue(label: "keyboard.engine")
	/// Glide must not wait behind a suggestion pass. Final decodes and
	/// live previews use separate queues; the final queue has interactive priority and
	/// stale preview work cooperatively exits when the finger lifts.
	private let glideQueue = DispatchQueue(label: "keyboard.engine.glide", qos: .userInteractive)
	private let glidePreviewQueue = DispatchQueue(label: "keyboard.engine.glide.preview", qos: .userInitiated)
	private let initializationGroup = DispatchGroup()
	private let glidePreviewLock = NSLock()
	private var glidePreviewGeneration = 0
	private let glidePreviewCacheLock = NSLock()
	private struct GlidePreviewCache {
		let key: UInt64
		let createdAt: TimeInterval
		let prediction: GlidePrediction
	}
	private var glidePreviewCache: GlidePreviewCache?
	private let lexicon = Lexicon()
	private let user = UserModel()
	/// Eager and immutable. Every decode in a word session uses this same model tier;
	/// memory pressure cannot silently change ranking semantics mid-word.
	private let ngram: NgramScorer
	/// Optional and promotion-gated. The production singleton intentionally supplies
	/// no neural prior until a checkpoint passes blind quality and device gates.
	private let neuralPrior: NeuralLanguagePrior?
	/// Accessed only on `queue`; one prepared context is retained for the active word.
	private var preparedNeuralSession: (id: UInt64, context: [String])?
	/// Static fuzzy-search DP columns retained for one append-only English word.
	/// Cursor edits rebuild this state; ordinary taps advance one column.
	private var incrementalDecodeSession:
		(id: UInt64, layoutRevision: UInt64, session: IncrementalDecodeSession)?
	/// Swift initializes each static singleton once on first access. Computed accessors
	/// keep English sessions from mapping multilingual packs they never query.
	private var transliterator: TenglishTransliterator { TenglishTransliterator.shared }
	private var teluguLexicon: TeluguLexicon { TeluguLexicon.shared }
	private let touchProfile = TouchSpatialProfile()

	// Tunables.
	/// Dynamic edit-distance budget by typed length. Short words get ~1 edit (tight —
	/// a 2-3 letter string is one slip from dozens of words, so a loose budget just adds
	/// noise); normal words ~2; long words ~3, since a longer word accumulates more
	/// independent slips before you notice. These are the weighted spatial model's costs,
	/// so they're budgets, not integer edit counts (1 substitution ≈ 0.3-1.1, 1 ins/del = 1.6).
	private func maxCost(for length: Int) -> Double {
		switch length {
		case ...4:  return 1.8      // ≈ 1 edit
		case 5...7: return 2.8      // ≈ 2 edits (the previous fixed value)
		default:    return 3.6      // ≈ 3 edits
		}
	}
	private let lmWeight = 1.0
	private let freqWeight = 0.3
	/// Completion suggestions consider more prefix matches than the UI shows, then
	/// rerank them by context. Frequency is compressed for suggestions only so high-count
	/// function words do not drown out more specific completions.
	private let completionCandidateLimit = 24
	/// When no completion exists, the bar may show correction candidates, but only
	/// cheap near-misses. This keeps partial prefixes like "con" from showing deletion
	/// corrections like "on"; space-key autocorrect still uses the wider budget.
	private let suggestionCorrectionMaxCost = 1.25
	/// Commits before a non-dictionary word enters the trie (and so becomes
	/// suggestable + immune to autocorrect). 5, not 3: a word you were only testing
	/// or typo'd repeatedly shouldn't graduate into the dictionary.
	private let adoptAfter = 8
	/// Keep a wide oracle funnel. The mmap n-gram scorer scans each context once for
	/// the requested IDs, so 32 rows cost little and avoid the old rank-16 ceiling.
	private let nBest = 24
	private let scoreCap = 32
	/// Autocorrect confidence gate: the best candidate must beat the TYPED string's
	/// blended score by this margin (natural-log units; 3 ≈ 20× more likely) before
	/// a correction fires. Genuine typos clear it by 8–15; slang/names that fit the
	/// context sit near 0 and survive uncorrected — no lexicon entry needed. Active
	private let correctionMargin = 3.0
	/// Broad recovery is reached only for long OOV input after the normal-radius trie
	/// fails. A ten-to-one posterior win over the literal plus a two-to-one win over
	/// an unrelated runner-up is sufficient there; requiring the normal typo margin
	/// discarded useful severe recoveries even after singleton context injection was
	/// removed.
	private let severeRecoveryMargin = log(10.0)
	private let severeRunnerUpMargin = log(2.0)
	/// Real-word correction (the "hoe → how", "js → is" case): a word that IS in the
	/// dictionary is only replaced when a near-neighbour real word dominates it in
	/// context by this much — far stricter than `correctionMargin`, because wrongly
	/// "correcting" a word the user meant is worse than missing one. Works on the
	/// n-gram alone (a real typed word has a genuine n-gram score, not the OOV floor).
	/// 5.0 is calibrated from the harness: legit real words in-context top out ~2.4,
	/// while genuine slips (js→is 7.0, hoe→how 5.3, od→of 9.4) clear it — a safe gap.
	private let realWordMargin = 5.0
	/// …and the winning neighbour must be within this channel cost of the typed word
	/// (≈ one edit), so only genuine slips — not distant words — can win.
	private let realWordMaxCost = 1.6
	/// Channel-dominance guard for the LOOSE candidate pools (context injection and
	/// broad recovery). Those pools exist to rescue heavily corrupted input; when the
	/// close search already found a plausible slip (cost ≤ realWordMaxCost), a loose
	/// candidate may only compete if its own cost is within this window of that best
	/// close cost (≈ one extra edit). Without it a strong bigram drags the decision to
	/// a spatially implausible word: live battery 2026-07-20 committed "you see" for
	/// "sebd" (send 0.8), "running for" for "coudl" (could 0.8) and "definitely
	/// decided" for "recieve" (receive 0.8).
	private let looseCandidateWindow = 1.6
	/// A loose-pool winner must additionally beat the best UNRELATED contender by
	/// this much before the boundary commits it. Heavy rewrites where the LM cannot
	/// separate the top candidates stay in the strip instead of auto-committing a
	/// coin flip. Calibrated from evidence dumps (2026-07-20): the legit severe
	/// rescue coeevitjkn→correction leads coercion by 1.26 nats in every context,
	/// while the junk pool physician/communion/corrections (over-confident 1-count
	/// "receive …" bigrams) is separated by only 0.22.
	private let looseRunnerUpMargin = 1.0
	private struct RankedCandidate {
		let word: String
		let score: Double
		let spatialCost: Double
		let logFrequency: Double
		let logLanguageProbability: Double
		let neuralLogProbability: Double?
	}

	/// Session-only autocorrect rejections. Every access is serialized on `queue`;
	/// the controller never reads this set on the input path.
	private var sessionKept = Set<String>()
	private func isKept(_ word: String) -> Bool { sessionKept.contains(word) }

	/// Learning fires on every committed word, and `user.save()` re-encodes the WHOLE
	/// personal model to JSON — O(model) work and a matching transient allocation on
	/// the engine barrier, per word typed. Coalesce to one save per 2 s typing burst.
	/// Rare, signal-bearing events (kept words, undo healing) still save immediately;
	/// losing ≤2 s of ordinary counts to a jetsam kill is an acceptable trade.
	private var savePending = false
	private func scheduleSave() {
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
	/// This edition ships WITHOUT the neural rescorer. The GRU's value is in-trie
	/// candidate generation (`contextSearchPrior`, always on) — a separate transformer
	/// rescorer that only reranks the n-gram's output is redundant next to it, so the
	/// default build (Debug and Release alike) is n-gram + in-trie search prior only.
	///
	/// The rescorer is disabled, not deleted, so it stays a one-switch revival:
	///   • `INTERNAL_NEURAL` → the transformer W8 rescorer (`CoreMLNeuralLanguagePrior`).
	///     Add it to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and set
	///     `INTERNAL_NEURAL_ENABLED = YES` (Config/Secrets.xcconfig) to also bundle the
	///     model. Previously this branch also fired for plain `DEBUG`; that was dropped
	///     so day-to-day dev builds match what ships.
	///   • `INTERNAL_GRU` → the GRU streaming prior (`GRULanguagePrior`), for profiling
	///     the exported `gru.mlpackage` once it is bundled.
	static let shared: KeyboardEngine = {
		#if INTERNAL_GRU
		return KeyboardEngine(neuralPrior: GRULanguagePrior.bundled())
		#elseif INTERNAL_NEURAL
		return KeyboardEngine(neuralPrior: CoreMLNeuralLanguagePrior.bundled())
		#else
		return KeyboardEngine()
		#endif
	}()

	init(languageDataURL: URL? = nil, neuralPrior: NeuralLanguagePrior? = nil) {
		let ng = NgramScorer(user: user)
		ngram = ng
		self.neuralPrior = neuralPrior
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
			KBPersonalData.acknowledgeReset(epoch: KBPersonalData.currentEpoch)
		}
	}

	/// Called by the controller only when a new word session begins. Release builds use
	/// the production singleton above, which has no neural prior and therefore always
	/// return `.ngram`. Internal profiling can inject a verified prior without creating
	/// a second ranking path in the controller.
	func preferredModelTier(for languageMode: KBLanguageMode) -> DecodeModelTier {
		neuralPrior?.prepareForSelection()
		let neuralAllowed = KBSettings.neuralEnabled
		let tier: DecodeModelTier
		if languageMode == .english, let neuralPrior, neuralPrior.isReady, neuralAllowed {
			tier = neuralPrior.modelTier
		} else {
			tier = .ngram
		}
		// NEURAL_DEBUG_TELEMETRY_REMOVE
		#if DEBUG || INTERNAL_NEURAL
		if languageMode != .english {
			KBDiagnostics.recordNeuralState(tier: .ngram, ready: false,
				state: "disabled-for-language")
		} else if neuralPrior == nil {
			KBDiagnostics.recordNeuralState(tier: .ngram, ready: false,
				state: "not-configured")
		} else if !neuralAllowed {
			KBDiagnostics.recordNeuralState(tier: .ngram,
				ready: neuralPrior?.isReady ?? false, state: "disabled-by-setting")
		} else if tier != .ngram {
			KBDiagnostics.recordNeuralState(tier: tier, ready: true, state: "ready")
		}
		// A present but non-ready prior publishes its own concrete loader state. Do not
		// replace artifact-missing/compiling/memory-gated failures with "inactive".
		#endif
		return tier
	}

	func handleMemoryPressure() {
		neuralPrior?.handleMemoryPressure()
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
			self.neuralPrior?.discardSession(wordSessionID)
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
				self.neuralPrior?.discardSession(session.id)
				self.preparedNeuralSession = nil
			}
			self.savePending = false
			self.sessionKept.removeAll(keepingCapacity: false)
			self.user.reset(to: epoch)
			self.lexicon.resetPersonalization()
			self.glideProfile.reset(to: epoch)
			self.touchProfile.reset()
			KBPersonalData.acknowledgeReset(epoch: epoch)
		}
	}

	// MARK: Autocorrect decision (background decode only)

	/// Bare lowercase "i" and its contractions — stock always capitalizes these.
	/// They sit beneath the ≥3-char gate the fuzzy path uses, so they're special-cased.
	private static let iForms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]

	/// Left-context words that make a following "id" the noun (an ID), not "I'd"/"is".
	/// Possessives and articles only — demonstratives ("this"/"that") are deliberately
	/// excluded so "this id" can still correct to "this is".
	private static let idNounDeterminers: Set<String> = [
		"my", "your", "his", "her", "our", "their", "a", "an", "the",
		"valid", "fake", "user", "login", "student", "employee", "email", "caller",
	]

	private struct CorrectionDecision {
		let word: String?
		/// Winner minus typed-word score in natural-log units. This is the actual
		/// confidence signal published in DecodeSnapshot, not a boolean placeholder.
		let margin: Double
	}

	private func rawScore(_ candidate: RankedCandidate) -> Double {
		-candidate.spatialCost + lmWeight * candidate.logLanguageProbability
			+ freqWeight * candidate.logFrequency
	}

	/// The user typed a trailing 's' that the bare-base correction would DROP; if
	/// base+"'s" is a real contraction it renders the typed letters better ("thads" →
	/// base "that", but the typed 's' means "that's"). Validity-gated, so only genuine
	/// dictionary contractions are ever promoted.
	private func contractionPreservingTypedSuffix(base: String, typed lw: String) -> String? {
		guard lw.hasSuffix("s"), !base.hasSuffix("s") else { return nil }
		let contraction = base + "'s"
		guard lexicon.contains(contraction), !lexicon.isProfane(contraction) else { return nil }
		return contraction
	}

	/// Context-aware next-character priors for key-target resizing (Plan 1). The
	/// context-free trie prior (`base`) is lifted wherever the in-context ranking already
	/// favours a completion extending the current prefix: the character each higher-ranked
	/// completion adds gets a rank-decayed weight, normalized, and folded in with MAX so
	/// context can only ENLARGE a likely key, never shrink one below its lexical baseline.
	private func contextualCharPriors(evidence: [DecodeCandidateEvidence], prefix lw: String,
									  base: [Character: Double]) -> [Character: Double] {
		guard !lw.isEmpty else { return base }
		var contextual: [Character: Double] = [:]
		var weight = 1.0
		for candidate in evidence
			where candidate.word.count > lw.count && candidate.word.hasPrefix(lw) {
			let next = candidate.word[candidate.word.index(candidate.word.startIndex,
				offsetBy: lw.count)]
			contextual[next, default: 0] += weight
			weight *= 0.85
		}
		guard let top = contextual.values.max(), top > 0 else { return base }
		var out = base
		for (character, value) in contextual {
			out[character] = Swift.max(out[character] ?? 0, value / top)
		}
		return out
	}

	/// Decide from the same already-scored table used by the suggestion strip. The
	/// language model is never invoked here; display and commit therefore share one
	/// candidate generation pass and one prior batch.
	private func correction(from scored: [RankedCandidate], correctionCosts: [String: Double],
							typed lw: String, context: [String],
							split: (candidate: Candidate, a: String, b: String)?,
							looseWords: Set<String> = [],
							broadRecoveryWords: Set<String> = []) -> CorrectionDecision {
		guard !isKept(lw) else { return CorrectionDecision(word: nil, margin: 0) }

		guard let typed = scored.first(where: { $0.word == lw }) else {
			return CorrectionDecision(word: nil, margin: 0)
		}
		let typedScore = rawScore(typed)
		let eligible = scored.filter {
			$0.word != lw && correctionCosts[$0.word] != nil
		}
		var bestWord = eligible.first?.word
		var bestScore = eligible.first.map(rawScore) ?? -.infinity
		for candidate in eligible.dropFirst() {
			let score = rawScore(candidate)
			if score > bestScore { bestWord = candidate.word; bestScore = score }
		}

		// Real dictionary words (js, hoe, form) are normally immune to autocorrect — that
		// immunity is why "js" showed "is" in the bar but never applied it. Correct one
		// only when a near-neighbour real word dominates it in context by realWordMargin
		// (the iOS-17 "hoe → how" behaviour). Allowed down to 2 chars because the strict
		// margin + single-edit requirement make it safe there; runs on the n-gram too.
		if lexicon.contains(lw) {
			// "id" is a kept dictionary word (Freudian id / "your id"). At a sentence start
			// it is almost always "I'd". A possessive/article before it marks the noun, so
			// keep it. Any other left context falls through to the normal real-word branch,
			// which corrects the near-homophone in context ("this id" -> "is"). Frequency
			// alone can't separate these — "is" outweighs "id" everywhere — so the noun is
			// protected by its determiner, not by the margin.
			if lw == "id" {
				if context.isEmpty { return CorrectionDecision(word: "i'd", margin: 100) }
				if let previous = context.last, Self.idNounDeterminers.contains(previous) {
					return CorrectionDecision(word: nil, margin: 0)
				}
			}
			guard lw.count >= 2, let bestWord, lexicon.contains(bestWord),
				  let cost = correctionCosts[bestWord], cost <= realWordMaxCost else {
				return CorrectionDecision(word: nil, margin: 0)
			}
			let margin = bestScore - typedScore
			let fire = margin > realWordMargin
			KBDiagnostics.logDecision(typed: lw, best: bestWord, margin: margin,
									  threshold: realWordMargin, corrected: fire)
			return CorrectionDecision(word: fire ? bestWord : nil, margin: margin)
		}

		// OOV contraction guard: "when's" / "mustn't" are valid English even though the
		// 60k vocab only carries the frequent contractions. Without this, an OOV
		// contraction fell through to the correction machinery, whose best candidate
		// is usually the bare base word — typing "When's" got "corrected" to "When".
		// A known base + standard clitic is a word the user meant; never rewrite it.
		if lexicon.isContractionForm(lw) { return CorrectionDecision(word: nil, margin: 0) }

		// Apostrophe restoration — stock's contraction behavior, computed from the
		// lexicon instead of a hardcoded pair list. An OOV string that becomes a
		// dictionary word by inserting one apostrophe ("dont" → "don't", "im" → "i'm",
		// "whats" → "what's") is a contraction typed without the ' (the letters page
		// has no ' key), not a typo to score: no blend ranking can prefer "what's"
		// over "what" (frequency and context gaps exceed the whole channel gap), so this
		// fires DIRECTLY, before scoring, on both the full and the fast inline path.
		// Real words ("its", "cant", "well") never reach here — the real-word branch
		// above already returned, so its strict margin still guards those.
		if lw.count >= 2, let restored = lexicon.apostropheRestoration(of: lw),
		   !lexicon.isProfane(restored) {
			KBDiagnostics.logDecision(typed: lw, best: restored, margin: .infinity,
									  threshold: 0, corrected: true)
			return CorrectionDecision(word: restored, margin: 100)
		}

		guard lw.count >= 3 else { return CorrectionDecision(word: nil, margin: 0) }
		// Missing-space split ("alot" → "a lot"): rides the same gates as single-word
		// candidates. Score it as two conditional n-gram probabilities because the
		// single-word scorer intentionally has no multi-word candidate representation.
		if let split {
			let s = -split.candidate.cost + freqWeight * split.candidate.logFreq
				+ lmWeight * ngram.pairLogProb(split.a, split.b, context: context)
			if s > bestScore { bestWord = split.candidate.word; bestScore = s }
		}
		if let current = bestWord, !current.contains("'"),
		   let promoted = contractionPreservingTypedSuffix(base: current, typed: lw) {
			bestWord = promoted
		}
		guard let bestWord else { return CorrectionDecision(word: nil, margin: 0) }
		let margin = bestScore - typedScore
		let isSevereBroadRecovery = lw.count >= 8 && broadRecoveryWords.contains(bestWord)
		let requiredMargin = isSevereBroadRecovery ? severeRecoveryMargin : correctionMargin
		var fire = margin > requiredMargin
		// A LOOSE winner (context injection / broad recovery) is a heavy rewrite of
		// what the user typed. At those spatial costs the channel can no longer
		// discriminate between candidates, so unless the language model clearly
		// separates the winner from the runner-up the "rescue" is a frequency coin
		// flip — live 2026-07-20 committed "physician" for "coeevitjkn". Fire only
		// when the winner dominates every other candidate by looseRunnerUpMargin;
		// otherwise the strip still offers the pool for a one-tap fix.
		if fire, looseWords.contains(bestWord) {
			// Near-forms of the winner (correction/corrections) are not rivals —
			// committing either is the same rescue. Only an UNRELATED contender
			// scoring close means the pool is a coin flip.
			let contender = eligible
				.filter { $0.word != bestWord && !Self.nearForm($0.word, bestWord) }
				.map(rawScore).max()
			let requiredRunnerUp = isSevereBroadRecovery
				? severeRunnerUpMargin : looseRunnerUpMargin
			if let contender, bestScore - contender < requiredRunnerUp { fire = false }
		}
		KBDiagnostics.logDecision(typed: lw, best: bestWord, margin: margin,
								  threshold: requiredMargin, corrected: fire)
		return CorrectionDecision(word: fire ? bestWord : nil, margin: margin)
	}

	/// Plain (unit-cost) edit distance ≤ 2 — "correction"/"corrections" are one form.
	/// Deliberately NOT the keyboard-weighted channel cost: form-similarity is a
	/// lexical question, not a typing-slip question.
	private static func nearForm(_ a: String, _ b: String) -> Bool {
		let x = Array(a.utf8), y = Array(b.utf8)
		if abs(x.count - y.count) > 2 { return false }
		var prev = Array(0...y.count)
		var curr = [Int](repeating: 0, count: y.count + 1)
		for i in 1...x.count {
			curr[0] = i
			var rowMin = curr[0]
			for j in 1...y.count {
				curr[j] = min(prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1),
							  min(prev[j] + 1, curr[j - 1] + 1))
				rowMin = min(rowMin, curr[j])
			}
			if rowMin > 2 { return false }
			swap(&prev, &curr)
		}
		return prev[y.count] <= 2
	}

	/// Best "missing space" split of an OOV string into two real words, or nil.
	/// Channel cost is one skipped space (just under one insertion). Single-letter
	/// halves are only "a"/"i" — anything else is a typo fragment, not a word.
	private static let splitCost = 1.1
	/// A user aiming for the space bar can land on its nearest letter row. Consume one
	/// adjacent `c/v/b/n/m` as the boundary instead of demanding two perfect substrings.
	private static let spatialBoundarySubstitutionCost = 0.72
	private static let spaceNeighbourLetters = Set("cvbnm")
	/// Channel cost of a missing apostrophe in the SUGGESTION bar's contraction
	/// candidate ("its" → "it's"). Well under one edit: the omission is a keyboard
	/// layout gap, not a slip — ranking, not this cost, decides if it surfaces.
	private static let apostropheCost = 0.5
	private func splitCandidate(of lw: String) -> (candidate: Candidate, a: String, b: String)? {
		guard lw.count >= 4 else { return nil }
		var best: (Candidate, String, String)?
		var bestStrength = -Double.infinity
		let characters = Array(lw)
		func consider(_ a: String, _ b: String, cost: Double) {
			guard a.count >= 2 || a == "a" || a == "i",
				  b.count >= 2 || b == "a" || b == "i",
				  lexicon.contains(a), lexicon.contains(b),
				  !lexicon.isProfane(a), !lexicon.isProfane(b),
				  let fa = lexicon.logFreq(of: a), let fb = lexicon.logFreq(of: b) else { return }
			let lf = min(fa, fb)      // the pair is only as strong as its rarer half
			let strength = lf - cost
			if strength > bestStrength {
				bestStrength = strength
				best = (Candidate(word: a + " " + b, cost: cost, logFreq: lf), a, b)
			}
		}
		for i in 1..<characters.count {
			consider(String(characters[..<i]), String(characters[i...]),
				cost: Self.splitCost)
			if Self.spaceNeighbourLetters.contains(characters[i]), i + 1 < characters.count {
				consider(String(characters[..<i]), String(characters[(i + 1)...]),
					cost: Self.spatialBoundarySubstitutionCost)
			}
		}
		guard let best else { return nil }
		return (best.0, best.1, best.2)
	}

	func dontCorrect(_ word: String) {
		let lw = word.lowercased()
		queue.async { [weak self] in
			guard let self else { return }
			self.sessionKept.insert(lw)
			self.user.confirmSpelling(lw)
			self.scheduleSave()
		}
	}

	/// The user let an autocorrect of `original` stand (typed on instead of undoing).
	/// Acceptance is counter-evidence against an earlier rejection this session —
	/// lift the keep so correction resumes. Nothing persists; keeps are session-scoped.
	func correctionStood(_ original: String) {
		let lw = original.lowercased()
		queue.async { [weak self] in self?.sessionKept.remove(lw) }
	}

	/// The user actively replaced `original` with a different word (picked a suggestion
	/// over their typed word, undid a correction back out of `original`, or erased it
	/// and retyped something else by hand). Strong evidence `original` was a mistake:
	/// lift its session keep — so autocorrect resumes immediately — and walk back one
	/// learned use, so repeated hand-fixes keep it from adopting into the dictionary.
	func wordReplaced(original: String, with replacement: String) {
		let lw = original.lowercased()
		guard lw != replacement.lowercased() else { return }
		queue.async { [weak self] in
			guard let self else { return }
			self.sessionKept.remove(lw)
			self.user.demote(lw)
			self.scheduleSave()
		}
	}

	// MARK: Glide typing

	// Glide decode → commit blend. Shape is the dominant signal (it IS the input);
	// dividing by σ converts grid-distance into nats so the LM prior can arbitrate only
	// genuinely close shapes ("helo" vs "hello", "morning" vs "mourning"). σ and the
	// frequency weight are TUNED, not guessed — tools/glide_eval grid-searches them on
	// synthetic noisy swipes decoded by this exact production code (see WORKLOG).
	private let glideLMWeight = 0.6
	private let glideFreqWeight = 0.10
	/// Shape candidates handed to the prior. The wider funnel lets a
	/// frequent-but-sloppily-swiped word survives shape ranking for the LM/context to rescue.
	private let glideCandidates = 16
	/// #4 context-recall augmentation: how many n-gram-predicted next words to fold into the
	/// rerank pool. Recovers a context-obvious word the beam missed (the recall ceiling is what
	/// caps glide top-1) — but ONLY when its own shape still fits the swipe (bounded by the gate),
	/// so context can rescue a dropped word, never override what the finger actually traced.
	private let glideContextAugment = 16
	/// Phase 2 endpoint-anchor augmentation. Fetch words whose first/last letter sit within
	/// `glideAnchorRadius` grid units of the swipe's start/end (up to `glideAnchorEnds` letters
	/// each end), `glideAnchorPerBucket` most-frequent per (first,last) pair, then shape-score them.
	/// glide_eval sweet spot: recovers the 48-wide beam's skip-case misses (recall 89→93,
	/// top-1 87→90) for
	/// ~2 surviving candidates/word; larger values just add candidates the gate then rejects.
	private let glideAnchorRadius: CGFloat = 1.3
	private let glideAnchorEnds = 3
	private let glideAnchorPerBucket = 40
	/// #5 doubled-letter dwell bonus: a swipe traces no loop for "ll", so "hello"/"helo" tie on
	/// shape; a sustained dwell on `l` (velocity minimum near the key) is the positive evidence
	/// that breaks the tie toward the double. Small — it only arbitrates near-ties, and is 0
	/// whenever the stroke carried no timestamps (dwellKeys empty).
	private let glideDoubleBonus = 0.35
	/// σ (rerank temperature) and the SHAPE gate (best candidate's cost must clear it or
	/// nothing commits — an accidental smear types nothing, not a random word) are NOT fixed
	/// constants anymore: the baked grid-searched values (σ 0.10, gate 0.43 — the correct-word
	/// p95 / scribble p10 midpoint) live in `GlideProfile` as the defaults, and #37 nudges
	/// them per user only from explicit alternative selections. See `GlideProfile`.
	private let glideProfile = GlideProfile()
	private let glideSessionIDLock = NSLock()
	private var nextGlideSessionID: UInt64 = 0

	/// Accessed only on `glidePreviewQueue`. Each session retains its resampler,
	/// candidate pool, and online DTW rows for the lifetime of one finger gesture.
	private struct StreamingGlideSession {
		let id: GlideSessionID
		let context: [String]
		var rawPointCount = 0
		var layoutPitch: (CGFloat, CGFloat)?
		var resampler = IncrementalGlideResampler()
		var candidates: [String: OnlineGlideCandidate] = [:]
		var endpointSignature = ""
		var revision: UInt64 = 0
		var latestPrediction: GlidePrediction?
		var invalid = false
	}
	private var glideSessions: [GlideSessionID: StreamingGlideSession] = [:]

	private func currentGlidePreviewGeneration() -> Int {
		glidePreviewLock.lock(); defer { glidePreviewLock.unlock() }
		return glidePreviewGeneration
	}

	private func isCurrentGlidePreview(_ generation: Int) -> Bool {
		glidePreviewLock.lock(); defer { glidePreviewLock.unlock() }
		return generation == glidePreviewGeneration
	}

	/// Called at gesture start, cancellation, and lift. A decoder already running checks
	/// this ticket once per trie depth and exits instead of competing with the final pass.
	func cancelGlidePreviews() {
		glidePreviewLock.lock()
		glidePreviewGeneration &+= 1
		glidePreviewLock.unlock()
		glidePreviewQueue.async { [weak self] in self?.glideSessions.removeAll(keepingCapacity: true) }
	}

	func beginGlideSession(context: [String]) -> GlideSessionID {
		glideSessionIDLock.lock()
		nextGlideSessionID &+= 1
		let id = GlideSessionID(rawValue: nextGlideSessionID)
		glideSessionIDLock.unlock()
		glidePreviewQueue.async { [weak self] in
			self?.glideSessions[id] = StreamingGlideSession(id: id, context: context)
		}
		return id
	}

	func cancelGlideSession(_ id: GlideSessionID) {
		glidePreviewQueue.async { [weak self] in self?.glideSessions[id] = nil }
	}

	/// Consume a cumulative UIKit path while processing only its unconsumed suffix.
	/// Completion is always delivered on main so the controller can directly publish
	/// the middle suggestion without another synchronization hop.
	func updateGlideSession(_ id: GlideSessionID, path: [CGPoint], times: [TimeInterval],
		layout: GlideLayout, completion: @escaping (GlideUpdate?) -> Void) {
		let started = ProcessInfo.processInfo.systemUptime
		let signpost = KBDiagnostics.beginGlidePreview()
		glidePreviewQueue.async { [weak self] in
			defer {
				KBDiagnostics.endGlidePreview(signpost,
					milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
			}
			guard let self else {
				DispatchQueue.main.async { completion(nil) }
				return
			}
			self.initializationGroup.wait()
			guard var session = self.glideSessions[id],
				let languageData = self.lexicon.languageDataSnapshot() else {
				DispatchQueue.main.async { completion(nil) }
				return
			}
			let update = self.consumeStreamingPath(path, layout: layout,
				languageData: languageData, session: &session)
			self.glideSessions[id] = session.invalid ? nil : session
			DispatchQueue.main.async { completion(update) }
		}
	}

	/// Finalizes from the same retained session. Only the winner and visible runners-up
	/// receive exact full-path shape validation; trie search is not restarted.
	func finishGlideSession(_ id: GlideSessionID, path: [CGPoint], times: [TimeInterval],
		layout: GlideLayout, completion: @escaping (String?, [String]) -> Void) {
		let started = ProcessInfo.processInfo.systemUptime
		let signpost = KBDiagnostics.beginGlideFinal()
		glidePreviewQueue.async { [weak self] in
			defer {
				KBDiagnostics.endGlideFinal(signpost,
					milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
			}
			guard let self else {
				DispatchQueue.main.async { completion(nil, []) }
				return
			}
			self.initializationGroup.wait()
			guard var session = self.glideSessions.removeValue(forKey: id),
				let languageData = self.lexicon.languageDataSnapshot() else {
				self.glide(path: path, times: times, layout: layout,
					context: [], completion: completion)
				return
			}
			let update = self.consumeStreamingPath(path, layout: layout,
				languageData: languageData, session: &session)
			guard !session.invalid else {
				self.glide(path: path, times: times, layout: layout,
					context: session.context, completion: completion)
				return
			}
			guard let prediction = update?.prediction ?? session.latestPrediction,
				let processed = GlidePreprocess.run(path, layout: layout,
					times: times.isEmpty ? nil : times) else {
				DispatchQueue.main.async { completion(nil, []) }
				return
			}

			let displayed = [prediction.word] + prediction.alternatives
			var exactCosts: [String: Double] = [:]
			for word in displayed {
				if let cost = GlideDecoder.shapeCost(of: word, processed) { exactCosts[word] = cost }
			}
			// The streaming snapshot is authoritative. A lift-only shape gate made the
			// visible winner disappear after release, so exact costs are retained only
			// for learning/diagnostics and never change the displayed commit decision.
			let committed = GlidePrediction(word: prediction.word,
				alternatives: prediction.alternatives,
				shapeCostByWord: exactCosts,
				margin: prediction.margin)
			let gestureID = self.noteGlideCommit(winner: committed.word,
				shapeCostByWord: committed.shapeCostByWord)
			DispatchQueue.main.async { completion(committed.word, committed.alternatives) }
			self.glideQueue.async { [weak self] in
				self?.logCachedGlide(committed, path: path, times: times,
					layout: layout, processed: processed, gestureID: gestureID)
			}
		}
	}

	private func consumeStreamingPath(_ path: [CGPoint], layout: GlideLayout,
		languageData: LangData, session: inout StreamingGlideSession) -> GlideUpdate? {
		guard !session.invalid, path.count >= session.rawPointCount,
			layout.xPitch > 0, layout.yPitch > 0 else {
			session.invalid = true
			return nil
		}
		let pitch = (layout.xPitch, layout.yPitch)
		if let previous = session.layoutPitch,
			(abs(previous.0 - pitch.0) > 0.01 || abs(previous.1 - pitch.1) > 0.01) {
			session.invalid = true
			return nil
		}
		session.layoutPitch = pitch
		let suffix = path[session.rawPointCount...].map { GlidePreprocess.toGrid($0, layout: layout) }
		session.rawPointCount = path.count
		let newSamples = session.resampler.append(suffix[...])
		if !newSamples.isEmpty {
			for word in Array(session.candidates.keys) {
				guard var candidate = session.candidates[word] else { continue }
				candidate.consume(newSamples)
				session.candidates[word] = candidate
			}
		}
		augmentStreamingCandidates(languageData: languageData, session: &session)
		guard session.resampler.samples.count >= 2 else { return nil }
		let prediction = rankStreamingCandidates(session)
		guard let prediction else { return nil }
		session.revision &+= 1
		session.latestPrediction = prediction
		return GlideUpdate(sessionID: session.id, revision: session.revision,
			prediction: prediction)
	}

	private func augmentStreamingCandidates(languageData: LangData,
		session: inout StreamingGlideSession) {
		guard let start = session.resampler.samples.first,
			let end = session.resampler.samples.last else { return }
		let firsts = GlidePreprocess.lettersNear(start, radius: glideAnchorRadius,
			maxN: glideAnchorEnds)
		let lasts = GlidePreprocess.lettersNear(end, radius: glideAnchorRadius,
			maxN: glideAnchorEnds)
		let signature = String(firsts) + ":" + String(lasts)
		guard session.candidates.isEmpty || signature != session.endpointSignature else { return }
		session.endpointSignature = signature

		var proposed: [String] = []
		if session.candidates.isEmpty {
			proposed.append(contentsOf: ngram.nextWords(context: session.context, limit: 48))
			for first in firsts {
				proposed.append(contentsOf: languageData.trieCompletions(
					prefix: String(first), limit: 72).map(\.word))
			}
		}
		proposed.append(contentsOf: languageData.glideAnchorWords(first: firsts,
			last: lasts, perBucket: glideAnchorPerBucket))
		let firstSet = Set(firsts), lastSet = Set(lasts)
		proposed.append(contentsOf: lexicon.glideDynamicWords(limit: 128).filter {
			guard let first = $0.first, let last = $0.last else { return false }
			return firstSet.contains(first) && lastSet.contains(last)
		})

		for word in proposed where session.candidates.count < 384 {
			let normalized = word.lowercased()
			guard normalized.count >= 2, session.candidates[normalized] == nil,
				!lexicon.isProfane(normalized),
				var candidate = OnlineGlideCandidate(word: normalized) else { continue }
			candidate.consume(session.resampler.samples)
			session.candidates[normalized] = candidate
		}
	}

	private func rankStreamingCandidates(_ session: StreamingGlideSession) -> GlidePrediction? {
		let rows = session.candidates.values.filter { $0.prefixCost.isFinite }
		guard !rows.isEmpty else { return nil }
		let words = rows.map(\.word)
		let priors = ngram.logProbs(words, context: session.context)
		let scored = rows.enumerated().map { index, candidate in
			let frequency = lexicon.logFreq(of: candidate.word) ?? 0
			let score = -candidate.prefixCost / 0.10
				+ glideLMWeight * priors[index]
				+ glideFreqWeight * frequency
				- lexicon.safetyPenalty(candidate.word)
			return (candidate.word, candidate.prefixCost, score)
		}.sorted { $0.2 > $1.2 }
		guard let winner = scored.first else { return nil }
		let margin = scored.count > 1 ? scored[0].2 - scored[1].2 : .greatestFiniteMagnitude
		let alternatives = scored.dropFirst().prefix(3).map(\.0)
		let costs = Dictionary(scored.prefix(12).map { ($0.0, $0.1) },
			uniquingKeysWith: min)
		return GlidePrediction(word: winner.0, alternatives: alternatives,
			shapeCostByWord: costs, margin: margin)
	}

	/// In-progress decode for UI feedback. It runs the exact production candidate and
	/// ranking pipeline used on release. The controller keeps this single-flight, so
	/// preview work can never occupy the final decoder or suggestion queue.
	func glidePreview(path: [CGPoint], times: [TimeInterval] = [], layout: GlideLayout,
					  context: [String], completion: @escaping (GlidePrediction?) -> Void) {
		let generation = currentGlidePreviewGeneration()
		let cacheKey = glideCacheKey(path: path, times: times, layout: layout, context: context)
		let started = ProcessInfo.processInfo.systemUptime
		let signpost = KBDiagnostics.beginGlidePreview()
		glidePreviewQueue.async { [weak self] in
			defer {
				KBDiagnostics.endGlidePreview(signpost,
					milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
			}
			func deliver(_ prediction: GlidePrediction?) {
				DispatchQueue.main.async { completion(prediction) }
			}
			guard let self else { return deliver(nil) }
			self.initializationGroup.wait()
			guard self.isCurrentGlidePreview(generation),
				  let ld = self.lexicon.languageDataSnapshot(),
				  let g = GlidePreprocess.run(path, layout: layout, times: times.isEmpty ? nil : times)
			else { return deliver(nil) }
			let isCancelled = { [weak self] in self?.isCurrentGlidePreview(generation) != true }
			guard let result = self.decodeGlide(g, lang: ld, context: context,
											 shouldCancel: isCancelled) else { return deliver(nil) }
			let scored = result.scored
			guard let winner = scored.first?.word else { return deliver(nil) }
			let margin = scored.count > 1 ? scored[0].s - scored[1].s : Double.greatestFiniteMagnitude
			let prediction = GlidePrediction(
				word: winner,
				alternatives: scored.dropFirst().prefix(3).map(\.word),
				shapeCostByWord: Dictionary(result.candidates.map { ($0.word, $0.cost) }, uniquingKeysWith: min),
				margin: margin)
			self.storeGlidePreview(prediction, key: cacheKey)
			deliver(prediction)
		}
	}

	private func storeGlidePreview(_ prediction: GlidePrediction, key: UInt64) {
		glidePreviewCacheLock.lock()
		glidePreviewCache = GlidePreviewCache(
			key: key,
			createdAt: ProcessInfo.processInfo.systemUptime,
			prediction: prediction
		)
		glidePreviewCacheLock.unlock()
	}

	private func recentGlidePreview(key: UInt64) -> GlidePrediction? {
		glidePreviewCacheLock.lock(); defer { glidePreviewCacheLock.unlock() }
		guard let cached = glidePreviewCache,
			  cached.key == key,
			  // A user may pause on the final key before lifting. The exact cache key
			  // already includes every path point, timestamp, layout pitch, and context,
			  // so a five-second gesture-local window is safer than expiring a valid
			  // displayed result after 350 ms and launching a disagreeing final decode.
			  ProcessInfo.processInfo.systemUptime - cached.createdAt <= 5.0
		else { return nil }
		return cached.prediction
	}

	/// Stable FNV-1a fingerprint of the exact raw path, timing samples, layout scale,
	/// and language context. A cache hit therefore means preview and commit consumed
	/// identical evidence, not merely a similar endpoint.
	private func glideCacheKey(path: [CGPoint], times: [TimeInterval], layout: GlideLayout,
							   context: [String]) -> UInt64 {
		var hash: UInt64 = 0xcbf29ce484222325
		func mix(_ value: UInt64) {
			hash = (hash ^ value) &* 0x100000001b3
		}
		mix(UInt64(path.count))
		for point in path {
			mix(Double(point.x).bitPattern)
			mix(Double(point.y).bitPattern)
		}
		mix(UInt64(times.count))
		for time in times { mix(time.bitPattern) }
		mix(Double(layout.xPitch).bitPattern)
		mix(Double(layout.yPitch).bitPattern)
		for word in context {
			for byte in word.utf8 { mix(UInt64(byte)) }
			mix(0xff)
		}
		return hash
	}

	private func scoreGlideCandidates(_ candidates: [(word: String, cost: Double)],
									  glide: ProcessedGlide, context: [String]) -> [(word: String, s: Double)] {
		let sigma = glideProfile.sigma
		let dwell = Set(glide.dwellKeys)
		let priors = ngram.logProbs(candidates.map(\.word), context: context)
		return candidates.enumerated().map { i, candidate in
			let frequency = lexicon.logFreq(of: candidate.word) ?? 0
			let dwellBonus = dwell.isEmpty
				? 0
				: glideDoubleBonus * Double(dwelledDoubles(candidate.word, dwell))
			return (candidate.word, -candidate.cost / sigma
				+ glideLMWeight * priors[i]
				+ glideFreqWeight * frequency
				- lexicon.safetyPenalty(candidate.word)
				+ dwellBonus)
		}
		.sorted { $0.s > $1.s }
	}

	private struct GlideDecodeResult {
		let candidates: [(word: String, cost: Double)]
		let scored: [(word: String, s: Double)]
	}

	/// The single production Glide pipeline used by both live feedback and final commit.
	/// Keeping candidate generation, recovery, gating, and ranking here prevents the preview
	/// from promising a word that a different release-time decoder would immediately replace.
	private func decodeGlide(_ glide: ProcessedGlide, lang: LangData, context: [String],
								 shouldCancel: (() -> Bool)? = nil) -> GlideDecodeResult? {
		guard shouldCancel?() != true else { return nil }
		let gate = glideProfile.gate
		var candidates = GlideDecoder.decode(
			glide, lang: lang, limit: glideCandidates, shouldCancel: shouldCancel
		).filter { !lexicon.isProfane($0.word) }
		guard shouldCancel?() != true else { return nil }
		var knownWords = Set(candidates.map(\.word))

		if !context.isEmpty {
			for word in ngram.nextWords(context: context, limit: glideContextAugment)
			where !knownWords.contains(word) && word.count >= 2 && !lexicon.isProfane(word) {
				guard shouldCancel?() != true else { return nil }
				if let cost = GlideDecoder.shapeCost(of: word, glide), cost <= gate {
					candidates.append((word: word, cost: cost))
					knownWords.insert(word)
				}
			}
		}

		if let start = glide.points.first, let end = glide.points.last {
			let firsts = GlidePreprocess.lettersNear(start, radius: glideAnchorRadius, maxN: glideAnchorEnds)
			let lasts = GlidePreprocess.lettersNear(end, radius: glideAnchorRadius, maxN: glideAnchorEnds)
			let firstSet = Set(firsts)
			let lastSet = Set(lasts)
			for word in lexicon.glideDynamicWords(limit: 128)
			where !knownWords.contains(word) && !lexicon.isProfane(word) {
				guard let first = word.first, let last = word.last,
					  firstSet.contains(first), lastSet.contains(last) else { continue }
				guard shouldCancel?() != true else { return nil }
				if let cost = GlideDecoder.shapeCost(of: word, glide), cost <= gate {
					candidates.append((word: word, cost: cost))
					knownWords.insert(word)
				}
			}
			for word in lang.glideAnchorWords(first: firsts, last: lasts, perBucket: glideAnchorPerBucket)
			where !knownWords.contains(word) && word.count >= 2 && !lexicon.isProfane(word) {
				guard shouldCancel?() != true else { return nil }
				if let cost = GlideDecoder.shapeCost(of: word, glide), cost <= gate {
					candidates.append((word: word, cost: cost))
					knownWords.insert(word)
				}
			}
		}

		guard shouldCancel?() != true else { return nil }
		// Every candidate, not merely the cheapest one, must satisfy the shape gate.
		// Otherwise a strong context prior can pull an unrelated endpoint word over a
		// valid stroke and turn the safety gate into a no-op.
		candidates = candidates.filter { $0.cost <= gate }
		guard !candidates.isEmpty else { return nil }
		let scored = scoreGlideCandidates(candidates, glide: glide, context: context)
		return scored.isEmpty ? nil : GlideDecodeResult(candidates: candidates, scored: scored)
	}

	/// Decode a swipe into a word: preprocess (P2) → shape-match against the trie (P3) →
	/// rerank with the language prior + frequency and gate (P4). Delivers the winner and
	/// up to 3 alternatives for the suggestion bar (swap targets) on the MAIN queue;
	/// (nil, []) when the swipe matched nothing well enough to commit.
	func glide(path: [CGPoint], times: [TimeInterval] = [], layout: GlideLayout, context: [String],
				   publishedPrediction: GlidePrediction? = nil,
				   completion: @escaping (String?, [String]) -> Void) {
		cancelGlidePreviews()
		// Invalidate any suggestion pass already dispatched to the engine queue.
		// A queued pass that hasn't started yet bails at its isLatest() check;
		// a pass mid-execution still completes, but any further queued ones skip.
		// The controller also cancels the debounced work item before calling here.
		cancelSuggestions()
		if let publishedPrediction {
			let gestureID = noteGlideCommit(winner: publishedPrediction.word,
				shapeCostByWord: publishedPrediction.shapeCostByWord)
			// The visible preview is the gesture's contract. Commit it inline on the
			// main-thread lift callback; never run a second decoder that can disagree.
			completion(publishedPrediction.word, publishedPrediction.alternatives)
			glideQueue.async { [weak self] in
				guard let self,
					  let processed = GlidePreprocess.run(path, layout: layout,
						times: times.isEmpty ? nil : times) else { return }
				self.logCachedGlide(publishedPrediction, path: path, times: times,
					layout: layout, processed: processed, gestureID: gestureID)
			}
			return
		}
		let cacheKey = glideCacheKey(path: path, times: times, layout: layout, context: context)
		if let cached = recentGlidePreview(key: cacheKey) {
			let gestureID = noteGlideCommit(winner: cached.word, shapeCostByWord: cached.shapeCostByWord)
			// `glide` is invoked from touchesEnded on main. Deliver inline so an exact
			// preview hit inserts before the next display frame.
			completion(cached.word, cached.alternatives)
			glideQueue.async { [weak self] in
				guard let self,
					  let processed = GlidePreprocess.run(path, layout: layout, times: times.isEmpty ? nil : times)
				else { return }
				self.logCachedGlide(cached, path: path, times: times, layout: layout,
					processed: processed, gestureID: gestureID)
			}
			return
		}
		// Dedicated interactive queue: the full-path decision never waits behind
		// suggestions or a live-preview decode.
		let finalStarted = ProcessInfo.processInfo.systemUptime
		let finalSignpost = KBDiagnostics.beginGlideFinal()
		glideQueue.async { [weak self] in
			defer {
				KBDiagnostics.endGlideFinal(finalSignpost,
					milliseconds: (ProcessInfo.processInfo.systemUptime - finalStarted) * 1_000)
			}
			func deliver(_ w: String?, _ alts: [String]) { DispatchQueue.main.async { completion(w, alts) } }
			guard let self else { return deliver(nil, []) }
			self.initializationGroup.wait()
			guard let ld = self.lexicon.languageDataSnapshot(),
				  let g = GlidePreprocess.run(path, layout: layout, times: times.isEmpty ? nil : times)
			else { return deliver(nil, []) }
			guard let result = self.decodeGlide(g, lang: ld, context: context) else {
				deliver(nil, [])
				KBDiagnostics.logGlide(points: g.points.count, pivots: g.pivots.count, letters: "rejected")
				return
			}
			// The same stable n-gram tier used by previews ranks the final shape candidates.
			// No model load or second semantic tier can alter the word at release time.
			let cands = result.candidates
			let scored = result.scored
			let winner = scored[0].word
			let alts = scored.dropFirst().prefix(3).map(\.word)
			// #6 COMMIT CONFIDENCE = the reranked top-1/top-2 margin. A tiny margin means the two
			// best words are near-tied — exactly where auto-commit guesses wrong — so it is logged
			// and captured; the runner-up is already one tap away on the bar and one backspace wipes
			// the whole glided word, so a low-confidence commit is cheap to correct.
			let margin = scored.count >= 2 ? scored[0].s - scored[1].s : Double.greatestFiniteMagnitude
			// Stash raw shape costs so an explicit alternative selection can provide a
			// supervised sample. An automatic commit is never treated as ground truth.
			let gestureID = self.noteGlideCommit(winner: winner,
				shapeCostByWord: Dictionary(cands.map { ($0.word, $0.cost) }, uniquingKeysWith: min))
			// Queue the visible insertion before diagnostics and optional capture formatting.
			// Those facilities must never add lift-to-insert latency.
			deliver(winner, Array(alts))
			KBDiagnostics.logGlide(points: g.points.count, pivots: g.pivots.count,
								   letters: ([winner] + alts).joined(separator: ","), margin: margin)
			// Offline calibration capture (debug flag): RAW grid path + timestamps so the fitter
			// can recover velocity, plus dwell letters and the commit margin.
			let rawGrid = path.map { p -> (Double, Double) in
				let gp = GlidePreprocess.toGrid(p, layout: layout); return (Double(gp.x), Double(gp.y))
			}
			KBDiagnostics.captureGlide(id: gestureID, path: rawGrid, times: times.map { Double($0) }, dwell: g.dwellKeys,
									   candidates: scored.prefix(3).map(\.word), committed: winner, margin: margin)
		}
	}

	private func logCachedGlide(_ prediction: GlidePrediction, path: [CGPoint], times: [TimeInterval],
							layout: GlideLayout, processed: ProcessedGlide, gestureID: String) {
		let displayed = [prediction.word] + prediction.alternatives
		KBDiagnostics.logGlide(points: processed.points.count, pivots: processed.pivots.count,
							   letters: displayed.joined(separator: ","), margin: prediction.margin)
		let rawGrid = path.map { point -> (Double, Double) in
			let grid = GlidePreprocess.toGrid(point, layout: layout)
			return (Double(grid.x), Double(grid.y))
		}
		KBDiagnostics.captureGlide(id: gestureID, path: rawGrid, times: times.map { Double($0) },
								   dwell: processed.dwellKeys, candidates: Array(displayed.prefix(3)),
								   committed: prediction.word, margin: prediction.margin)
	}

	/// #5 helper: how many of a word's DOUBLED letters the finger dwelled on. "hello" with a
	/// dwell at `l` → 1; "little" with dwells at `t` → 1. Positive evidence for the double.
	private func dwelledDoubles(_ word: String, _ dwell: Set<Character>) -> Int {
		let chars = Array(word.lowercased())
		var count = 0
		var i = 1
		while i < chars.count {
			if chars[i] == chars[i - 1], dwell.contains(chars[i]) { count += 1; i += 2 } else { i += 1 }
		}
		return count
	}

	// MARK: Per-user glide adaptation (#37) — supervision from the user's own verdict
	//
	// A committed glide leaves a stash of its candidates' raw SHAPE costs. The controller
	// then reports what the user did with it. Only tapping a different bar alternative
	// teaches the profile because that is the sole explicit label. Typing on or deleting
	// merely discards the pending sample. All of
	// these run WITHOUT the engine queue: `GlideProfile` is self-locked, the stash is behind
	// `glideLock`, so a verdict fired from the main thread is a couple of microseconds.

	private let glideLock = NSLock()
	private struct GlideOutcome {
		let id: String
		let winner: String
		let shapeCostByWord: [String: Double]
	}
	private var lastGlideOutcome: GlideOutcome?

	@discardableResult
	private func noteGlideCommit(winner: String, shapeCostByWord: [String: Double]) -> String {
		let id = UUID().uuidString
		glideLock.lock()
		lastGlideOutcome = GlideOutcome(id: id, winner: winner, shapeCostByWord: shapeCostByWord)
		glideLock.unlock()
		return id
	}
	private func takeGlideOutcome() -> GlideOutcome? {
		glideLock.lock(); defer { lastGlideOutcome = nil; glideLock.unlock() }; return lastGlideOutcome
	}

	/// Typing on is not proof that the automatic winner was intended. Discard the
	/// pending sample without adapting; only an explicit alternative supplies a label.
	func glideUnverified() { _ = takeGlideOutcome() }
	/// The user swapped the glided word for a bar alternative — THAT word is the true one,
	/// so its shape cost is the correct sample (the winner was a near-miss the σ/gate should
	/// learn to rank better next time).
	func glideCorrected(to word: String) {
		guard let o = takeGlideOutcome() else { return }
		KBDiagnostics.captureGlideLabel(id: o.id, intended: word.lowercased())
		guard let cost = o.shapeCostByWord[word.lowercased()] else { return }
		glideProfile.observeCorrect(cost: cost)
		KBDiagnostics.logGlideAdapt(kind: "correct", cost: cost, profile: glideProfile)
	}
	/// The user backspaced the whole glided word away. We don't know what they meant, so the
	/// cost statistics stay put; we only drop the stash so a later verdict can't double-count.
	func glideRejected() { _ = takeGlideOutcome() }

	// MARK: Suggestions (background; also precomputes the autocorrect decision)

	/// Fast typing queues several passes on the serial engine queue; without a ticket each
	/// would run its full search even when a newer keystroke had already superseded it
	/// (staleness was only detected in the main-thread callback, after the work was spent).
	/// Ticket outside, check inside: a pass that is no longer the newest returns before
	/// doing anything — this coalescing is WHY the queue can stay serial without backlog.
	/// NSLock, not the engine queue, guards the counter — the increment happens on the
	/// caller's thread.
	private let genLock = NSLock()
	private var suggestGen = 0
	private func isLatest(_ gen: Int) -> Bool { genLock.lock(); defer { genLock.unlock() }; return gen == suggestGen }
	func cancelSuggestions() { genLock.lock(); suggestGen &+= 1; genLock.unlock() }

	/// Targeted spatial alignment between two fixed strings using the same per-character
	/// cost table as the trie DP, so injected candidates compare directly in ranking.
	/// O(n·m) where n = typed length, m = target length — fast enough to call per word.
	private func spatialCost(typed t: String, target g: String, taps: [KeyTap?]? = nil) -> Double {
		let tb = Array(t.utf8), gb = Array(g.utf8)
		let n = tb.count, m = gb.count
		let gap = 1.6   // insertion / deletion — matches the trie DP
		var prev = (0...m).map { Double($0) * gap }
		var curr = [Double](repeating: 0, count: m + 1)
		for i in 1...n {
			curr[0] = Double(i) * gap
			let tap: KeyTap?
			if let ts = taps, i - 1 < ts.count { tap = ts[i - 1] } else { tap = nil }
			for j in 1...m {
				let sub = prev[j - 1] + KB.subCost(gb[j - 1], typed: tb[i - 1], tap: tap)
				// Skipping a target apostrophe the user omitted is cheap — same discount
				// as the trie DPs, so injected candidates compare on the same scale.
				let skip = gb[j - 1] == KB.apostrophe ? KB.apostropheSkipCost : gap
				curr[j] = min(sub, min(prev[j] + gap, curr[j - 1] + skip))
			}
			swap(&prev, &curr)
		}
		return prev[m]
	}

	/// Context injection lets likely n-gram successors enter the spatial candidate set,
	/// then the spatial model validates
	/// them against the typed string. Surfaces candidates the fixed-radius trie DP misses
	/// when input is heavily corrupted — e.g. "coeevitjkn" → "correction" after "auto"
	/// (spatial cost ~9.7, far above the normal trie budget of 3.6).
	///
	/// Two-tier spatial gate:
	///  • Strict (budget 2×): cost ≤ budget → use actual spatial cost.
	///  • Loose (long words only): first OR last character matches + length within 3 →
	///    include at max-budget cost. The LM margin gate (typed OOV ≈ −18 vs predicted
	///    word in context ≈ −7) provides the safety filter; no spatial budget needed when
	///    the LM signal is this decisive.
	private func contextInjectedCandidates(typed lw: String, context: [String],
	                                        taps: [KeyTap?]? = nil) -> [Candidate] {
		guard lw.count >= 4, !context.isEmpty else { return [] }
		let budget = maxCost(for: lw.count) * 2.0

		let allWords = ngram.nextWords(context: context, limit: 32)

		// --- Spatial validation ---
		var out: [Candidate] = []
		for word in allWords {
			guard !lexicon.isProfane(word) else { continue }
			guard abs(lw.count - word.count) <= 3 else { continue }
			let cost = spatialCost(typed: lw, target: word, taps: taps)
			if cost <= budget {
				out.append(Candidate(word: word, cost: cost, logFreq: lexicon.logFreq(of: word) ?? 0))
			} else if lw.count >= 8, lw.first == word.first || lw.last == word.last {
				// Heavily corrupted long word: spatial cost exceeds any reasonable budget,
				// but the LM margin (OOV typed vs context-predicted word) is decisive.
				// Assign max-budget cost so only a strong LM win can fire the correction.
				out.append(Candidate(word: word, cost: budget, logFreq: lexicon.logFreq(of: word) ?? 0))
			}
		}
		return out
	}

	private func tenglishToTeluguSnapshot(for request: DecodeRequest) -> DecodeSnapshot {
		let currentWord = request.currentWord
		if currentWord.isEmpty {
			let predictions = teluguLexicon.suggestions(prefix: "",
				context: request.context, limit: 8)
				.filter { !lexicon.isProfane($0) }
			let evidence = predictions.map {
				DecodeCandidateEvidence(word: $0, score: 0, spatialCost: 0,
					logFrequency: 0, logLanguageProbability: 0,
					source: .completion, typedWordMargin: 0)
			}
			return DecodeSnapshot(request: request,
				suggestions: Array(predictions.prefix(3)), candidates: evidence,
				correction: nil, confidence: 0, nextCharacterPriors: [:],
				modelTier: .ngram,
				completedAtUptime: ProcessInfo.processInfo.systemUptime)
		}
		let candidates = transliterator.candidates(for: currentWord.lowercased(),
			context: request.context, limit: 16)
			.filter { !lexicon.isProfane($0.text) }
			.sorted {
				$0.score + teluguLexicon.contextBonus(for: $0.text, context: request.context)
					- lexicon.safetyPenalty($0.text)
					> $1.score + teluguLexicon.contextBonus(for: $1.text, context: request.context)
						- lexicon.safetyPenalty($1.text)
			}
		var suggestions: [String] = []
		if let primary = candidates.first { suggestions.append(primary.text) }
		if !currentWord.isEmpty { suggestions.append(currentWord) }
		for candidate in candidates.dropFirst() where !suggestions.contains(candidate.text) {
			suggestions.append(candidate.text)
		}
		suggestions = Array(suggestions.prefix(3))
		let primary = candidates.first
		let decision = primary.flatMap {
			$0.fromLexicon && $0.confidence >= 0.90 ? $0.text : nil
		}
		let evidence = candidates.map {
			let score = $0.score + teluguLexicon.contextBonus(for: $0.text,
				context: request.context)
			return DecodeCandidateEvidence(word: $0.text, score: score,
				spatialCost: 0, logFrequency: 0,
				logLanguageProbability: score,
				source: $0.fromLexicon ? .transliterationLexicon
					: .transliterationComposition,
				typedWordMargin: score)
		}
		return DecodeSnapshot(request: request, suggestions: suggestions,
			candidates: evidence, correction: decision,
			confidence: primary?.confidence ?? 0, nextCharacterPriors: [:],
			modelTier: .ngram,
			completedAtUptime: ProcessInfo.processInfo.systemUptime)
	}

	private func romanTeluguSnapshot(for request: DecodeRequest) -> DecodeSnapshot {
		let currentWord = request.currentWord.lowercased()
		let candidates = (currentWord.isEmpty
			? transliterator.romanPredictions(context: request.context, limit: 8)
			: transliterator.romanCandidates(for: currentWord, limit: 8))
			.filter { !lexicon.isProfane($0.text) }
			.sorted {
				$0.score + transliterator.romanContextBonus(
					for: $0.text, context: request.context)
				> $1.score + transliterator.romanContextBonus(
					for: $1.text, context: request.context)
			}
		var suggestions = currentWord.isEmpty ? [] : [currentWord]
		for candidate in candidates where !suggestions.contains(candidate.text) {
			suggestions.append(candidate.text)
		}
		let evidence = candidates.map {
			let score = $0.score + transliterator.romanContextBonus(
				for: $0.text, context: request.context)
			return DecodeCandidateEvidence(word: $0.text, score: score,
				spatialCost: 0, logFrequency: $0.score,
				logLanguageProbability: score - $0.score, source: .completion,
				typedWordMargin: score)
		}
		return DecodeSnapshot(request: request, suggestions: Array(suggestions.prefix(3)),
			candidates: evidence, correction: nil,
			confidence: candidates.first?.confidence ?? 0, nextCharacterPriors: [:],
			modelTier: .ngram,
			completedAtUptime: ProcessInfo.processInfo.systemUptime)
	}

	/// Tenglish exact lookup is a bounded memory-mapped binary search. It is the only
	/// synchronous boundary fallback, preventing a fast space from outrunning the
	/// asynchronous preview without ever putting English/neural work on the main thread.
	func immediateBoundarySnapshot(_ request: DecodeRequest) -> DecodeSnapshot? {
		guard !request.currentWord.isEmpty else { return nil }
		switch request.languageMode {
		case .tenglishToTelugu: return tenglishToTeluguSnapshot(for: request)
		case .romanTelugu: return romanTeluguSnapshot(for: request)
		case .english, .telugu: return nil
		}
	}

	/// Returns the current word's retained static search state. The first four letters
	/// continue through the exact full-trie implementation because short-word root
	/// penalties and budgets deliberately differ; from length five onward the retained
	/// state is complete for the normal production radius.
	private func retainedDecodeSession(for request: DecodeRequest, word: String,
		taps: [KeyTap?]?) -> IncrementalDecodeSession? {
		let bytes = Array(word.utf8)
		guard request.languageMode == .english, bytes.count >= 5,
			let first = bytes.first else { return nil }
		let session: IncrementalDecodeSession
		if let active = incrementalDecodeSession,
			active.id == request.wordSessionID,
			active.layoutRevision == request.layoutRevision,
			active.session.typed.first == nil || active.session.typed.first == first {
			session = active.session
		} else {
			guard let created = lexicon.makeIncrementalDecodeSession(
				typedFirst: first, firstTap: taps?.first ?? nil) else { return nil }
			incrementalDecodeSession = (request.wordSessionID,
				request.layoutRevision, created)
			session = created
		}
		guard session.advance(to: word, taps: taps) else {
			incrementalDecodeSession = nil
			return nil
		}
		return session
	}

	func decode(_ request: DecodeRequest, completion: @escaping (DecodeSnapshot) -> Void) {
		genLock.lock(); suggestGen &+= 1; let gen = suggestGen; genLock.unlock()
		let started = ProcessInfo.processInfo.systemUptime
		// A decode with no partial word is a fresh word start — it builds the context /
		// prediction search space (Gboard's UpdateLM). Time it separately as initialization
		// latency, in addition to the ordinary tap-decode histogram.
		let isWordStart = request.currentWord.isEmpty
		let signpost = KBDiagnostics.beginTapDecode()
		queue.async { [weak self] in
			defer {
				let ms = (ProcessInfo.processInfo.systemUptime - started) * 1_000
				KBDiagnostics.endTapDecode(signpost, milliseconds: ms)
				if isWordStart { KBDiagnostics.recordInitializationLatency(milliseconds: ms) }
			}
			guard let self, self.isLatest(gen) else { return }   // superseded — the newest pass delivers
			KBDiagnostics.recorder.sample()   // cheap footprint/headroom probe, background only
			let currentWord = request.currentWord
			let context = request.context
			let lw = currentWord.lowercased()
			let taps = request.languageMode == .english
				? self.touchProfile.adjusted(request.taps, typed: lw) : nil
			if request.languageMode == .tenglishToTelugu {
				guard self.isLatest(gen) else { return }
				let snapshot = self.tenglishToTeluguSnapshot(for: request)
				DispatchQueue.main.async { completion(snapshot) }
				return
			}
			if request.languageMode == .romanTelugu {
				guard self.isLatest(gen) else { return }
				let snapshot = self.romanTeluguSnapshot(for: request)
				DispatchQueue.main.async { completion(snapshot) }
				return
			}
			if request.languageMode == .telugu {
				// Native Telugu Beta is deliberately completion-only. No English score or
				// correction decision is allowed to rewrite a Telugu grapheme.
				let suggestions = self.teluguLexicon.suggestions(prefix: currentWord,
					context: context, limit: 8).filter {
						$0 == currentWord || !self.lexicon.isProfane($0)
					}.sorted { lhs, rhs in
						let lhsTyped = lhs == currentWord
						let rhsTyped = rhs == currentWord
						if lhsTyped != rhsTyped { return lhsTyped }
						return self.lexicon.safetyPenalty(lhs) < self.lexicon.safetyPenalty(rhs)
					}.prefix(3)
				let evidence = suggestions.map {
					DecodeCandidateEvidence(word: $0, score: 0, spatialCost: 0,
						logFrequency: 0, logLanguageProbability: 0,
						source: .completion, typedWordMargin: 0)
				}
				let snapshot = DecodeSnapshot(request: request,
						suggestions: Array(suggestions), candidates: evidence,
					correction: nil, confidence: 0, nextCharacterPriors: [:],
					modelTier: .ngram,
					completedAtUptime: ProcessInfo.processInfo.systemUptime)
				DispatchQueue.main.async { completion(snapshot) }
				return
			}
			let publishEnglish: ([String], [DecodeCandidateEvidence], String?, Double,
				DecodeModelTier) -> Void = { suggestions, evidence, decision, confidence, tier in
				let priors = self.contextualCharPriors(evidence: evidence, prefix: lw,
					base: self.lexicon.nextCharPriors(prefix: lw))
				guard self.isLatest(gen) else { return }
				let snapshot = DecodeSnapshot(request: request, suggestions: suggestions,
					candidates: evidence, correction: decision, confidence: confidence,
					nextCharacterPriors: priors, modelTier: tier,
					completedAtUptime: ProcessInfo.processInfo.systemUptime)
				DispatchQueue.main.async { completion(snapshot) }
			}

			if currentWord.isEmpty {
				let next = self.nextWords(context: context)
				let candidates = next.map {
					Candidate(word: $0.lowercased(), cost: 0,
						logFreq: self.lexicon.logFreq(of: $0.lowercased()) ?? 0)
				}
				self.rank(candidates, context: context, request: request, generation: gen,
					frequencyMode: .compressed) { outcome in
					guard let (ranked, tier) = outcome else { return }
					let words = ranked.prefix(3).map(\.word)
					publishEnglish(words, [], nil, 0, tier)
				}
				return
			} else {
				// One fuzzy search per keystroke: the corrections feed BOTH the suggestion
				// ranking and the precomputed autocorrect decision below (previously the
				// trie DP ran twice — once here, once inside computeCorrection).
				let normalCost = self.maxCost(for: lw.count)
				// NN-LM in the trie: the words the LM expects next fund extra edit budget
				// along their prefixes, so a context-plausible word just outside the base
				// radius is GENERATED (recall). Applied ONLY to the recovery walk below —
				// the close search stays pure-channel so a good spatial match ("sebd"→"send")
				// is never dragged to an LM-plausible neighbour ("see"); the recovery pool
				// already rides the channel-dominance guards that keep the rescue honest.
				let searchPrior = self.contextSearchPrior(context)
				let retained = self.retainedDecodeSession(for: request, word: lw,
					taps: taps)
				let corrections: [Candidate]
				if let retained {
					corrections = retained.candidates(maxCost: normalCost)
						+ self.lexicon.mutableCorrections(for: lw,
							maxCost: normalCost, taps: taps)
				} else {
					corrections = self.lexicon.corrections(for: lw,
						maxCost: normalCost, taps: taps,
						shouldCancel: { [weak self] in self?.isLatest(gen) != true })
				}
				// Exit before context expansion if a newer key or Glide superseded this pass.
				guard self.isLatest(gen) else { return }
				// Context injection: n-gram successors validated
				// spatially. Finds candidates the fixed-radius trie DP misses when input is
				// heavily corrupted (e.g. "coeevitjkn" → "correction" after "auto").
				let injected = self.contextInjectedCandidates(typed: lw, context: context, taps: taps)
				let completions = self.lexicon.completions(prefix: lw,
					limit: self.completionCandidateLimit)
				// Candidate recovery cannot depend on the close search returning zero: a
				// plausible-but-wrong neighbour is exactly what hid severe intended words in
				// the old decoder. Escalate an OOV only when it has no prefix completions and
				// close evidence is absent or weak. Cooperative cancellation keeps an older
				// wide walk from building a queue while the user continues typing.
				let closestCost = corrections.map(\.cost).min() ?? .infinity
				let shouldRecover = lw.count >= 6 && !self.lexicon.contains(lw)
					&& completions.isEmpty
					&& (lw.count >= 8 || corrections.isEmpty || closestCost > 0.65)
				let broadCorrections: [Candidate] = shouldRecover
					? Array(
						(retained?.candidates(maxCost: normalCost * 2.0)
							?? self.lexicon.broadCorrections(for: lw,
								maxCost: normalCost * 2.0, taps: taps, prior: searchPrior,
								shouldCancel: { [weak self] in self?.isLatest(gen) != true }))
							.sorted {
								let lhs = $0.cost - 0.12 * $0.logFreq
								let rhs = $1.cost - 0.12 * $1.logFreq
								return lhs == rhs ? $0.word < $1.word : lhs < rhs
							}
							.prefix(24)
					  )
					: []
				// Channel-dominance guard: any match inside the NORMAL budget caps how
				// far the loose pools may reach — they exist for when the normal search
				// fails, not to leapfrog it ("could possibly" at spatial cost 7.2 must
				// not beat "definitely" at 2.0). `closestCost` is ∞ when the close
				// search found nothing, leaving the rescue path unrestricted.
				let looseCostCeiling = closestCost <= normalCost
					? closestCost + self.looseCandidateWindow : .infinity
				let admittedBroad = broadCorrections.filter { $0.cost <= looseCostCeiling }
				let correctionWords = Set((corrections + admittedBroad).map(\.word))
				let newFromContext = injected.filter {
					!correctionWords.contains($0.word) && $0.cost <= looseCostCeiling
				}
				let allCorrections = corrections + admittedBroad + newFromContext
				// Injected and broad candidates don't share the typed prefix — they only appear
				// in the bar when there are no completions (pure correction mode). The LM
				// ranking naturally suppresses weak candidates that don't fit context.
				var correctionSuggestions = completions.isEmpty
					? corrections.filter { $0.cost <= self.suggestionCorrectionMaxCost } + admittedBroad + newFromContext
					: corrections.filter { $0.word.hasPrefix(lw) }
				// Contraction sibling — "its" → "it's", "cant" → "can't". A real typed word
				// never reaches the OOV apostrophe-restoration branch, "it's" is no trie
				// completion of "its" (the apostrophe branches at "it"), and the hasPrefix
				// filter above drops it from corrections — so without this the bar can never
				// offer the contraction. Cheap channel cost: the letters page has no ' key,
				// so the missing apostrophe is a layout gap, not a typo.
				if lw.count >= 2, let restored = self.lexicon.apostropheRestoration(of: lw),
				   !correctionSuggestions.contains(where: { $0.word == restored }) {
					correctionSuggestions.append(Candidate(word: restored, cost: Self.apostropheCost,
														   logFreq: self.lexicon.logFreq(of: restored) ?? 0))
				}
				// Exit before ranking if Glide or a newer key took ownership.
				guard self.isLatest(gen) else { return }
				let split = self.splitCandidate(of: lw)
				var scoringCandidates = completions + correctionSuggestions + allCorrections
				if let split { scoringCandidates.append(split.candidate) }
				// The typed row is always present, including for a real dictionary word.
				// Using its shipped frequency fixes the old real-word gate, which compared
				// candidates against a typed row whose frequency was incorrectly near zero.
				let typedFrequency = self.lexicon.logFreq(of: lw)
					?? log(Double(self.user.uniCount(lw)) + 1)
				let typed = Candidate(word: lw, cost: 0, logFreq: typedFrequency)
				let closeWords = Set(corrections.map(\.word))
				let broadWords = Set(admittedBroad.map(\.word))
				let contextWords = Set(newFromContext.map(\.word))
				let completionWords = Set(completions.map(\.word))
				var displayWords = Set((completions + correctionSuggestions).map(\.word))
				if let split { displayWords.insert(split.candidate.word) }
				self.rank(scoringCandidates, including: typed, context: context,
					request: request, generation: gen, log: "decode '\(lw)'",
					frequencyMode: .compressed) { outcome in
					guard let (ranked, tier) = outcome else { return }
					var result = ranked.filter { displayWords.contains($0.word) }.prefix(3)
						.map(\.word)
					let typedScore = ranked.first(where: { $0.word == lw })?.score ?? 0
					func source(for word: String) -> DecodeCandidateSource {
						if word == lw { return .typed }
						if split?.candidate.word == word { return .splitCorrection }
						if closeWords.contains(word) { return .fuzzyLexicon }
						if contextWords.contains(word) { return .contextInjection }
						if broadWords.contains(word) { return .broadRecovery }
						if completionWords.contains(word) { return .completion }
						return .fuzzyLexicon
					}
					let evidence = ranked.prefix(self.nBest).map {
						DecodeCandidateEvidence(word: $0.word,
							score: $0.score, spatialCost: $0.spatialCost,
							logFrequency: $0.logFrequency,
							logLanguageProbability: $0.logLanguageProbability,
							neuralLogProbability: $0.neuralLogProbability,
							source: source(for: $0.word),
							typedWordMargin: $0.score - typedScore)
					}
					let decision: String?
					let decisionConfidence: Double
					if currentWord == lw, Self.iForms.contains(lw) {
						decision = lw
						decisionConfidence = 100
					} else {
						var correctionCosts: [String: Double] = [:]
						for candidate in allCorrections {
							correctionCosts[candidate.word] = min(
								correctionCosts[candidate.word] ?? .infinity,
								candidate.cost)
						}
						if let split { correctionCosts[split.candidate.word] = split.candidate.cost }
						let broadRecoveryWords = broadWords.subtracting(closeWords)
						let resolved = self.correction(from: ranked,
							correctionCosts: correctionCosts, typed: lw,
							context: context, split: split,
							looseWords: broadWords.union(contextWords)
								.subtracting(closeWords),
							broadRecoveryWords: broadRecoveryWords)
						decision = resolved.word
						decisionConfidence = resolved.margin
					}
					// The center suggestion and boundary decision are one contract.
					if let decision {
						result.removeAll { $0.caseInsensitiveCompare(decision) == .orderedSame }
						result.insert(decision, at: 0)
					} else if !result.contains(where: {
						$0.caseInsensitiveCompare(currentWord) == .orderedSame
					}) {
						if result.count >= 3 { result[2] = currentWord }
						else { result.append(currentWord) }
					}
					publishEnglish(Array(result.prefix(3)), evidence, decision,
						decisionConfidence, tier)
				}
				return
			}
		}
	}

	/// Compatibility wrapper for tests and non-controller callers. Production typing
	/// uses the versioned `decode` contract above.
	func suggestions(currentWord: String, context: [String], taps: [KeyTap?]? = nil,
					 completion: @escaping ([String], [Character: Double]) -> Void) {
		let request = DecodeRequest(fieldRevision: 0, documentRevision: 0,
			wordSessionID: 0, generation: 0, layoutRevision: 0,
			currentWord: currentWord, context: context, taps: taps)
		decode(request) { completion($0.suggestions, $0.nextCharacterPriors) }
	}

	/// iOS supplementary lexicon (contact names, text-replacement shortcuts): make
	/// these words first-class citizens — suggestable and immune to autocorrect —
	/// exactly how stock stops "mangling" names. Modest frequency: context counts,
	/// not the freq term, should surface them.
	func importSupplementaryLexicon(_ words: [String]) {
		queue.async { [weak self] in
			guard let self else { return }
			for w in words {
				let lw = w.lowercased()
				guard lw.count >= 2, lw.allSatisfy({ $0.isLetter || $0 == "'" }),
					  !self.lexicon.contains(lw), self.lexicon.isSafeToLearn(lw) else { continue }
				self.lexicon.insert(lw, freq: 50)
			}
		}
	}

	func learn(context: [String], word: String) {
		let lw = word.lowercased()
		// ≥2 chars, or the only real one-letter words. Single letters must never learn
		// or adopt: contraction fragments ("what's" split at an unrecognized quote used
		// to commit "s"/"t" as words) would otherwise flood suggestions after 5 uses.
		guard lw.count >= 2 || lw == "a" || lw == "i",
			  lw.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
		if !lexicon.isSafeToLearn(lw) { return }
		let ctx = context.map { $0.lowercased() }
		queue.async { [weak self] in
			guard let self else { return }
			self.user.learn(context: ctx, word: lw)
			self.user.pruneIfNeeded()
			let count = self.user.uniCount(lw)
			self.lexicon.noteUse(of: lw, timesUsed: count, adoptAfter: self.adoptAfter,
				allowAdoption: self.allowsPersonalAdoption(of: lw, count: count))
			self.scheduleSave()
		}
	}

	/// Learn only from a literal, accepted static word. Autocorrections and suggestion
	/// replacements are excluded because their intended per-letter alignment is unknown.
	func learnTouchProfile(word: String, taps: [KeyTap?]) {
		let lower = word.lowercased()
		guard lower.utf8.count == taps.count,
			  lower.utf8.allSatisfy({ KB.pos[$0] != nil }) else { return }
		queue.async { [weak self] in
			guard let self, self.lexicon.isStaticWord(lower),
				  self.lexicon.isSafeToLearn(lower) else { return }
			self.touchProfile.observe(word: lower, taps: taps)
		}
	}

	/// Unknown spellings enter the searchable trie only after meaningful evidence.
	/// A user-confirmed spelling may graduate at the normal threshold. Otherwise it
	/// needs use in multiple contexts (or twice the normal count) and must not be a
	/// one-edit neighbour of a shipped word. This keeps repeated fat-finger errors out
	/// of completions without preventing genuinely novel vocabulary from adapting.
	private func allowsPersonalAdoption(of word: String, count: Int) -> Bool {
		guard count >= adoptAfter else { return false }
		if lexicon.contains(word) { return true }
		if user.spellingConfirmationCount(word) > 0 { return true }
		guard user.contextDiversity(for: word) >= 2 || count >= adoptAfter * 2 else { return false }
		return !lexicon.corrections(for: word, maxCost: 1.05).contains {
			$0.word != word && $0.cost <= 1.05 && lexicon.isStaticWord($0.word)
		}
	}

	// MARK: Ranking — the blend of channel, prior, personalization, and frequency

	/// Dedupes (keeping each word's cheapest channel cost), drops blocked words, then
	private enum FrequencyMode { case raw, compressed }

	private func frequencyTerm(_ logFreq: Double, mode: FrequencyMode) -> Double {
		switch mode {
		case .raw:
			return logFreq
		case .compressed:
			return log1p(max(logFreq, 0))
		}
	}

	/// Blends one batched prior call with the channel cost and lexicon frequency:
	///   final = -spatialCost + lmWeight·logP(w|ctx) + freqWeight·logFreq
	/// Suggestion ranking uses a compressed frequency term; correction ranking keeps
	/// raw frequency so the calibrated autocorrect gates remain stable.
	/// Runs only on the serial decoder queue.
	/// `extra` (the margin gate's typed-word row) is exempt from the profanity filter
	/// and the cap: it must always come back scored.
	private func rankNgram(_ cands: [Candidate], including extra: Candidate? = nil,
						  context: [String], log label: String? = nil,
						  frequencyMode: FrequencyMode = .raw) -> [RankedCandidate] {
		var best: [String: Candidate] = [:]
		for c in cands where c.word == extra?.word || !lexicon.isProfane(c.word) {
			if let cur = best[c.word], cur.cost <= c.cost { continue }
			best[c.word] = c
		}
		if let extra { best[extra.word] = extra }
		guard !best.isEmpty else { return [] }
		var list = Array(best.values)
		// Bound long candidate tails before one batched n-gram lookup. With an `extra`
		// typed row, keep one slot free so confidence always compares against the input.
		let cap = extra == nil ? scoreCap : scoreCap - 1
		if list.count > cap {
			list.sort {
				(-$0.cost + freqWeight * frequencyTerm($0.logFreq, mode: frequencyMode))
					> (-$1.cost + freqWeight * frequencyTerm($1.logFreq, mode: frequencyMode))
			}
			list = Array(list.prefix(cap))
		}
		if let extra {
			list.removeAll { $0.word == extra.word }
			list.append(extra)
		}
		let doLog = label != nil && KBDiagnostics.verbose
		let t0 = doLog ? Date() : nil
		let priors = ngram.logProbs(list.map(\.word), context: context)
		let scored = zip(list, priors)
			.map { candidate, prior in
				RankedCandidate(
					word: candidate.word,
					score: -candidate.cost - (candidate.word == extra?.word
						? 0 : lexicon.safetyPenalty(candidate.word)) + lmWeight * prior
						+ freqWeight * frequencyTerm(candidate.logFreq, mode: frequencyMode),
					spatialCost: candidate.cost,
					logFrequency: candidate.logFreq,
					logLanguageProbability: prior,
					neuralLogProbability: nil
				)
			}
			.sorted { $0.score > $1.score }
		if doLog, let label {
			let ms = t0.map { Date().timeIntervalSince($0) * 1000 } ?? 0
			var rows: [KBDiagnostics.RankRow] = []
			for (i, c) in list.enumerated() {
				let freqTerm = frequencyTerm(c.logFreq, mode: frequencyMode)
					let safetyPenalty = c.word == extra?.word ? 0 : lexicon.safetyPenalty(c.word)
					rows.append(.init(word: c.word, cost: c.cost + safetyPenalty, logFreq: c.logFreq,
									  freqTerm: freqTerm,
									  ngram: priors[i],
									  score: -c.cost - safetyPenalty + lmWeight * priors[i]
										+ freqWeight * freqTerm))
			}
			rows.sort { $0.score > $1.score }
			KBDiagnostics.logRanking(label: label, context: context, rows: rows, ms: ms)
		}
		return scored
	}

	/// Produces one authoritative ranking for the tier frozen into `request`. Neural
	/// scoring is asynchronous and never blocks either host insertion or the serial
	/// decoder queue. A failed neural session publishes no replacement snapshot; it
	/// cannot silently change ranking semantics to n-gram halfway through a word.
	private func rank(_ cands: [Candidate], including extra: Candidate? = nil,
					  context: [String], request: DecodeRequest, generation: Int,
					  log label: String? = nil,
					  frequencyMode: FrequencyMode = .raw,
					  completion: @escaping (([RankedCandidate], DecodeModelTier)?) -> Void) {
		let ngramRows = rankNgram(cands, including: extra, context: context,
			log: label, frequencyMode: frequencyMode)
		guard request.requestedModelTier != .ngram else {
			completion((ngramRows, .ngram))
			return
		}
		guard request.languageMode == .english,
			  let neuralPrior,
			  neuralPrior.modelTier == request.requestedModelTier,
			  !ngramRows.isEmpty else {
			// NEURAL_DEBUG_TELEMETRY_REMOVE
			#if DEBUG || INTERNAL_NEURAL
			if neuralPrior == nil {
				KBDiagnostics.recordNeuralState(tier: request.requestedModelTier,
					ready: false, state: "not-configured")
			}
			#endif
			completion(nil)
			return
		}

		if preparedNeuralSession?.id != request.wordSessionID
			|| preparedNeuralSession?.context != context {
			if let previous = preparedNeuralSession {
				neuralPrior.discardSession(previous.id)
			}
			neuralPrior.prepareContext(context, wordSessionID: request.wordSessionID)
			preparedNeuralSession = (request.wordSessionID, context)
		}

		let words = ngramRows.map(\.word)
		neuralPrior.score(candidates: words, wordSessionID: request.wordSessionID) {
			[weak self] result in
			guard let self else { return }
			self.queue.async {
				guard self.isLatest(generation) else {
					completion(nil)
					return
				}
				guard case .success(let probabilities) = result else {
					// The prior owns and publishes the concrete failure state/detail.
					completion(nil)
					return
				}
				var rescored: [RankedCandidate] = []
				rescored.reserveCapacity(ngramRows.count)
				for row in ngramRows {
					guard let neural = probabilities[row.word], neural.isFinite else {
						// NEURAL_DEBUG_TELEMETRY_REMOVE
						#if DEBUG || INTERNAL_NEURAL
						KBDiagnostics.recordNeuralState(tier: request.requestedModelTier,
							ready: neuralPrior.isReady, state: "incomplete-score-result",
							detail: "Core ML omitted a score for \(row.word)")
						#endif
						completion(nil)
						return
					}
					let prior = 0.7 * neural + 0.3 * row.logLanguageProbability
					let isTypedRow = row.word == request.currentWord.lowercased()
					let score = -row.spatialCost
						- (isTypedRow ? 0 : self.lexicon.safetyPenalty(row.word))
						+ self.lmWeight * prior
						+ self.freqWeight * self.frequencyTerm(row.logFrequency,
							mode: frequencyMode)
					rescored.append(RankedCandidate(word: row.word, score: score,
						spatialCost: row.spatialCost, logFrequency: row.logFrequency,
						logLanguageProbability: row.logLanguageProbability,
						neuralLogProbability: neural))
				}
				rescored.sort { $0.score > $1.score }
				// NEURAL_DEBUG_TELEMETRY_REMOVE
				#if DEBUG || INTERNAL_NEURAL
				let ngramRank = Dictionary(uniqueKeysWithValues:
					ngramRows.enumerated().map { ($0.element.word, $0.offset + 1) })
				let ngramByWord = Dictionary(uniqueKeysWithValues:
					ngramRows.map { ($0.word, $0) })
				let telemetryRows = rescored.enumerated().compactMap { index, row
					-> KBDiagnostics.NeuralRankRowSnapshot? in
					guard let baseline = ngramByWord[row.word],
						  let baselineRank = ngramRank[row.word],
						  let neural = row.neuralLogProbability else { return nil }
					return .init(word: row.word, ngramRank: baselineRank,
						finalRank: index + 1, spatialCost: row.spatialCost,
						ngramLogProbability: baseline.logLanguageProbability,
						neuralLogProbability: neural, ngramScore: baseline.score,
						finalScore: row.score)
				}
				KBDiagnostics.recordNeuralRanking(tier: request.requestedModelTier,
					typedWord: request.currentWord, context: context,
					wordSessionID: request.wordSessionID, rows: telemetryRows)
				#endif
				completion((rescored, request.requestedModelTier))
			}
		}
	}

	/// Context-conditioned trie search prior (NN-LM in the trie). The words the LM expects
	/// to come next fund extra edit budget along their prefixes inside the trie walk, so a
	/// context-plausible word just outside the fixed edit radius is generated. Empty context
	/// or no predictions → nil, which reproduces today's exact pure-channel search. Source is
	/// the shipped n-gram now; the GRU's next-word distribution is the drop-in upgrade — same
	/// search, richer prior. Must run on `queue`.
	private func contextSearchPrior(_ context: [String]) -> TrieSearchPrior? {
		guard !context.isEmpty else { return nil }
		let likely = ngram.nextWords(context: context, limit: 24)
		guard !likely.isEmpty else { return nil }
		let prior = TrieSearchPrior(likelyWords: likely)
		return prior.isEmpty ? nil : prior
	}

	/// Must run on `queue`.
	private func nextWords(context: [String]) -> [String] {
		// Never re-offer the word that was just committed — "the the" reads as a bug,
		// and stock never does it. (Legit doubles are rare and still typeable.)
		let last = context.last?.lowercased()
		var out: [String] = []
		for w in ngram.nextWords(context: context, limit: 8)
			where w != last && !out.contains(w) && !lexicon.isProfane(w) { out.append(w) }
		// Sparse personal or corpus contexts should not monopolize the bar. Fill any
		// remaining slots from the shipped sentence-start list, never personal unigrams.
		for w in lexicon.topWords where out.count < 3 && w.lowercased() != last && !out.contains(w) {
			out.append(w)
		}
		let final = Array(out.prefix(3))
		KBDiagnostics.logPredict(context: context, words: final, beam: 0, ngram: out.count)
		return final
	}
}

// MARK: - GlideProfile (#37): runtime per-user glide adaptation
//
// The glide decoder has two calibration knobs — σ (the rerank temperature that converts
// grid-distance into nats so the LM can arbitrate only genuinely close shapes) and the
// commit GATE (the best shape cost that still counts as "traced something"). Both were
// grid-searched OFFLINE on synthetic swipes (tools/glide_eval) and, with #36, re-fit to
// captured real strokes via calibrate.py. #37 moves that fitting ON DEVICE and makes it
// continuous: it watches the user's OWN glides and nudges σ and the gate toward their hand.
//
//   • A sloppy glider's correct swipes carry higher shape cost → the mean rises → the gate
//     rises (so those correct swipes keep committing instead of being rejected as "nothing
//     traced") and σ grows (so the LM/frequency terms stay comparable to the shape term).
//   • A precise glider's costs are low → the gate tightens (junk smears stop committing)
//     and σ shrinks (shape dominates, as it should when the trace is clean).
//
// Safety (the reason #37 waited on #36's real data — "adapt now and you adapt toward noise"):
//   1. Supervised ONLY. Statistics move only when the user explicitly picks a different
//      candidate, whose intended word and shape cost are known, never on automatic commits.
//   2. Warm-up blend. Until `warmup` supervised samples exist the returned σ/gate are exactly
//      the baked defaults; the adapted value ramps in linearly, so a first odd stroke moves
//      nothing and the keyboard is identical to today's on a fresh install.
//   3. Hard clamps. σ ∈ [0.06, 0.30], gate ∈ [0.30, 0.60] — the profile can refine the
//      decoder for a user but can never wander into a degenerate regime.
//
// Thread-safety: self-contained behind `lock`, so the engine reads σ/gate from the concurrent
// glide pass and feeds samples from the main thread without touching the engine queue. The
// tiny Codable state persists to the App Group so a user's tuning survives across sessions.

final class GlideProfile {
	/// Baked grid-searched defaults — identical to the constants glide shipped with.
	static let baseSigma = 0.10
	static let baseGate  = 0.43

	/// EWMA of the CORRECT-word shape cost, seeded near the synthetic-harness correct-cost
	/// distribution (mean ~0.22, var ~0.006) so early on-device samples blend smoothly.
	private nonisolated struct State: Codable {
		var epoch: UInt64?
		var n = 0
		var mean = 0.22
		var varc = 0.006
	}
	private var state = State(epoch: KBPersonalData.currentEpoch)
	private let lock = NSLock()

	private static let key = "kb.glideprofile"
	private static var store: UserDefaults { KBSettings.sharedDefaults }
	private static let io = DispatchQueue(label: "keyboard.glideprofile.io", qos: .utility)

	// Adaptation constants.
	private static let alpha  = 0.12                 // EWMA rate — slow; no single stroke dominates
	private static let warmup = 12.0                 // supervised samples before adapted fully replaces default
	private static let sigmaK = baseSigma / 0.22     // σ tracks the mean, anchored so mean 0.22 → baseSigma
	private static let gateK  = 2.7                  // gate sits ~2.7σ above the mean (≈ the offline p95 midpoint)

	func load() {
		let epoch = KBPersonalData.currentEpoch
		guard let d = Self.store.data(forKey: Self.key),
			  var s = try? JSONDecoder().decode(State.self, from: d),
			  (s.epoch ?? epoch) == epoch else {
			reset(to: epoch)
			return
		}
		s.epoch = epoch
		lock.lock(); state = s; lock.unlock()
	}
	private func persist(_ s: State) {
		Self.io.async {
			guard let epoch = s.epoch,
				  let d = try? JSONEncoder().encode(s) else { return }
			KBPersonalData.withExclusiveStoreLock {
				guard KBPersonalData.currentEpoch == epoch else { return }
				Self.store.set(d, forKey: Self.key)
			}
		}
	}
	private func snapshot() -> State { lock.lock(); defer { lock.unlock() }; return state }

	/// Feed a known-correct shape cost from an explicitly selected alternative.
	func observeCorrect(cost: Double) {
		guard cost.isFinite, cost >= 0 else { return }
		let epoch = KBPersonalData.currentEpoch
		let s: State = {
			lock.lock(); defer { lock.unlock() }
			if state.epoch != epoch { state = State(epoch: epoch) }
			let old = state.mean
			state.mean = (1 - Self.alpha) * state.mean + Self.alpha * cost
			// EWMA variance (Welford-style increment) — the spread the gate leaves headroom over.
			state.varc = (1 - Self.alpha) * state.varc + Self.alpha * (cost - old) * (cost - state.mean)
			state.n += 1
			return state
		}()
		persist(s)
	}

	func reset(to epoch: UInt64 = KBPersonalData.currentEpoch) {
		lock.lock()
		state = State(epoch: epoch)
		lock.unlock()
	}

	/// 0 until the first sample, ramping to 1 at `warmup` — how much of the adapted value shows.
	private func blend(_ n: Int) -> Double { min(1.0, Double(n) / Self.warmup) }

	/// Per-user rerank temperature. Larger for a sloppy hand (LM stays in play), smaller for a
	/// precise one (shape dominates). Clamped so it can refine but never degenerate.
	var sigma: Double {
		let s = snapshot()
		let adapted = Self.sigmaK * s.mean
		let v = Self.baseSigma + (adapted - Self.baseSigma) * blend(s.n)
		return min(0.30, max(0.06, v))
	}
	/// Per-user commit gate = mean correct cost + ~2.7·std, i.e. leave the same headroom over
	/// the user's own correct-cost spread that the offline p95/scribble midpoint left over the
	/// synthetic one. Clamped to a safe band around the baked 0.43.
	var gate: Double {
		let s = snapshot()
		let adapted = s.mean + Self.gateK * max(0, s.varc).squareRoot()
		let v = Self.baseGate + (adapted - Self.baseGate) * blend(s.n)
		return min(0.60, max(0.30, v))
	}

	/// For diagnostics / a future health-screen readout.
	var summary: (sigma: Double, gate: Double, samples: Int) { (sigma, gate, snapshot().n) }
}
