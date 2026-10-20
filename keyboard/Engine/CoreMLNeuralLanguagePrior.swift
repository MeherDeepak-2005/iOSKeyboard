// MIGRATION-FILE: planned SPLIT | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: CPP_CORE owns tokenizer/search mathematics; OBJCXX_BRIDGE owns Core ML/tensors; SWIFT_IOS owns lifecycle façades.
import Foundation
import CoreML

/// Words of left-context the neural models condition on. The controller (`contextWords`) already
/// SENTENCE-SCOPES the context (it stops at `.!?\n`) and caps it at 8 words, so this is a redundant
/// safety cap kept in sync — the models never silently see more than the controller supplies. 8 also
/// matches the GRU's measured effective memory (tools/lm: the next-word distribution stops moving by
/// ~6–8 words), so a longer window would only add state-rebuild cost when a >8-word sentence slides
/// it. Because context is sentence-scoped and short, persisted state (see `runContext`) almost always
/// just extends by the newly committed word instead of rebuilding.
private let neuralContextWordCap = 8

// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
nonisolated enum NeuralRuntimeState: String, Codable, Equatable, Sendable {
	case artifactMissing = "artifact-missing"
	case compiling
	case loading
	case incompatibleInterface = "incompatible-interface"
	case memoryGated = "memory-gated"
	case ready
	case scoringFailure = "scoring-failure"
	case pressureUnloaded = "pressure-unloaded"
}

// MIGRATION: planned CPP_CORE | stage=neural | target=Tokenizer
// MIGRATION-NOTE: Preserve existing token IDs, byte fallback, English tag and word-boundary convention.
private nonisolated final class KeyboardSentencePieceTokenizer: @unchecked Sendable {
	private var pieces: [String: (id: Int32, score: Float)] = [:]
	private let unknownID: Int32
	let padID: Int32
	let englishModeID: Int32?
	private let maximumPieceLength: Int
	// Decode + word-boundary tables for next-word GENERATION (the subword beam).
	//   idToPiece         : id -> piece string, so a beam's token ids reconstruct a word.
	//   startContent[id]  : "▁word" — a word-initial alphabetic piece.
	//   continuation[id]  : "ing"   — a mid-word alphabetic piece (no space marker).
	// Punctuation, byte-fallback (<0x..>), digits, and control pieces are neither: they act
	// as word boundaries and never become part of a generated word (same alphabetic gate the
	// lexicon applies), so the generator emits only real word candidates.
	private(set) var idToPiece: [String] = []
	private(set) var startContent: [Bool] = []
	private(set) var continuationContent: [Bool] = []
	/// For a word-initial content piece ("▁word"), its lowercased first letter ('w'); nil for
	/// every other piece. Lets prefix-AWARE generation seed only word-starts whose first letter is
	/// spatially reachable from the first tap, without the beam parsing piece strings on its hot loop.
	private(set) var startFirstLetter: [Character?] = []

	// MIGRATION: planned SPLIT | stage=neural | target=Tokenizer
	// MIGRATION-SPLIT: SWIFT_IOS resolves/maps the tokenizer resource; CPP_CORE validates and builds the exact existing token/boundary tables.
	init?(url: URL) {
		guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
			data.count >= 16 else { return nil }
		// MIGRATION: planned CPP_CORE | stage=neural | target=Tokenizer
		// MIGRATION-NOTE: Preserve existing token IDs, byte fallback, English tag and word-boundary convention.
		func u32(_ offset: Int) -> Int {
			Int(UInt32(littleEndian: data.withUnsafeBytes {
				$0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
			}))
		}
		guard u32(0) == 0x4B42544B, u32(4) == 1 else { return nil }
		let count = u32(8)
		unknownID = Int32(u32(12))
		let scoresBase = 16
		let offsetsBase = scoresBase + 4 * count
		let blobBase = offsetsBase + 4 * (count + 1)
		guard count > 0, blobBase <= data.count else { return nil }
		var maximum = 1
		var pad: Int32?
		var english: Int32?
		pieces.reserveCapacity(count)
		var idToPieceLocal = [String](repeating: "", count: count)
		var startLocal = [Bool](repeating: false, count: count)
		var continuationLocal = [Bool](repeating: false, count: count)
		var startFirstLetterLocal = [Character?](repeating: nil, count: count)
		for index in 0..<count {
			let rawScore = UInt32(littleEndian: data.withUnsafeBytes {
				$0.loadUnaligned(fromByteOffset: scoresBase + 4 * index, as: UInt32.self)
			})
			let start = blobBase + u32(offsetsBase + 4 * index)
			let end = blobBase + u32(offsetsBase + 4 * (index + 1))
			guard start >= blobBase, end >= start, end <= data.count else { return nil }
			let piece = String(decoding: data[start..<end], as: UTF8.self)
			pieces[piece] = (Int32(index), Float(bitPattern: rawScore))
			if piece == "<pad>" { pad = Int32(index) }
			if piece == "<en>" { english = Int32(index) }
			maximum = max(maximum, piece.count)
			idToPieceLocal[index] = piece
			let isWordStart = piece.hasPrefix("\u{2581}")
			let body = isWordStart ? Substring(piece.dropFirst()) : Substring(piece)
			let alphabetic = !body.isEmpty && body.unicodeScalars.allSatisfy {
				($0.value >= 97 && $0.value <= 122)     // a-z
					|| ($0.value >= 65 && $0.value <= 90) // A-Z
					|| $0.value == 39                     // apostrophe
			}
			startLocal[index] = isWordStart && alphabetic
			continuationLocal[index] = !isWordStart && alphabetic
			if isWordStart && alphabetic {
				startFirstLetterLocal[index] = body.first.flatMap { $0.lowercased().first }
			}
		}
		padID = pad ?? 0
		englishModeID = english
		maximumPieceLength = min(maximum, 24)
		idToPiece = idToPieceLocal
		startContent = startLocal
		continuationContent = continuationLocal
		startFirstLetter = startFirstLetterLocal
	}

	// MIGRATION: planned CPP_CORE | stage=neural | target=Tokenizer
	// MIGRATION-NOTE: Preserve existing token IDs, byte fallback, English tag and word-boundary convention.
	func encode(_ text: String) -> [Int32] {
		let normalized = text.precomposedStringWithCompatibilityMapping
		let words = normalized.split(whereSeparator: { $0.isWhitespace })
		guard !words.isEmpty else { return [] }
		let characters = Array("\u{2581}" + words.joined(separator: "\u{2581}"))
		let count = characters.count
		var scores = [Float](repeating: -.infinity, count: count + 1)
		var backStart = [Int](repeating: 0, count: count + 1)
		var backIDs = [[Int32]](repeating: [unknownID], count: count + 1)
		scores[0] = 0
		for end in 1...count {
			for start in max(0, end - maximumPieceLength)..<end where scores[start].isFinite {
				let value = String(characters[start..<end])
				if let piece = pieces[value], scores[start] + piece.score > scores[end] {
					scores[end] = scores[start] + piece.score
					backStart[end] = start
					backIDs[end] = [piece.id]
				}
			}
			if !scores[end].isFinite {
				let bytes = String(characters[end - 1]).utf8
				let byteIDs = bytes.compactMap { byte in
					pieces[String(format: "<0x%02X>", byte)]?.id
				}
				backIDs[end] = byteIDs.count == bytes.count ? byteIDs : [unknownID]
				scores[end] = scores[end - 1] - 20
				backStart[end] = end - 1
			}
		}
		var result: [Int32] = []
		var cursor = count
		while cursor > 0 {
			result.append(contentsOf: backIDs[cursor].reversed())
			cursor = backStart[cursor]
		}
		return result.reversed()
	}

	/// Reconstruct the word a beam's piece ids spell (drop the ▁ word marker, lowercase to
	/// the lexicon's form). Used only by next-word generation.
	// MIGRATION: planned CPP_CORE | stage=neural | target=Tokenizer
	// MIGRATION-NOTE: Preserve existing token IDs, byte fallback, English tag and word-boundary convention.
	func word(fromPieceIDs ids: [Int32]) -> String {
		var text = ""
		text.reserveCapacity(ids.count * 4)
		for id in ids {
			let index = Int(id)
			if index >= 0, index < idToPiece.count { text += idToPiece[index] }
		}
		return text.replacingOccurrences(of: "\u{2581}", with: "").lowercased()
	}
}

