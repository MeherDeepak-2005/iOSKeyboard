import Foundation
import CoreGraphics

extension KeyboardEngine {
	// MARK: Glide typing


	/// Accessed only on `glidePreviewQueue`. Each session retains its resampler,
	/// candidate pool, and online DTW rows for the lifetime of one finger gesture.
	struct StreamingGlideSession {
		let id: GlideSessionID
		let context: [String]
		var rawPointCount = 0
		var layoutPitch: (CGFloat, CGFloat)?
		let native = KBNativeGlideSession()
        var shared: KBSharedGlide?
        /// Vocabulary cannot change mid-gesture; computed once when the shared stream starts.
        var sharedDynamicWords: [String] = []
		var resampler = IncrementalGlideResampler()
		var candidates: [String: OnlineGlideCandidate] = [:]
		var endpointSignature = ""
		var revision: UInt64 = 0
		var latestPrediction: GlidePrediction?
		var invalid = false
	}

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
        if candidateBackend == .cpp, searchPrior == nil, let engine = sharedEngine {
            if session.shared == nil {
                session.shared = engine.glideSession(withContext: session.context.map { $0.lowercased() })
                session.sharedDynamicWords = lexicon.glideDynamicWords(limit: 128)
            }
            do {
                let scored = try session.shared!.update(GlideBuffers.points(path), keys: GlideBuffers.keys(layout),
                    centers: GlideBuffers.points(layout.centers.map(\.point)), xPitch: Double(layout.xPitch), yPitch: Double(layout.yPitch),
                    lexicon: lexicon.nativeGenerationView(), personal: user.nativeCountsSnapshot(), dynamicWords: session.sharedDynamicWords)
                guard let winner = scored.first else { return nil }
                let prediction = GlidePrediction(word: winner.word, alternatives: scored.dropFirst().prefix(3).map(\.word),
                    shapeCostByWord: Dictionary(scored.prefix(12).map { ($0.word, $0.cost) }, uniquingKeysWith: min),
                    margin: scored.count > 1 ? scored[0].score - scored[1].score : .greatestFiniteMagnitude)
                session.revision &+= 1; session.latestPrediction = prediction
                return GlideUpdate(sessionID: session.id, revision: session.revision, prediction: prediction)
            } catch { session.invalid = true; return nil }
        }
        if candidateBackend == .cpp {
            let native = session.native
            guard native.consume(GlideBuffers.points(path), keys: GlideBuffers.keys(layout), centers: GlideBuffers.points(layout.centers.map(\.point)),
                xPitch: Double(layout.xPitch), yPitch: Double(layout.yPitch)) else { session.invalid = true; return nil }
            if native.needsAugmentation {
                let seed = native.empty ? ngram.nextWords(context: session.context, limit: 48) : []
                let proposed = native.empty ? seed + neuralNextWords(context: session.context, seed: seed) : []
                native.augment(with: lexicon.nativeGenerationView(), contextWords: proposed, dynamicWords: lexicon.glideDynamicWords(limit: 128))
            }
            var order: [String: KBChannelCandidate] = [:]
            for row in native.rows { order[row.word] = row }
            let rows = Array(order.values)
            let language = ngram.logProbs(rows.map(\.word), context: session.context)
            let scored = KBGlidePipeline.rank(rows: rows, lexicon: lexicon.nativeGenerationView(), language: language.withUnsafeBytes { Data($0) },
                safety: rows.map { NSNumber(value: lexicon.generatedPenalty($0.word)) }, sigma: 0.10, dwell: Data())
            guard let winner = scored.first else { return nil }
            let prediction = GlidePrediction(word: winner.word, alternatives: scored.dropFirst().prefix(3).map(\.word),
                shapeCostByWord: Dictionary(scored.prefix(12).map { ($0.word, $0.cost) }, uniquingKeysWith: min),
                margin: scored.count > 1 ? scored[0].score - scored[1].score : .greatestFiniteMagnitude)
            session.revision &+= 1; session.latestPrediction = prediction
            return GlideUpdate(sessionID: session.id, revision: session.revision, prediction: prediction)
        }
#if DEBUG || KB_REFERENCE_DECODER_YES

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
		let suffix = GlidePreprocess.gridPoints(Array(path[session.rawPointCount...]), layout: layout)
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
#else
        return nil
#endif
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
			let ngramNext = ngram.nextWords(context: session.context, limit: 48)
			proposed.append(contentsOf: ngramNext)
			// #7: the GRU's generated next-words (the SAME cached list the recovery search funds the
			// trie with) join glide's rerank pool, so a swipe can resolve to a context-word the sparse
			// n-gram tables never listed. Non-blocking: reads the cache, warms it for later passes.
			proposed.append(contentsOf: neuralNextWords(context: session.context, seed: ngramNext))
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
			// Every proposal source (successors, completions, anchors, neural and learned
			// words) excludes blocked words at generation, so no per-candidate check here.
			guard normalized.count >= 2, session.candidates[normalized] == nil,
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
		let scored: [(String, Double, Double)] = rows.enumerated().map { index, candidate in
			let frequency: Double = lexicon.logFreq(of: candidate.word) ?? 0
			let score: Double = -candidate.prefixCost / 0.10
				+ glideLMWeight * priors[index]
				+ glideFreqWeight * frequency
				- lexicon.generatedPenalty(candidate.word)
			return (candidate.word, candidate.prefixCost, score)
		}.sorted { $0.2 == $1.2 ? $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) : $0.2 > $1.2 }
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

    private func scoreGlideCandidates(_ candidates: [(word: String, cost: Double)], glide: ProcessedGlide, context: [String]) -> [(word: String, s: Double)] {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if candidateBackend == .swiftReference { return scoreGlideCandidatesReference(candidates, glide: glide, context: context) }
#endif
        let language = ngram.logProbs(candidates.map(\.word), context: context)
        return KBGlidePipeline.rank(rows: candidates.map { KBChannelCandidate.make(word: $0.word, cost: $0.cost, logFrequency: 0) },
            lexicon: lexicon.nativeGenerationView(), language: language.withUnsafeBytes { Data($0) },
            safety: candidates.map { NSNumber(value: lexicon.generatedPenalty($0.word)) }, sigma: glideProfile.sigma,
            dwell: Data(glide.dwellKeys.compactMap(\.asciiValue))).map { ($0.word, $0.score) }
    }
