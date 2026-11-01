import Foundation

extension KeyboardEngine {
	// MARK: Suggestions (background; also precomputes the autocorrect decision)

	func isLatest(_ gen: Int) -> Bool { genLock.lock(); defer { genLock.unlock() }; return gen == suggestGen }
	func cancelSuggestions() {
		genLock.lock(); sharedDecodeToken?.cancel(); suggestGen &+= 1; genLock.unlock()
		searchPrior?.cancelPendingSearch()
	}

	/// Targeted spatial alignment between two fixed strings using the same per-character
	/// cost table as the trie DP, so injected candidates compare directly in ranking.
	/// O(n·m) where n = typed length, m = target length — fast enough to call per word.
#if DEBUG || KB_REFERENCE_DECODER_YES
	func spatialCost(typed t: String, target g: String, taps: [KeyTap?]? = nil) -> Double {
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
				let sub = prev[j - 1] + KB.subCost(gb[j - 1], typed: tb[i - 1], tap: tap, typedFirst: i == 1)
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
		let budget = maxCost(for: lw.count) * (lw.count >= 8 ? Self.longBroadRecoveryFactor : Self.broadRecoveryFactor)

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
#endif

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
		// Score each candidate once rather than twice per comparison: the context bonus
		// and the safety lookup both walk mmap'd tables.
		let candidates = transliterator.candidates(for: currentWord.lowercased(),
			context: request.context, limit: 16)
			.filter { !lexicon.isProfane($0.text) }
			.map { candidate in
				(candidate: candidate, rank: candidate.score
					+ teluguLexicon.contextBonus(for: candidate.text, context: request.context)
					- lexicon.safetyPenalty(candidate.text))
			}
			.sorted { $0.rank > $1.rank }
			.map(\.candidate)
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
		let second = bytes[1]   // seeds a swapped first pair; part of the reuse key, as in native
		// As native: seeds cover this length's radius (2.8 up to 7 letters, so most first letters
		// stay under the state cap); a word growing past 7 letters reseeds once at 3.6.
		let radius = maxCost(for: word.count)
		let session: IncrementalDecodeSession
		if let active = incrementalDecodeSession,
			active.id == request.wordSessionID,
			active.layoutRevision == request.layoutRevision,
			active.radius >= radius,
			active.session.typed.isEmpty || (active.session.typed.count >= 2
				&& active.session.typed[0] == first && active.session.typed[1] == second) {
			session = active.session
		} else {
			guard let created = lexicon.makeIncrementalDecodeSession(
				typedFirst: first, firstTap: taps?.first ?? nil, typedSecond: second, maxCost: radius) else { return nil }
			incrementalDecodeSession = (request.wordSessionID,
				request.layoutRevision, radius, created)
			session = created
		}
		guard session.advance(to: word, taps: taps) else {
			incrementalDecodeSession = nil
			return nil
		}
		return session
	}


    private struct EnglishCandidatePool {
        let close: [Candidate]
        let broad: [Candidate]
        let injected: [Candidate]
        let completions: [Candidate]
        let displayCorrections: [Candidate]
        let split: (candidate: Candidate, a: String, b: String)?
        /// The closest dictionary match is a blocked word: no autocorrect (native `aimedAtBlocked`).
        let aimedAtBlocked: Bool
    }

