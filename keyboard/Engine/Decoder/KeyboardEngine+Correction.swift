import Foundation

extension KeyboardEngine {
	// MARK: Autocorrect decision (background decode only)

	/// Bare lowercase "i" and its contractions — stock always capitalizes these.
	/// They sit beneath the ≥3-char gate the fuzzy path uses, so they're special-cased.
	static let iForms: Set<String> = ["i", "i'm", "i'll", "i've", "i'd"]

	/// Left-context words that make a following "id" the noun (an ID), not "I'd"/"is".
	/// Possessives and articles only — demonstratives ("this"/"that") are deliberately
	/// excluded so "this id" can still correct to "this is".
	private static let idNounDeterminers: Set<String> = [
		"my", "your", "his", "her", "our", "their", "a", "an", "the",
		"valid", "fake", "user", "login", "student", "employee", "email", "caller",
	]

	struct CorrectionDecision {
		let word: String?
		/// Winner minus typed-word score in natural-log units. This is the actual
		/// confidence signal published in DecodeSnapshot, not a boolean placeholder.
		let margin: Double
	}

#if DEBUG || KB_REFERENCE_DECODER_YES
	private func rawScore(_ candidate: RankedCandidate, channel: Double) -> Double {
		let prior = candidate.neuralLogProbability.map {
			neuralPriorWeight * $0 + (1 - neuralPriorWeight) * candidate.logLanguageProbability
		} ?? candidate.logLanguageProbability
		return -channel * candidate.spatialCost + lmWeight * prior + freqWeight * candidate.logFrequency
	}

	/// The user typed a trailing 's' that the bare-base correction would DROP. Mirrors
	/// native Ranking.cpp: promote only when the typed word is strictly closer to base+"s"
	/// (minuts → minutes, but muts → must), and then as a plural before a contraction
	/// ("thads" → "that's" because "thats" is not a word). Validity-gated.
	private func contractionPreservingTypedSuffix(base: String, typed lw: String) -> String? {
		guard lw.hasSuffix("s"), !base.hasSuffix("s"),
			  Self.osaDistance(lw, base + "s") < Self.osaDistance(lw, base) else { return nil }
		let plural = base + "s", contraction = base + "'s"
		if lexicon.contains(plural), !lexicon.isProfane(plural) { return plural }
		guard lexicon.contains(contraction), !lexicon.isProfane(contraction) else { return nil }
		return contraction
	}

	/// Mirrors native `inflection`: longer is shorter (3+ letters) plus a regular ending.
	private static func isInflection(_ shorter: String, of longer: String) -> Bool {
		guard shorter.count >= 3, longer.hasPrefix(shorter) else { return false }
		let ending = String(longer.dropFirst(shorter.count))
		switch ending {
		case "s": return !shorter.hasSuffix("s")
		case "es": return ["s", "x", "z", "ch", "sh", "o"].contains { shorter.hasSuffix($0) }
		case "d": return shorter.hasSuffix("e")
		case "ed", "'s": return true
		default: return false
		}
	}

	/// Mirrors native `osaDistance` (unit costs, adjacent transpositions) over UTF-8 bytes.
	private static func osaDistance(_ a: String, _ b: String) -> Int {
		let x = Array(a.utf8), y = Array(b.utf8)
		var d = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
		for i in 0...x.count { d[i][0] = i }
		for j in 0...y.count { d[0][j] = j }
		if x.isEmpty || y.isEmpty { return d[x.count][y.count] }
		for i in 1...x.count { for j in 1...y.count {
			d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
			if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
		} }
		return d[x.count][y.count]
	}
#endif

	/// Context-aware next-character priors for key-target resizing (Plan 1). The
	/// context-free trie prior (`base`) is lifted wherever the in-context ranking already
	/// favours a completion extending the current prefix: the character each higher-ranked
	/// completion adds gets a rank-decayed weight, normalized, and folded in with MAX so
	/// context can only ENLARGE a likely key, never shrink one below its lexical baseline.
	func contextualCharPriors(evidence: [DecodeCandidateEvidence], prefix lw: String,
									  base: [Character: Double]) -> [Character: Double] {
		guard !lw.isEmpty else { return base }
        let letters = evidence.compactMap { candidate -> String? in
            guard candidate.word.count > lw.count, candidate.word.hasPrefix(lw) else { return nil }
            return String(candidate.word[candidate.word.index(candidate.word.startIndex, offsetBy: lw.count)])
        }
        var keys = Array(base.keys)
        for letter in letters { let c = Character(letter); if !keys.contains(c) { keys.append(c) } }
        let values = KBNumericPolicy.contextualPriors(letters, baseLetters: keys.map(String.init),
            values: keys.map { NSNumber(value: base[$0] ?? 0) })
        return Dictionary(uniqueKeysWithValues: zip(keys, values.map(\.doubleValue)))
	}

