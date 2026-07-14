import Foundation

// Noisy-channel engine, v3 — restructured for the neural rescorer (Phase A).
//
// Pipeline:   Lexicon (trie = channel model) generates an N-best candidate list
//           → a LanguageScorer supplies the context prior in ONE batched call
//             (today: bundled n-grams; later: tiny neural LM behind the same seam)
//           → UserModel layers on-device personalization on top.
//
// Autocorrect decisions are precomputed by the debounced background pass while the
// word is still being typed, so the space key normally does an O(1) cache read; when
// the user out-types the debounce it computes an n-gram-only decision INLINE on the
// main thread (~1 ms, lock-safe, no queue hop) — a neural scorer (5–20 ms) must never
// run synchronously on the keystroke path, and the keystroke must never wait on the
// serial engine queue.
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
	/// with a concurrent queue every fast keystroke's pass ran its full trie DP + neural
	/// forward SIMULTANEOUSLY, exploding CPU/threads inside the jetsam-limited extension.
	/// Nothing on the KEYSTROKE path ever waits on this queue (see `autocorrection`).
	private let queue = DispatchQueue(label: "keyboard.engine")
	private let lexicon = Lexicon()
	private let user = UserModel()
	/// Eager `let`, NOT lazy: the main thread's fast-autocorrect path touches it, and a
	/// lazy var's first initialization racing the engine queue's init task is undefined.
	private let ngram: NgramScorer
	/// The active prior. When the neural rescorer lands it replaces (or blends with)
	/// `ngram` here — nothing else in the engine changes. Written once on the engine
	/// queue's init task; read only from the queue (the fast path uses `ngram` directly).
	private var scorer: LanguageScorer
	/// Direct handle for capabilities beyond the scorer seam (trie-constrained
	/// beam-search prediction). nil when the model files aren't bundled.
	private var neuralLM: NeuralScorer?

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
	private let adoptAfter = 5
	/// Candidates that survive to rescoring. Deliberately wider than the 3 shown:
	/// a neural rescorer's value is promoting words the crude score ranked 4th–12th.
	private let nBest = 12
	/// Max candidates handed to the prior in one call. Must be ≤ the neural model's
	/// exported Core ML batch limit (RangeDim(1, 16) in tools/lm/export_coreml.py) — over
	/// that, Core ML rejects the input. 16 comfortably covers the 12 kept.
	private let scoreCap = 16
	/// Autocorrect confidence gate: the best candidate must beat the TYPED string's
	/// blended score by this margin (natural-log units; 3 ≈ 20× more likely) before
	/// a correction fires. Genuine typos clear it by 8–15; slang/names that fit the
	/// context sit near 0 and survive uncorrected — no lexicon entry needed. Active
	/// only while the neural model is resident (`scorer.scoresArbitraryWords`).
	private let correctionMargin = 3.0
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
	/// Previous-word (n-1) rescue certainty (the "poler game → poker game" case). AFTER a
	/// word commits, the just-typed word becomes right-context evidence for the word before
	/// it; a single-edit neighbour must beat the standing word by this much — WITH that
	/// forward evidence — before we silently rewrite already-committed text. As strict as
	/// `realWordMargin` because this edits behind the cursor. Neural-only.
	private let prevWordMargin = 5.0

	/// The precomputed autocorrect decision for the word currently being typed, plus the
	/// session's correction rejections. BOTH are read on the SPACE-KEY path (main thread),
	/// so they live behind a tiny `stateLock` rather than the engine `queue`: a `queue.sync`
	/// here would block the keystroke behind whatever neural pass (suggestions, glide decode,
	/// n-1 rescue) is draining, which is exactly the "heavy keyboard" stall. The lock is held
	/// only for the microseconds it takes to read/copy this small state — never during a
	/// Core ML forward. All heavy work stays on `queue`; only these two fields are shared.
	private let stateLock = NSLock()
	private struct PendingCorrection { let word: String; let correction: String? }
	private var pending: PendingCorrection?          // guard with stateLock
	private var sessionKept = Set<String>()          // guard with stateLock

	private func readPending() -> PendingCorrection? { stateLock.lock(); defer { stateLock.unlock() }; return pending }
	private func setPending(_ p: PendingCorrection?) { stateLock.lock(); pending = p; stateLock.unlock() }
	private func clearPending(ifWord lw: String) { stateLock.lock(); if pending?.word == lw { pending = nil }; stateLock.unlock() }
	private func isKept(_ w: String) -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return sessionKept.contains(w) }
	private func keepInsert(_ w: String) { stateLock.lock(); sessionKept.insert(w); stateLock.unlock() }
	private func keepRemove(_ w: String) { stateLock.lock(); sessionKept.remove(w); stateLock.unlock() }

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

	init() {
		let ng = NgramScorer(user: user)
		ngram = ng
		scorer = ng
		queue.async { [weak self] in
			guard let self else { return }
			self.lexicon.loadFromBundle()
			self.ngram.attach(data: self.lexicon.langData,
							  resolveID: { [lexicon = self.lexicon] in lexicon.wordID($0) })
			self.user.load()
			self.glideProfile.load()          // #37: restore this user's adapted glide σ / gate
			self.applyLearned()
			// Tiered scorer — two levels, each overriding the previous on this serial queue.
			//
			// Tier 1 (UnigramScorer, ~200 KB): loads whenever tokenizer.bin is present,
			//   on every device. Sets scoresArbitraryWords=true so the autocorrect margin
			//   gate runs on iPhone 13 and older with zero CoreML cost. Piece score sums
			//   give OOV strings a real log-probability instead of the n-gram's flat floor.
			//
			// Tier 3 (BlendedScorer + full transformer, ~20-30 MB): only when there is
			//   at least minAvailableMBToLoad MB of headroom. Supersedes Tier 1 if it
			//   loads. Insufficient headroom or missing model → Tier 1 stays active.
			if KBSettings.neuralRescorer {
				if let tok = SPTokenizer.fromBundle() {
					self.scorer = UnigramScorer(tokenizer: tok, ngram: self.ngram)
				}
				let availableMB = Double(KBDiagnostics.availableBytes()) / 1_048_576
				let hasHeadroom = availableMB == 0 || availableMB >= NeuralScorer.minAvailableMBToLoad
				if hasHeadroom, let neural = NeuralScorer.bundled() {
					self.neuralLM = neural
					self.scorer = BlendedScorer(neural: neural, ngram: self.ngram)
				}
			}
		}
	}
	private func applyLearned() {
		// Kept words deliberately do NOT enter the trie: keeping means "stop
		// correcting this", not "suggest this". They still adopt organically below
		// once typed adoptAfter times. Snapshot (COW) so no lock is held across the loop.
		for (w, c) in user.unigramsSnapshot() {
			lexicon.noteUse(of: w, timesUsed: min(c, 50), adoptAfter: adoptAfter)
		}
	}

	// MARK: Autocorrect (O(1) cache read on the word boundary)

	/// Bare lowercase "i" and its contractions — stock always capitalizes these.
	/// They sit beneath the ≥3-char gate the fuzzy path uses, so they're special-cased.
	private static let iForms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]

	/// The space-key autocorrect read — two tiers, both fast:
	///
	/// 1. If the debounced background pass already precomputed a decision for THIS exact
	///    word, use it: an O(1) lock-guarded read, and the best quality available (it can
	///    carry the neural margin-gate verdict when the model had time to run).
	/// 2. Otherwise the user out-typed the 60 ms debounce, so compute the decision NOW,
	///    INLINE ON THE MAIN THREAD, n-gram-only (`fast`): a bounded trie DP + n-gram rank,
	///    ~1 ms, never a Core ML forward. Deliberately NOT `queue.sync` — the engine queue
	///    may be mid-way through a 20–30 ms neural pass (or have several passes and learn
	///    tasks queued), and syncing onto it from the main thread is exactly the "keyboard
	///    hangs on space" stall. The data this touches is safe off-queue: the static trie is
	///    immutable mmap, and the dynamic trie / boosts / user counts are behind fine-grained
	///    locks inside Lexicon and UserModel (held microseconds each).
	///
	/// Net effect of the two tiers: autocorrect ALWAYS fires, at any typing speed. The async
	/// pass upgrades the DECISION's quality (slang-survives margin gate) when it has time; it
	/// is no longer a prerequisite for correcting at all — which is what regressed when the
	/// neural rescorer (default-on) started dominating the debounced pass.
	func autocorrection(for word: String, context: [String], taps: [KeyTap?]? = nil) -> String? {
		let lw = word.lowercased()
		if isKept(lw) { return nil }
		if word == lw, Self.iForms.contains(lw) { return "I" + word.dropFirst() }
		guard word.count >= 2 else { return nil }
		if let p = readPending(), p.word == lw {
			guard let corrected = p.correction else { return nil }   // the pass decided "keep typed"
			return matchCase(of: word, to: corrected)
		}
		// No precomputed decision for this exact word yet — compute a fast one inline.
		let corrections = lexicon.corrections(for: lw, maxCost: maxCost(for: lw.count), taps: taps)
		guard let c = correction(from: corrections, typed: lw, context: context, fast: true) else { return nil }
		return matchCase(of: word, to: c)
	}

	/// The autocorrect decision from an ALREADY-computed correction set — lets the
	/// suggestion pass reuse its one fuzzy search instead of running the trie DP twice
	/// per keystroke. Runs on `queue` normally; with `fast: true` it is the space key's
	/// synchronous MAIN-THREAD fallback: every ranking below goes n-gram-only (lock-safe,
	/// no Core ML), and the OOV margin gate (which is only meaningful on the neural prior)
	/// yields to the legacy always-correct rule — the same behavior as when the model
	/// isn't resident.
	private func correction(from corrections: [Candidate], typed lw: String, context: [String], fast: Bool = false) -> String? {
		guard !isKept(lw) else { return nil }

		// Real dictionary words (js, hoe, form) are normally immune to autocorrect — that
		// immunity is why "js" showed "is" in the bar but never applied it. Correct one
		// only when a near-neighbour real word dominates it in context by realWordMargin
		// (the iOS-17 "hoe → how" behaviour). Allowed down to 2 chars because the strict
		// margin + single-edit requirement make it safe there; runs on the n-gram too.
		if lexicon.contains(lw) {
			guard lw.count >= 2 else { return nil }
			let typed = Candidate(word: lw, cost: 0, logFreq: log(Double(user.uniCount(lw)) + 1))
			let ranked = rank(corrections, including: typed, context: context, log: "realword '\(lw)'", ngramOnly: fast)
			guard let best = ranked.first, best.word != lw, lexicon.contains(best.word),
				  let cand = corrections.first(where: { $0.word == best.word }), cand.cost <= realWordMaxCost
			else { return nil }
			let typedScore = ranked.first(where: { $0.word == lw })?.score ?? 0
			let margin = best.score - typedScore
			let fire = margin > realWordMargin
			KBDiagnostics.logDecision(typed: lw, best: best.word, margin: margin,
									  threshold: realWordMargin, corrected: fire)
			return fire ? best.word : nil
		}

		guard lw.count >= 3 else { return nil }
		// Missing-space split ("alot" → "a lot"): rides the same gates as single-word
		// candidates. The neural batch scores the spaced string natively (subword
		// tokenizer); the pure-n-gram path scores it with the PAIR probability below,
		// because the single-candidate seam floors multi-word strings.
		let split = splitCandidate(of: lw)
		// Margin gate (the iOS-17 "slang survives" mechanism). Pre-gate, OOV meant
		// probability zero → forced replacement. The neural LM can score ANY string
		// via subwords, so the typed word rides the SAME batched forward pass as the
		// candidates (one extra row, spatial cost 0 by definition) and a correction
		// fires only when the best candidate beats it by `correctionMargin`. In a
		// register where the typed word is plausible ("lol im finna…") the margin
		// collapses and we stay silent. Repeated personal use raises the typed row's
		// logFreq term, reinforcing the keep. Without the neural model resident, the
		// n-gram OOV floor is meaningless, so keep the legacy always-correct rule.
		if !fast, scorer.scoresArbitraryWords {
			let typed = Candidate(word: lw, cost: 0,
								  logFreq: log(Double(user.uniCount(lw)) + 1))
			var cands = corrections
			if let split { cands.append(split.candidate) }
			let ranked = rank(cands, including: typed, context: context, log: "autocorrect")
			let best = ranked.first
			let typedScore = ranked.first(where: { $0.word == lw })?.score ?? 0
			let margin = (best?.score ?? 0) - typedScore
			let fire = best != nil && best!.word != lw && margin > correctionMargin
			KBDiagnostics.logDecision(typed: lw, best: best?.word, margin: margin,
									  threshold: correctionMargin, corrected: fire)
			return fire ? best!.word : nil
		}
		let ranked = rank(corrections, context: context, log: "autocorrect", ngramOnly: fast)
		var bestWord = ranked.first?.word
		var bestScore = ranked.first?.score ?? -.infinity
		if let split {
			let s = -split.candidate.cost + freqWeight * split.candidate.logFreq
				+ lmWeight * ngram.pairLogProb(split.a, split.b, context: context)
			if s > bestScore { bestWord = split.candidate.word; bestScore = s }
		}
		guard let bestWord, bestWord != lw else { return nil }
		return bestWord
	}

	/// Best "missing space" split of an OOV string into two real words, or nil.
	/// Channel cost is one skipped space (just under one insertion). Single-letter
	/// halves are only "a"/"i" — anything else is a typo fragment, not a word.
	private static let splitCost = 1.1
	private func splitCandidate(of lw: String) -> (candidate: Candidate, a: String, b: String)? {
		guard lw.count >= 4 else { return nil }
		var best: (Candidate, String, String)?
		var bestFreq = -Double.infinity
		for i in 1...(lw.count - 1) {
			let a = String(lw.prefix(i)), b = String(lw.dropFirst(i))
			guard a.count >= 2 || a == "a" || a == "i",
				  b.count >= 2 || b == "a" || b == "i",
				  lexicon.contains(a), lexicon.contains(b),
				  !lexicon.isProfane(a), !lexicon.isProfane(b),
				  let fa = lexicon.logFreq(of: a), let fb = lexicon.logFreq(of: b) else { continue }
			let lf = min(fa, fb)      // the pair is only as strong as its rarer half
			if lf > bestFreq {
				bestFreq = lf
				best = (Candidate(word: a + " " + b, cost: Self.splitCost, logFreq: lf), a, b)
			}
		}
		guard let best else { return nil }
		return (best.0, best.1, best.2)
	}

	func dontCorrect(_ word: String) {
		let lw = word.lowercased()
		// SYNCHRONOUS (lock-guarded, not the queue): a manual fix must be visible to the
		// autocorrect read on the SAME commit that registers it — otherwise the word the user
		// just fixed by hand gets re-corrected. Both fields are behind `stateLock`, so this is
		// a microsecond write, safe to do inline on the main thread.
		keepInsert(lw)                                           // protect now, THIS session only
		clearPending(ifWord: lw)                                 // stale decision must not re-fire
	}

	/// The user let an autocorrect of `original` stand (typed on instead of undoing).
	/// Acceptance is counter-evidence against an earlier rejection this session —
	/// lift the keep so correction resumes. Nothing persists; keeps are session-scoped.
	func correctionStood(_ original: String) {
		let lw = original.lowercased()
		keepRemove(lw)
	}

	/// The user actively replaced `original` with a different word (picked a suggestion
	/// over their typed word, undid a correction back out of `original`, or erased it
	/// and retyped something else by hand). Strong evidence `original` was a mistake:
	/// lift its session keep — so autocorrect resumes immediately — and walk back one
	/// learned use, so repeated hand-fixes keep it from adopting into the dictionary.
	func wordReplaced(original: String, with replacement: String) {
		let lw = original.lowercased()
		guard lw != replacement.lowercased() else { return }
		keepRemove(lw)
		clearPending(ifWord: lw)
		queue.async { [weak self] in
			guard let self else { return }
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
	/// Shape candidates handed to the prior = the neural batch cap (16). Wider funnel so a
	/// frequent-but-sloppily-swiped word survives shape ranking for the LM/context to rescue.
	private let glideCandidates = 16
	/// σ (rerank temperature) and the SHAPE gate (best candidate's cost must clear it or
	/// nothing commits — an accidental smear types nothing, not a random word) are NOT fixed
	/// constants anymore: the baked grid-searched values (σ 0.10, gate 0.43 — the correct-word
	/// p95 / scribble p10 midpoint) live in `GlideProfile` as the defaults, and #37 nudges
	/// them per user from their own accepted swipes. See `GlideProfile`.
	private let glideProfile = GlideProfile()

	/// Decode a swipe into a word: preprocess (P2) → shape-match against the trie (P3) →
	/// rerank with the language prior + frequency and gate (P4). Delivers the winner and
	/// up to 3 alternatives for the suggestion bar (swap targets) on the MAIN queue;
	/// (nil, []) when the swipe matched nothing well enough to commit.
	func glide(path: [CGPoint], layout: GlideLayout, context: [String],
			   completion: @escaping (String?, [String]) -> Void) {
		// Invalidate any suggestion pass already dispatched to the engine queue.
		// A queued pass that hasn't started yet bails at its isLatest() check;
		// a pass mid-execution still completes, but any further queued ones skip.
		// The controller also cancels the debounced work item before calling here.
		genLock.lock(); suggestGen &+= 1; genLock.unlock()
		// Serial engine queue: one decode at a time, behind at most the passes already in
		// flight. Nothing on the keystroke path waits for this — the commit arrives via the
		// main-queue completion; learning happens later on the controller's `learn` call.
		queue.async { [weak self] in
			func deliver(_ w: String?, _ alts: [String]) { DispatchQueue.main.async { completion(w, alts) } }
			guard let self, let ld = self.lexicon.langData,
				  let g = GlidePreprocess.run(path, layout: layout) else { return deliver(nil, []) }
			let cands = GlideDecoder.decode(g, lang: ld, limit: self.glideCandidates)
				.filter { !self.lexicon.isProfane($0.word) }
			// Gate on the best SHAPE fit (decoder output is shape-sorted): the question is
			// "did this swipe trace anything?", which the LM must not be able to overrule.
			// The gate is per-user (#37): a sloppy glider's correct swipes sit higher, so
			// their gate rises to let those through; a precise glider's gate tightens.
			guard let bestShape = cands.first?.cost, bestShape <= self.glideProfile.gate else {
				KBDiagnostics.logGlide(points: g.points.count, pivots: g.pivots.count, letters: "rejected")
				return deliver(nil, [])
			}
			// N-GRAM prior only — never the neural model. A glide commits the instant the
			// finger lifts, so it must not block on a synchronous Core ML forward pass; the
			// n-gram (with personalization) already ranks shape candidates well (glide_eval
			// top-1 ~83% on shape+freq alone). Neural's contextual value is applied AFTER the
			// commit, asynchronously, via the previous-word rescue (see `rescorePreviousWord`).
			let sigma = self.glideProfile.sigma           // per-user rerank temperature (#37)
			let priors = self.ngram.logProbs(cands.map(\.word), context: context)
			var scored: [(word: String, s: Double)] = []
			scored.reserveCapacity(cands.count)
			for (i, c) in cands.enumerated() {
				let lf = self.lexicon.logFreq(of: c.word) ?? 0
				scored.append((c.word, -c.cost / sigma
									   + self.glideLMWeight * priors[i]
									   + self.glideFreqWeight * lf))
			}
			scored.sort { $0.s > $1.s }
			let winner = scored[0].word
			let alts = scored.dropFirst().prefix(3).map(\.word)
			// Stash this commit's raw SHAPE costs so the controller's later verdict (accepted
			// winner / swapped-to alternative / undone) can supervise the per-user adaptation.
			self.noteGlideCommit(winner: winner, shapeCostByWord: Dictionary(cands.map { ($0.word, $0.cost) },
																			  uniquingKeysWith: min))
			KBDiagnostics.logGlide(points: g.points.count, pivots: g.pivots.count,
								   letters: ([winner] + alts).joined(separator: ","))
			// Offline calibration capture (debug flag; grid-space path so the fitter can
			// compare it to the committed word's ideal path).
			KBDiagnostics.captureGlide(path: g.points.map { (Double($0.x), Double($0.y)) },
									   candidates: scored.prefix(3).map(\.word), committed: winner)
			deliver(winner, Array(alts))
		}
	}

	// MARK: Per-user glide adaptation (#37) — supervision from the user's own verdict
	//
	// A committed glide leaves a stash of its candidates' raw SHAPE costs. The controller
	// then reports what the user did with it, and that verdict — never raw noise — teaches
	// the profile:  the winner stood → its cost is a CORRECT sample;  the user tapped a bar
	// alternative → THAT word's cost is the correct one;  the user backspaced it away →
	// diagnostic only (we don't know the true word, so we don't move the statistics). All of
	// these run WITHOUT the engine queue: `GlideProfile` is self-locked, the stash is behind
	// `glideLock`, so a verdict fired from the main thread is a couple of microseconds.

	private let glideLock = NSLock()
	private struct GlideOutcome { let winner: String; let shapeCostByWord: [String: Double] }
	private var lastGlideOutcome: GlideOutcome?

	private func noteGlideCommit(winner: String, shapeCostByWord: [String: Double]) {
		glideLock.lock(); lastGlideOutcome = GlideOutcome(winner: winner, shapeCostByWord: shapeCostByWord); glideLock.unlock()
	}
	private func takeGlideOutcome() -> GlideOutcome? {
		glideLock.lock(); defer { lastGlideOutcome = nil; glideLock.unlock() }; return lastGlideOutcome
	}

	/// The glided word stood (the user typed on / committed the next word without undoing).
	func glideAccepted() {
		guard let o = takeGlideOutcome(), let cost = o.shapeCostByWord[o.winner] else { return }
		glideProfile.observeCorrect(cost: cost)
		KBDiagnostics.logGlideAdapt(kind: "accept", cost: cost, profile: glideProfile)
	}
	/// The user swapped the glided word for a bar alternative — THAT word is the true one,
	/// so its shape cost is the correct sample (the winner was a near-miss the σ/gate should
	/// learn to rank better next time).
	func glideCorrected(to word: String) {
		guard let o = takeGlideOutcome(), let cost = o.shapeCostByWord[word.lowercased()] else { return }
		glideProfile.observeCorrect(cost: cost)
		KBDiagnostics.logGlideAdapt(kind: "correct", cost: cost, profile: glideProfile)
	}
	/// The user backspaced the whole glided word away. We don't know what they meant, so the
	/// cost statistics stay put; we only drop the stash so a later verdict can't double-count.
	func glideRejected() { _ = takeGlideOutcome() }

	// MARK: Previous-word (n-1) rescue — Apple-style "poler game → poker game"

	/// After `current` commits, re-judge the PREVIOUS word using `current` as forward
	/// evidence: this is where the neural model earns its keep (contextual disambiguation),
	/// applied ASYNC and off every keystroke/glide path. Returns a replacement for `prev`,
	/// or nil to leave it. Only the immediately-previous word (n-1) is ever touched.
	///
	/// Scores each single-edit real-word neighbour C of `prev` by the neural sequence score
	///   logP(C | leftContext) + logP(current | leftContext + [C])
	/// and fires only when the best C beats the standing word by `prevWordMargin`.
	func rescorePreviousWord(prev: String, current: String, leftContext: [String],
							 completion: @escaping (String?) -> Void) {
		// Serial engine queue, entirely off the keystroke path: the cheap pre-gate below
		// exits on most commits before any neural work, so this rarely occupies the queue.
		queue.async { [weak self] in
			func done(_ r: String?) { DispatchQueue.main.async { completion(r) } }
			guard let self else { return done(nil) }
			// Transformer-only: prev-word rescue scores logP(current | left+[C]) which
			// requires a context signal. UnigramScorer.scoresArbitraryWords is true but
			// has no context — it would fire on frequency differences alone, which is
			// too aggressive. Gate specifically on the full model being resident.
			guard self.neuralLM?.isReady == true else { return done(nil) }
			guard prev.count >= 3, !current.isEmpty, !self.isKept(prev) else { return done(nil) }

			// Single-edit real-word neighbours of the previous word (typo candidates only).
			// CHEAP PRE-GATE before any neural work: keep only neighbours MORE frequent than
			// the standing word and take the few most frequent. A correctly-spelled common
			// word has no more-frequent neighbour → we exit here on most commits, spending
			// zero neural forwards; only genuinely ambiguous slips ("poler"←"poker") escalate.
			let prevFreq = self.lexicon.logFreq(of: prev) ?? 0
			let neighbours = self.lexicon.corrections(for: prev, maxCost: self.realWordMaxCost)
				.filter { $0.word != prev && self.lexicon.contains($0.word)
						  && (self.lexicon.logFreq(of: $0.word) ?? 0) > prevFreq }
				.sorted { (self.lexicon.logFreq(of: $0.word) ?? 0) > (self.lexicon.logFreq(of: $1.word) ?? 0) }
				.prefix(3)
			guard !neighbours.isEmpty else { return done(nil) }
			let cands = [prev] + neighbours.map(\.word)   // ≤4 → at most 4 neural forwards below

			// term1: logP(C | left) — one batched forward. term2: logP(current | left + [C]).
			let pC = self.scorer.logProbs(cands, context: leftContext)
			var best = prev, bestScore = -Double.infinity, prevScore = -Double.infinity
			for (i, c) in cands.enumerated() {
				let fwd = self.scorer.logProbs([current], context: leftContext + [c]).first ?? -.infinity
				let s = pC[i] + fwd
				if c == prev { prevScore = s }
				if s > bestScore { bestScore = s; best = c }
			}
			guard best != prev, bestScore - prevScore > self.prevWordMargin else { return done(nil) }
			KBDiagnostics.logDecision(typed: prev, best: best, margin: bestScore - prevScore,
									  threshold: self.prevWordMargin, corrected: true)
			done(best)
		}
	}

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

	/// The exact-match word→emoji table riding in emoji.bin (nil when not bundled).
	private let emojiStore = EmojiStore.bundled
	/// Cache for context-injection neural predictions: one beam search per word boundary,
	/// not per keystroke. Keyed by context array; invalidated automatically when context
	/// changes (new word committed). Lives on the engine queue — no locking needed.
	private var injectionCache: (context: [String], words: [String])?

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
				curr[j] = min(sub, min(prev[j] + gap, curr[j - 1] + gap))
			}
			swap(&prev, &curr)
		}
		return prev[m]
	}

	/// Apple-style context injection: the neural LM (beam search over trie-valid subword
	/// sequences) predicts likely next words from context, then the spatial model validates
	/// them against the typed string. Surfaces candidates the fixed-radius trie DP misses
	/// when input is heavily corrupted — e.g. "coeevitjkn" → "correction" after "auto"
	/// (spatial cost ~9.7, far above the normal trie budget of 3.6).
	///
	/// Neural predictions are CACHED by context: one beam search fires the first time a
	/// context is seen, then every subsequent keystroke of the same word is a free hit.
	/// N-gram predictions supplement when the neural model isn't resident (Tier 1 devices).
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

		// --- Prediction: neural (cached) + n-gram supplement ---
		var neuralWords: [String] = []
		if let neural = neuralLM, neural.isReady {
			if let cached = injectionCache, cached.context == context {
				neuralWords = cached.words
			} else {
				let preds = neural.predictWords(
					context: context, limit: 8,
					isPrefix: { [lexicon] in lexicon.isPrefix($0) },
					isWord:   { [lexicon] in lexicon.contains($0) })
				neuralWords = (preds ?? []).map(\.word).filter { !lexicon.isProfane($0) }
				injectionCache = (context, neuralWords)
			}
		}
		// N-gram fills remaining slots and is the whole answer while neural loads.
		let ngramWords = ngram.nextWords(context: context, limit: 20)
		var seen = Set(neuralWords)
		var allWords = neuralWords
		for w in ngramWords where !seen.contains(w) { seen.insert(w); allWords.append(w) }

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

	func suggestions(currentWord: String, context: [String], taps: [KeyTap?]? = nil,
					 completion: @escaping ([String], [Character: Double]) -> Void) {
		genLock.lock(); suggestGen &+= 1; let gen = suggestGen; genLock.unlock()
		queue.async { [weak self] in
			guard let self, self.isLatest(gen) else { return }   // superseded — the newest pass delivers
			KBDiagnostics.recorder.sample()   // cheap footprint/headroom probe, background only
			let lw = currentWord.lowercased()
			var result: [String]
			if currentWord.isEmpty {
				self.injectionCache = nil   // context changed at word boundary; stale predictions freed
				self.setPending(nil)
				result = self.nextWords(context: context)
			} else {
				// One fuzzy search per keystroke: the corrections feed BOTH the suggestion
				// ranking and the precomputed autocorrect decision below (previously the
				// trie DP ran twice — once here, once inside computeCorrection).
				let corrections = self.lexicon.corrections(for: lw, maxCost: self.maxCost(for: lw.count), taps: taps)
				// Publish a FAST (n-gram) decision immediately — ~1 ms into the pass — so a
				// space that lands while the neural rank below is still running reads a real
				// decision instead of nothing. `pending` is word-keyed, so if the user has
				// already typed on, this entry simply never matches.
				self.setPending(PendingCorrection(word: lw,
					correction: self.correction(from: corrections, typed: lw, context: context, fast: true)))
				// First early exit: bail before context injection. The neural beam search
				// inside contextInjectedCandidates takes ~50 ms on first call; if glide
				// superseded this pass, skip that work entirely so glide gets the queue fast.
				guard self.isLatest(gen) else { return }
				// Context injection: neural beam search + n-gram predictions validated
				// spatially. Finds candidates the fixed-radius trie DP misses when input is
				// heavily corrupted (e.g. "coeevitjkn" → "correction" after "auto").
				let injected = self.contextInjectedCandidates(typed: lw, context: context, taps: taps)
				let correctionWords = Set(corrections.map(\.word))
				let newFromContext = injected.filter { !correctionWords.contains($0.word) }
				let allCorrections = corrections + newFromContext
				let completions = self.lexicon.completions(prefix: lw, limit: self.completionCandidateLimit)
				// Injected candidates don't share the typed prefix, so they only appear in
				// the bar when there are no completions (pure correction mode). The LM
				// ranking naturally suppresses weak injections that don't fit context.
				let correctionSuggestions = completions.isEmpty
					? corrections.filter { $0.cost <= self.suggestionCorrectionMaxCost } + newFromContext
					: corrections.filter { $0.word.hasPrefix(lw) }
				// Second early exit: bail before the neural ranking pass (rank() → CoreML
				// forward, 15–20 ms). A glide that fired after the injection step gets the
				// queue as soon as this returns rather than waiting for a full neural forward.
				guard self.isLatest(gen) else { return }
				let ranked = self.rank(completions + correctionSuggestions, context: context, log: "suggest '\(lw)'",
					frequencyMode: .compressed).prefix(self.nBest)
				result = ranked.prefix(3).map { matchCase(of: currentWord, to: $0.word) }
				// SwiftKey-style emoji candidate: an exact word→emoji hit takes the last
				// slot; picking it replaces the word (stock QuickType behavior).
				if let e = self.emojiStore?.emoji(forWord: lw) {
					if result.count >= 3 { result[2] = e } else { result.append(e) }
				}
				// UPGRADE the pending decision with allCorrections (includes injected) so
				// the neural margin gate considers context-predicted candidates too.
				self.setPending(PendingCorrection(word: lw,
					correction: self.correction(from: allCorrections, typed: lw, context: context)))
			}
			// Next-character priors for key-target resizing, straight off the mmap trie
			// for the CURRENT prefix (root when the word is empty = sentence starts).
			// Never the neural model: this must stay microseconds, every pass.
			let priors = self.lexicon.nextCharPriors(prefix: lw)
			// Deliver the UI only if still the newest pass; a newer pass owns the bar now.
			guard self.isLatest(gen) else { return }
			DispatchQueue.main.async { completion(result, priors) }
		}
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
					  !self.lexicon.contains(lw), !self.lexicon.isProfane(lw) else { continue }
				self.lexicon.insert(lw, freq: 50)
			}
		}
	}

	func learn(context: [String], word: String) {
		let lw = word.lowercased()
		guard lw.count >= 1, lw.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
		if lexicon.isProfane(lw) { return }        // never learn/adopt blocked words
		let ctx = context.map { $0.lowercased() }
		queue.async { [weak self] in
			guard let self else { return }
			self.user.learn(context: ctx, word: lw)
			self.user.pruneIfNeeded()
			self.lexicon.noteUse(of: lw, timesUsed: self.user.uniCount(lw), adoptAfter: self.adoptAfter)
			self.scheduleSave()
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
	/// Runs on `queue` normally; ALSO safe from the main thread when `ngramOnly` (the
	/// space key's fast fallback) — everything it touches is immutable or self-locked.
	/// `extra` (the margin gate's typed-word row) is exempt from the profanity filter
	/// and the cap: it must always come back scored.
	private func rank(_ cands: [Candidate], including extra: Candidate? = nil,
						  context: [String], log label: String? = nil,
						  ngramOnly: Bool = false,
						  frequencyMode: FrequencyMode = .raw) -> [(word: String, score: Double)] {
		var best: [String: Candidate] = [:]
		for c in cands where !lexicon.isProfane(c.word) {
			if let cur = best[c.word], cur.cost <= c.cost { continue }
			best[c.word] = c
		}
		guard !best.isEmpty else { return [] }
		var list = Array(best.values)
		// A fuzzy search can return dozens of candidates, but the prior (esp. the neural
		// model, whose Core ML batch is capped at `scoreCap`) should only rescore the
		// strongest handful. Pre-rank cheaply on channel + frequency and keep the top
		// `scoreCap`: a candidate the crude score ranks below that never climbs into the
		// shown top 3 after rescoring, and this bounds the prior to a single batch.
		// With an `extra` row, keep one slot free so the batch still fits in one pass.
		let cap = extra == nil ? scoreCap : scoreCap - 1
		if list.count > cap {
			list.sort {
				(-$0.cost + freqWeight * frequencyTerm($0.logFreq, mode: frequencyMode))
					> (-$1.cost + freqWeight * frequencyTerm($1.logFreq, mode: frequencyMode))
			}
			list = Array(list.prefix(cap))
		}
		if let extra, !list.contains(where: { $0.word == extra.word }) { list.append(extra) }
		let doLog = label != nil && KBDiagnostics.verbose
		let t0 = doLog ? Date() : nil
		let prior: LanguageScorer = ngramOnly ? ngram : scorer
		let priors = prior.logProbs(list.map(\.word), context: context)
		let scored = zip(list, priors)
			.map { (word: $0.word, score: -$0.cost + lmWeight * $1 + freqWeight * frequencyTerm($0.logFreq, mode: frequencyMode)) }
			.sorted { $0.score > $1.score }
		// Helpfulness telemetry: when the neural prior contributed (lastSplit non-nil),
		// re-rank the same list on the n-gram column alone and record whether blending
		// changed the winner. ≤16 candidates, so this is a trivial second argmax.
		if let split = prior.lastSplit, let blendedTop = scored.first?.word {
			var ngTop: String?
			var ngBest = -Double.infinity
			for (i, c) in list.enumerated() {
				let s = -c.cost + lmWeight * split.ngram[i] + freqWeight * frequencyTerm(c.logFreq, mode: frequencyMode)
				if s > ngBest { ngBest = s; ngTop = c.word }
			}
			KBDiagnostics.recorder.rankPass(changedTop1: blendedTop != ngTop)
		}
		if doLog, let label {
			let ms = t0.map { Date().timeIntervalSince($0) * 1000 } ?? 0
			let split = prior.lastSplit
			var rows: [KBDiagnostics.RankRow] = []
			for (i, c) in list.enumerated() {
				let freqTerm = frequencyTerm(c.logFreq, mode: frequencyMode)
				rows.append(.init(word: c.word, cost: c.cost, logFreq: c.logFreq,
									  freqTerm: freqTerm,
									  neural: split?.neural[i] ?? Double.nan,
									  ngram: split?.ngram[i] ?? priors[i],
									  prior: priors[i],
									  score: -c.cost + lmWeight * priors[i] + freqWeight * freqTerm))
			}
			rows.sort { $0.score > $1.score }
			KBDiagnostics.logRanking(label: label, context: context, rows: rows,
									 modelActive: prior.scoresArbitraryWords, ms: ms)
		}
		return scored
	}

	/// Must run on `queue`.
	private func nextWords(context: [String]) -> [String] {
		// Trie-constrained beam search when the LM is resident: the model proposes
		// subword pieces, every partial expansion must stay a valid trie prefix, and
		// only complete trie words score — open, whole-sentence-context generation
		// with zero hallucinated strings (prediction is where the neural model
		// measurably beats the n-gram). The n-gram list — which carries the user's
		// personal counts — fills remaining slots, and is the whole answer while
		// the model loads. Background queue only.
		// Never re-offer the word that was just committed — "the the" reads as a bug,
		// and stock never does it. (Legit doubles are rare and still typeable.)
		let last = context.last?.lowercased()
		var out: [String] = []
		if !context.isEmpty, let preds = neuralLM?.predictWords(
			context: context, limit: 8,
			isPrefix: { [lexicon] in lexicon.isPrefix($0) },
			isWord: { [lexicon] in lexicon.contains($0) }) {
			out = preds.map(\.word).filter { $0 != last && !lexicon.isProfane($0) }
		}
		let beamCount = out.count
		for w in ngram.nextWords(context: context, limit: 8)
			where w != last && !out.contains(w) && !lexicon.isProfane(w) { out.append(w) }
		if out.isEmpty { out = lexicon.topWords }   // fresh install, no context: top dictionary words
		let final = Array(out.prefix(3).map(displayCase))
		KBDiagnostics.logPredict(context: context, words: final, beam: beamCount, ngram: out.count - beamCount)
		return final
	}
	/// Bare "i" / "i'm" from lowercased corpora read wrong on the suggestion bar.
	private func displayCase(_ w: String) -> String {
		if w == "i" { return "I" }
		if w.hasPrefix("i'") { return "I" + w.dropFirst() }
		return w
	}
}

private func matchCase(of source: String, to target: String) -> String {
	// ALL-CAPS input stays ALL-CAPS ("HELLO" → "HELP!", not "Help"). Multi-char only:
	// a single capital (sentence-start letter, bare "I") means capitalize, not shout.
	if source.count > 1, source == source.uppercased(), source != source.lowercased() {
		return target.uppercased()
	}
	guard let f = source.first, f.isUppercase else { return target }
	return target.prefix(1).uppercased() + target.dropFirst()
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
//   1. Supervised ONLY. Statistics move on the user's own verdict — an accepted winner or a
//      picked alternative, whose TRUE word (and therefore correct shape cost) we know — never
//      on raw, unlabeled strokes.
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
		var n = 0
		var mean = 0.22
		var varc = 0.006
	}
	private var state = State()
	private let lock = NSLock()

	private static let key = "kb.glideprofile"
	private static var store: UserDefaults { UserDefaults(suiteName: KBSettings.appGroup) ?? .standard }
	private static let io = DispatchQueue(label: "keyboard.glideprofile.io", qos: .utility)

	// Adaptation constants.
	private static let alpha  = 0.12                 // EWMA rate — slow; no single stroke dominates
	private static let warmup = 12.0                 // supervised samples before adapted fully replaces default
	private static let sigmaK = baseSigma / 0.22     // σ tracks the mean, anchored so mean 0.22 → baseSigma
	private static let gateK  = 2.7                  // gate sits ~2.7σ above the mean (≈ the offline p95 midpoint)

	func load() {
		guard let d = Self.store.data(forKey: Self.key),
			  let s = try? JSONDecoder().decode(State.self, from: d) else { return }
		lock.lock(); state = s; lock.unlock()
	}
	private func persist(_ s: State) {
		Self.io.async { if let d = try? JSONEncoder().encode(s) { Self.store.set(d, forKey: Self.key) } }
	}
	private func snapshot() -> State { lock.lock(); defer { lock.unlock() }; return state }

	/// Feed a known-CORRECT shape cost (an accepted winner, or the alternative the user picked).
	func observeCorrect(cost: Double) {
		guard cost.isFinite, cost >= 0 else { return }
		let s: State = {
			lock.lock(); defer { lock.unlock() }
			let old = state.mean
			state.mean = (1 - Self.alpha) * state.mean + Self.alpha * cost
			// EWMA variance (Welford-style increment) — the spread the gate leaves headroom over.
			state.varc = (1 - Self.alpha) * state.varc + Self.alpha * (cost - old) * (cost - state.mean)
			state.n += 1
			return state
		}()
		persist(s)
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