    /// C++ owns English candidate generation. The legacy implementation remains
    /// independently selectable in validation builds. Unicode normalization and
    /// grapheme segmentation are supplied by Swift at the text boundary.
    private func generateEnglishPool(request: DecodeRequest, typed lw: String, context: [String],
        taps: [KeyTap?]?, normalCost: Double, recoveryPrior: TrieSearchPrior?,
        retained: IncrementalDecodeSession?, generation gen: Int) -> EnglishCandidatePool? {
        if candidateBackend == .cpp {
            do {
                let successors = context.isEmpty || lw.count < 4 ? [] : ngram.nextWords(context: context, limit: 32)
                let native = try lexicon.generateEnglishCandidates(typed: lw, taps: taps,
                    successors: successors, prior: recoveryPrior,
                    retainedStatic: retained?.candidates(maxCost: normalCost),
                    gruTier: request.requestedModelTier == .neuralGRU,
                    shouldCancel: { [weak self] in self?.isLatest(gen) != true })
                guard !native.cancelled, isLatest(gen) else { return nil }
                let split: (candidate: Candidate, a: String, b: String)? = native.split.flatMap {
                    let words = $0.word.split(separator: " ").map(String.init)
                    guard words.count == 2 else { return nil }
                    return (Candidate(native: $0), words[0], words[1])
                }
                return EnglishCandidatePool(close: native.close.map(Candidate.init(native:)),
                    broad: native.broad.map(Candidate.init(native:)), injected: native.injected.map(Candidate.init(native:)),
                    completions: native.completions.map(Candidate.init(native:)),
                    displayCorrections: native.displayCorrections.map(Candidate.init(native:)), split: split,
                    aimedAtBlocked: native.aimedAtBlocked)
            } catch {
                // Publish no partial native result; the controller retains literal input.
                return nil
            }
        }
#if DEBUG || KB_REFERENCE_DECODER_YES
        return generateEnglishPoolReference(request: request, typed: lw, context: context,
            taps: taps, normalCost: normalCost, recoveryPrior: recoveryPrior,
            retained: retained, generation: gen)
#else
        return nil
#endif
    }

#if DEBUG || KB_REFERENCE_DECODER_YES
    private func generateEnglishPoolReference(request: DecodeRequest, typed lw: String, context: [String],
        taps: [KeyTap?]?, normalCost: Double, recoveryPrior: TrieSearchPrior?,
        retained: IncrementalDecodeSession?, generation gen: Int) -> EnglishCandidatePool? {

        var corrections: [Candidate]
        if let retained {
            corrections = retained.candidates(maxCost: normalCost)
                + self.lexicon.mutableCorrections(for: lw,
                    maxCost: normalCost, taps: taps)
        } else {
            corrections = self.lexicon.corrections(for: lw,
                maxCost: normalCost, taps: taps,
                shouldCancel: { [weak self] in self?.isLatest(gen) != true })
        }
        // As native: neither search emits dropped-first-letter candidates (bove → above).
        if lw.count >= 4 {
            corrections += self.lexicon.missingFirstLetterCorrections(for: lw, maxCost: normalCost, taps: taps,
                shouldCancel: { [weak self] in self?.isLatest(gen) != true })
        }
        // As native: first letters a speller confuses (emminent → imminent), beside the retained search.
        let ascii = lw.utf8.count == lw.count
        if retained != nil, ascii, lw.count >= 5 {
            corrections += self.lexicon.firstLetterVariantCorrections(for: lw, maxCost: normalCost, taps: taps,
                shouldCancel: { [weak self] in self?.isLatest(gen) != true })
        }
        // As native: a neighbouring key typed before a non-word (vfell → fell).
        let bytes = Array(lw.utf8)
        if Trie.extraLeadingKeyCost < 3, ascii, bytes.count >= 3, KB.neighbouringKeys(bytes[0], bytes[1]),
           !self.lexicon.contains(lw) {
            let radius = self.maxCost(for: bytes.count - 1) - Trie.extraLeadingKeyCost
            let rest = taps.flatMap { $0.count == bytes.count ? Array($0.dropFirst()) : nil }
            if radius >= 0 {
                corrections += self.lexicon.corrections(for: String(lw.dropFirst()), maxCost: radius, taps: rest,
                    shouldCancel: { [weak self] in self?.isLatest(gen) != true })
                    .map { Candidate(word: $0.word, cost: $0.cost + Trie.extraLeadingKeyCost, logFreq: $0.logFreq) }
            }
        }
        // As native generateCandidates: blocked words are skipped during generation, but the
        // typed text itself is never censored and keeps its exact (cost 0) match.
        if self.lexicon.isGenerationBlocked(lw), !corrections.contains(where: { $0.word == lw }) {
            corrections.append(Candidate(word: lw, cost: 0, logFreq: self.lexicon.logFreq(of: lw) ?? 0))
        }
        // Exit before context expansion if a newer key or Glide superseded this pass.
        guard self.isLatest(gen) else { return nil }
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
        // As native: the closest blocked dictionary match bounds recovery (never a candidate).
        let blockedClosest = self.lexicon.closestBlockedCost(lw, maxCost: normalCost, taps: taps)
        let cleanClosest = corrections.map(\.cost).min() ?? .infinity
        let closestCost = min(cleanClosest, blockedClosest)
        // As native: strictly closer than every clean candidate means the typo is aimed at the
        // blocked word, so it is neither recovered nor autocorrected.
        let aimedAtBlocked = blockedClosest < cleanClosest
        let shouldRecover = lw.count >= 6 && !self.lexicon.contains(lw) && !aimedAtBlocked
            && completions.isEmpty
            && (lw.count >= 8 || (corrections.isEmpty && !blockedClosest.isFinite) || closestCost > 0.65)
        // As native: broad words above the loose ceiling are dropped below, so the walk stops there.
        let looseCostCeiling = closestCost <= normalCost
            ? closestCost + self.looseCandidateWindow : .infinity
        let broadCorrections: [Candidate] = shouldRecover
            ? Array(
                self.lexicon.broadCorrections(for: lw,
                maxCost: min(normalCost * (lw.count >= 8 ? Self.longBroadRecoveryFactor : Self.broadRecoveryFactor),
                    looseCostCeiling), taps: taps, prior: recoveryPrior,
                shouldCancel: { [weak self] in self?.isLatest(gen) != true })
                    .sorted {
                let lhs = $0.cost - 0.12 * $0.logFreq
                let rhs = $1.cost - 0.12 * $1.logFreq
                return lhs == rhs ? $0.word < $1.word : lhs < rhs
                    }
                    .prefix(request.requestedModelTier == .neuralGRU ? Int.max : 24)
              )
            : []
        // Channel-dominance guard: any match inside the NORMAL budget caps how
        // far the loose pools may reach — they exist for when the normal search
        // fails, not to leapfrog it ("could possibly" at spatial cost 7.2 must
        // not beat "definitely" at 2.0). `closestCost` is ∞ when the close
        // search found nothing, leaving the rescue path unrestricted.
        let admittedBroad = broadCorrections.filter { $0.cost <= looseCostCeiling }
        let correctionWords = Set((corrections + admittedBroad).map(\.word))
        let newFromContext = injected.filter {
            !correctionWords.contains($0.word) && $0.cost <= looseCostCeiling
        }
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
        guard self.isLatest(gen) else { return nil }
        let split = self.splitCandidate(of: lw)
        return EnglishCandidatePool(close: corrections, broad: admittedBroad, injected: newFromContext,
            completions: completions, displayCorrections: correctionSuggestions, split: split,
            aimedAtBlocked: aimedAtBlocked)
    }
#endif