/// Internal-only Core ML scorer. The model tier is sampled between words; this class
/// never inserts text and never blocks the host-input path.
// MIGRATION: planned SPLIT | stage=neural | target=NeuralFacade
// MIGRATION-SPLIT: CPP_CORE owns tokenization/search/score policy; OBJCXX_BRIDGE owns Core ML execution/tensor transport; SWIFT_IOS keeps protocol and lifecycle façades.
final class CoreMLNeuralLanguagePrior: NeuralLanguagePrior, @unchecked Sendable {
	// MIGRATION: planned SPLIT | stage=neural | target=NativeErrors
	// MIGRATION-SPLIT: OBJCXX_BRIDGE translates native/model failures into bridge errors; SWIFT_IOS retains localized protocol-facing error presentation.
	private enum RuntimeError: LocalizedError {
		case missingSession
		case staleSession
		case candidateTooLong(String)
		case allocation
		case invalidOutput
		case incompatible(String)

		var errorDescription: String? {
			switch self {
			case .missingSession: return "Neural context session is missing"
			case .staleSession: return "Neural context session was cancelled"
			case .candidateTooLong(let word): return "Candidate is too long for Core ML: \(word)"
			case .allocation: return "Unable to allocate fixed Core ML inputs"
			case .invalidOutput: return "Core ML returned an invalid candidate score tensor"
			case .incompatible(let detail): return detail
			}
		}
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	private struct Session {
		let generation: UInt64
		let contextTokens: [Int32]
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private final class Buffers {
		let tokens: MLMultiArray
		let scorePositions: MLMultiArray
		let targetIDs: MLMultiArray
		let scoreMask: MLMultiArray
		let nextPositions: MLMultiArray

		// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
		// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
		init?() {
			guard let tokens = try? MLMultiArray(shape: [16, 32], dataType: .int32),
				let positions = try? MLMultiArray(shape: [16, 8], dataType: .int32),
				let targets = try? MLMultiArray(shape: [16, 8], dataType: .int32),
				let mask = try? MLMultiArray(shape: [16, 8], dataType: .float32),
				let next = try? MLMultiArray(shape: [16, 1], dataType: .int32) else { return nil }
			self.tokens = tokens
			scorePositions = positions
			targetIDs = targets
			scoreMask = mask
			nextPositions = next
		}
	}

	/// Tokenization is deterministic and repeated across adjacent keystrokes. A small
	/// bounded cache removes SentencePiece dynamic-programming work without retaining
	/// the 60k-word lexicon or changing model scores.
	// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private final class CandidateTokenCache {
		private let lock = NSLock()
		private var values: [String: [Int32]] = [:]
		private var insertionOrder: [String] = []
		private let capacity: Int

		// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
		// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
		init(capacity: Int) { self.capacity = capacity }

		// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
		// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
		func value(for key: String) -> [Int32]? {
			lock.lock(); defer { lock.unlock() }
			return values[key]
		}

		// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
		// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
		func insert(_ value: [Int32], for key: String) {
			lock.lock(); defer { lock.unlock() }
			if values.updateValue(value, forKey: key) == nil {
				insertionOrder.append(key)
			}
			if insertionOrder.count > capacity {
				let removeCount = max(1, capacity / 4)
				for old in insertionOrder.prefix(removeCount) { values[old] = nil }
				insertionOrder.removeFirst(removeCount)
			}
		}

		// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
		// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
		func removeAll() {
			lock.lock()
			values.removeAll(keepingCapacity: false)
			insertionOrder.removeAll(keepingCapacity: false)
			lock.unlock()
		}
	}

	let modelTier: DecodeModelTier = .neuralW8
	private static let sequenceLength = 32
	private static let scoreSlots = 8
	private static let batchSize = 16
	private static let minimumAvailableMB = 35.0
	private static let retryDelay: TimeInterval = 30

