import Foundation

extension KeyboardEngine {
	// MARK: Ranking — the blend of channel, prior, personalization, and frequency

	/// Dedupes (keeping each word's cheapest channel cost), drops blocked words, then
	enum FrequencyMode { case raw, compressed }

	func frequencyTerm(_ logFreq: Double, mode: FrequencyMode) -> Double {
		switch mode {
		case .raw:
			return logFreq
		case .compressed:
			return log1p(max(logFreq, 0))
		}
	}

	/// Blends one batched prior call with the channel cost and lexicon frequency:
	///   final = -channelWeight·spatialCost + lmWeight·logP(w|ctx) + freqWeight·logFreq
	/// Suggestion ranking uses a compressed frequency term; correction ranking keeps
	/// raw frequency so the calibrated autocorrect gates remain stable.
	/// Runs only on the serial decoder queue.
	/// `extra` (the margin gate's typed-word row) is exempt from the profanity filter
	/// and the cap: it must always come back scored.
    private func rankNgram(_ cands: [Candidate], including extra: Candidate? = nil,
        context: [String], log label: String? = nil, frequencyMode: FrequencyMode = .raw,
        limit: Int? = 32) -> [RankedCandidate] {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if candidateBackend == .swiftReference {
            return rankNgramReference(cands, including: extra, context: context, log: label, frequencyMode: frequencyMode, limit: limit)
        }
#endif
        // Blocked words are excluded during candidate generation, so only residual
        // in-dictionary demote penalties (none in the shipped pack) apply here.
        func penalty(_ word: String) -> NSNumber { NSNumber(value: lexicon.generatedPenalty(word)) }
        let prepared = KBRanking.prepare(cands.map(\.native),
            safety: cands.map { penalty($0.word) }, extra: extra?.native)
        // Boundary-only iteration permutation preserves the old Swift dictionary
        // tie semantics. Deduplication and every ranking decision are native.
        var order: [String: KBScoredRow] = [:]
        order.reserveCapacity(prepared.count)
        for row in prepared { order[row.word] = row }
        let list = KBRanking.shortlistRows(Array(order.values), extra: extra?.native,
            limit: limit.map { NSNumber(value: $0) }, compressed: frequencyMode == .compressed)
        let priors = ngram.candidateLogProbs(list.map(\.word), context: context)
        let data = priors.withUnsafeBytes { Data($0) }
        let scored = KBRanking.rankRows(list, language: data, neural: nil,
            safety: list.map { penalty($0.word) }, typed: extra?.word ?? "",
            compressed: frequencyMode == .compressed, limit: nil).map(RankedCandidate.init(native:))
        if let label, KBDiagnostics.verbose {
            KBDiagnostics.logRanking(label: label, context: context, rows: scored.map {
                .init(word: $0.word, cost: $0.spatialCost, logFreq: $0.logFrequency,
                    freqTerm: frequencyTerm($0.logFrequency, mode: frequencyMode), ngram: $0.logLanguageProbability, score: $0.score)
            }, ms: 0)
        }
        return scored
    }
#if DEBUG || KB_REFERENCE_DECODER_YES