	func decode(_ request: DecodeRequest, completion: @escaping (DecodeSnapshot) -> Void) {
		genLock.lock(); sharedDecodeToken?.cancel(); let nativeToken = KBCancellationToken(); sharedDecodeToken = nativeToken; suggestGen &+= 1; let gen = suggestGen; genLock.unlock()
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
			self.latestSearchRequest = (request, gen)
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
					}.map {
						(word: $0, isTyped: $0 == currentWord, penalty: self.lexicon.safetyPenalty($0))
					}.sorted { lhs, rhs in
						if lhs.isTyped != rhs.isTyped { return lhs.isTyped }
						return lhs.penalty < rhs.penalty
					}.map(\.word).prefix(3)
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

            if self.candidateBackend == .cpp,
               request.requestedModelTier == .ngram || request.requestedModelTier == .neuralSearchSpace {
                let view = self.lexicon.nativeGenerationView()
                if self.sharedEngine == nil { self.sharedEngine = self.makeSharedEngine() }
                if let engine = self.sharedEngine {
                    let tier: DecodeModelTier = request.requestedModelTier == .neuralSearchSpace
                        && engine.supportsNeuralSearchSpace ? .neuralSearchSpace : .ngram
                    let identity = [request.fieldRevision, request.documentRevision, request.wordSessionID,
                        request.generation, request.layoutRevision, self.lexicon.vocabularyRevision, KBPersonalData.currentEpoch]
                    var offsets = [0]
                    for ch in lw { offsets.append(offsets.last! + String(ch).utf8.count) }
                    let flags = Data(lw.flatMap { ch in Array(repeating: UInt8(ch.isLetter ? 1 : 0), count: String(ch).utf8.count) })
                    let buffers = NativeTapBuffers(taps: taps, expectedCount: lw.utf8.count)
                    do {
                        let result = try engine.decode(word: currentWord, normalized: lw, context: context.map { $0.lowercased() },
                            identity: identity.withUnsafeBytes { Data($0) }, characterOffsets: offsets.map { NSNumber(value: $0) },
                            letterFlags: flags, tapOffsets: buffers?.offsets, tapValidity: buffers?.validity,
                            lexicon: view, personal: self.user.nativeCountsSnapshot(),
                            topWords: self.lexicon.topWords.map { $0.lowercased() }, kept: self.isKept(lw),
                            modelTier: tier.rawValue, token: nativeToken)
                        guard !result.cancelled, self.isLatest(gen) else { return }
                        let typedScore = result.rows.first(where: { $0.word == lw })?.score ?? 0
                        let evidence = zip(result.rows, result.sources).map { row, source in
                            DecodeCandidateEvidence(word: row.word, score: row.score, spatialCost: row.cost,
                                logFrequency: row.logFrequency, logLanguageProbability: row.language,
                                source: DecodeCandidateSource(rawValue: source) ?? .fuzzyLexicon, typedWordMargin: row.score - typedScore)
                        }
                        let decision = result.correction
                        if let kind = decision.kind.flatMap(CorrectionGateEvidence.Kind.init(rawValue:)), let candidate = decision.candidate {
                            self.correctionObserver?(CorrectionGateEvidence(typed: lw, candidate: candidate, kind: kind,
                                typedMargin: decision.margin, candidateGap: decision.gap?.doubleValue,
                                spatialCost: decision.cost, allowsCloseRescue: decision.allowsCloseRescue))
                        }
                        publishEnglish(result.suggestions, evidence, decision.word, decision.margin, tier)
                        return
                    } catch { KBDiagnostics.recorder.storageFailure(operation: "native-decode") }
                }
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
				// The typed word + taps make generation prefix-aware (word-starts spatially
				// reachable from the first tap) once it is long enough to pin the word down.
				let recoveryPrior = self.contextSearchPrior(context, typedPrefix: lw, taps: taps)
				let retained = self.retainedDecodeSession(for: request, word: lw,
					taps: taps)

                guard let pool = self.generateEnglishPool(request: request, typed: lw, context: context,
                    taps: taps, normalCost: normalCost, recoveryPrior: recoveryPrior,
                    retained: retained, generation: gen) else { return }
                let corrections = pool.close
                let admittedBroad = pool.broad
                let newFromContext = pool.injected
                let completions = pool.completions
                let correctionSuggestions = pool.displayCorrections
                let allCorrections = corrections + admittedBroad + newFromContext
                let split = pool.split

				func finish(_ neuralSplits: [Candidate]) {
				let splitCandidates = (split.map { [$0.candidate] } ?? []) + neuralSplits
				let splitWords = Set(splitCandidates.map(\.word))
				var scoringCandidates = completions + correctionSuggestions + allCorrections
				scoringCandidates += splitCandidates
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
				displayWords.formUnion(splitWords)
				// Mirrors native EngineSession::score: where the 32-row pre-LM shortlist applies,
				// keep only the best 16 completion-only rows so zero-cost completions cannot crowd
				// out corrections (tat lost "that"). Same order, tie-break and blocked-row filter.
				if request.requestedModelTier != .neuralGRU {
					var completionOnly = completionWords.subtracting(correctionSuggestions.map(\.word))
						.subtracting(allCorrections.map(\.word)).subtracting(splitWords)
					completionOnly.remove(lw)
					let ranked = completions.filter { completionOnly.contains($0.word) }   // completions exclude blocked words
						.sorted {
							let a = -$0.cost + self.shortlistFreqWeight * self.frequencyTerm($0.logFreq, mode: .compressed)
							let b = -$1.cost + self.shortlistFreqWeight * self.frequencyTerm($1.logFreq, mode: .compressed)
							return a == b ? $0.word.utf8.lexicographicallyPrecedes($1.word.utf8) : a > b
						}
					if ranked.count > 16 {
						let dropped = Set(ranked.dropFirst(16).map(\.word))
						scoringCandidates.removeAll { dropped.contains($0.word) }
					}
				}
				self.rank(scoringCandidates, including: typed, context: context,
					request: request, generation: gen, log: "decode '\(lw)'",
					frequencyMode: .compressed) { outcome in
					guard let (ranked, tier) = outcome else { return }
					var result = ranked.filter { displayWords.contains($0.word) }.prefix(3)
						.map(\.word)
					let typedScore = ranked.first(where: { $0.word == lw })?.score ?? 0
					func source(for word: String) -> DecodeCandidateSource {
						if word == lw { return .typed }
						if splitWords.contains(word) { return .splitCorrection }
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
						for split in splitCandidates {
							correctionCosts[split.word] = min(correctionCosts[split.word] ?? .infinity, split.cost)
						}
						let broadRecoveryWords = broadWords.subtracting(closeWords)
						let resolved = self.correction(from: ranked,
							correctionCosts: correctionCosts, typed: lw,
							context: context, split: split,
							looseWords: broadWords.union(contextWords)
								.subtracting(closeWords),
							broadRecoveryWords: broadRecoveryWords, aimedAtBlocked: pool.aimedAtBlocked)
						decision = resolved.word
						decisionConfidence = resolved.margin
					}
					// The center suggestion and boundary decision are one contract.
					if let decision {
						result.removeAll { $0.caseInsensitiveCompare(decision) == .orderedSame }
						result.insert(decision, at: 0)
					} else if self.isKept(lw) {
						// An undone correction keeps the typed word in the middle; as native placeDecision.
						result.removeAll { $0.caseInsensitiveCompare(currentWord) == .orderedSame }
						result.insert(currentWord, at: 0)
					} else if !result.contains(where: {
						$0.caseInsensitiveCompare(currentWord) == .orderedSame
					}) {
						if result.count >= 3 { result[2] = currentWord }
						else { result.append(currentWord) }
					}
					publishEnglish(Array(result.prefix(3)), evidence, decision,
						decisionConfidence, tier)
				}
				}
				if request.requestedModelTier == .neuralGRU {
					self.multiwordCandidates(typed: lw, taps: taps, request: request,
						generation: gen, completion: finish)
				} else { finish([]) }

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
	func allowsPersonalAdoption(of word: String, count: Int) -> Bool {
        return user.allowsAdoption(word, count: count, lexicon: lexicon.nativeGenerationView())
	}
}