	private let compiledURL: URL?
	private let packageURL: URL?
	private let tokenizer: KeyboardSentencePieceTokenizer?
	private let lock = NSLock()
	private let scoreQueue = DispatchQueue(label: "keyboard.neural.coreml",
		qos: .userInitiated)
	private var model: MLModel?
	private var runtimeState: NeuralRuntimeState
	private var stateDetail: String?
	private var loading = false
	private var lastFailureAt: Date?
	private var compiledTemporaryURL: URL?
	private var sessions: [UInt64: Session] = [:]
	private var nextSessionGeneration: UInt64 = 0
	private var buffers: Buffers?
	private let candidateTokens = CandidateTokenCache(capacity: 4_096)
	private var pressureSource: DispatchSourceMemoryPressure?

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	static func bundled() -> CoreMLNeuralLanguagePrior {
		CoreMLNeuralLanguagePrior(
			compiledURL: Bundle.main.url(forResource: "rescorer", withExtension: "mlmodelc"),
			packageURL: Bundle.main.url(forResource: "rescorer", withExtension: "mlpackage"),
			tokenizerURL: Bundle.main.url(forResource: "tokenizer", withExtension: "bin")
		)
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	init(compiledURL: URL?, packageURL: URL? = nil, tokenizerURL: URL?) {
		self.compiledURL = compiledURL
		self.packageURL = packageURL
		tokenizer = tokenizerURL.flatMap(KeyboardSentencePieceTokenizer.init(url:))
		if tokenizer == nil || (compiledURL == nil && packageURL == nil) {
			runtimeState = .artifactMissing
			stateDetail = tokenizer == nil ? "tokenizer.bin is missing or invalid"
				: "rescorer.mlmodelc is not bundled"
		} else {
			runtimeState = packageURL != nil && compiledURL == nil ? .compiling : .loading
			stateDetail = nil
		}
		publishState()
		installMemoryPressureHandler()
		prepareForSelection()
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	deinit { pressureSource?.cancel() }

	var isReady: Bool {
		lock.lock(); defer { lock.unlock() }
		return model != nil && runtimeState == .ready
	}

	var state: (NeuralRuntimeState, String?) {
		lock.lock(); defer { lock.unlock() }
		return (runtimeState, stateDetail)
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS selects artifacts, applies memory/cooldown gates and readiness policy; OBJCXX_BRIDGE loads/validates Core ML models.
	func prepareForSelection() {
		lock.lock()
		guard tokenizer != nil, compiledURL != nil || packageURL != nil,
			model == nil, !loading else { lock.unlock(); return }
		if let lastFailureAt, Date().timeIntervalSince(lastFailureAt) < Self.retryDelay {
			lock.unlock(); return
		}
		let availableMB = Double(KBDiagnostics.availableBytes()) / 1_048_576
		guard availableMB == 0 || availableMB >= Self.minimumAvailableMB else {
			runtimeState = .memoryGated
			stateDetail = String(format: "%.1f MB available", availableMB)
			lock.unlock()
			publishState()
			return
		}
		loading = true
		runtimeState = compiledURL == nil ? .compiling : .loading
		stateDetail = nil
		lock.unlock()
		publishState()
		scoreQueue.async { [weak self] in self?.loadModel() }
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	func prepareContext(_ words: [String], wordSessionID: UInt64) {
		guard let tokenizer else { return }
		var tokens = tokenizer.englishModeID.map { [$0] } ?? []
		tokens += tokenizer.encode(words.suffix(neuralContextWordCap).joined(separator: " ").lowercased())
		if tokens.isEmpty { tokens = [tokenizer.padID] }
		lock.lock()
		nextSessionGeneration &+= 1
		sessions[wordSessionID] = Session(generation: nextSessionGeneration,
			contextTokens: tokens)
		lock.unlock()
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS retains protocol/session/cancellation and completion semantics; CPP_CORE owns candidate/token/score orchestration; OBJCXX_BRIDGE executes model work.
	func score(candidates: [String], wordSessionID: UInt64,
		completion: @escaping (Result<[String: Double], Error>) -> Void) {
		guard !candidates.isEmpty else { completion(.success([:])); return }
		lock.lock()
		let session = sessions[wordSessionID]
		let readyModel = model
		lock.unlock()
		guard let session else { completion(.failure(RuntimeError.missingSession)); return }
		guard let readyModel else {
			prepareForSelection()
			completion(.failure(RuntimeError.incompatible("Core ML model is not ready")))
			return
		}
		let bounded = Array(candidates.prefix(32))
		scoreQueue.async { [weak self] in
			guard let self else { return }
			do {
				let result = try self.performScore(bounded, session: session,
					wordSessionID: wordSessionID, model: readyModel)
				DispatchQueue.main.async { completion(.success(result)) }
			} catch {
				// Session cancellation is normal during rapid typing and must not poison an
				// otherwise healthy model. Prediction/interface failures unload the model so
				// the next word can retry after a short cooldown instead of getting stuck in
				// a non-ready state while retaining an unreachable MLModel instance.
				if let runtimeError = error as? RuntimeError,
					case .staleSession = runtimeError {
					DispatchQueue.main.async { completion(.failure(error)) }
					return
				}
				self.setState(.scoringFailure, detail: error.localizedDescription,
					retainModel: false, startsRetryCooldown: true)
				DispatchQueue.main.async { completion(.failure(error)) }
			}
		}
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	func discardSession(_ wordSessionID: UInt64) {
		lock.lock(); sessions[wordSessionID] = nil; lock.unlock()
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS handles pressure/epochs/cooldown; CPP_CORE clears search caches; OBJCXX_BRIDGE releases model/tensor/state resources.
	func handleMemoryPressure() {
		setState(.pressureUnloaded, detail: "Core ML unloaded after memory pressure",
			retainModel: false, startsRetryCooldown: true)
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS owns resource selection, epochs and state publication; OBJCXX_BRIDGE compiles/loads/validates Core ML models.
	private func loadModel() {
		do {
			let modelURL: URL
			if let compiledURL {
				modelURL = compiledURL
			} else if let packageURL {
				setState(.compiling, detail: nil, retainModel: false, keepLoading: true)
				let temporary = try MLModel.compileModel(at: packageURL)
				compiledTemporaryURL = temporary
				modelURL = temporary
			} else {
				throw RuntimeError.incompatible("Core ML artifact is missing")
			}
			setState(.loading, detail: nil, retainModel: false, keepLoading: true)
			let configuration = MLModelConfiguration()
			configuration.computeUnits = .cpuAndNeuralEngine
			let loaded = try MLModel(contentsOf: modelURL, configuration: configuration)
			try validate(loaded)
			lock.lock()
			model = loaded
			loading = false
			lastFailureAt = nil
			runtimeState = .ready
			stateDetail = nil
			lock.unlock()
			publishState()
		} catch {
			lock.lock()
			model = nil
			loading = false
			lastFailureAt = Date()
			runtimeState = error is RuntimeError ? .incompatibleInterface : .scoringFailure
			stateDetail = error.localizedDescription
			lock.unlock()
			publishState()
		}
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private func validate(_ model: MLModel) throws {
		let inputs = model.modelDescription.inputDescriptionsByName
		let outputs = model.modelDescription.outputDescriptionsByName
		let requiredInputs = ["tokens", "score_positions", "target_ids", "score_mask",
			"next_positions"]
		guard requiredInputs.allSatisfy({ inputs[$0] != nil }),
			outputs["candidate_log_probs"] != nil, outputs["next_logits"] != nil else {
			throw RuntimeError.incompatible("Core ML input/output names do not match the W8 scorer contract")
		}
		let expected = [
			"tokens": [16, 32], "score_positions": [16, 8],
			"target_ids": [16, 8], "score_mask": [16, 8], "next_positions": [16, 1],
		]
		for (name, shape) in expected {
			let actual = inputs[name]?.multiArrayConstraint?.shape.map(\.intValue) ?? []
			guard actual == shape else {
				throw RuntimeError.incompatible("Core ML input \(name) has shape \(actual), expected \(shape)")
			}
		}
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	private func performScore(_ candidates: [String], session: Session,
		wordSessionID: UInt64, model: MLModel) throws -> [String: Double] {
		guard let tokenizer else { throw RuntimeError.incompatible("Tokenizer is unavailable") }
		let tokenized = try candidates.map { word -> [Int32] in
			let key = word.lowercased()
			let ids: [Int32]
			if let cached = candidateTokens.value(for: key) {
				ids = cached
			} else {
				ids = tokenizer.encode(" " + key)
				if !ids.isEmpty { candidateTokens.insert(ids, for: key) }
			}
			guard !ids.isEmpty, ids.count < Self.sequenceLength else {
				throw RuntimeError.candidateTooLong(word)
			}
			return ids
		}
		let maximumCandidate = tokenized.map(\.count).max() ?? 1
		let context = trimmedContext(session.contextTokens,
			maximumCandidateTokens: maximumCandidate)
		guard !context.isEmpty else { throw RuntimeError.invalidOutput }
		if buffers == nil { buffers = Buffers() }
		guard let buffers else { throw RuntimeError.allocation }
		var values = [Double](repeating: 0, count: candidates.count)
		for chunkStart in stride(from: 0, to: candidates.count, by: Self.batchSize) {
			try ensureCurrent(session, wordSessionID: wordSessionID)
			let chunkEnd = min(chunkStart + Self.batchSize, candidates.count)
			let count = chunkEnd - chunkStart
			let rows = Array(tokenized[chunkStart..<chunkEnd])
			fillTokens(buffers.tokens, rows: rows, context: context, padID: tokenizer.padID)
			let chunkMaximum = rows.map(\.count).max() ?? 1
			for slotStart in stride(from: 0, to: chunkMaximum, by: Self.scoreSlots) {
				try ensureCurrent(session, wordSessionID: wordSessionID)
				fillScoringInputs(buffers, rows: rows, contextCount: context.count,
					slotStart: slotStart)
				let provider = try MLDictionaryFeatureProvider(dictionary: [
					"tokens": buffers.tokens,
					"score_positions": buffers.scorePositions,
					"target_ids": buffers.targetIDs,
					"score_mask": buffers.scoreMask,
					"next_positions": buffers.nextPositions,
				])
				let output = try model.prediction(from: provider)
				guard let array = output.featureValue(for: "candidate_log_probs")?.multiArrayValue,
					let scores = readScores(array, count: count) else {
					throw RuntimeError.invalidOutput
				}
				for index in 0..<count { values[chunkStart + index] += scores[index] }
			}
		}
		return Dictionary(uniqueKeysWithValues: zip(candidates, values))
	}

	// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private func trimmedContext(_ tokens: [Int32], maximumCandidateTokens: Int) -> [Int32] {
		let capacity = max(1, Self.sequenceLength - maximumCandidateTokens)
		guard tokens.count > capacity else { return tokens }
		if let mode = tokenizer?.englishModeID, capacity > 1 {
			return [mode] + tokens.filter { $0 != mode }.suffix(capacity - 1)
		}
		return Array(tokens.suffix(capacity))
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	private func ensureCurrent(_ session: Session, wordSessionID: UInt64) throws {
		lock.lock(); let current = sessions[wordSessionID]; lock.unlock()
		guard current?.generation == session.generation else { throw RuntimeError.staleSession }
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private func fillTokens(_ array: MLMultiArray, rows: [[Int32]], context: [Int32],
		padID: Int32) {
		let pointer = array.dataPointer.bindMemory(to: Int32.self,
			capacity: Self.batchSize * Self.sequenceLength)
		for batch in 0..<Self.batchSize {
			let row = batch < rows.count ? context + rows[batch] : context
			for index in 0..<Self.sequenceLength {
				pointer[batch * Self.sequenceLength + index] = index < row.count ? row[index] : padID
			}
		}
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private func fillScoringInputs(_ buffers: Buffers, rows: [[Int32]],
		contextCount: Int, slotStart: Int) {
		let positions = buffers.scorePositions.dataPointer.bindMemory(to: Int32.self,
			capacity: Self.batchSize * Self.scoreSlots)
		let targets = buffers.targetIDs.dataPointer.bindMemory(to: Int32.self,
			capacity: Self.batchSize * Self.scoreSlots)
		let masks = buffers.scoreMask.dataPointer.bindMemory(to: Float.self,
			capacity: Self.batchSize * Self.scoreSlots)
		let next = buffers.nextPositions.dataPointer.bindMemory(to: Int32.self,
			capacity: Self.batchSize)
		for batch in 0..<Self.batchSize {
			let row = batch < rows.count ? rows[batch] : []
			next[batch] = Int32(max(0, contextCount + row.count - 1))
			for slot in 0..<Self.scoreSlots {
				let tokenIndex = slotStart + slot
				let offset = batch * Self.scoreSlots + slot
				positions[offset] = tokenIndex < row.count
					? Int32(contextCount - 1 + tokenIndex) : 0
				targets[offset] = tokenIndex < row.count ? row[tokenIndex] : 0
				masks[offset] = tokenIndex < row.count ? 1 : 0
			}
		}
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private func readScores(_ array: MLMultiArray, count: Int) -> [Double]? {
		let shape = array.shape.map(\.intValue)
		guard shape == [Self.batchSize] || shape == [Self.batchSize, 1] else { return nil }
		let rowStride = array.strides[0].intValue
		var result = [Double](repeating: 0, count: count)
		func copy<T: BinaryFloatingPoint>(_ values: UnsafeBufferPointer<T>) {
			for index in 0..<count { result[index] = Double(values[index * rowStride]) }
		}
		switch array.dataType {
		case .float16: array.withUnsafeBufferPointer(ofType: Float16.self) { copy($0) }
		case .float32: array.withUnsafeBufferPointer(ofType: Float.self) { copy($0) }
		case .double: array.withUnsafeBufferPointer(ofType: Double.self) { copy($0) }
		default: return nil
		}
		return result
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	private func installMemoryPressureHandler() {
		let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
			queue: scoreQueue)
		source.setEventHandler { [weak self] in self?.handleMemoryPressure() }
		source.resume()
		pressureSource = source
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	private func setState(_ state: NeuralRuntimeState, detail: String?, retainModel: Bool,
		keepLoading: Bool = false, startsRetryCooldown: Bool = false) {
		lock.lock()
		runtimeState = state
		stateDetail = detail
		if !retainModel { model = nil; buffers = nil; sessions.removeAll() }
		if !keepLoading { loading = false }
		if startsRetryCooldown { lastFailureAt = Date() }
		lock.unlock()
		if !retainModel { candidateTokens.removeAll() }
		publishState()
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	private func publishState() {
		#if DEBUG || INTERNAL_NEURAL || INTERNAL_GRU
		let snapshot = state
		KBDiagnostics.recordNeuralState(tier: modelTier,
			ready: snapshot.0 == .ready, state: snapshot.0.rawValue,
			detail: snapshot.1)
		#endif
	}
}

/// GRU streaming search-prior (roadmap Plan 3). Conforms to the SAME NeuralLanguagePrior
/// seam as the transformer above, so it inherits the engine's ranking blend, per-word tier
/// freeze, and memory handling for free. FAIL-SAFE: with no bundled model/tokenizer, `isReady`
/// stays false and the engine ranks on the n-gram alone — production/`main` is untouched.
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
		let isKnownWord: (String) -> Bool
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
			#if DEBUG || INTERNAL_NEURAL || INTERNAL_GRU
			KBDiagnostics.recordNeuralState(tier: .neuralGRU, ready: false, state: "memory-gated")
			#endif
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
			#if DEBUG || INTERNAL_NEURAL || INTERNAL_GRU
			if current { KBDiagnostics.recordNeuralState(tier: .neuralGRU, ready: true, state: "ready") }
			#endif
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
		tokens += tokenizer.encode(words.suffix(neuralContextWordCap).joined(separator: " ").lowercased())
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
	func warmSearchPrior(_ query: SearchPriorQuery, isKnownWord: @escaping (String) -> Bool) {
		guard tokenizer != nil, !query.context.isEmpty else { return }
		let queries = query.prefix == nil ? [query] : [query.withoutPrefix, query]
		lock.lock()
		latestWarmQueries = Set(queries)
		pendingWarmJobs = queries.filter { searchPriorCache[$0] == nil && activeWarmQuery != $0 }
			.map { WarmJob(query: $0, epoch: modelEpoch, isKnownWord: isKnownWord) }
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
				isKnownWord: job.isKnownWord, shouldCancel: cancelled)
			// Keep all seed words, including adopted words appended after the original pool.
			var combined = generated.map(\.word)
			var seen = Set(combined)
			for word in job.query.pool where job.isKnownWord(word)
				&& Self.matchesPrefix(word, firstLetters: job.query.prefix?.firstLetters)
				&& seen.insert(word).inserted { combined.append(word) }
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
	private static func matchesPrefix(_ word: String, firstLetters: Set<Character>?) -> Bool {
		guard let firstLetters else { return true }
		guard let first = word.lowercased().first else { return false }
		return firstLetters.contains(first)
	}

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
		tokens += tokenizer.encode(context.suffix(neuralContextWordCap).joined(separator: " ").lowercased())
		let session = Session(contextTokens: tokens)
		guard let scored = try? streamScore(pool, session: session, model: model,
			tokenizer: tokenizer, shouldCancel: shouldCancel) else { return [] }
		return pool
			.compactMap { word in
				scored[word.lowercased()].map { SearchPriorWord(word: word, logProbability: $0) }
			}
			.sorted { $0.logProbability > $1.logProbability }
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
	private struct BeamHypothesis {
		var pieces: [Int32]
		var logProbability: Double
		var state: MLMultiArray
		var previous: Int32
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns legal-token filtering, beam hypotheses and complete-word scoring; OBJCXX_BRIDGE predicts recurrent steps; SWIFT_IOS supplies cancellation/epoch validity.
	private func generateNextWords(context: [String], model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer, firstLetters: Set<Character>?, limit: Int,
		beamWidth: Int = 12, branch: Int = 8, maxPieces: Int = 6,
		isKnownWord: (String) -> Bool = { _ in true }, shouldCancel: () -> Bool = { false })
		-> [(word: String, logProbability: Double)] {
		var tokens = tokenizer.englishModeID.map { [$0] } ?? []
		tokens += tokenizer.encode(context.suffix(neuralContextWordCap).joined(separator: " ").lowercased())
		if tokens.isEmpty { tokens = [tokenizer.padID] }
		guard let contextState = try? runContext(tokens, model: model) else { return [] }
		var frontier = [BeamHypothesis(pieces: [], logProbability: 0,
			state: contextState, previous: tokens.last ?? tokenizer.padID)]
		var completed: [String: Double] = [:]
		for depth in 0...maxPieces {
			guard !shouldCancel() else { return [] }
			var extended: [BeamHypothesis] = []
			for hypothesis in frontier {
				guard !shouldCancel() else { return [] }
				guard let (logits, nextState) = try? step(hypothesis.previous,
						state: hypothesis.state, model: model),
					let logProbabilities = Self.logProbabilities(logits) else { continue }
				// Record the word ending HERE, weighted by the probability it ends here.
				if !hypothesis.pieces.isEmpty {
					let word = tokenizer.word(fromPieceIDs: hypothesis.pieces)
					if !word.isEmpty, isKnownWord(word) {
						let boundary = Self.boundaryLogProbability(logProbabilities,
							tokenizer: tokenizer)
						completed[word] = max(completed[word] ?? -.infinity,
							hypothesis.logProbability + boundary)
					}
				}
				guard depth < maxPieces else { continue }
				let legal: (Int) -> Bool = { index in
					if hypothesis.pieces.isEmpty {
						return tokenizer.startContent[index] && Self.startLetterAllowed(index,
							firstLetters: firstLetters, tokenizer: tokenizer)
					}
					return tokenizer.continuationContent[index]
				}
				for token in Self.topIndices(logProbabilities, count: branch, allowed: legal) {
					let index = Int(token)
					guard index < tokenizer.continuationContent.count else { continue }
					let step = hypothesis.logProbability + Double(logProbabilities[index])
					if hypothesis.pieces.isEmpty {
						// Prefix-AWARE: seed only word-starts whose first letter is spatially
						// reachable from the first tap (nil ⇒ no constraint, today's behavior).
						if tokenizer.startContent[index],
							Self.startLetterAllowed(index, firstLetters: firstLetters,
								tokenizer: tokenizer) {
							extended.append(BeamHypothesis(pieces: [token],
								logProbability: step, state: nextState, previous: token))
						}
					} else if tokenizer.continuationContent[index] {
						extended.append(BeamHypothesis(pieces: hypothesis.pieces + [token],
							logProbability: step, state: nextState, previous: token))
					}
				}
			}
			if extended.isEmpty { break }
			extended.sort { $0.logProbability > $1.logProbability }
			frontier = Array(extended.prefix(beamWidth))
		}
		// Keep the beam's own log-probabilities (previously discarded): the caller re-scores the
		// union on a consistent scale, but returning them honours the generation ordering and lets
		// a pure-beam caller fund the trie directly.
		return completed.sorted { $0.value > $1.value }.prefix(limit)
			.map { (word: $0.key, logProbability: $0.value) }
	}

	/// Whether a word-initial piece may seed the beam under a prefix constraint — its first letter
	/// must be in the spatially-plausible set. nil set ⇒ unconstrained (context-only generation).
	// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private static func startLetterAllowed(_ index: Int, firstLetters: Set<Character>?,
		tokenizer: KeyboardSentencePieceTokenizer) -> Bool {
		guard let firstLetters else { return true }
		guard index < tokenizer.startFirstLetter.count,
			let letter = tokenizer.startFirstLetter[index] else { return false }
		return firstLetters.contains(letter)
	}

	/// Dense log-softmax read straight off the logits buffer (no per-element NSNumber
	/// boxing on the beam's hot loop).
	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: OBJCXX_BRIDGE extracts checked stride-aware logits; CPP_CORE calculates finite log-softmax values.
	private static func logProbabilities(_ array: MLMultiArray) -> [Float]? {
		let count = array.count
		guard count > 0 else { return nil }
		var values = [Float](repeating: 0, count: count)
		func load<T: BinaryFloatingPoint>(_ buffer: UnsafeBufferPointer<T>) {
			for index in 0..<count { values[index] = Float(buffer[index]) }
		}
		if !Self.isContiguous(array) {
			for index in 0..<count { values[index] = array[index].floatValue }
		} else { switch array.dataType {
		case .float16: array.withUnsafeBufferPointer(ofType: Float16.self) { load($0) }
		case .float32: array.withUnsafeBufferPointer(ofType: Float.self) { load($0) }
		case .double: array.withUnsafeBufferPointer(ofType: Double.self) { load($0) }
		default: return nil
		}
		}
		guard values.allSatisfy(\.isFinite) else { return nil }
		var maximum = -Float.greatestFiniteMagnitude
		for value in values where value > maximum { maximum = value }
		var sum: Float = 0
		for value in values { sum += expf(value - maximum) }
		let logSum = maximum + logf(sum)
		for index in 0..<count { values[index] -= logSum }
		return values
	}

	/// log P(next token is a boundary) = logsumexp over every non-continuation piece (a new
	/// word start, punctuation, byte, or EOS) — the probability the current word ends here.
	// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	private static func boundaryLogProbability(_ logProbabilities: [Float],
		tokenizer: KeyboardSentencePieceTokenizer) -> Double {
		let continuation = tokenizer.continuationContent
		let count = min(logProbabilities.count, continuation.count)
		var maximum = -Float.greatestFiniteMagnitude
		for index in 0..<count where !continuation[index] && logProbabilities[index] > maximum {
			maximum = logProbabilities[index]
		}
		guard maximum > -Float.greatestFiniteMagnitude else { return -30 }
		var sum: Float = 0
		for index in 0..<count where !continuation[index] {
			sum += expf(logProbabilities[index] - maximum)
		}
		return Double(maximum + logf(sum))
	}

	/// Indices of the `count` largest values — a bounded top-k over the ~6k vocab (a full
	/// sort would dominate the beam step).
	// MIGRATION: planned CPP_CORE | stage=neural | target=NeuralSearch
	// MIGRATION-NOTE: Preserve existing coverage, ordering, costs, limits and score conventions.
	static func topIndices(_ values: [Float], count: Int, allowed: (Int) -> Bool = { _ in true }) -> [Int32] {
		let k = min(count, values.count)
		guard k > 0 else { return [] }
		var top: [(value: Float, index: Int32)] = []
		top.reserveCapacity(k)
		var threshold = -Float.greatestFiniteMagnitude
		for index in 0..<values.count where allowed(index) {
			let value = values[index]
			if top.count < k {
				top.append((value, Int32(index)))
				if top.count == k {
					top.sort { $0.value > $1.value }
					threshold = top[k - 1].value
				}
			} else if value > threshold {
				top[k - 1] = (value, Int32(index))
				var position = k - 1
				while position > 0, top[position].value > top[position - 1].value {
					top.swapAt(position, position - 1)
					position -= 1
				}
				threshold = top[k - 1].value
			}
		}
		return top.sorted { $0.value == $1.value ? $0.index < $1.index : $0.value > $1.value }.map(\.index)
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: SWIFT_IOS retains protocol/session/cancellation and completion semantics; CPP_CORE owns candidate/token/score orchestration; OBJCXX_BRIDGE executes model work.
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

	/// Complete-word probabilities. Optional batch exports must implement the same
	/// boundary convention; legacy exports fall back to streaming rather than changing scores.
	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	private func streamScore(_ candidates: [String], session: Session, model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer, shouldCancel: () -> Bool = { false }) throws -> [String: Double] {
		lock.lock(); let batched = scoreModel; lock.unlock()
		if let batched {
			return try batchScore(candidates, session: session, stepModel: model,
				scoreModel: batched, tokenizer: tokenizer, shouldCancel: shouldCancel)
		}
		return try streamScoreSingleStep(candidates, session: session, model: model, tokenizer: tokenizer, shouldCancel: shouldCancel)
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	private func streamScoreSingleStep(_ candidates: [String], session: Session, model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer, shouldCancel: () -> Bool = { false }) throws -> [String: Double] {
		let contextState = try runContext(session.contextTokens, model: model)
		let previousToken = session.contextTokens.last ?? tokenizer.padID
		let (firstLogits, firstState) = try step(previousToken, state: contextState, model: model)
		guard let firstLogProbs = Self.logProbabilities(firstLogits) else { throw GRUError.badOutput }
		var out: [String: Double] = [:]
		for key in Set(candidates.map { $0.lowercased() }).sorted() {
			guard !shouldCancel() else { throw GRUError.cancelled }
			let tokens = tokenizer.encode(key)
			guard let first = tokens.first, Int(first) < firstLogProbs.count else { continue }
			var probability = Double(firstLogProbs[Int(first)])
			var state = firstState
			var previous = first
			for token in tokens.dropFirst() {
				guard !shouldCancel() else { throw GRUError.cancelled }
				let (logits, nextState) = try step(previous, state: state, model: model)
				probability += Self.logSoftmax(logits, at: Int(token))
				state = nextState; previous = token
			}
			let (ending, _) = try step(previous, state: state, model: model)
			guard let endingProbabilities = Self.logProbabilities(ending) else { throw GRUError.badOutput }
			probability += Self.boundaryLogProbability(endingProbabilities, tokenizer: tokenizer)
			guard probability.isFinite else { throw GRUError.badOutput }
			out[key] = probability
		}
		return out
	}

	/// Chunked complete-word scoring. T reserves one position for the ending event.
	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination.
	private func batchScore(_ candidates: [String], session: Session, stepModel: MLModel,
		scoreModel: MLModel, tokenizer: KeyboardSentencePieceTokenizer, shouldCancel: () -> Bool = { false }) throws -> [String: Double] {
		let B = Self.scoreBatch, T = Self.scoreTime
		let contextState = try runContext(session.contextTokens, model: stepModel)
		let previousToken = session.contextTokens.last ?? tokenizer.padID
		let keys = Array(Set(candidates.map { $0.lowercased() })).sorted()
		var out: [String: Double] = [:]
		var overflow: [String] = []
		for start in stride(from: 0, to: keys.count, by: B) {
			lock.lock(); let current = self.model === stepModel; lock.unlock()
			guard current && !shouldCancel() else { throw GRUError.cancelled }
			var rows: [(key: String, tokens: [Int32])] = []
			for key in keys[start..<min(start + B, keys.count)] {
				let pieces = tokenizer.encode(key)
				guard !pieces.isEmpty else { continue }
				if pieces.count < T { rows.append((key, pieces)) } else { overflow.append(key) }
			}
			guard !rows.isEmpty else { continue }
			let tokens = try MLMultiArray(shape: [NSNumber(value: B), NSNumber(value: T)], dataType: .int32)
			let targets = try MLMultiArray(shape: tokens.shape, dataType: .int32)
			let mask = try MLMultiArray(shape: tokens.shape, dataType: .float32)
			let boundaries = try MLMultiArray(shape: [NSNumber(value: B)], dataType: .int32)
			let stateIn = try MLMultiArray(shape: [NSNumber(value: layers), NSNumber(value: B), NSNumber(value: hidden)], dataType: .float32)
			guard let contextValues = Self.readVector(contextState, count: layers * hidden) else { throw GRUError.badOutput }
			let tokenPointer = tokens.dataPointer.bindMemory(to: Int32.self, capacity: B * T)
			let targetPointer = targets.dataPointer.bindMemory(to: Int32.self, capacity: B * T)
			let maskPointer = mask.dataPointer.bindMemory(to: Float.self, capacity: B * T)
			for index in 0..<(B * T) { tokenPointer[index] = tokenizer.padID; targetPointer[index] = 0; maskPointer[index] = 0 }
			for batch in 0..<B { boundaries[batch] = 0 }
			for (batch, row) in rows.enumerated() {
				for index in row.tokens.indices {
					tokenPointer[batch * T + index] = index == 0 ? previousToken : row.tokens[index - 1]
					targetPointer[batch * T + index] = row.tokens[index]
					maskPointer[batch * T + index] = 1
				}
				tokenPointer[batch * T + row.tokens.count] = row.tokens.last!
				boundaries[batch] = NSNumber(value: row.tokens.count)
			}
			let statePointer = stateIn.dataPointer.bindMemory(to: Float.self, capacity: layers * B * hidden)
			for layer in 0..<layers { for batch in 0..<B { for unit in 0..<hidden {
				statePointer[(layer * B + batch) * hidden + unit] = Float(contextValues[layer * hidden + unit])
			} } }
			let provider = try MLDictionaryFeatureProvider(dictionary: ["tokens": tokens, "state_in": stateIn,
				"targets": targets, "mask": mask, "boundary_positions": boundaries])
			let output = try scoreModel.prediction(from: provider)
			guard let probabilities = output.featureValue(for: "log_probs")?.multiArrayValue,
				let values = Self.readVector(probabilities, count: rows.count), values.allSatisfy(\.isFinite)
			else { throw GRUError.badOutput }
			for (batch, row) in rows.enumerated() { out[row.key] = values[batch] }
		}
		if !overflow.isEmpty {
			out.merge(try streamScoreSingleStep(overflow, session: session, model: stepModel, tokenizer: tokenizer, shouldCancel: shouldCancel)) { $1 }
		}
		return out
	}

	/// Read the first `count` scalars of a 1-D Core ML array, fp16/fp32/double tolerant.
	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private static func isContiguous(_ array: MLMultiArray) -> Bool {
		var expected = 1
		for (dimension, stride) in zip(array.shape, array.strides).reversed() {
			if dimension.intValue > 1 && stride.intValue != expected { return false }
			expected *= dimension.intValue
		}
		return true
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private static func readVector(_ array: MLMultiArray, count: Int) -> [Double]? {
		guard array.count >= count else { return nil }
		if !isContiguous(array) { return (0..<count).map { array[$0].doubleValue } }
		var result = [Double](repeating: 0, count: count)
		func copy<T: BinaryFloatingPoint>(_ buffer: UnsafeBufferPointer<T>) {
			for index in 0..<count { result[index] = Double(buffer[index]) }
		}
		switch array.dataType {
		case .float16: array.withUnsafeBufferPointer(ofType: Float16.self) { copy($0) }
		case .float32: array.withUnsafeBufferPointer(ofType: Float.self) { copy($0) }
		case .double: array.withUnsafeBufferPointer(ofType: Double.self) { copy($0) }
		default: return nil
		}
		return result
	}

	/// Recurrent state after consuming [pad, t0 … t_{n-2}] — the state the first candidate/beam step
	/// continues from. PERSISTED across word boundaries: when the cached tokens are a prefix of
	/// `tokens` (the common case — a committed word grows the ≤12-word context), only the divergent
	/// suffix is threaded, not the whole context from zero, cutting ~20–30 sequential Core ML steps
	/// per pass to ~one per newly committed token. A prefix mismatch (backspace across a boundary,
	/// cursor move, field change) rebuilds from zero. The cache holds a pure function of the tokens,
	/// so a stale entry is never wrong — it either prefix-matches (exact extension) or is discarded.
	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: CPP_CORE owns context-token/state-cache policy; OBJCXX_BRIDGE owns recurrent-state transport/prediction; SWIFT_IOS coordinates model/session epochs.
	private func runContext(_ tokens: [Int32], model: MLModel) throws -> MLMultiArray {
		lock.lock()
		let epoch = modelEpoch
		let valid = self.model === model
		let cached = valid ? contextStateCache : nil
		lock.unlock()
		guard valid else { throw GRUError.cancelled }
		var state: MLMultiArray
		var previous: Int32
		var index: Int
		if let cached, !cached.tokens.isEmpty, tokens.starts(with: cached.tokens) {
			state = cached.state
			previous = cached.tokens[cached.tokens.count - 1]
			index = cached.tokens.count
		} else {
			state = try zeroState()
			previous = tokenizer?.padID ?? 0
			index = 0
		}
		while index < tokens.count {
			let (_, nextState) = try step(previous, state: state, model: model)
			state = nextState
			previous = tokens[index]
			index += 1
		}
		lock.lock()
		if modelEpoch == epoch && self.model === model { contextStateCache = (tokens, state) }
		lock.unlock()
		return state
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private func step(_ token: Int32, state: MLMultiArray, model: MLModel) throws
		-> (logits: MLMultiArray, state: MLMultiArray) {
		lock.lock(); let current = self.model === model; lock.unlock()
		guard current else { throw GRUError.cancelled }
		let tokenArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
		tokenArray[0] = NSNumber(value: token)
		let provider = try MLDictionaryFeatureProvider(dictionary: [
			"token": tokenArray, "state_in": state])
		let output = try model.prediction(from: provider)
		guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
			let newState = output.featureValue(for: "state_out")?.multiArrayValue,
			logits.count == tokenizer?.idToPiece.count,
			newState.shape.map(\.intValue) == [layers, 1, hidden],
			newState.dataType == .float32 else {
			throw GRUError.badOutput
		}
		return (logits, newState)
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private func zeroState() throws -> MLMultiArray {
		let state = try MLMultiArray(
			shape: [NSNumber(value: layers), 1, NSNumber(value: hidden)], dataType: .float32)
		memset(state.dataPointer, 0, state.count * MemoryLayout<Float>.stride)
		return state
	}

	/// Branch the recurrent state for one candidate. The state is a contiguous fp32 [layers,1,hidden]
	/// tensor (~512 floats), so a bulk `memcpy` replaces the old element-by-element subscript copy,
	/// which boxed an NSNumber per float — 512 boxes per candidate on the hottest path. Falls back to
	/// the element copy if the source is ever non-contiguous or not fp32.
	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
	private func duplicate(_ source: MLMultiArray) throws -> MLMultiArray {
		let clone = try MLMultiArray(shape: source.shape, dataType: source.dataType)
		if source.dataType == .float32, source.strides == clone.strides {
			memcpy(clone.dataPointer, source.dataPointer, source.count * MemoryLayout<Float>.stride)
		} else {
			for index in 0..<source.count { clone[index] = source[index] }
		}
		return clone
	}

	// MIGRATION: planned SPLIT | stage=neural | target=NeuralPipeline
	// MIGRATION-SPLIT: OBJCXX_BRIDGE exposes checked logits; CPP_CORE evaluates the log-softmax kernel at the requested index.
	private static func logSoftmax(_ array: MLMultiArray, at index: Int) -> Double {
		guard let probabilities = logProbabilities(array), probabilities.indices.contains(index)
		else { return .nan }
		return Double(probabilities[index])
	}
}
