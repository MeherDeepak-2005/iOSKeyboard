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
#if DEBUG || KB_REFERENCE_DECODER_YES
private nonisolated final class SwiftSentencePieceTokenizer: @unchecked Sendable {
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

#endif

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
		case invalidOutput
		case incompatible(String)

		var errorDescription: String? {
			switch self {
			case .missingSession: return "Neural context session is missing"
			case .staleSession: return "Neural context session was cancelled"
			case .candidateTooLong(let word): return "Candidate is too long for Core ML: \(word)"
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
		tokens += tokenizer.encode(KBNeuralMath.lastWords(words, limit: UInt(neuralContextWordCap)).joined(separator: " ").lowercased())
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
			if let cached = candidateTokens.value(for: key) { ids = cached }
			else { ids = tokenizer.encode(" " + key); if !ids.isEmpty { candidateTokens.insert(ids, for: key) } }
			guard !ids.isEmpty, ids.count < Self.sequenceLength else { throw RuntimeError.candidateTooLong(word) }
			return ids
		}
		guard ensureCurrent(session, wordSessionID: wordSessionID) else { throw RuntimeError.staleSession }
		let context = KBNeuralMath.trimmedContext(session.contextTokens.map(NSNumber.init(value:)),
			mode: tokenizer.englishModeID.map(NSNumber.init(value:)), sequenceLength: UInt(Self.sequenceLength),
			maximumCandidateTokens: UInt(tokenized.map(\.count).max() ?? 1))
		guard !context.isEmpty else { throw RuntimeError.invalidOutput }
		let rows = tokenized.map { $0.map(NSNumber.init(value:)) }
		let shouldStop = { [weak self] in
			guard let self else { return true }
			self.lock.lock(); defer { self.lock.unlock() }
			return self.sessions[wordSessionID]?.generation != session.generation || self.model !== model
		}
		let result = withoutActuallyEscaping(shouldStop) { cancel in
			KBNeuralRuntime.scoreTransformer(model, rows: rows, context: context, padID: tokenizer.padID,
				sequenceLength: UInt(Self.sequenceLength), batchSize: UInt(Self.batchSize),
				scoreSlots: UInt(Self.scoreSlots), cancel: cancel)
		}
		guard let result else { throw shouldStop() ? RuntimeError.staleSession : RuntimeError.invalidOutput }
		return Dictionary(uniqueKeysWithValues: zip(candidates, result.map(\.doubleValue)))
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=NeuralLifecycle
	// MIGRATION-NOTE: Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift.
	private func ensureCurrent(_ session: Session, wordSessionID: UInt64) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return sessions[wordSessionID]?.generation == session.generation
	}

	// MIGRATION: planned OBJCXX_BRIDGE | stage=neural | target=KBCoreMLBackend
	// MIGRATION-NOTE: Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors.
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
		if !retainModel { model = nil; sessions.removeAll() }
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
