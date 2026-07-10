import Foundation

// Noisy-channel engine, v3 — restructured for the neural rescorer (Phase A).
//
// Pipeline:   Lexicon (trie = channel model) generates an N-best candidate list
//           → a LanguageScorer supplies the context prior in ONE batched call
//             (today: bundled n-grams; later: tiny neural LM behind the same seam)
//           → UserModel layers on-device personalization on top.
//
// Autocorrect decisions are precomputed by the debounced background pass while the
// word is still being typed, so the space key only ever does an O(1) cache read —
// a neural scorer (5–20 ms) must never run synchronously on the keystroke path.
//
// Data ships as ONE binary, `langdata.bin` (built by tools/build_language_data.py),
// which is MEMORY-MAPPED at launch: the bi/tri-gram tables AND (format v3) the
// dictionary trie itself are read in place and never materialize as Swift heap
// structures. File-backed read-only pages are clean memory — the OS can evict them
// at will, so they barely count against the extension's ~60–70 MB kill limit (heap
// counts in full). Only a small dynamic trie (adopted + contact words) stays on the
// heap; a v2 file falls back to loading the full vocab into that trie as before.

final class KeyboardEngine {

	private let queue = DispatchQueue(label: "keyboard.engine", attributes: .concurrent)
	private let lexicon = Lexicon()
	private let user = UserModel()
	private lazy var ngram = NgramScorer(user: user)
	/// The active prior. When the neural rescorer lands it replaces (or blends with)
	/// `ngram` here — nothing else in the engine changes.
	private lazy var scorer: LanguageScorer = ngram
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

	/// The precomputed autocorrect decision for the word currently being typed,
	/// refreshed by the (debounced, background) suggestion pass. The space key reads
	/// it O(1) instead of running a search — mandatory once scoring involves a
	/// neural forward pass. Guarded by `queue`.
	private struct PendingCorrection { let word: String; let correction: String? }
	private var pending: PendingCorrection?

	/// Correction rejections from THIS session. Suppresses re-correction immediately
	/// (so the keyboard never fights the user) and deliberately does NOT persist:
	/// stock-style, a fresh session starts with a clean slate — cross-session keeps
	/// turned one undo into a permanently protected typo.
	private var sessionKept = Set<String>()

	/// Learning fires on every committed word, and `user.save()` re-encodes the WHOLE
	/// personal model to JSON — O(model) work and a matching transient allocation on
	/// the engine barrier, per word typed. Coalesce to one save per 2 s typing burst.
	/// Rare, signal-bearing events (kept words, undo healing) still save immediately;
	/// losing ≤2 s of ordinary counts to a jetsam kill is an acceptable trade.
	private var savePending = false
	private func scheduleSave() {
		guard !savePending else { return }
		savePending = true
		queue.asyncAfter(deadline: .now() + 2.0, flags: .barrier) { [weak self] in
			guard let self else { return }
			self.savePending = false
			self.user.save()
		}
	}