	private func rankNgramReference(_ cands: [Candidate], including extra: Candidate? = nil,
						  context: [String], log label: String? = nil,
						  frequencyMode: FrequencyMode = .raw, limit: Int? = 32) -> [RankedCandidate] {
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
		let cap = limit.map { extra == nil ? $0 : $0 - 1 }
		if let cap, list.count > cap {
			list.sort {
                let a = -$0.cost + shortlistFreqWeight * frequencyTerm($0.logFreq, mode: frequencyMode)
                let b = -$1.cost + shortlistFreqWeight * frequencyTerm($1.logFreq, mode: frequencyMode)
                return a == b ? $0.word.utf8.lexicographicallyPrecedes($1.word.utf8) : a > b
			}
			list = Array(list.prefix(cap))
		}
		if let extra {
			list.removeAll { $0.word == extra.word }
			list.append(extra)
		}
		let doLog = label != nil && KBDiagnostics.verbose
		let t0 = doLog ? Date() : nil
		var priors = ngram.logProbs(list.map(\.word), context: context)
		for index in list.indices where list[index].word.contains(" ") {
			priors[index] = ngram.sequenceLogProb(list[index].word.split(separator: " ").map(String.init), context: context)
		}
		let scored = zip(list, priors)
			.map { candidate, prior in
				RankedCandidate(
					word: candidate.word,
					score: -channelWeight * candidate.cost - (candidate.word == extra?.word
						? 0 : lexicon.safetyPenalty(candidate.word)) + lmWeight * prior
						+ freqWeight * frequencyTerm(candidate.logFreq, mode: frequencyMode),
					spatialCost: candidate.cost,
					logFrequency: candidate.logFreq,
					logLanguageProbability: prior,
					neuralLogProbability: nil
				)
			}
			.sorted { $0.score == $1.score ? $0.word.utf8.lexicographicallyPrecedes($1.word.utf8) : $0.score > $1.score }
		if doLog, let label {
			let ms = t0.map { Date().timeIntervalSince($0) * 1000 } ?? 0
			var rows: [KBDiagnostics.RankRow] = []
			for (i, c) in list.enumerated() {
				let freqTerm = frequencyTerm(c.logFreq, mode: frequencyMode)
					let safetyPenalty = c.word == extra?.word ? 0 : lexicon.safetyPenalty(c.word)
					rows.append(.init(word: c.word, cost: c.cost + safetyPenalty, logFreq: c.logFreq,
									  freqTerm: freqTerm,
									  ngram: priors[i],
									  score: -channelWeight * c.cost - safetyPenalty + lmWeight * priors[i]
										+ freqWeight * freqTerm))
			}
			rows.sort { $0.score > $1.score }
			KBDiagnostics.logRanking(label: label, context: context, rows: rows, ms: ms)
		}
		return scored
	}

#endif

	/// Produces one authoritative ranking for the tier frozen into `request`. Neural
	/// scoring is asynchronous and never blocks either host insertion or the serial
	/// decoder queue. A failed neural session publishes no replacement snapshot; it
	/// cannot silently change ranking semantics to n-gram halfway through a word.
	func rank(_ cands: [Candidate], including extra: Candidate? = nil,
					  context: [String], request: DecodeRequest, generation: Int,
					  log label: String? = nil,
					  frequencyMode: FrequencyMode = .raw,
					  completion: @escaping (([RankedCandidate], DecodeModelTier)?) -> Void) {
		let ngramRows = rankNgram(cands, including: extra, context: context,
			log: label, frequencyMode: frequencyMode,
			limit: request.requestedModelTier == .neuralGRU ? nil : scoreCap)
		guard request.requestedModelTier != .ngram else {
			completion((ngramRows, .ngram))
			return
		}
		guard request.languageMode == .english,
			  let prior = searchPrior,
			  prior.modelTier == request.requestedModelTier,
			  !ngramRows.isEmpty else {
			completion(nil)
			return
		}

		if preparedNeuralSession?.id != request.wordSessionID
			|| preparedNeuralSession?.context != context {
			if let previous = preparedNeuralSession {
				prior.discardSession(previous.id)
			}
			prior.prepareContext(context, wordSessionID: request.wordSessionID)
			preparedNeuralSession = (request.wordSessionID, context)
		}

		let words = ngramRows.map(\.word)
		prior.score(candidates: words, wordSessionID: request.wordSessionID) {
			[weak self] result in
			guard let self else { return }
			self.queue.async {
				guard self.isLatest(generation) else {
					completion(nil)
					return
				}
				guard case .success(let probabilities) = result else {
					completion(nil)
					return
				}
                let neuralValues = ngramRows.compactMap { probabilities[$0.word] }
                guard neuralValues.count == ngramRows.count, neuralValues.allSatisfy(\.isFinite) else {
                    completion(nil); return
                }
                let languages = ngramRows.map(\.logLanguageProbability).withUnsafeBytes { Data($0) }
                let neuralData = neuralValues.withUnsafeBytes { Data($0) }
                let ranked = KBRanking.rankRows(ngramRows.map(\.native), language: languages, neural: neuralData,
                    safety: ngramRows.map { NSNumber(value: self.lexicon.generatedPenalty($0.word)) },
                    typed: request.currentWord.lowercased(), compressed: frequencyMode == .compressed,
                    limit: NSNumber(value: self.scoreCap)).map(RankedCandidate.init(native:))
                completion((ranked, request.requestedModelTier))
			}
		}
	}

