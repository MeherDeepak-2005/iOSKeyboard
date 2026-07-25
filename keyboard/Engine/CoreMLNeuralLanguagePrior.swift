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

	init?(url: URL) {
		guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
			data.count >= 16 else { return nil }
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
final class CoreMLNeuralLanguagePrior: NeuralLanguagePrior, @unchecked Sendable {
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

	private struct Session {
		let generation: UInt64
		let contextTokens: [Int32]
	}

	private final class Buffers {
		let tokens: MLMultiArray
		let scorePositions: MLMultiArray
		let targetIDs: MLMultiArray
		let scoreMask: MLMultiArray
		let nextPositions: MLMultiArray

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
	private final class CandidateTokenCache {
		private let lock = NSLock()
		private var values: [String: [Int32]] = [:]
		private var insertionOrder: [String] = []
		private let capacity: Int

		init(capacity: Int) { self.capacity = capacity }

		func value(for key: String) -> [Int32]? {
			lock.lock(); defer { lock.unlock() }
			return values[key]
		}

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

	static func bundled() -> CoreMLNeuralLanguagePrior {
		CoreMLNeuralLanguagePrior(
			compiledURL: Bundle.main.url(forResource: "rescorer", withExtension: "mlmodelc"),
			packageURL: Bundle.main.url(forResource: "rescorer", withExtension: "mlpackage"),
			tokenizerURL: Bundle.main.url(forResource: "tokenizer", withExtension: "bin")
		)
	}

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

	deinit { pressureSource?.cancel() }

	var isReady: Bool {
		lock.lock(); defer { lock.unlock() }
		return model != nil && runtimeState == .ready
	}

	var state: (NeuralRuntimeState, String?) {
		lock.lock(); defer { lock.unlock() }
		return (runtimeState, stateDetail)
	}

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

	func discardSession(_ wordSessionID: UInt64) {
		lock.lock(); sessions[wordSessionID] = nil; lock.unlock()
	}

	func handleMemoryPressure() {
		setState(.pressureUnloaded, detail: "Core ML unloaded after memory pressure",
			retainModel: false, startsRetryCooldown: true)
	}

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

	private func trimmedContext(_ tokens: [Int32], maximumCandidateTokens: Int) -> [Int32] {
		let capacity = max(1, Self.sequenceLength - maximumCandidateTokens)
		guard tokens.count > capacity else { return tokens }
		if let mode = tokenizer?.englishModeID, capacity > 1 {
			return [mode] + tokens.filter { $0 != mode }.suffix(capacity - 1)
		}
		return Array(tokens.suffix(capacity))
	}

	private func ensureCurrent(_ session: Session, wordSessionID: UInt64) throws {
		lock.lock(); let current = sessions[wordSessionID]; lock.unlock()
		guard current?.generation == session.generation else { throw RuntimeError.staleSession }
	}

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

	private func installMemoryPressureHandler() {
		let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
			queue: scoreQueue)
		source.setEventHandler { [weak self] in self?.handleMemoryPressure() }
		source.resume()
		pressureSource = source
	}

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

	private func publishState() {
		#if DEBUG || INTERNAL_NEURAL
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
final class GRULanguagePrior: NeuralLanguagePrior, NeuralSearchPrior, @unchecked Sendable {
	let modelTier: DecodeModelTier = .neuralGRU

	private enum GRUError: Error { case notReady, badOutput }
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
	// Search-prior cache: GRU-ranked next-words WITH their log-probabilities, per (context, prefix)
	// key. Populated async by warmSearchPrior, read sync by searchPriorWords; bounded LRU so it
	// never grows with the conversation. `inFlightPriors` collapses duplicate warms for a key.
	private var searchPriorCache: [String: [SearchPriorWord]] = [:]
	private var searchPriorOrder: [String] = []
	private var inFlightPriors: Set<String> = []
	private static let searchPriorCacheCapacity = 48
	private static let searchPriorKeep = 24

	static func bundled() -> GRULanguagePrior {
		GRULanguagePrior(
			compiledURL: Bundle.main.url(forResource: "gru", withExtension: "mlmodelc"),
			packageURL: Bundle.main.url(forResource: "gru", withExtension: "mlpackage"),
			tokenizerURL: Bundle.main.url(forResource: "gru_tokenizer", withExtension: "bin"),
			scoreCompiledURL: Bundle.main.url(forResource: "gru_score", withExtension: "mlmodelc"),
			scorePackageURL: Bundle.main.url(forResource: "gru_score", withExtension: "mlpackage"))
	}

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

	func prepareForSelection() {
		lock.lock()
		guard tokenizer != nil, compiledURL != nil || packageURL != nil,
			model == nil, !loading else { lock.unlock(); return }
		loading = true
		lock.unlock()
		queue.async { [weak self] in self?.loadModel() }
	}

	private func loadModel() {
		do {
			let url: URL
			if let compiledURL { url = compiledURL }
			else if let packageURL { url = try MLModel.compileModel(at: packageURL) }
			else { lock.lock(); loading = false; lock.unlock(); return }
			let configuration = MLModelConfiguration()
			configuration.computeUnits = .cpuAndNeuralEngine
			let loaded = try MLModel(contentsOf: url, configuration: configuration)
			// Best-effort batched scorer: absent/failed ⇒ scoreModel stays nil and streamScore uses
			// the single-step path, so the streaming prior never depends on it.
			let batched = loadScoreModel(configuration: configuration)
			lock.lock(); model = loaded; scoreModel = batched; loading = false; lock.unlock()
		} catch {
			lock.lock(); model = nil; scoreModel = nil; loading = false; lock.unlock()
		}
	}

	private func loadScoreModel(configuration: MLModelConfiguration) -> MLModel? {
		do {
			let url: URL
			if let scoreCompiledURL { url = scoreCompiledURL }
			else if let scorePackageURL { url = try MLModel.compileModel(at: scorePackageURL) }
			else { return nil }
			return try MLModel(contentsOf: url, configuration: configuration)
		} catch { return nil }
	}

	func prepareContext(_ words: [String], wordSessionID: UInt64) {
		guard let tokenizer else { return }
		var tokens = tokenizer.englishModeID.map { [$0] } ?? []
		tokens += tokenizer.encode(words.suffix(neuralContextWordCap).joined(separator: " ").lowercased())
		lock.lock(); sessions[wordSessionID] = Session(contextTokens: tokens); lock.unlock()
	}

	func discardSession(_ wordSessionID: UInt64) {
		lock.lock(); sessions[wordSessionID] = nil; lock.unlock()
	}

	func handleMemoryPressure() {
		lock.lock()
		model = nil
		scoreModel = nil
		contextStateCache = nil
		searchPriorCache.removeAll()
		searchPriorOrder.removeAll()
		inFlightPriors.removeAll()
		lock.unlock()
	}

	// MARK: NeuralSearchPrior — GRU-conditioned, prefix-aware, probability-weighted in-trie prior

	private func searchPriorKey(_ context: [String], prefix: SearchPrefix?) -> String {
		let base = context.suffix(neuralContextWordCap).joined(separator: " ").lowercased()
		guard let prefix else { return base }
		// NUL-separate so a context ending in the prefix text can't collide with a prefix key.
		return base + "\u{0}" + prefix.text.lowercased()
	}

	func searchPriorWords(context: [String], prefix: SearchPrefix?) -> [SearchPriorWord]? {
		lock.lock(); defer { lock.unlock() }
		if let scoped = searchPriorCache[searchPriorKey(context, prefix: prefix)] { return scoped }
		// A prefix-constrained pass may not have landed yet (its key changes every keystroke);
		// fall back to the context-only prediction so recovery still rides the GRU, not nothing.
		if prefix != nil { return searchPriorCache[searchPriorKey(context, prefix: nil)] }
		return nil
	}

	/// Kick off the async generation+ranking passes (≤1 in flight per key). Never blocks the
	/// caller. The context-only pass is ALWAYS kept warm — it is the glide rerank source and the
	/// fallback `searchPriorWords` returns while a prefix pass is still in flight; the prefix pass,
	/// when a prefix is supplied, additionally constrains generation to the typed word.
	func warmSearchPrior(context: [String], prefix: SearchPrefix?, pool: [String]) {
		guard tokenizer != nil, !context.isEmpty else { return }
		warmOne(context: context, prefix: nil, pool: pool)
		if let prefix { warmOne(context: context, prefix: prefix, pool: pool) }
	}

	private func warmOne(context: [String], prefix: SearchPrefix?, pool: [String]) {
		guard let tokenizer else { return }
		let key = searchPriorKey(context, prefix: prefix)
		lock.lock()
		let ready = model
		guard searchPriorCache[key] == nil, !inFlightPriors.contains(key), let model = ready else {
			lock.unlock()
			if ready == nil { prepareForSelection() }
			return
		}
		inFlightPriors.insert(key)
		lock.unlock()
		let bounded = Array(pool.prefix(24))
		let firstLetters = prefix?.firstLetters
		queue.async { [weak self] in
			guard let self else { return }
			// GENERATION, not just reranking: decode the GRU's own likely next-words (optionally
			// prefix-constrained), union with the compatible n-gram pool, then rank the whole set
			// by the GRU on one consistent scale. Words the n-gram never proposed (its recall
			// ceiling) now enter the in-trie prior, each carrying its log-probability so the trie
			// bonus is probability-derived. Empty beam ⇒ degrades to reranking the pool.
			let generated = self.generateNextWords(context: context, model: model,
				tokenizer: tokenizer, firstLetters: firstLetters, limit: 24)
			var combined = generated.map(\.word)
			var seen = Set(combined.map { $0.lowercased() })
			for word in bounded where Self.matchesPrefix(word, firstLetters: firstLetters)
				&& seen.insert(word.lowercased()).inserted {
				combined.append(word)
			}
			let ranked = self.rankPool(combined, context: context, model: model,
				tokenizer: tokenizer)
			self.lock.lock()
			self.inFlightPriors.remove(key)
			if !ranked.isEmpty {
				if self.searchPriorCache[key] == nil { self.searchPriorOrder.append(key) }
				self.searchPriorCache[key] = ranked
				if self.searchPriorOrder.count > Self.searchPriorCacheCapacity {
					let drop = self.searchPriorOrder.count - Self.searchPriorKeep
					for old in self.searchPriorOrder.prefix(drop) { self.searchPriorCache[old] = nil }
					self.searchPriorOrder.removeFirst(drop)
				}
			}
			self.lock.unlock()
		}
	}

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
	private func rankPool(_ pool: [String], context: [String], model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer) -> [SearchPriorWord] {
		var tokens = tokenizer.englishModeID.map { [$0] } ?? []
		tokens += tokenizer.encode(context.suffix(neuralContextWordCap).joined(separator: " ").lowercased())
		let session = Session(contextTokens: tokens)
		guard let scored = try? streamScore(pool, session: session, model: model,
			tokenizer: tokenizer) else { return [] }
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

	private struct BeamHypothesis {
		var pieces: [Int32]
		var logProbability: Double
		var state: MLMultiArray
		var previous: Int32
	}

	private func generateNextWords(context: [String], model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer, firstLetters: Set<Character>?, limit: Int,
		beamWidth: Int = 12, branch: Int = 8, maxPieces: Int = 6)
		-> [(word: String, logProbability: Double)] {
		var tokens = tokenizer.englishModeID.map { [$0] } ?? []
		tokens += tokenizer.encode(context.suffix(neuralContextWordCap).joined(separator: " ").lowercased())
		if tokens.isEmpty { tokens = [tokenizer.padID] }
		guard let contextState = try? runContext(tokens, model: model) else { return [] }
		var frontier = [BeamHypothesis(pieces: [], logProbability: 0,
			state: contextState, previous: tokens.last ?? tokenizer.padID)]
		var completed: [String: Double] = [:]
		for _ in 0..<maxPieces {
			var extended: [BeamHypothesis] = []
			for hypothesis in frontier {
				guard let (logits, nextState) = try? step(hypothesis.previous,
						state: hypothesis.state, model: model),
					let logProbabilities = Self.logProbabilities(logits) else { continue }
				// Record the word ending HERE, weighted by the probability it ends here.
				if !hypothesis.pieces.isEmpty {
					let word = tokenizer.word(fromPieceIDs: hypothesis.pieces)
					if !word.isEmpty {
						let boundary = Self.boundaryLogProbability(logProbabilities,
							tokenizer: tokenizer)
						completed[word] = max(completed[word] ?? -.infinity,
							hypothesis.logProbability + boundary)
					}
				}
				for token in Self.topIndices(logProbabilities, count: branch) {
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
	private static func startLetterAllowed(_ index: Int, firstLetters: Set<Character>?,
		tokenizer: KeyboardSentencePieceTokenizer) -> Bool {
		guard let firstLetters else { return true }
		guard index < tokenizer.startFirstLetter.count,
			let letter = tokenizer.startFirstLetter[index] else { return false }
		return firstLetters.contains(letter)
	}

	/// Dense log-softmax read straight off the logits buffer (no per-element NSNumber
	/// boxing on the beam's hot loop).
	private static func logProbabilities(_ array: MLMultiArray) -> [Float]? {
		let count = array.count
		guard count > 0 else { return nil }
		var values = [Float](repeating: 0, count: count)
		func load<T: BinaryFloatingPoint>(_ buffer: UnsafeBufferPointer<T>) {
			for index in 0..<count { values[index] = Float(buffer[index]) }
		}
		switch array.dataType {
		case .float16: array.withUnsafeBufferPointer(ofType: Float16.self) { load($0) }
		case .float32: array.withUnsafeBufferPointer(ofType: Float.self) { load($0) }
		case .double: array.withUnsafeBufferPointer(ofType: Double.self) { load($0) }
		default: return nil
		}
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
	private static func topIndices(_ values: [Float], count: Int) -> [Int32] {
		let k = min(count, values.count)
		guard k > 0 else { return [] }
		var top: [(value: Float, index: Int32)] = []
		top.reserveCapacity(k)
		var threshold = -Float.greatestFiniteMagnitude
		for index in 0..<values.count {
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
		return top.map(\.index)
	}

	func score(candidates: [String], wordSessionID: UInt64,
		completion: @escaping (Result<[String: Double], Error>) -> Void) {
		guard !candidates.isEmpty else { completion(.success([:])); return }
		lock.lock(); let session = sessions[wordSessionID]; let ready = model; lock.unlock()
		guard let session, let ready, let tokenizer else {
			prepareForSelection()
			completion(.failure(GRUError.notReady))
			return
		}
		let bounded = Array(candidates.prefix(32))
		queue.async { [weak self] in
			guard let self else { return }
			do {
				let scores = try self.streamScore(bounded, session: session,
					model: ready, tokenizer: tokenizer)
				DispatchQueue.main.async { completion(.success(scores)) }
			} catch {
				DispatchQueue.main.async { completion(.failure(error)) }
			}
		}
	}

	/// Top-K the first-piece admission fixes EXACTLY: a multi-piece candidate whose first-piece
	/// upper bound can't beat the current K-th best exact score provably can't rank there, so it
	/// reports its (upper-bound) first-piece score instead of being threaded.
	private static let scoreAdmissionK = 16

	/// log P(word | context) for the whole candidate pool. Dispatches to the BATCHED scorer (one
	/// [B,T] Core ML call for all candidates) when it is loaded, otherwise the single-step path.
	private func streamScore(_ candidates: [String], session: Session, model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer) throws -> [String: Double] {
		lock.lock(); let batched = scoreModel; lock.unlock()
		if let batched {
			return try batchScore(candidates, session: session, stepModel: model,
				scoreModel: batched, tokenizer: tokenizer)
		}
		return try streamScoreSingleStep(candidates, session: session, model: model,
			tokenizer: tokenizer)
	}

	/// One log P(word | context) per candidate via SINGLE-STEP threading. The context state is
	/// threaded ONCE (persisted across word boundaries — see `runContext`), then a SINGLE shared step
	/// yields the first-piece distribution for EVERY candidate at once: since log P(word) =
	/// log P(firstPiece) + Σ log P(rest) and each added piece contributes ≤ 0, the first-piece
	/// log-prob is the EXACT score of a single-piece word and an UPPER BOUND for a multi-piece one
	/// (verified against gru.pt: 0 bound violations). So single-piece candidates cost zero extra
	/// steps, and only the top multi-piece candidates by that bound are fully threaded — the rest
	/// cannot outrank them, so their bound is reported as-is. Used when the batched `batchScore` is
	/// not loaded (which folds all of this into one call instead).
	private func streamScoreSingleStep(_ candidates: [String], session: Session, model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer) throws -> [String: Double] {
		let contextState = try runContext(session.contextTokens, model: model)
		let previousToken = session.contextTokens.last ?? tokenizer.padID
		// One shared step off the context state: first-piece distribution + the state to branch from.
		let (firstLogits, firstState) = try step(previousToken, state: contextState, model: model)
		guard let firstLogProbs = Self.logProbabilities(firstLogits) else {
			throw GRUError.badOutput
		}
		struct Pending { let key: String; let tokens: [Int32]; let bound: Double }
		var out: [String: Double] = [:]
		var multiPiece: [Pending] = []
		for word in candidates {
			let key = word.lowercased()
			let wordTokens = tokenizer.encode(key)
			guard let first = wordTokens.first else { continue }
			let firstIndex = Int(first)
			let bound = firstIndex < firstLogProbs.count ? Double(firstLogProbs[firstIndex]) : -30
			if wordTokens.count == 1 {
				out[key] = bound                                   // exact for single-piece words
			} else {
				multiPiece.append(Pending(key: key, tokens: wordTokens, bound: bound))
			}
		}
		guard !multiPiece.isEmpty else { return out }
		multiPiece.sort { $0.bound > $1.bound }
		// Threshold admission (exact for the top K): walk multi-piece candidates by descending
		// first-piece bound; a candidate can enter the top K only if its bound beats the current
		// K-th best EXACT score (true ≤ bound). Once one can't, no later one can either (bounds are
		// descending) — report the remaining bounds and stop threading. Single-piece scores seed the
		// threshold, so a pool the model is confident about prunes almost everything.
		var exact = out.values.sorted(by: >)                 // single-piece scores, descending
		for position in multiPiece.indices {
			let candidate = multiPiece[position]
			let kth = exact.count >= Self.scoreAdmissionK ? exact[Self.scoreAdmissionK - 1]
				: -Double.infinity
			if candidate.bound < kth {
				for rest in multiPiece[position...] { out[rest.key] = rest.bound }
				break
			}
			// Thread the remaining pieces from the post-first-token state; the first piece's
			// log-prob is the bound already in hand.
			var state = try duplicate(firstState)
			var previous = candidate.tokens[0]
			var logProbability = candidate.bound
			for token in candidate.tokens.dropFirst() {
				let (logits, nextState) = try step(previous, state: state, model: model)
				logProbability += Self.logSoftmax(logits, at: Int(token))
				state = nextState
				previous = token
			}
			out[candidate.key] = logProbability
			let insertAt = exact.firstIndex { $0 < logProbability } ?? exact.count
			exact.insert(logProbability, at: insertAt)
		}
		return out
	}

	/// Score the whole candidate pool in ONE batched Core ML call. Threads the context once via the
	/// single-step model (persisted state), broadcasts that state across the batch, and fills, per
	/// row, the sequence [prev, w0 … w_{k-2}] against targets [w0 … w_{k-1}] with a length mask —
	/// reading one summed log P(word | context) per row. Exactly reproduces streamScore (tools/lm
	/// parity Δ≈5e-6); candidates longer than the fixed T fall back to the single-step path.
	private func batchScore(_ candidates: [String], session: Session, stepModel: MLModel,
		scoreModel: MLModel, tokenizer: KeyboardSentencePieceTokenizer) throws -> [String: Double] {
		let B = Self.scoreBatch, T = Self.scoreTime
		let contextState = try runContext(session.contextTokens, model: stepModel)
		let previousToken = session.contextTokens.last ?? tokenizer.padID
		var rows: [(key: String, tokens: [Int32])] = []
		var overflow: [String] = []
		var seen = Set<String>()
		for word in candidates.prefix(B) {
			let key = word.lowercased()
			guard seen.insert(key).inserted else { continue }
			let wordTokens = tokenizer.encode(key)
			guard !wordTokens.isEmpty else { continue }
			if wordTokens.count <= T { rows.append((key, wordTokens)) }
			else { overflow.append(word) }              // longer than the fixed window → single-step
		}
		var out: [String: Double] = [:]
		if !rows.isEmpty {
			guard let tokens = try? MLMultiArray(
					shape: [NSNumber(value: B), NSNumber(value: T)], dataType: .int32),
				let targets = try? MLMultiArray(
					shape: [NSNumber(value: B), NSNumber(value: T)], dataType: .int32),
				let mask = try? MLMultiArray(
					shape: [NSNumber(value: B), NSNumber(value: T)], dataType: .float32),
				let stateIn = try? MLMultiArray(
					shape: [NSNumber(value: layers), NSNumber(value: B), NSNumber(value: hidden)],
					dataType: .float32),
				let contextValues = Self.readVector(contextState, count: layers * hidden)
			else { throw GRUError.badOutput }
			let tokenPointer = tokens.dataPointer.bindMemory(to: Int32.self, capacity: B * T)
			let targetPointer = targets.dataPointer.bindMemory(to: Int32.self, capacity: B * T)
			let maskPointer = mask.dataPointer.bindMemory(to: Float.self, capacity: B * T)
			for index in 0..<(B * T) {
				tokenPointer[index] = tokenizer.padID; targetPointer[index] = 0; maskPointer[index] = 0
			}
			for (batch, row) in rows.enumerated() {
				for step in 0..<row.tokens.count {
					// Row input: [prev, w0 … w_{k-2}] predicts targets [w0 … w_{k-1}]; mask = 1.
					tokenPointer[batch * T + step] = step == 0 ? previousToken : row.tokens[step - 1]
					targetPointer[batch * T + step] = row.tokens[step]
					maskPointer[batch * T + step] = 1
				}
			}
			// Broadcast the context state [layers,1,hidden] across all B rows → [layers,B,hidden].
			let statePointer = stateIn.dataPointer.bindMemory(to: Float.self,
				capacity: layers * B * hidden)
			for layer in 0..<layers {
				let base = layer * hidden
				for batch in 0..<B {
					let destination = (layer * B + batch) * hidden
					for unit in 0..<hidden {
						statePointer[destination + unit] = Float(contextValues[base + unit])
					}
				}
			}
			let provider = try MLDictionaryFeatureProvider(dictionary: [
				"tokens": tokens, "state_in": stateIn, "targets": targets, "mask": mask])
			let output = try scoreModel.prediction(from: provider)
			guard let logProbs = output.featureValue(for: "log_probs")?.multiArrayValue,
				let values = Self.readVector(logProbs, count: rows.count) else {
				throw GRUError.badOutput
			}
			for (batch, row) in rows.enumerated() { out[row.key] = values[batch] }
		}
		if !overflow.isEmpty {
			let extra = try streamScoreSingleStep(overflow, session: session,
				model: stepModel, tokenizer: tokenizer)
			out.merge(extra) { current, _ in current }
		}
		return out
	}

	/// Read the first `count` scalars of a 1-D Core ML array, fp16/fp32/double tolerant.
	private static func readVector(_ array: MLMultiArray, count: Int) -> [Double]? {
		guard array.count >= count else { return nil }
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
	private func runContext(_ tokens: [Int32], model: MLModel) throws -> MLMultiArray {
		lock.lock(); let cached = contextStateCache; lock.unlock()
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
		lock.lock(); contextStateCache = (tokens, state); lock.unlock()
		return state
	}

	private func step(_ token: Int32, state: MLMultiArray, model: MLModel) throws
		-> (logits: MLMultiArray, state: MLMultiArray) {
		let tokenArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
		tokenArray[0] = NSNumber(value: token)
		let provider = try MLDictionaryFeatureProvider(dictionary: [
			"token": tokenArray, "state_in": state])
		let output = try model.prediction(from: provider)
		guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
			let newState = output.featureValue(for: "state_out")?.multiArrayValue else {
			throw GRUError.badOutput
		}
		return (logits, newState)
	}

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
	private func duplicate(_ source: MLMultiArray) throws -> MLMultiArray {
		let clone = try MLMultiArray(shape: source.shape, dataType: source.dataType)
		if source.dataType == .float32, source.strides == clone.strides {
			memcpy(clone.dataPointer, source.dataPointer, source.count * MemoryLayout<Float>.stride)
		} else {
			for index in 0..<source.count { clone[index] = source[index] }
		}
		return clone
	}

	/// log-softmax at one index, read straight off the logits buffer (no per-element NSNumber
	/// boxing — the old subscript form boxed ~vocab NSNumbers per step on the scoring hot loop).
	private static func logSoftmax(_ array: MLMultiArray, at index: Int) -> Double {
		let count = array.count
		guard index >= 0, index < count else { return -30 }
		func compute<T: BinaryFloatingPoint>(_ buffer: UnsafeBufferPointer<T>) -> Double {
			var maximum = -Float.greatestFiniteMagnitude
			for i in 0..<count { let value = Float(buffer[i]); if value > maximum { maximum = value } }
			var sum: Float = 0
			for i in 0..<count { sum += expf(Float(buffer[i]) - maximum) }
			return Double(Float(buffer[index]) - maximum - logf(sum))
		}
		switch array.dataType {
		case .float16: return array.withUnsafeBufferPointer(ofType: Float16.self) { compute($0) }
		case .float32: return array.withUnsafeBufferPointer(ofType: Float.self) { compute($0) }
		case .double: return array.withUnsafeBufferPointer(ofType: Double.self) { compute($0) }
		default: return -30
		}
	}
}