	init() {
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.lexicon.loadFromBundle()
			self.ngram.attach(data: self.lexicon.langData,
							  resolveID: { [lexicon = self.lexicon] in lexicon.wordID($0) })
			self.user.load()
			self.applyLearned()
			// Phase C: if the user opted in AND the exported model ships, blend it with
			// the n-gram prior. Default-OFF — the n-gram engine is the shipping default,
			// so a fresh install stays at the ~31 MB baseline (no 20-30 MB model working
			// set). Absent model or opt-out = pure n-gram, no other differences.
			if KBSettings.neuralRescorer, let neural = NeuralScorer.bundled() {
				self.neuralLM = neural
				self.scorer = BlendedScorer(neural: neural, ngram: self.ngram)
			}
		}
	}
	private func applyLearned() {
		// Kept words deliberately do NOT enter the trie: keeping means "stop
		// correcting this", not "suggest this". They still adopt organically below
		// once typed adoptAfter times.
		for (w, c) in user.unigrams {
			lexicon.noteUse(of: w, timesUsed: min(c, 50), adoptAfter: adoptAfter)
		}
	}

	// MARK: Autocorrect (O(1) cache read on the word boundary)

	/// Bare lowercase "i" and its contractions — stock always capitalizes these.
	/// They sit beneath the ≥3-char gate the fuzzy path uses, so they're special-cased.
	private static let iForms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]

	func autocorrection(for word: String, context: [String], taps: [KeyTap?]? = nil) -> String? {
		let lw = word.lowercased()
		return queue.sync {
			guard !sessionKept.contains(lw) else { return nil }
			if word == lw, Self.iForms.contains(lw) { return "I" + word.dropFirst() }
			// ≥2: real 2-char words can be corrected via the strict real-word path below;
			// 2-char OOV strings are still filtered out inside `correction(from:)`.
			guard word.count >= 2 else { return nil }
			let correction: String?
			if let p = pending, p.word == lw { correction = p.correction }
			// Typed faster than the debounce → compute now, but in `fast` mode: this
			// runs synchronously under the space key, where a Core ML forward pass
			// (5–20 ms) must never happen. Fast mode scores with the n-gram only.
			else { correction = computeCorrection(lw, context: context, taps: taps, fast: true) }
			return correction.map { matchCase(of: word, to: $0) }
		}
	}

	/// Must run on `queue`.
	private func computeCorrection(_ lw: String, context: [String], taps: [KeyTap?]? = nil, fast: Bool = false) -> String? {
		correction(from: lexicon.corrections(for: lw, maxCost: maxCost(for: lw.count), taps: taps), typed: lw, context: context, fast: fast)
	}

	/// The autocorrect decision from an ALREADY-computed correction set — lets the
	/// suggestion pass reuse its one fuzzy search instead of running the trie DP twice
	/// per keystroke. Must run on `queue`. `fast` = the synchronous space-key fallback:
	/// every ranking below goes n-gram-only, and the OOV margin gate (which is only
	/// meaningful on the neural prior) yields to the legacy always-correct rule —
	/// the same behavior as when the model isn't resident.
	private func correction(from corrections: [Candidate], typed lw: String, context: [String], fast: Bool = false) -> String? {
		guard !sessionKept.contains(lw) else { return nil }

		// Real dictionary words (js, hoe, form) are normally immune to autocorrect — that
		// immunity is why "js" showed "is" in the bar but never applied it. Correct one
		// only when a near-neighbour real word dominates it in context by realWordMargin
		// (the iOS-17 "hoe → how" behaviour). Allowed down to 2 chars because the strict
		// margin + single-edit requirement make it safe there; runs on the n-gram too.
		if lexicon.contains(lw) {
			guard lw.count >= 2 else { return nil }
			let typed = Candidate(word: lw, cost: 0, logFreq: log(Double(user.unigrams[lw] ?? 0) + 1))
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
								  logFreq: log(Double(user.unigrams[lw] ?? 0) + 1))
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
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.sessionKept.insert(lw)                          // protect now, THIS session only
			if self.pending?.word == lw { self.pending = nil }   // stale decision must not re-fire
		}
	}

	/// The user let an autocorrect of `original` stand (typed on instead of undoing).
	/// Acceptance is counter-evidence against an earlier rejection this session —
	/// lift the keep so correction resumes. Nothing persists; keeps are session-scoped.
	func correctionStood(_ original: String) {
		let lw = original.lowercased()
		queue.async(flags: .barrier) { [weak self] in
			self?.sessionKept.remove(lw)
		}
	}

	/// The user actively replaced `original` with a different word (picked a suggestion
	/// over their typed word, undid a correction back out of `original`, or erased it
	/// and retyped something else by hand). Strong evidence `original` was a mistake:
	/// lift its session keep — so autocorrect resumes immediately — and walk back one
	/// learned use, so repeated hand-fixes keep it from adopting into the dictionary.
	func wordReplaced(original: String, with replacement: String) {
		let lw = original.lowercased()
		guard lw != replacement.lowercased() else { return }
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.sessionKept.remove(lw)
			self.user.demote(lw)
			if self.pending?.word == lw { self.pending = nil }
			self.scheduleSave()
		}
	}

	// MARK: Suggestions (background; also precomputes the autocorrect decision)

	/// Fast typing queues several barrier passes; each used to run its full search even
	/// when a newer keystroke had already superseded it (staleness was only detected in
	/// the main-thread callback, after the work was spent). Ticket outside, check inside:
	/// a pass that is no longer the newest returns before doing anything. NSLock, not the
	/// engine queue, guards the counter — the increment happens on the caller's thread.
	private let genLock = NSLock()
	private var suggestGen = 0

	/// The exact-match word→emoji table riding in emoji.bin (nil when not bundled).
	private let emojiStore = EmojiStore.bundled

	func suggestions(currentWord: String, context: [String], taps: [KeyTap?]? = nil,
					 completion: @escaping ([String], [Character: Double]) -> Void) {
		genLock.lock(); suggestGen &+= 1; let gen = suggestGen; genLock.unlock()
		// Barrier: this pass writes `pending` (and is the only frequent writer).
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.genLock.lock(); let latest = self.suggestGen; self.genLock.unlock()
			guard gen == latest else { return }   // superseded — the newest pass delivers
			KBDiagnostics.recorder.sample()   // cheap footprint/headroom probe, background only
			let lw = currentWord.lowercased()
			var result: [String]
			if currentWord.isEmpty {
				self.pending = nil
				result = self.nextWords(context: context)
			} else {
				// One fuzzy search per keystroke: the corrections feed BOTH the suggestion
				// ranking and the precomputed autocorrect decision below (previously the
				// trie DP ran twice — once here, once inside computeCorrection).
				let corrections = self.lexicon.corrections(for: lw, maxCost: self.maxCost(for: lw.count), taps: taps)
				let completions = self.lexicon.completions(prefix: lw, limit: 12)
				let ranked = self.rank(completions + corrections, context: context, log: "suggest '\(lw)'").prefix(self.nBest)
				result = ranked.prefix(3).map { matchCase(of: currentWord, to: $0.word) }
				// SwiftKey-style emoji candidate: an exact word→emoji hit takes the last
				// slot; picking it replaces the word (stock QuickType behavior).
				if let e = self.emojiStore?.emoji(forWord: lw) {
					if result.count >= 3 { result[2] = e } else { result.append(e) }
				}
				// Precompute "what happens if the user commits this word right now" so the
				// space key is an O(1) cache read, reusing the corrections just computed.
				self.pending = PendingCorrection(word: lw,
					correction: self.correction(from: corrections, typed: lw, context: context))
			}
			// Next-character priors for key-target resizing, straight off the mmap trie
			// for the CURRENT prefix (root when the word is empty = sentence starts).
			// Never the neural model: this must stay microseconds, every pass.
			let priors = self.lexicon.nextCharPriors(prefix: lw)
			DispatchQueue.main.async { completion(result, priors) }
		}
	}

	/// iOS supplementary lexicon (contact names, text-replacement shortcuts): make
	/// these words first-class citizens — suggestable and immune to autocorrect —
	/// exactly how stock stops "mangling" names. Modest frequency: context counts,
	/// not the freq term, should surface them.
	func importSupplementaryLexicon(_ words: [String]) {
		queue.async(flags: .barrier) { [weak self] in
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
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.user.learn(context: ctx, word: lw)
			self.user.pruneIfNeeded()
			self.lexicon.noteUse(of: lw, timesUsed: self.user.unigrams[lw] ?? 0, adoptAfter: self.adoptAfter)
			self.scheduleSave()
		}
	}

	// MARK: Ranking — the blend of channel, prior, personalization, and frequency

	/// Dedupes (keeping each word's cheapest channel cost), drops blocked words, then
	/// blends one batched prior call with the channel cost and lexicon frequency:
	///   final = -spatialCost + lmWeight·logP(w|ctx) + freqWeight·logFreq
	/// Must run on `queue`. `extra` (the margin gate's typed-word row) is exempt
	/// from the profanity filter and the cap: it must always come back scored.
	private func rank(_ cands: [Candidate], including extra: Candidate? = nil,
					  context: [String], log label: String? = nil,
					  ngramOnly: Bool = false) -> [(word: String, score: Double)] {
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
			list.sort { (-$0.cost + freqWeight * $0.logFreq) > (-$1.cost + freqWeight * $1.logFreq) }
			list = Array(list.prefix(cap))
		}
		if let extra, !list.contains(where: { $0.word == extra.word }) { list.append(extra) }
		let doLog = label != nil && KBDiagnostics.verbose
		let t0 = doLog ? Date() : nil
		let prior: LanguageScorer = ngramOnly ? ngram : scorer
		let priors = prior.logProbs(list.map(\.word), context: context)
		let scored = zip(list, priors)
			.map { (word: $0.word, score: -$0.cost + lmWeight * $1 + freqWeight * $0.logFreq) }
			.sorted { $0.score > $1.score }
		if doLog, let label {
			let ms = t0.map { Date().timeIntervalSince($0) * 1000 } ?? 0
			let split = prior.lastSplit
			var rows: [KBDiagnostics.RankRow] = []
			for (i, c) in list.enumerated() {
				rows.append(.init(word: c.word, cost: c.cost, logFreq: c.logFreq,
								  neural: split?.neural[i] ?? Double.nan,
								  ngram: split?.ngram[i] ?? priors[i],
								  prior: priors[i],
								  score: -c.cost + lmWeight * priors[i] + freqWeight * c.logFreq))
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