	/// Context-conditioned trie search prior (NN-LM in the trie). The words the LM expects
	/// to come next fund extra edit budget along their prefixes inside the trie walk, so a
	/// context-plausible word just outside the fixed edit radius is generated. Empty context
	/// or no predictions → nil, which reproduces today's exact pure-channel search. Must run
	/// on `queue`.
	///
	/// Source is the n-gram by default (rank-decayed funding). When a neural `searchPrior` is
	/// present it GENERATES its own likely next-words and ranks them WITH log-probabilities, so
	/// the funding is probability-DERIVED (`TrieSearchPrior(scoredWords:)`) — a confident context
	/// widens the search narrowly and deeply, an unsure one broadly and shallowly. `warmSearchPrior`
	/// kicks off an async pass (idempotent per key) and `searchPriorWords` returns the cache once
	/// ready — until then this transparently falls back to the n-gram, so the prior is never blocked
	/// on Core ML. Once the typed word is long enough to pin the word down, generation is additionally
	/// PREFIX-constrained to word-starts spatially reachable from the first tap.
	func contextSearchPrior(_ context: [String], typedPrefix lw: String = "",
		taps: [KeyTap?]? = nil) -> TrieSearchPrior? {
		guard !context.isEmpty else { return nil }
		let pool = ngram.nextWords(context: context, limit: 24)
		if let searchPrior {
			// Prefix-aware generation only once a few characters pin the word down; below that the
			// spatial first-letter set is too permissive to sharpen anything.
			let prefix: SearchPrefix? = lw.count >= 3
				? SearchPrefix(text: lw,
					firstLetters: plausibleFirstLetters(typedPrefix: lw, taps: taps))
				: nil
			// #6: seed the pool with the user's ADOPTED next-words. The corpus n-gram's `nextWords`
			// drops these (they're not static words, so they must not flood plain suggestions), but
			// the GRU CAN assign them a real P(word|context) — the n-gram has only the OOV floor —
			// so a context-plausible personal word can be generated in the recovery search where the
			// corpus tables never proposed it. They're in the personal trie, so the trie can emit them.
			let seeded = pool + userAdoptedNextWords(context: context,
				excluding: Set(pool.map { $0.lowercased() }))
			let query = SearchPriorQuery(context: context, prefix: prefix, pool: seeded,
				vocabularyRevision: lexicon.vocabularyRevision)
			searchPrior.warmSearchPrior(query, lexicon: lexicon.nativeGenerationView())
			if let scored = searchPrior.searchPriorWords(query) {
				// The neural set GENERATES next-words (subword beam), not just reranks the pool.
				// Keep only words the trie can emit — a prefix bonus on an OOV word funds a path to
				// no candidate; the generated in-lexicon words the sparse n-gram tables missed are
				// the recall win. Each word carries its log-prob, so the bonus is probability-derived.
				let usable = scored.filter { lexicon.contains($0.word) }
				if !usable.isEmpty {
					let prior = TrieSearchPrior(
						scoredWords: usable.map { ($0.word, $0.logProbability) })
					KBDiagnostics.recordSearchPrior(state: "neural-funded")
					return prior.isEmpty ? nil : prior
				}
			}
		}
		guard !pool.isEmpty else { return nil }
		let prior = TrieSearchPrior(likelyWords: pool)
		KBDiagnostics.recordSearchPrior(state: "ngram-funded")
		return prior.isEmpty ? nil : prior
	}