	/// Decide from the same already-scored table used by the suggestion strip. The
	/// language model is never invoked here; display and commit therefore share one
	/// candidate generation pass and one prior batch.
    func correction(from scored: [RankedCandidate], correctionCosts: [String: Double],
        typed lw: String, context: [String], split: (candidate: Candidate, a: String, b: String)?,
        looseWords: Set<String> = [], broadRecoveryWords: Set<String> = [],
        aimedAtBlocked: Bool = false) -> CorrectionDecision {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if candidateBackend == .swiftReference {
            return correctionReference(from: scored, correctionCosts: correctionCosts, typed: lw,
                context: context, split: split, looseWords: looseWords, broadRecoveryWords: broadRecoveryWords,
                aimedAtBlocked: aimedAtBlocked)
        }
#endif
        let flags = Data(lw.flatMap { ch in Array(repeating: UInt8(ch.isLetter ? 1 : 0), count: String(ch).utf8.count) })
        let value = KBRanking.correct(scored.map(\.native), lexicon: lexicon.nativeGenerationView(),
            costs: correctionCosts.mapValues { NSNumber(value: $0) }, typed: lw, characterCount: UInt(lw.count),
            letterFlags: flags, context: context, kept: isKept(lw) || aimedAtBlocked, loose: Array(looseWords),
            broad: Array(broadRecoveryWords), policy: correctionPolicy.nativeValues)
        if let kind = value.kind.flatMap(CorrectionGateEvidence.Kind.init(rawValue:)), let candidate = value.candidate {
            correctionObserver?(CorrectionGateEvidence(typed: lw, candidate: candidate, kind: kind,
                typedMargin: value.margin, candidateGap: value.gap?.doubleValue,
                spatialCost: value.cost, allowsCloseRescue: value.allowsCloseRescue))
            KBDiagnostics.logDecision(typed: lw, best: candidate, margin: value.margin,
                threshold: value.threshold, corrected: value.word != nil)
        }
        return CorrectionDecision(word: value.word, margin: value.margin)
    }
#if DEBUG || KB_REFERENCE_DECODER_YES

