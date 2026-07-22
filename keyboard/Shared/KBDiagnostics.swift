import Foundation
import os

// Diagnostics: extension measures, app displays (App Group) — extracted from Keyboard.swift.

enum KBDiagnostics {

	/// Everything the app displays. All sizes in MB; times in seconds.
	struct Snapshot: Codable {
		var updated = Date.distantPast
		var warningCount = 0
		var criticalCount = 0
		var peakFootprintMB = 0.0   // highest phys_footprint seen (what jetsam watches)
		var minAvailableMB = 0.0    // lowest headroom seen (0 = never sampled)
		var limitMB = 0.0           // inferred kill ceiling = footprint + headroom, at the tightest moment
		var storageFailureCount: Int?
		var lastStorageOperation: String?
		// Fixed buckets contain counts only. No text, context, file paths, or identifiers.
		var hostInsertLatencyBins: [Int]?
		var tapDecodeLatencyBins: [Int]?
		var glidePreviewLatencyBins: [Int]?
		var glideFinalLatencyBins: [Int]?
		var glideCommitLatencyBins: [Int]?
	}

	static let key = "kb.diag"
	static var store: UserDefaults { KBSettings.sharedDefaults }
	private static let log = Logger(subsystem: KBSettings.appGroup, category: "diag")
	private static let glideCaptureQueue = DispatchQueue(label: "keyboard.glide.capture", qos: .utility)
	private static let metricsQueue = DispatchQueue(label: "keyboard.metrics", qos: .utility)
	private static let performanceLog = OSLog(subsystem: KBSettings.appGroup,
		category: .pointsOfInterest)
	private static let latencyThresholds: [Double] = [1, 2, 4, 8, 16, 32, 50, 75, 120, 250]

	enum LatencyOperation: Sendable {
		case hostInsert, tapDecode, glidePreview, glideFinal, glideCommit
	}

	static func beginHostInsert() -> OSSignpostID {
		let id = OSSignpostID(log: performanceLog)
		os_signpost(.begin, log: performanceLog, name: "Host Insert", signpostID: id)
		return id
	}
	static func endHostInsert(_ id: OSSignpostID, milliseconds: Double) {
		os_signpost(.end, log: performanceLog, name: "Host Insert", signpostID: id)
		recordLatency(.hostInsert, milliseconds: milliseconds)
	}
	static func beginTapDecode() -> OSSignpostID {
		let id = OSSignpostID(log: performanceLog)
		os_signpost(.begin, log: performanceLog, name: "Tap Decode", signpostID: id)
		return id
	}
	static func endTapDecode(_ id: OSSignpostID, milliseconds: Double) {
		os_signpost(.end, log: performanceLog, name: "Tap Decode", signpostID: id)
		recordLatency(.tapDecode, milliseconds: milliseconds)
	}
	static func beginGlidePreview() -> OSSignpostID {
		let id = OSSignpostID(log: performanceLog)
		os_signpost(.begin, log: performanceLog, name: "Glide Preview", signpostID: id)
		return id
	}
	static func endGlidePreview(_ id: OSSignpostID, milliseconds: Double) {
		os_signpost(.end, log: performanceLog, name: "Glide Preview", signpostID: id)
		recordLatency(.glidePreview, milliseconds: milliseconds)
	}
	static func beginGlideFinal() -> OSSignpostID {
		let id = OSSignpostID(log: performanceLog)
		os_signpost(.begin, log: performanceLog, name: "Glide Final", signpostID: id)
		return id
	}
	static func endGlideFinal(_ id: OSSignpostID, milliseconds: Double) {
		os_signpost(.end, log: performanceLog, name: "Glide Final", signpostID: id)
		recordLatency(.glideFinal, milliseconds: milliseconds)
	}

	private static func recordLatency(_ operation: LatencyOperation, milliseconds: Double) {
		metricsQueue.async { Recorder.shared.recordLatency(operation, milliseconds: milliseconds) }
	}

	static func percentile(_ bins: [Int]?, fraction: Double) -> String? {
		guard let bins, bins.count == latencyThresholds.count + 1 else { return nil }
		let total = bins.reduce(0, +)
		guard total > 0 else { return nil }
		let target = max(1, Int(ceil(Double(total) * min(max(fraction, 0), 1))))
		var running = 0
		for (index, count) in bins.enumerated() {
			running += count
			if running >= target {
				return index < latencyThresholds.count
					? "≤ \(Int(latencyThresholds[index])) ms"
					: "> \(Int(latencyThresholds.last ?? 250)) ms"
			}
		}
		return nil
	}

