// MIGRATION-FILE: planned SPLIT | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: CPP_CORE owns tokenizer/search mathematics; OBJCXX_BRIDGE owns Core ML/tensors; SWIFT_IOS owns lifecycle façades.
import Foundation
import CoreML

/// Words of left-context the neural model conditions on. The controller (`contextWords`) already
/// SENTENCE-SCOPES the context (it stops at `.!?\n`) and caps it at 8 words, so this is a redundant
/// safety cap kept in sync — the models never silently see more than the controller supplies. 8 also
/// matches the GRU's measured effective memory (tools/lm: the next-word distribution stops moving by
/// ~6–8 words), so a longer window would only add state-rebuild cost when a >8-word sentence slides
/// it. Because context is sentence-scoped and short, persisted state (see `runContext`) almost always
/// just extends by the newly committed word instead of rebuilding.
private let neuralContextWordCap = 8

// MIGRATION: planned CPP_CORE | stage=neural | target=Tokenizer
// MIGRATION-NOTE: Preserve existing token IDs, byte fallback, English tag and word-boundary convention.
private nonisolated final class KeyboardSentencePieceTokenizer: @unchecked Sendable {
    let native: KBNeuralTokenizer
    let padID: Int32
    let englishModeID: Int32?
    let idToPiece: [String]
    let startContent: [Bool]
    let continuationContent: [Bool]
    let startFirstLetter: [Character?]
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let native = KBNeuralTokenizer(data: data) else { return nil }
        self.native = native
        idToPiece = native.pieces
        native.setCharacterLengths(idToPiece.map { NSNumber(value: $0.count) })
        padID = native.pad
        englishModeID = native.english >= 0 ? native.english : nil
        startContent = native.starts.map(\.boolValue)
        continuationContent = native.continuations.map(\.boolValue)
        startFirstLetter = zip(idToPiece, startContent).map { piece, start in
            start ? piece.dropFirst().first.flatMap { $0.lowercased().first } : nil
        }
    }
    func encode(_ text: String) -> [Int32] {
        let words = text.precomposedStringWithCompatibilityMapping.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return [] }
        let characters = Array("\u{2581}" + words.joined(separator: "\u{2581}")).map(String.init)
        return native.encodeCharacters(characters).map(\.int32Value)
    }
    func word(fromPieceIDs ids: [Int32]) -> String {
        native.word(fromIDs: ids.map(NSNumber.init(value:))).lowercased()
    }
}

/// GRU streaming model for the neural search space (roadmap Plan 3) — the decoder's only neural
/// model. It generates hypotheses inside the trie search and supplies the exact complete-word
/// scores those hypotheses are ranked by; there is no second rescoring model. FAIL-SAFE: with no
/// bundled model/tokenizer, `isReady` stays false and the engine ranks on the n-gram alone.
///
/// UNVERIFIED until `gru.mlpackage` is exported (Colab, coremltools) and bundled: `step` runs
/// the exported forward_step (token + explicit recurrent state → logits + new state). It
/// compiles against the generic MLModel API, but its numeric path — and the streaming-vs-
/// batched score-export choice — can only be validated with the real model plus a running
/// keyboard. See the GRU integration walkthrough.
// MIGRATION: planned SPLIT | stage=neural | target=NeuralFacade
// MIGRATION-SPLIT: CPP_CORE owns tokenization/search/score policy; OBJCXX_BRIDGE owns Core ML execution/tensor transport; SWIFT_IOS keeps protocol and lifecycle façades.
final class GRULanguagePrior: NeuralLanguagePrior, NeuralSearchPrior, @unchecked Sendable {
	let modelTier: DecodeModelTier = .neuralGRU

	// MIGRATION: planned SPLIT | stage=neural | target=NativeErrors
	// MIGRATION-SPLIT: OBJCXX_BRIDGE translates model-output failures; SWIFT_IOS retains readiness/cancellation and protocol-facing error presentation.
	private enum GRUError: Error { case notReady, badOutput, cancelled }
	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	private struct Session { let contextTokens: [Int32] }

