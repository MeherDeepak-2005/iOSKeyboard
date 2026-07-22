import Foundation
import CoreML

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
		}
		padID = pad ?? 0
		englishModeID = english
		maximumPieceLength = min(maximum, 24)
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
		tokens += tokenizer.encode(words.suffix(12).joined(separator: " ").lowercased())
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
final class GRULanguagePrior: NeuralLanguagePrior, @unchecked Sendable {
	let modelTier: DecodeModelTier = .neuralGRU

	private enum GRUError: Error { case notReady, badOutput }
	private struct Session { let contextTokens: [Int32] }

	private let compiledURL: URL?
	private let packageURL: URL?
	private let tokenizer: KeyboardSentencePieceTokenizer?
	private let layers: Int
	private let hidden: Int
	private let queue = DispatchQueue(label: "keyboard.neural.gru", qos: .userInitiated)
	private let lock = NSLock()
	private var model: MLModel?
	private var loading = false
	private var sessions: [UInt64: Session] = [:]

	static func bundled() -> GRULanguagePrior {
		GRULanguagePrior(
			compiledURL: Bundle.main.url(forResource: "gru", withExtension: "mlmodelc"),
			packageURL: Bundle.main.url(forResource: "gru", withExtension: "mlpackage"),
			tokenizerURL: Bundle.main.url(forResource: "gru_tokenizer", withExtension: "bin"))
	}

	init(compiledURL: URL?, packageURL: URL?, tokenizerURL: URL?,
		layers: Int = 2, hidden: Int = 256) {
		self.compiledURL = compiledURL
		self.packageURL = packageURL
		self.tokenizer = tokenizerURL.flatMap(KeyboardSentencePieceTokenizer.init(url:))
		self.layers = layers
		self.hidden = hidden
		prepareForSelection()
	}

	var isReady: Bool { lock.lock(); defer { lock.unlock() }; return model != nil }

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
			lock.lock(); model = loaded; loading = false; lock.unlock()
		} catch {
			lock.lock(); model = nil; loading = false; lock.unlock()
		}
	}

	func prepareContext(_ words: [String], wordSessionID: UInt64) {
		guard let tokenizer else { return }
		var tokens = tokenizer.englishModeID.map { [$0] } ?? []
		tokens += tokenizer.encode(words.suffix(12).joined(separator: " ").lowercased())
		lock.lock(); sessions[wordSessionID] = Session(contextTokens: tokens); lock.unlock()
	}

	func discardSession(_ wordSessionID: UInt64) {
		lock.lock(); sessions[wordSessionID] = nil; lock.unlock()
	}

	func handleMemoryPressure() {
		lock.lock(); model = nil; lock.unlock()
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

	/// One log P(word | context) per candidate: rebuild the recurrent state over the context,
	/// then thread each candidate's word tokens, summing log-softmax of each realized token.
	/// Per-token prediction has overhead; a batched score export is the perf optimization.
	private func streamScore(_ candidates: [String], session: Session, model: MLModel,
		tokenizer: KeyboardSentencePieceTokenizer) throws -> [String: Double] {
		let contextState = try runContext(session.contextTokens, model: model)
		let previousToken = session.contextTokens.last ?? tokenizer.padID
		var out: [String: Double] = [:]
		for word in candidates {
			let wordTokens = tokenizer.encode(word.lowercased())
			guard !wordTokens.isEmpty else { continue }
			var state = try duplicate(contextState)
			var previous = previousToken
			var logProbability = 0.0
			for token in wordTokens {
				let (logits, nextState) = try step(previous, state: state, model: model)
				logProbability += logSoftmax(logits, at: Int(token))
				state = nextState
				previous = token
			}
			out[word.lowercased()] = logProbability
		}
		return out
	}

	private func runContext(_ tokens: [Int32], model: MLModel) throws -> MLMultiArray {
		var state = try zeroState()
		var previous = tokenizer?.padID ?? 0
		for token in tokens {
			let (_, nextState) = try step(previous, state: state, model: model)
			state = nextState
			previous = token
		}
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
		for index in 0..<state.count { state[index] = 0 }
		return state
	}

	private func duplicate(_ source: MLMultiArray) throws -> MLMultiArray {
		let clone = try MLMultiArray(shape: source.shape, dataType: source.dataType)
		for index in 0..<source.count { clone[index] = source[index] }
		return clone
	}

	private func logSoftmax(_ logits: MLMultiArray, at index: Int) -> Double {
		let count = logits.count
		guard index >= 0, index < count else { return -30 }
		var maximum = -Double.greatestFiniteMagnitude
		for i in 0..<count { maximum = max(maximum, logits[i].doubleValue) }
		var sum = 0.0
		for i in 0..<count { sum += exp(logits[i].doubleValue - maximum) }
		return logits[index].doubleValue - maximum - log(sum)
	}
}