	// MARK: App side — read + reset

	static func read() -> Snapshot {
		guard let data = store.data(forKey: key),
			  let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
		return s
	}
	static func reset() {
		store.removeObject(forKey: key)
		// NEURAL_DEBUG_TELEMETRY_REMOVE
		#if DEBUG || INTERNAL_NEURAL
		store.removeObject(forKey: neuralDebugKey)
		#endif
		Recorder.shared.clear()
	}

	// MARK: DEBUG-only neural ranking telemetry
	// NEURAL_DEBUG_TELEMETRY_REMOVE: remove every block carrying this marker in
	// KBDiagnostics.swift, Keyboardengine.swift, and ContentView.swift after promotion.
	#if DEBUG || INTERNAL_NEURAL
	struct NeuralRankRowSnapshot: Codable, Equatable, Identifiable {
		var id: String { "\(finalRank)-\(word)" }
		let word: String
		let ngramRank: Int
		let finalRank: Int
		let spatialCost: Double
		let ngramLogProbability: Double
		let neuralLogProbability: Double
		let ngramScore: Double
		let finalScore: Double
	}

	struct NeuralDebugSnapshot: Codable, Equatable {
		let updated: Date
		let state: String
		let detail: String?
		let modelTier: String
		let isActive: Bool
		let isReady: Bool
		let topPickChangeCount: Int
		let typedWord: String?
		let contextTail: [String]
		let ngramTopPick: String?
		let finalTopPick: String?
		let wordSessionID: UInt64?
		let rows: [NeuralRankRowSnapshot]
	}

	private static let neuralDebugKey = "kb.diag.neural.debug.v1"
	private static let neuralDebugQueue = DispatchQueue(
		label: "keyboard.neural.debug.telemetry", qos: .utility)

	static func readNeuralDebug() -> NeuralDebugSnapshot? {
		guard let data = store.data(forKey: neuralDebugKey) else { return nil }
		return try? JSONDecoder().decode(NeuralDebugSnapshot.self, from: data)
	}

	static func recordNeuralState(tier: DecodeModelTier, ready: Bool, state: String,
		detail: String? = nil) {
		neuralDebugQueue.async {
			let previous = readNeuralDebug()
			persistNeuralDebug(NeuralDebugSnapshot(updated: Date(), state: state,
				detail: detail,
				modelTier: tier.rawValue, isActive: tier != .ngram && ready,
				isReady: ready, topPickChangeCount: previous?.topPickChangeCount ?? 0,
				typedWord: previous?.typedWord, contextTail: previous?.contextTail ?? [],
				ngramTopPick: previous?.ngramTopPick, finalTopPick: previous?.finalTopPick,
				wordSessionID: previous?.wordSessionID, rows: previous?.rows ?? []))
		}
	}

	static func recordNeuralRanking(tier: DecodeModelTier, typedWord: String,
		context: [String], wordSessionID: UInt64, rows: [NeuralRankRowSnapshot]) {
		neuralDebugQueue.async {
			let previous = readNeuralDebug()
			let ngramTop = rows.min(by: { $0.ngramRank < $1.ngramRank })?.word
			let finalTop = rows.min(by: { $0.finalRank < $1.finalRank })?.word
			let changed = ngramTop != nil && finalTop != nil && ngramTop != finalTop
			persistNeuralDebug(NeuralDebugSnapshot(updated: Date(), state: "ranked",
				detail: nil,
				modelTier: tier.rawValue, isActive: true, isReady: true,
				topPickChangeCount: (previous?.topPickChangeCount ?? 0) + (changed ? 1 : 0),
				typedWord: typedWord, contextTail: Array(context.suffix(4)),
				ngramTopPick: ngramTop, finalTopPick: finalTop,
				wordSessionID: wordSessionID,
				rows: rows.sorted { $0.finalRank < $1.finalRank }))
		}
	}

	private static func persistNeuralDebug(_ snapshot: NeuralDebugSnapshot) {
		if let data = try? JSONEncoder().encode(snapshot) {
			store.set(data, forKey: neuralDebugKey)
		}
	}
	#endif