	private let compiledURL: URL?
	private let packageURL: URL?
	// Optional BATCHED scorer (gru_score.mlpackage from export_gru_score_coreml.py). Scores the
	// whole candidate pool in one [B,T] Core ML call instead of per-candidate single-step threading
	// — the §5 perf lever. `forward_step` already takes a batch dim, so it is the same recurrence
	// gathered at the candidate positions (tools/lm parity Δ≈5e-6). Best-effort: absent ⇒ the
	// single-step + first-piece-admission path is used, so nothing regresses without it.
	private let scoreCompiledURL: URL?
	private let scorePackageURL: URL?
	private let tokenizer: KeyboardSentencePieceTokenizer?
	private let layers: Int
	private let hidden: Int
	// Must match export_gru_score_coreml.py's B (candidate batch) and T (max scored pieces/word).
	private static let scoreBatch = 32
	private static let scoreTime = 16
	private let queue = DispatchQueue(label: "keyboard.neural.gru", qos: .userInitiated)
	private let lock = NSLock()
	private var model: MLModel?          // single-step: streaming generation + context threading
	private var scoreModel: MLModel?     // batched scorer; nil ⇒ single-step scoring path
	private var loading = false
	private var sessions: [UInt64: Session] = [:]
	// Persisted recurrent state (roadmap Plan 3, the streaming-state win). The GRU's whole point
	// is that state is a VALUE you can keep: rather than re-threading the ≤12-word context from
	// zero on every scoring pass (~20–30 sequential Core ML steps), cache (tokens, state) and, when
	// the next request's tokens EXTEND the cached ones (a committed word grows the context), thread
	// only the divergent suffix — verified bit-identical to a full rebuild. A prefix mismatch
	// (backspace across a boundary, cursor move, field change) rebuilds from zero. Guarded by
	// `lock`; correctness never depends on the guard because the state is a pure function of the
	// tokens (a stale entry either prefix-matches, extending exactly, or is discarded).
	private var contextStateCache: (tokens: [Int32], state: MLMultiArray)?
	private var modelEpoch: UInt64 = 0
	private var scoreGeneration: UInt64 = 0
	private var nextLoadUptime: Double = 0
	private var searchPriorCache: [SearchPriorQuery: [SearchPriorWord]] = [:]
	private var searchPriorOrder: [SearchPriorQuery] = []
	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	private struct WarmJob {
		let query: SearchPriorQuery
		let epoch: UInt64
        let lexicon: KBGenerationLexicon
	}
	// At most one active job and the latest context/prefix jobs, never one closure per key tap.
	private var pendingWarmJobs: [WarmJob] = []
	private var activeWarmQuery: SearchPriorQuery?
	private var latestWarmQueries: Set<SearchPriorQuery> = []
	private var drainingWarmJobs = false
	private var readyHandler: ((SearchPriorQuery) -> Void)?
	var onSearchPriorReady: ((SearchPriorQuery) -> Void)? {
		get { lock.lock(); defer { lock.unlock() }; return readyHandler }
		set { lock.lock(); readyHandler = newValue; lock.unlock() }
	}
	private static let searchPriorCacheCapacity = 48

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	static func bundled() -> GRULanguagePrior {
		GRULanguagePrior(
			compiledURL: Bundle.main.url(forResource: "gru", withExtension: "mlmodelc"),
			packageURL: Bundle.main.url(forResource: "gru", withExtension: "mlpackage"),
			tokenizerURL: Bundle.main.url(forResource: "gru_tokenizer", withExtension: "bin"),
			scoreCompiledURL: Bundle.main.url(forResource: "gru_score", withExtension: "mlmodelc"),
			scorePackageURL: Bundle.main.url(forResource: "gru_score", withExtension: "mlpackage"))
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	init(compiledURL: URL?, packageURL: URL?, tokenizerURL: URL?,
		scoreCompiledURL: URL? = nil, scorePackageURL: URL? = nil,
		layers: Int = 2, hidden: Int = 256) {
		self.compiledURL = compiledURL
		self.packageURL = packageURL
		self.scoreCompiledURL = scoreCompiledURL
		self.scorePackageURL = scorePackageURL
		self.tokenizer = tokenizerURL.flatMap(KeyboardSentencePieceTokenizer.init(url:))
		self.layers = layers
		self.hidden = hidden
		prepareForSelection()
	}

	var isReady: Bool { lock.lock(); defer { lock.unlock() }; return model != nil }

	/// Test/diagnostic: whether the optional batched scorer loaded (so scoring uses `batchScore`
	/// rather than the single-step path). Only meaningful once `isReady`.
	var usesBatchedScorer: Bool { lock.lock(); defer { lock.unlock() }; return scoreModel != nil }

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS selects artifacts, applies memory/cooldown gates and readiness policy; OBJCXX_BRIDGE loads/validates Core ML models.
	func prepareForSelection() {
		lock.lock()
		guard ProcessInfo.processInfo.systemUptime >= nextLoadUptime,
			tokenizer != nil, compiledURL != nil || packageURL != nil,
			model == nil, !loading else { lock.unlock(); return }
		let available = KBDiagnostics.availableBytes()
		guard available == 0 || available >= 35 * 1024 * 1024 else {
			nextLoadUptime = ProcessInfo.processInfo.systemUptime + 30
			lock.unlock()
			return
		}
		loading = true
		let epoch = modelEpoch
		lock.unlock()
		queue.async { [weak self] in self?.loadModel(epoch: epoch) }
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS owns resource selection, epochs and state publication; OBJCXX_BRIDGE compiles/loads/validates Core ML models.
	private func loadModel(epoch: UInt64) {
		do {
			let url: URL
			if let compiledURL { url = compiledURL }
			else if let packageURL { url = try MLModel.compileModel(at: packageURL) }
			else { lock.lock(); if modelEpoch == epoch { loading = false }; lock.unlock(); return }
			let configuration = MLModelConfiguration()
			configuration.computeUnits = .cpuAndNeuralEngine
			let loaded = try MLModel(contentsOf: url, configuration: configuration)
			// Best-effort batched scorer: absent/failed ⇒ scoreModel stays nil and streamScore uses
			// the single-step path, so the streaming prior never depends on it.
			let batched = loadScoreModel(configuration: configuration)
			try validateStepModel(loaded)
			lock.lock()
			let current = modelEpoch == epoch
			if current { model = loaded; scoreModel = batched; loading = false }
			let drain = current && !drainingWarmJobs && !pendingWarmJobs.isEmpty
			if drain { drainingWarmJobs = true }
			lock.unlock()
			if drain { queue.async { [weak self] in self?.drainWarmJobs() } }
		} catch {
			lock.lock()
			if modelEpoch == epoch {
				model = nil; scoreModel = nil; loading = false
				nextLoadUptime = ProcessInfo.processInfo.systemUptime + 30
			}
			lock.unlock()
		}
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private func validateStepModel(_ model: MLModel) throws {
		let inputs = model.modelDescription.inputDescriptionsByName
		let outputs = model.modelDescription.outputDescriptionsByName
		guard inputs["token"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, 1],
			inputs["state_in"]?.multiArrayConstraint?.shape.map(\.intValue) == [layers, 1, hidden],
			outputs["state_out"]?.multiArrayConstraint?.shape.map(\.intValue) == [layers, 1, hidden],
			outputs["logits"]?.multiArrayConstraint?.shape.last?.intValue == tokenizer?.idToPiece.count
		else { throw GRUError.badOutput }
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private func loadScoreModel(configuration: MLModelConfiguration) -> MLModel? {
		do {
			let url: URL
			if let scoreCompiledURL { url = scoreCompiledURL }
			else if let scorePackageURL { url = try MLModel.compileModel(at: scorePackageURL) }
			else { return nil }
			let loaded = try MLModel(contentsOf: url, configuration: configuration)
			// Older score exports omit word-ending probability. Fall back to exact streaming.
			guard loaded.modelDescription.inputDescriptionsByName["boundary_positions"] != nil,
				(loaded.modelDescription.metadata[.creatorDefinedKey] as? [String: String])?["keyboard_score_version"] == "2" else { return nil }
			return loaded
		} catch { return nil }
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	func prepareContext(_ words: [String], wordSessionID: UInt64) {
		guard let tokenizer else { return }
		var tokens = tokenizer.englishModeID.map { [$0] } ?? []
		tokens += tokenizer.encode(KBNeuralMath.lastWords(words, limit: UInt(neuralContextWordCap)).joined(separator: " ").lowercased())
		lock.lock(); sessions[wordSessionID] = Session(contextTokens: tokens); lock.unlock()
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	func discardSession(_ wordSessionID: UInt64) {
		lock.lock(); sessions[wordSessionID] = nil; lock.unlock()
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS handles pressure/epochs/cooldown; CPP_CORE clears search caches; OBJCXX_BRIDGE releases model/tensor/state resources.
	func handleMemoryPressure() {
		lock.lock()
		modelEpoch &+= 1
		scoreGeneration &+= 1
		nextLoadUptime = ProcessInfo.processInfo.systemUptime + 30
		model = nil; scoreModel = nil; loading = false
		contextStateCache = nil
		sessions.removeAll()
		searchPriorCache.removeAll(); searchPriorOrder.removeAll()
		pendingWarmJobs.removeAll(); latestWarmQueries.removeAll()
		lock.unlock()
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	func cancelPendingSearch() {
		lock.lock()
		pendingWarmJobs.removeAll(); latestWarmQueries.removeAll()
		scoreGeneration &+= 1
		lock.unlock()
	}

	func score(candidates: [String], wordSessionID: UInt64,
		completion: @escaping (Result<[String: Double], Error>) -> Void) {
		guard !candidates.isEmpty else { completion(.success([:])); return }
		lock.lock()
		let session = sessions[wordSessionID], ready = model
		scoreGeneration &+= 1
		let ticket = scoreGeneration, epoch = modelEpoch
		lock.unlock()
		guard let session, let ready, let tokenizer else {
			prepareForSelection()
			completion(.failure(GRUError.notReady))
			return
		}
		let bounded = Array(Set(candidates.map { $0.lowercased() })).sorted()
		queue.async { [weak self] in
			guard let self else { return }
			do {
				let scores = try self.streamScore(bounded, session: session,
					model: ready, tokenizer: tokenizer, shouldCancel: {
						self.lock.lock(); defer { self.lock.unlock() }
						return self.scoreGeneration != ticket || self.modelEpoch != epoch || self.sessions[wordSessionID] == nil
					})
				DispatchQueue.main.async { completion(.success(scores)) }
			} catch {
				DispatchQueue.main.async { completion(.failure(error)) }
			}
		}
	}

	private func streamScore(_ candidates: [String], session: Session, model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer, shouldCancel: () -> Bool = { false }) throws -> [String: Double] {
		guard !shouldCancel() else { throw GRUError.cancelled }
		let state = try runContext(session.contextTokens, model: model)
		let previous = session.contextTokens.last ?? tokenizer.padID
		let keys = Array(Set(candidates.map { $0.lowercased() })).sorted()
		let pairs = keys.compactMap { key -> (String, [Int32])? in
			let ids = tokenizer.encode(key)
			return ids.isEmpty ? nil : (key, ids)
		}
		lock.lock(); let batched = scoreModel; lock.unlock()
		var result: [String: Double] = [:]
		var remaining = pairs
		if let batched {
			let eligible = pairs.filter { $0.1.count < Self.scoreTime }
			remaining = pairs.filter { $0.1.count >= Self.scoreTime }
			if !eligible.isEmpty {
				let values: [NSNumber]? = withoutActuallyEscaping(shouldCancel) { cancel in
					KBNeuralRuntime.scoreBatch(batched, state: state, previous: previous,
						padID: tokenizer.padID, rows: eligible.map { $0.1.map(NSNumber.init(value:)) },
						layers: UInt(layers), hidden: UInt(hidden), batchSize: UInt(Self.scoreBatch),
						time: UInt(Self.scoreTime), cancel: cancel)
				}
				guard let values, values.count == eligible.count else { throw GRUError.badOutput }
				for (index, item) in eligible.enumerated() { result[item.0] = values[index].doubleValue }
			}
		}
		if !remaining.isEmpty {
			let scored: [String: NSNumber]? = withoutActuallyEscaping(shouldCancel) { cancel in
				KBNeuralRuntime.score(tokenizer.native, model: model, state: state, previous: previous,
					words: remaining.map(\.0), tokens: remaining.map { $0.1.map(NSNumber.init(value:)) },
					layers: UInt(layers), hidden: UInt(hidden), cancel: cancel)
			}
			guard let scored else { throw GRUError.badOutput }
			for (key, value) in scored { result[key] = value.doubleValue }
		}
		guard !shouldCancel() else { throw GRUError.cancelled }
		return result
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns exact query keys, cache lookup and LRU; SWIFT_IOS supplies vocabulary/model epochs and records hit/miss diagnostics.
	func searchPriorWords(_ query: SearchPriorQuery) -> [SearchPriorWord]? {
		lock.lock(); defer { lock.unlock() }
		let key = searchPriorCache[query] != nil ? query : query.withoutPrefix
		guard let words = searchPriorCache[key] else { KBDiagnostics.recordSearchPrior(state: "miss"); return nil }
		KBDiagnostics.recordSearchPrior(state: "hit")
		searchPriorOrder.removeAll { $0 == key }
		searchPriorOrder.append(key) // true LRU: hits refresh recency
		return words
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS coalesces/schedules and publishes current readiness; CPP_CORE owns query/seed and search-cache policy; OBJCXX_BRIDGE executes model batches.
	func warmSearchPrior(_ query: SearchPriorQuery, lexicon: KBGenerationLexicon) {
		guard tokenizer != nil, !query.context.isEmpty else { return }
		let queries = query.prefix == nil ? [query] : [query.withoutPrefix, query]
		lock.lock()
		latestWarmQueries = Set(queries)
		pendingWarmJobs = queries.filter { searchPriorCache[$0] == nil && activeWarmQuery != $0 }
			.map { WarmJob(query: $0, epoch: modelEpoch, lexicon: lexicon) }
		guard model != nil else { lock.unlock(); prepareForSelection(); return }
		let schedule = !drainingWarmJobs && !pendingWarmJobs.isEmpty
		if schedule { drainingWarmJobs = true }
		lock.unlock()
		if schedule { queue.async { [weak self] in self?.drainWarmJobs() } }
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	private func isCurrent(_ job: WarmJob) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return modelEpoch == job.epoch && latestWarmQueries.contains(job.query) && model != nil
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS owns job scheduling, epoch/cancellation checks and notifications; CPP_CORE generates/ranks and manages cache policy; OBJCXX_BRIDGE executes predictions.
	private func drainWarmJobs() {
		while true {
			lock.lock()
			guard !pendingWarmJobs.isEmpty, let model, let tokenizer else {
				drainingWarmJobs = false; activeWarmQuery = nil; lock.unlock(); return
			}
			let job = pendingWarmJobs.removeFirst()
			activeWarmQuery = job.query
			lock.unlock()
			let started = ProcessInfo.processInfo.systemUptime
			let cancelled = { !self.isCurrent(job) }
			let generated = generateNextWords(context: job.query.context, model: model,
				tokenizer: tokenizer, firstLetters: job.query.prefix?.firstLetters, limit: 24,
				lexicon: job.lexicon, shouldCancel: cancelled)
			// Keep all seed words, including adopted words appended after the original pool.
            var combined = generated.map(\.word)
            var seen = Set(combined)
            let letters = (job.query.prefix?.firstLetters ?? []).map(String.init)
            let seed = KBNeuralMath.knownWords(job.query.pool, lexicon: job.lexicon, firstLetters: letters)
            for word in seed where seen.insert(word).inserted { combined.append(word) }
			let ranked = cancelled() ? [] : rankPool(combined, context: job.query.context,
				model: model, tokenizer: tokenizer, shouldCancel: cancelled)
			lock.lock()
			let current = modelEpoch == job.epoch && latestWarmQueries.contains(job.query)
			let callback = current && !ranked.isEmpty ? readyHandler : nil
			if current && !ranked.isEmpty {
				searchPriorCache[job.query] = ranked
				searchPriorOrder.removeAll { $0 == job.query }
				searchPriorOrder.append(job.query)
				while searchPriorOrder.count > Self.searchPriorCacheCapacity {
					searchPriorCache.removeValue(forKey: searchPriorOrder.removeFirst())
				}
			}
			activeWarmQuery = nil
			lock.unlock()
			KBDiagnostics.recordSearchPrior(milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
				state: current ? "completed" : "cancelled")
			callback?(job.query)
		}
	}

	// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.


	/// GRU log P(word | context) for each supplied word, best first, WITH the log-prob attached.
	/// Reuses the streaming score path so the words are ranked by the neural LM on one consistent
	/// scale. Best-effort: a Core ML failure yields [] and the caller keeps the n-gram pool. The
	/// supplied set is the GRU's GENERATED next-words unioned with the n-gram pool, so ranking spans
	/// both sources — the GRU no longer merely re-orders what the n-gram already proposed.
	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	private func rankPool(_ pool: [String], context: [String], model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer, shouldCancel: () -> Bool = { false }) -> [SearchPriorWord] {
		var tokens = tokenizer.englishModeID.map { [$0] } ?? []
		tokens += tokenizer.encode(KBNeuralMath.lastWords(context, limit: UInt(neuralContextWordCap)).joined(separator: " ").lowercased())
		let session = Session(contextTokens: tokens)
		guard let scored = try? streamScore(pool, session: session, model: model,
			tokenizer: tokenizer, shouldCancel: shouldCancel) else { return [] }
        let available = pool.filter { scored[$0.lowercased()] != nil }
        let ordered = KBNeuralRuntime.sortWords(available, scores: available.map { NSNumber(value: scored[$0.lowercased()]!) }, limit: UInt(available.count))
        return ordered.compactMap { word in scored[word.lowercased()].map { SearchPriorWord(word: word, logProbability: $0) } }
	}

	// MARK: Next-word GENERATION (subword beam) — the recall fix vs pool reranking
	//
	// rankPool only RE-ORDERS the n-gram's candidate pool, so it inherits the n-gram's
	// next-word recall ceiling. This decodes the GRU's OWN next-word distribution as a
	// bounded subword beam, GENERATING context-plausible words the n-gram never proposed
	// (e.g. "on my WAY", "what are you DOING" when those continuations aren't in the sparse
	// bi/trigram tables). Each word is scored by log P(word) + log P(it ends here), so a
	// fragment the model wants to keep extending ("apo" → "apolog…") sinks below real words.
	// Alphabetic candidates only; the engine intersects them with the lexicon (a generated
	// word helps only if the trie can emit it). Validated against the PyTorch checkpoint in
	// tools/lm/generate_next_words.py, whose beam this mirrors step for step.

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.


	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns legal-token filtering, beam hypotheses and complete-word scoring; OBJCXX_BRIDGE predicts recurrent steps; SWIFT_IOS supplies cancellation/epoch validity.
	private func generateNextWords(context: [String], model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer, firstLetters: Set<Character>?, limit: Int,
		beamWidth: Int = 12, branch: Int = 8, maxPieces: Int = 6,
		lexicon: KBGenerationLexicon, shouldCancel: () -> Bool = { false })
		-> [(word: String, logProbability: Double)] {
		var tokens = tokenizer.englishModeID.map { [$0] } ?? []
		tokens += tokenizer.encode(KBNeuralMath.lastWords(context, limit: UInt(neuralContextWordCap)).joined(separator: " ").lowercased())
		if tokens.isEmpty { tokens = [tokenizer.padID] }
		guard let contextState = try? runContext(tokens, model: model) else { return [] }
        let allowed = tokenizer.startFirstLetter.map { letter in
            NSNumber(value: firstLetters.map { letters in letter.map { letters.contains($0) } ?? false } ?? true)
        }
        let completed: [String: NSNumber]? = withoutActuallyEscaping(shouldCancel) { cancel in
            KBNeuralRuntime.generate(tokenizer.native, model: model, state: contextState,
                previous: tokens.last ?? tokenizer.padID, starts: allowed,
                width: UInt(max(0, beamWidth)), branch: UInt(max(0, branch)), depth: UInt(max(0, maxPieces)),
                layers: UInt(layers), hidden: UInt(hidden), lexicon: lexicon, cancel: cancel)
        }
        guard let completed else { return [] }
        let words = Array(completed.keys)
        return KBNeuralRuntime.sortWords(words, scores: words.map { completed[$0]! }, limit: UInt(max(0, limit)))
            .map { (word: $0, logProbability: completed[$0]!.doubleValue) }
	}


	/// Dense log-softmax read straight off the logits buffer (no per-element NSNumber
	/// boxing on the beam's hot loop).
	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: OBJCXX_BRIDGE extracts checked stride-aware logits; CPP_CORE calculates finite log-softmax values.
	private func runContext(_ tokens: [Int32], model: MLModel) throws -> MLMultiArray {
		lock.lock()
		let epoch = modelEpoch
		let valid = self.model === model
		let cached = valid ? contextStateCache : nil
		lock.unlock()
		guard valid, let tokenizer else { throw GRUError.cancelled }
		let plan = KBNeuralRuntime.contextPlan(tokens.map(NSNumber.init(value:)),
			cached: (cached?.tokens ?? []).map(NSNumber.init(value:)), pad: tokenizer.padID)
		let state = plan[0].boolValue ? cached!.state : KBNeuralRuntime.zeroState(withLayers: UInt(layers), hidden: UInt(hidden))
		let suffix = Array(tokens.dropFirst(plan[1].intValue)).map(NSNumber.init(value:))
		let cancelled = { [weak self] in
			guard let self else { return true }
			self.lock.lock(); defer { self.lock.unlock() }
			return self.modelEpoch != epoch || self.model !== model
		}
		guard let result = withoutActuallyEscaping(cancelled, do: { cancel in
			KBNeuralRuntime.threadContext(suffix, tokenizer: tokenizer.native, model: model, state: state,
				previous: plan[2].int32Value, layers: UInt(layers), hidden: UInt(hidden), cancel: cancel)
		}) else { throw GRUError.cancelled }
		lock.lock()
		if modelEpoch == epoch && self.model === model { contextStateCache = (tokens, result) }
		lock.unlock()
		return result
	}

}