	private func correctionReference(from scored: [RankedCandidate], correctionCosts: [String: Double],
							typed lw: String, context: [String],
							split: (candidate: Candidate, a: String, b: String)?,
							looseWords: Set<String> = [],
							broadRecoveryWords: Set<String> = [],
							aimedAtBlocked: Bool = false) -> CorrectionDecision {
        // These calibrated margins were measured with the n-gram prior only.
        let policy = scored.contains { $0.neuralLogProbability != nil }
            ? CorrectionPolicy.baseline : correctionPolicy
		guard !isKept(lw), !aimedAtBlocked else { return CorrectionDecision(word: nil, margin: 0) }

		guard let typed = scored.first(where: { $0.word == lw }) else {
			return CorrectionDecision(word: nil, margin: 0)
		}
		// A typed dictionary word (real-word gate) keeps its own channel weight; as native.
		var channel = lexicon.contains(lw) ? realWordChannelWeight : channelWeight
		// A non-word is judged against each candidate's correction cost, not as a cost-0
		// completion of the typed prefix (successfull → successfully); the real-word gate keeps
		// the completion cost it was calibrated with (wit → with); as native.
		let realWord = lexicon.contains(lw)
		func gateScore(_ candidate: RankedCandidate) -> Double {
			let cost = realWord || candidate.word == lw ? nil : correctionCosts[candidate.word]
			return rawScore(candidate, channel: channel) - channel * ((cost ?? candidate.spatialCost) - candidate.spatialCost)
		}
		var eligible = scored.filter {
			$0.word != lw && correctionCosts[$0.word] != nil
		}
		// The real-word gate only weighs slips (cost ≤ realWordMaxCost); as native.
		if realWord { eligible.removeAll { correctionCosts[$0.word]! > realWordMaxCost } }
		var typedScore = 0.0, bestWord: String?, bestScore = -Double.infinity
		func pickBest() {
			typedScore = gateScore(typed)
			bestWord = eligible.first?.word
			bestScore = eligible.first.map(gateScore) ?? -.infinity
			for candidate in eligible.dropFirst() {
				let score = gateScore(candidate)
				if score > bestScore { bestWord = candidate.word; bestScore = score }
			}
		}
		pickBest()
		// A split that cannot clear its own margin gives way to the best single word; as native.
		if let word = bestWord, word.contains(" "), bestScore - typedScore <= splitCorrectionMargin {
			eligible.removeAll { $0.word.contains(" ") }
			pickBest()
		}
		// Recovery beyond the close search is far from what was typed whatever the candidate:
		// the gate weighs the channel less there; as native.
		if let word = bestWord, !lexicon.contains(lw), looseWords.contains(word), recoveryChannelWeight != channel {
			channel = recoveryChannelWeight
			pickBest()
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
				  let cost = correctionCosts[bestWord], cost <= realWordMaxCost,
				  // At most one added letter (dog → doggy is no slip); as native.
				  bestWord.utf8.count <= lw.utf8.count + 1 else {
				return CorrectionDecision(word: nil, margin: 0)
			}
			// A valid word is never replaced by its own inflection (tests → test); as native.
			if Self.isInflection(lw, of: bestWord) || Self.isInflection(bestWord, of: lw) {
				return CorrectionDecision(word: nil, margin: 0)
			}
			let margin = bestScore - typedScore
            let runnerUp = eligible.filter { $0.word != bestWord }.map(gateScore).max()
            let gate = CorrectionGateEvidence(typed: lw, candidate: bestWord, kind: .realWord,
                typedMargin: margin, candidateGap: runnerUp.map { bestScore - $0 },
                spatialCost: cost, allowsCloseRescue: false)
            correctionObserver?(gate)
            let fire = policy.accepts(gate)
			KBDiagnostics.logDecision(typed: lw, best: bestWord, margin: margin,
									  threshold: policy.realWordMargin, corrected: fire)
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

		// Two-letter non-words are corrected too (ro → to, yu → you), as native
		// minimumCorrectionLength; an undo still teaches the word through dontCorrect.
		guard lw.count >= 2 else { return CorrectionDecision(word: nil, margin: 0) }

		if let current = bestWord, !current.contains("'"),
		   let promoted = contractionPreservingTypedSuffix(base: current, typed: lw) {
			bestWord = promoted
		}
		guard let bestWord else { return CorrectionDecision(word: nil, margin: 0) }
		let margin = bestScore - typedScore
		let isSevereBroadRecovery = lw.count >= 8 && broadRecoveryWords.contains(bestWord)
		let requiredMargin = isSevereBroadRecovery ? severeRecoveryMargin : policy.oovMargin
        let isLoose = looseWords.contains(bestWord)
        // Preserve the existing unrelated-runner guard for broad/context recovery.
        // Close rescues compare against every eligible alternative, including forms.
        let contender = eligible.filter {
            $0.word != bestWord && (!isLoose || !Self.nearForm($0.word, bestWord))
        }.map(gateScore).max()
        let cost = correctionCosts[bestWord] ?? Double.greatestFiniteMagnitude
        let gate = CorrectionGateEvidence(typed: lw, candidate: bestWord,
            kind: isLoose ? (isSevereBroadRecovery ? .severe : .loose) : .close,
            typedMargin: margin, candidateGap: contender.map { bestScore - $0 },
            spatialCost: cost,
            allowsCloseRescue: !isLoose && cost <= realWordMaxCost
                && lexicon.isStaticWord(bestWord) && !bestWord.contains(" ")
                && !bestWord.contains("'") && lw.count >= 4)
        correctionObserver?(gate)
        // A missing-space split keeps the earlier non-word margin (iamhere is not "ia here"); as native.
        let fire = policy.accepts(gate) && !(bestWord.contains(" ") && margin <= splitCorrectionMargin)
        let loggedThreshold = fire && gate.kind == .close && margin <= policy.oovMargin
            ? policy.closeRescueMargin : requiredMargin
		KBDiagnostics.logDecision(typed: lw, best: bestWord, margin: margin,
								  threshold: loggedThreshold, corrected: fire)
		return CorrectionDecision(word: fire ? bestWord : nil, margin: margin)
	}

#endif

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
#if DEBUG || KB_REFERENCE_DECODER_YES
	private static let splitCost = 2.0   // native splitCost
	/// A user aiming for the space bar can land on its nearest letter row. Consume one
	/// adjacent `c/v/b/n/m` as the boundary instead of demanding two perfect substrings.
	private static let spatialBoundarySubstitutionCost = 0.72
	private static let spaceNeighbourLetters = Set("cvbnm")
	/// Channel cost of a missing apostrophe in the SUGGESTION bar's contraction
	/// candidate ("its" → "it's"). Well under one edit: the omission is a keyboard
	/// layout gap, not a slip — ranking, not this cost, decides if it surfaces.
	func splitCandidate(of lw: String) -> (candidate: Candidate, a: String, b: String)? {
		guard lw.count >= 4 else { return nil }
		var best: (Candidate, String, String)?
		var bestStrength = -Double.infinity
		let characters = Array(lw)
		func consider(_ a: String, _ b: String, cost: Double) {
			guard a.count >= 2 || a == "a" || a == "i",
				  b.count >= 2 || b == "a" || b == "i",
				  lexicon.contains(a), lexicon.contains(b),
				  !lexicon.isProfane(a), !lexicon.isProfane(b), !lexicon.isProfane(a + " " + b),
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
#endif
	static let apostropheCost = 0.5

	/// Scores each beam expansion as a full continuation from committed context.
	/// Streaming scoring branches the shared recurrent state, so a second/third word
	/// is conditioned on its own uncommitted prefix, not a hard-coded split winner.
	func multiwordCandidates(typed: String, taps: [KeyTap?]?, request: DecodeRequest,
		generation: Int, completion: @escaping ([Candidate]) -> Void) {
		guard request.requestedModelTier == .neuralGRU, !lexicon.contains(typed),
			let prior = searchPrior, prior.modelTier == .neuralGRU else { completion([]); return }
        let search: MultiwordSearch
#if DEBUG || KB_REFERENCE_DECODER_YES
        if candidateBackend == .cpp {
            search = MultiwordSearch(typed: typed, taps: taps, lexicon: lexicon.nativeGenerationView())
        }
        else {
            search = MultiwordSearch(typed: typed, taps: taps) { [lexicon] word, taps in
                lexicon.corrections(for: word, maxCost: 1.8, taps: taps).filter { !lexicon.isProfane($0.word) }
            }
        }
#else
        search = MultiwordSearch(typed: typed, taps: taps, lexicon: lexicon.nativeGenerationView())
#endif
		prior.prepareContext(request.context, wordSessionID: request.wordSessionID)
		preparedNeuralSession = (request.wordSessionID, request.context)
		var finished: [Candidate] = []
		func advance(_ frontier: [MultiwordSearch.Hypothesis], depth: Int) {
			guard self.isLatest(generation) else { return }
			let expanded = search.expand(frontier, shouldCancel: { !self.isLatest(generation) })
			guard !expanded.isEmpty else { completion(finished); return }
			let words = Array(Set(expanded.map { $0.candidate.word })).sorted()
			prior.score(candidates: words, wordSessionID: request.wordSessionID) { result in
				self.queue.async {
					guard self.isLatest(generation) else { return }
					guard case .success(let probabilities) = result else { completion(finished); return }
                    if let pruned = search.prune(expanded, neural: expanded.map { probabilities[$0.candidate.word] ?? .nan },
                        language: self.ngram.candidateLogProbs(expanded.map { $0.candidate.word }, context: request.context)) {
                        finished.append(contentsOf: pruned.finished)
                        if depth < MultiwordSearch.maximumWords && !pruned.frontier.isEmpty { advance(pruned.frontier, depth: depth + 1) }
                        else { completion(finished) }
                        return
                    }

					var ranked: [(MultiwordSearch.Hypothesis, Double)] = []
					for state in expanded {
						guard let neural = probabilities[state.candidate.word], neural.isFinite else { continue }
						let language = self.ngram.sequenceLogProb(state.words, context: request.context)
						let score = -state.cost + self.lmWeight * (self.neuralPriorWeight * neural
							+ (1 - self.neuralPriorWeight) * language)
							+ self.freqWeight * self.frequencyTerm(state.logFrequency, mode: .compressed)
						ranked.append((state, score))
					}
					ranked.sort { $0.1 == $1.1 ? $0.0.candidate.word < $1.0.candidate.word : $0.1 > $1.1 }
					var perPosition: [Int: Int] = [:]
					var next: [MultiwordSearch.Hypothesis] = []
					for (state, _) in ranked {
						if state.offset == search.inputCount {
							if state.words.count >= 2 { finished.append(state.candidate) }
						} else if (perPosition[state.offset] ?? 0) < MultiwordSearch.beamPerPosition {
							perPosition[state.offset, default: 0] += 1; next.append(state)
						}
					}
					if depth < MultiwordSearch.maximumWords && !next.isEmpty { advance(next, depth: depth + 1) }
					else { completion(finished) }
				}
			}
		}
		advance([search.root], depth: 1)
	}

	func dontCorrect(_ word: String) {
		let lw = word.lowercased()
		queue.async { [weak self] in
			guard let self else { return }
			self.user.confirmSpelling(lw)
			self.scheduleSave()
		}
	}

	/// The user let an autocorrect of `original` stand (typed on instead of undoing).
	/// Acceptance is counter-evidence against an earlier rejection this session —
	/// lift the keep so correction resumes. Nothing persists; keeps are session-scoped.
	func correctionStood(_ original: String) {
		let lw = original.lowercased()
		queue.async { [weak self] in self?.user.releaseKeep(lw) }
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
			self.user.releaseKeep(lw)
			self.user.demote(lw)
			self.scheduleSave()
		}
	}
}