	// MARK: Live ranking log — inspect channel, n-gram, and frequency contributions
	//
	// When `verbose` is on, the engine logs one message per keystroke to the unified
	// log (category "ranking"): every candidate's channel cost, n-gram score,
	// frequency contribution, and final rank, plus the autocorrect margin decision.
	// Watch it live while typing:
	//   log stream --predicate 'subsystem == "group.com.swiftuimasterclass.keyboard"' --level info

	static let defaultVerbose = false
	#if DEBUG
	static var verbose: Bool {
		get { store.object(forKey: "kb.diag.verbose") as? Bool ?? defaultVerbose }
		set { store.set(newValue, forKey: "kb.diag.verbose") }
	}
	#else
	static var verbose: Bool {
		get { false }
		set { store.removeObject(forKey: "kb.diag.verbose") }
	}
	#endif
	private static let rankLog = Logger(subsystem: KBSettings.appGroup, category: "ranking")

	struct RankRow {
		let word: String
		let cost, logFreq, freqTerm, ngram, score: Double
	}

	/// One candidate table per ranking pass. `rows` already sorted best-first.
	static func logRanking(label: String, context: [String], rows: [RankRow], ms: Double) {
		#if DEBUG
		guard verbose else { return }
		func f(_ x: Double) -> String { String(format: "%+.2f", x) }
		let ctx = context.suffix(4).joined(separator: " ")
		var lines = ["[\(label)] ctx=\"\(ctx)\"  model=ngram  (\(String(format: "%.1f", ms)) ms)  score = chan + ngram + 0.3·freq"]
		for (i, r) in rows.prefix(6).enumerated() {
			let word = r.word.count >= 12 ? String(r.word.prefix(12))
				: r.word.padding(toLength: 12, withPad: " ", startingAt: 0)
			let freq = r.freqTerm == r.logFreq
				? String(format: "%.2f", r.logFreq)
				: "\(String(format: "%.2f", r.logFreq))→\(String(format: "%.2f", r.freqTerm))"
			lines.append("  \(i < 3 ? "▶" : " ") \(word) chan \(f(-r.cost))  ng \(f(r.ngram))  freq \(freq)  = \(f(r.score))")
		}
		rankLog.debug("\(lines.joined(separator: "\n"), privacy: .private(mask: .hash))")
		#endif
	}

	/// The autocorrect margin-gate outcome for the word just committed.
	static func logDecision(typed: String, best: String?, margin: Double, threshold: Double, corrected: Bool) {
		#if DEBUG
		guard verbose else { return }
		rankLog.debug("[autocorrect] typed=\"\(typed, privacy: .private(mask: .hash))\" best=\"\(best ?? "—", privacy: .private(mask: .hash))\" margin=\(String(format: "%.2f", margin), privacy: .public) gate=\(String(format: "%.1f", threshold), privacy: .public) result=\(corrected ? "correct" : "keep", privacy: .public)")
		#endif
	}

	/// Suggestion-pick trace (#3): the bar mode, the word being replaced, the picked
	/// suggestion, the document tail, and how many deleteBackward calls the replace
	/// transaction actually issued — so a "picking deletes the whole word" report
	/// captures the exact replace that misfired instead of relying on a live repro.
	static func logPick(mode: String, replacing: String, with picked: String,
		contextTail: String, deletes: Int, inserted: Bool) {
		#if DEBUG
		guard verbose else { return }
		rankLog.debug("[pick] mode=\(mode, privacy: .public) replace=\"\(replacing, privacy: .private(mask: .hash))\" -> \"\(picked, privacy: .private(mask: .hash))\" tail=\"\(contextTail, privacy: .private(mask: .hash))\" deletes=\(deletes, privacy: .public) inserted=\(inserted, privacy: .public)")
		#endif
	}

	/// Next-word prediction: which words, and how many came from beam search vs n-gram.
	static func logPredict(context: [String], words: [String], beam: Int, ngram: Int) {
		#if DEBUG
		guard verbose else { return }
		let ctx = context.suffix(4).joined(separator: " ")
		rankLog.debug("[predict] ctx=\"\(ctx, privacy: .private(mask: .hash))\" words=\(words.joined(separator: ", "), privacy: .private(mask: .hash)) beam=\(beam, privacy: .public) ngram=\(ngram, privacy: .public)")
		#endif
	}