#if DEBUG || KB_REFERENCE_DECODER_YES

	private func scoreGlideCandidatesReference(_ candidates: [(word: String, cost: Double)],
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
		.sorted { $0.s == $1.s ? $0.word.utf8.lexicographicallyPrecedes($1.word.utf8) : $0.s > $1.s }
	}

#endif

	private struct GlideDecodeResult {
		let candidates: [(word: String, cost: Double)]
		let scored: [(word: String, s: Double)]
	}

	/// The single production Glide pipeline used by both live feedback and final commit.
	/// Keeping candidate generation, recovery, gating, and ranking here prevents the preview
	/// from promising a word that a different release-time decoder would immediately replace.
    private func decodeGlide(_ glide: ProcessedGlide, lang: LangData, context: [String], shouldCancel: (() -> Bool)? = nil) -> GlideDecodeResult? {
#if DEBUG || KB_REFERENCE_DECODER_YES
        if candidateBackend == .swiftReference { return decodeGlideReference(glide, lang: lang, context: context, shouldCancel: shouldCancel) }
#endif
        guard shouldCancel?() != true else { return nil }
        let beam = GlideDecoder.decode(glide, lang: lang, limit: glideCandidates, shouldCancel: shouldCancel)
        let seed = context.isEmpty ? [] : ngram.nextWords(context: context, limit: glideContextAugment)
        let proposed = context.isEmpty ? [] : seed + neuralNextWords(context: context, seed: seed)
        let candidates = KBGlidePipeline.augment(beam: beam.map { KBChannelCandidate.make(word: $0.word, cost: $0.cost, logFrequency: 0) },
            lexicon: lexicon.nativeGenerationView(), points: GlideBuffers.points(glide.points), contextWords: proposed,
            dynamicWords: lexicon.glideDynamicWords(limit: 128), gate: glideProfile.gate, shouldCancel: shouldCancel).map { (word: $0.word, cost: $0.cost) }
        guard shouldCancel?() != true, !candidates.isEmpty else { return nil }
        let scored = scoreGlideCandidates(candidates, glide: glide, context: context)
        return scored.isEmpty ? nil : GlideDecodeResult(candidates: candidates, scored: scored)
    }
#if DEBUG || KB_REFERENCE_DECODER_YES

	private func decodeGlideReference(_ glide: ProcessedGlide, lang: LangData, context: [String],
								 shouldCancel: (() -> Bool)? = nil) -> GlideDecodeResult? {
		guard shouldCancel?() != true else { return nil }
		let gate = glideProfile.gate
		var candidates = SwiftGlideDecoder.decode(
			glide, lang: lang, limit: glideCandidates, shouldCancel: shouldCancel
		).filter { !lexicon.isProfane($0.word) }
		guard shouldCancel?() != true else { return nil }
		var knownWords = Set(candidates.map(\.word))

		if !context.isEmpty {
			let ngramAugment = ngram.nextWords(context: context, limit: glideContextAugment)
			// #7: fold the GRU's cached next-words into the same context-augment loop (see
			// augmentStreamingCandidates) so the final glide decode ranks them too.
			for word in ngramAugment + neuralNextWords(context: context, seed: ngramAugment)
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
#endif

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
}