	/// First characters the opening tap could plausibly be — the literal typed first letter plus
	/// its spatial neighbours (≤ ~one edit under the touch model). Feeds prefix-AWARE generation so
	/// the beam only spends on words whose start is reachable from where the finger actually landed,
	/// tolerating a first-letter slip instead of hard-filtering on the literal character. Empty ⇒
	/// no constraint.
	private func plausibleFirstLetters(typedPrefix lw: String, taps: [KeyTap?]?) -> Set<Character> {
		guard let firstByte = lw.utf8.first else { return [] }
		let aligned = taps?.count == lw.utf8.count ? taps : nil
		let firstTap = aligned?.first ?? nil
		var letters: Set<Character> = [Character(UnicodeScalar(firstByte))]
		for row in KB.rows {
			for byte in row.utf8 where KB.subCost(byte, typed: firstByte, tap: firstTap) <= 1.0 {
				letters.insert(Character(UnicodeScalar(byte)))
			}
		}
		return letters
	}

	/// The user's ADOPTED next-words for this context (#6): successors they have actually typed
	/// here that live in the personal trie but NOT the static corpus (`contains && !isStaticWord`),
	/// which is exactly the set `NgramScorer.nextWords` drops. Handed to the neural search prior so
	/// the GRU can rank them by P(word|context) — signal neither the n-gram (OOV floor only) nor the
	/// current wiring can express. Bounded and best-count-first; `seen` (the n-gram pool) is skipped.
	/// Must run on `queue`.
	private func userAdoptedNextWords(context: [String], excluding seen: Set<String>,
		limit: Int = 12) -> [String] {
		guard let last = context.last?.lowercased() else { return [] }
		var counts: [String: Int] = [:]
		if context.count >= 2 {
			let key = context[context.count - 2].lowercased() + " " + last
			for (word, count) in user.triDist(key) { counts[word, default: 0] += count }
		}
		for (word, count) in user.biDist(last) { counts[word, default: 0] += count }
		return counts.sorted { $0.value > $1.value }.map(\.key).filter {
			!seen.contains($0.lowercased()) && !lexicon.isStaticWord($0)
				&& lexicon.contains($0) && !lexicon.isProfane($0)
		}.prefix(limit).map { $0 }
	}

	/// #7: the neural search prior's cached context-only next-words (words only) — the SAME ranked
	/// list `contextSearchPrior` funds the recovery trie with, now also feeding glide's rerank pools
	/// (which previously folded only `ngram.nextWords`). Non-blocking: kicks a warm so a later pass
	/// has it, and returns whatever is already cached (nil ⇒ empty, today's behavior). Kept to
	/// trie-emittable words for parity with the recovery path. Safe off any queue — the provider is
	/// internally locked. `pool` seeds the warm (the n-gram next-words already computed by the caller).
	func neuralNextWords(context: [String], seed pool: [String], limit: Int = 24) -> [String] {
		guard let searchPrior, !context.isEmpty else { return [] }
		let query = SearchPriorQuery(context: context, prefix: nil, pool: pool,
			vocabularyRevision: lexicon.vocabularyRevision)
		searchPrior.warmSearchPrior(query, lexicon: lexicon.nativeGenerationView())
		guard let scored = searchPrior.searchPriorWords(query) else { return [] }
		return scored.prefix(limit).map(\.word).filter { lexicon.contains($0) }
	}

	/// Must run on `queue`.
	func nextWords(context: [String]) -> [String] {
		// Never re-offer the word that was just committed — "the the" reads as a bug,
		// and stock never does it. (Legit doubles are rare and still typeable.)
		let last = context.last?.lowercased()
		var out: [String] = []
		for w in ngram.nextWords(context: context, limit: 8)
			where w != last && !out.contains(w) { out.append(w) }   // successors exclude blocked words
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