	/// Glide preprocessing trace: how many points survived resampling, how many pivots,
	/// and which letters those pivots land on (the decoder's raw signal).
	static func logGlide(points: Int, pivots: Int, letters: String, margin: Double = -1) {
		#if DEBUG
		guard verbose else { return }
		let m = margin >= 0 ? String(format: " margin=%.2f", margin) : ""
		rankLog.debug("[glide] \(points, privacy: .public) pts, \(pivots, privacy: .public) pivots\(m, privacy: .public) words=\(letters, privacy: .private(mask: .hash))")
		#endif
	}

	/// End-to-end device latency from finger lift through the host `insertText` call.
	/// Emitted after insertion, so diagnostics can never delay the visible commit.
	static func logGlideCommit(ms: Double) {
		recordLatency(.glideCommit, milliseconds: ms)
		#if DEBUG
		guard verbose else { return }
		rankLog.debug("[glide-commit] lift-to-insert \(String(format: "%.2f", ms), privacy: .public) ms")
		#endif
	}

	/// Per-user glide adaptation (#37): the supervised sample just observed and the σ / gate
	/// it produced, so the runtime tuning is watchable in the same log stream as ranking.
	static func logGlideAdapt(kind: String, cost: Double, profile: GlideProfile) {
		#if DEBUG
		guard verbose else { return }
		let s = profile.summary
		rankLog.debug("[glide-adapt] \(kind, privacy: .public) cost=\(String(format: "%.3f", cost), privacy: .public) sigma=\(String(format: "%.3f", s.sigma), privacy: .public) gate=\(String(format: "%.3f", s.gate), privacy: .public) n=\(s.samples, privacy: .public)")
		#endif
	}

	/// The App Group file real glide strokes are appended to (for offline calibration).
	static var glideCaptureURL: URL? {
		FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KBSettings.appGroup)?
			.appendingPathComponent("glide_capture.jsonl")
	}

	/// Append one glide record as a JSONL line, when KBSettings.glideCapture is on. Fits the
	/// harness noise model to real strokes offline (tools/glide_eval/calibrate.py). Best-effort;
	/// never blocks typing.
	///
	/// `path` is the RAW grid trajectory aligned 1:1 with `times` (seconds), NOT the resampled
	/// path — resampling to even arc length erases the velocity that dwell/pivot calibration
	/// needs. `dwell` are the letters the finger lingered on; `margin` is the reranked top-1/top-2
	/// gap (commit confidence). A commit is deliberately not a training label. An
	/// explicit alternative pick appends a separate label event for the same opaque ID.
	static func captureGlide(id: String, path: [(Double, Double)], times: [Double], dwell: [Character],
							 candidates: [String], committed: String?, margin: Double) {
		#if DEBUG
		guard KBSettings.glideCapture else { return }
		glideCaptureQueue.async {
			writeGlideCapture([
				"event": "gesture",
				"id": id,
				"path": path.map { [$0.0, $0.1] },
				"times": times,
				"dwell": dwell.map(String.init),
				"candidates": candidates,
				"committed": (committed as Any?) ?? NSNull(),
				"margin": margin,
			])
		}
		#endif
	}

	/// Add ground truth only when the user explicitly chooses a different Glide word.
	static func captureGlideLabel(id: String, intended: String) {
		#if DEBUG
		guard KBSettings.glideCapture, !intended.isEmpty else { return }
		glideCaptureQueue.async {
			writeGlideCapture(["event": "label", "id": id, "intended": intended])
		}
		#endif
	}

	#if DEBUG
	private static func writeGlideCapture(_ record: [String: Any]) {
		guard let url = glideCaptureURL,
			  JSONSerialization.isValidJSONObject(record),
			  var data = try? JSONSerialization.data(withJSONObject: record) else { return }
		data.append(0x0A)
		let existingSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
		if existingSize > 5_000_000 { try? FileManager.default.removeItem(at: url) }
		if let handle = try? FileHandle(forWritingTo: url) {
			defer { try? handle.close() }
			_ = try? handle.seekToEnd()
			try? handle.write(contentsOf: data)
		} else {
			try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
		}
	}
	#endif

	// MARK: Measurement primitives (only meaningful INSIDE the memory-limited extension)

	/// The process's physical footprint in bytes — the exact quantity jetsam meters.
	static func footprintBytes() -> UInt64 {
		var info = task_vm_info_data_t()
		var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
		let kr = withUnsafeMutablePointer(to: &info) { p in
			p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
				task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
			}
		}
		return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
	}

	/// Bytes remaining before THIS process is jetsam-killed. Returns the extension's
	/// tight budget when called there; ~0 / large in the roomy host app, so only the
	/// extension records it.
	static func availableBytes() -> UInt64 {
		let a = os_proc_available_memory()
		return a > 0 ? UInt64(a) : 0
	}

	// MARK: Extension side — the accumulator

	static var recorder: Recorder { Recorder.shared }

	/// Owns the running snapshot in the extension. Cheap (a few counters); persists to
	/// the App Group only on state transitions and every 16th sample, so it never adds
	/// disk churn to the typing path.
	final class Recorder {
		static let shared = Recorder()
		private let lock = NSLock()
		private var snap: Snapshot
		private var tick = 0

		private init() { snap = KBDiagnostics.read() }

		func clear() { lock.lock(); snap = Snapshot(); tick = 0; lock.unlock() }
		func flush() { lock.lock(); persistLocked(); lock.unlock() }

		func memoryPressure(critical: Bool) {
			lock.lock()
			if critical { snap.criticalCount += 1 } else { snap.warningCount += 1 }
			sampleLocked()
			persistLocked()
			lock.unlock()
			KBDiagnostics.log.notice("memory pressure \(critical ? "critical" : "warning")")
		}

		func recordLatency(_ operation: LatencyOperation, milliseconds: Double) {
			lock.lock()
			switch operation {
			case .hostInsert:
				snap.hostInsertLatencyBins = bucket(snap.hostInsertLatencyBins, milliseconds)
			case .tapDecode:
				snap.tapDecodeLatencyBins = bucket(snap.tapDecodeLatencyBins, milliseconds)
			case .glidePreview:
				snap.glidePreviewLatencyBins = bucket(snap.glidePreviewLatencyBins, milliseconds)
			case .glideFinal:
				snap.glideFinalLatencyBins = bucket(snap.glideFinalLatencyBins, milliseconds)
			case .glideCommit:
				snap.glideCommitLatencyBins = bucket(snap.glideCommitLatencyBins, milliseconds)
			}
			tick += 1
			if tick % 32 == 0 { persistLocked() }
			lock.unlock()
		}

		private func bucket(_ existing: [Int]?, _ milliseconds: Double) -> [Int] {
			var bins = existing ?? []
			if bins.count != KBDiagnostics.latencyThresholds.count + 1 {
				bins = [Int](repeating: 0, count: KBDiagnostics.latencyThresholds.count + 1)
			}
			let index = KBDiagnostics.latencyThresholds.firstIndex { milliseconds <= $0 }
				?? KBDiagnostics.latencyThresholds.count
			bins[index] &+= 1
			return bins
		}

		/// Non-content persistence health. `operation` is a fixed code selected by the
		/// caller (for example `personal-model-read`), never a path or user string.
		func storageFailure(operation: String) {
			lock.lock()
			snap.storageFailureCount = (snap.storageFailureCount ?? 0) + 1
			snap.lastStorageOperation = operation
			persistLocked()
			lock.unlock()
			KBDiagnostics.log.error("storage operation failed: \(operation, privacy: .public)")
		}

		/// Cheap footprint/headroom sample. Call from the background suggestion pass.
		func sample() {
			lock.lock()
			sampleLocked()
			tick += 1
			if tick % 16 == 0 { persistLocked() }
			lock.unlock()
		}

		private func sampleLocked() {
			let foot = Double(KBDiagnostics.footprintBytes()) / 1_048_576
			let avail = Double(KBDiagnostics.availableBytes()) / 1_048_576
			if foot > snap.peakFootprintMB { snap.peakFootprintMB = foot }
			if avail > 0, snap.minAvailableMB == 0 || avail < snap.minAvailableMB {
				snap.minAvailableMB = avail
				snap.limitMB = foot + avail        // the ceiling, inferred at the tightest point
			}
		}
		private func persistLocked() {
			var out = snap
			out.updated = Date()
			if let data = try? JSONEncoder().encode(out) { KBDiagnostics.store.set(data, forKey: KBDiagnostics.key) }
		}
	}
}
