import Foundation
import os

// Diagnostics: extension measures, app displays (App Group) — extracted from Keyboard.swift.

enum KBDiagnostics {

	/// Everything the app displays. All sizes in MB; times in seconds.
	struct Snapshot: Codable {
		var updated = Date.distantPast
		var modelActive = false
		var loadCount = 0           // times the model became resident (incl. reloads)
		var dropCount = 0           // times pressure evicted a resident model
		var warningCount = 0
		var criticalCount = 0
		var activeSeconds = 0.0     // cumulative time the model was resident
		var lastLoadMs = 0.0        // most recent MLModel load latency
		var peakFootprintMB = 0.0   // highest phys_footprint seen (what jetsam watches)
		var minAvailableMB = 0.0    // lowest headroom seen (0 = never sampled)
		var limitMB = 0.0           // inferred kill ceiling = footprint + headroom, at the tightest moment
		// Helpfulness: of the ranking passes the neural prior actually scored, how many
		// times did blending it in CHANGE the top candidate vs the n-gram alone? The
		// residency stats above say the model is loaded; this says it earns its memory.
		var neuralRankPasses = 0
		var neuralTop1Changed = 0
		// Optional for backward-compatible decoding of snapshots written by older builds.
		var modelState: String?
		var lastModelError: String?
		var lastGateAvailableMB: Double?
	}

	static let key = "kb.diag"
	static var store: UserDefaults { UserDefaults(suiteName: KBSettings.appGroup) ?? .standard }
	private static let log = Logger(subsystem: KBSettings.appGroup, category: "diag")

	// MARK: App side — read + reset

	static func read() -> Snapshot {
		guard let data = store.data(forKey: key),
			  let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
		return s
	}
	static func reset() { store.removeObject(forKey: key); Recorder.shared.clear() }

	// MARK: Live ranking log — see how the neural + n-gram scorers rank each candidate
	//
	// When `verbose` is on, the engine logs one message per keystroke to the unified
	// log (category "ranking"): every candidate's channel cost, neural score, n-gram
	// score, blended prior, and final rank, plus the autocorrect margin-gate decision.
	// Watch it live while typing:
	//   log stream --predicate 'subsystem == "group.com.swiftuimasterclass.keyboard"' --level info

	#if DEBUG
	static let defaultVerbose = true
	#else
	static let defaultVerbose = false
	#endif
	static var verbose: Bool {
		get { store.object(forKey: "kb.diag.verbose") as? Bool ?? defaultVerbose }
		set { store.set(newValue, forKey: "kb.diag.verbose") }
	}
	private static let rankLog = Logger(subsystem: KBSettings.appGroup, category: "ranking")

	struct RankRow {
		let word: String
		let cost, logFreq, freqTerm, neural, ngram, prior, score: Double
	}

	/// One candidate table per ranking pass. `rows` already sorted best-first.
	static func logRanking(label: String, context: [String], rows: [RankRow], modelActive: Bool, ms: Double) {
		guard verbose else { return }
		func f(_ x: Double) -> String { String(format: "%+.2f", x) }
		let ctx = context.suffix(4).joined(separator: " ")
		var lines = ["[\(label)] ctx=\"\(ctx)\"  model=\(modelActive ? "ACTIVE" : "ngram-only")  (\(String(format: "%.1f", ms)) ms)  score = chan + blend + 0.3·freq"]
		for (i, r) in rows.prefix(6).enumerated() {
			let word = r.word.count >= 12 ? String(r.word.prefix(12))
				: r.word.padding(toLength: 12, withPad: " ", startingAt: 0)
			let neu = r.neural.isNaN ? "   —  " : f(r.neural)
			let freq = r.freqTerm == r.logFreq
				? String(format: "%.2f", r.logFreq)
				: "\(String(format: "%.2f", r.logFreq))→\(String(format: "%.2f", r.freqTerm))"
			lines.append("  \(i < 3 ? "▶" : " ") \(word) chan \(f(-r.cost))  neu \(neu)  ng \(f(r.ngram))  blend \(f(r.prior))  freq \(freq)  = \(f(r.score))")
		}
		rankLog.info("\(lines.joined(separator: "\n"), privacy: .public)")
	}

	/// The autocorrect margin-gate outcome for the word just committed.
	static func logDecision(typed: String, best: String?, margin: Double, threshold: Double, corrected: Bool) {
		guard verbose else { return }
		rankLog.info("[autocorrect] typed=\"\(typed, privacy: .public)\" best=\"\(best ?? "—", privacy: .public)\" margin=\(String(format: "%.2f", margin), privacy: .public) gate=\(String(format: "%.1f", threshold), privacy: .public) → \(corrected ? "CORRECT" : "keep typed", privacy: .public)")
	}

	/// Next-word prediction: which words, and how many came from beam search vs n-gram.
	static func logPredict(context: [String], words: [String], beam: Int, ngram: Int) {
		guard verbose else { return }
		let ctx = context.suffix(4).joined(separator: " ")
		rankLog.info("[predict] ctx=\"\(ctx, privacy: .public)\" → \(words.joined(separator: ", "), privacy: .public)  (beam \(beam), ngram \(ngram))")
	}

	/// Glide preprocessing trace: how many points survived resampling, how many pivots,
	/// and which letters those pivots land on (the decoder's raw signal).
	static func logGlide(points: Int, pivots: Int, letters: String, margin: Double = -1) {
		guard verbose else { return }
		let m = margin >= 0 ? String(format: " margin=%.2f", margin) : ""
		rankLog.info("[glide] \(points) pts, \(pivots) pivots\(m, privacy: .public) → \(letters, privacy: .public)")
	}

	/// Per-user glide adaptation (#37): the supervised sample just observed and the σ / gate
	/// it produced, so the runtime tuning is watchable in the same log stream as ranking.
	static func logGlideAdapt(kind: String, cost: Double, profile: GlideProfile) {
		guard verbose else { return }
		let s = profile.summary
		rankLog.info("[glide-adapt] \(kind, privacy: .public) cost=\(String(format: "%.3f", cost), privacy: .public) → σ=\(String(format: "%.3f", s.sigma), privacy: .public) gate=\(String(format: "%.3f", s.gate), privacy: .public) (n=\(s.samples, privacy: .public))")
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
	/// gap (commit confidence). Extra keys are additive: calibrate.py reads only `word`/`path`.
	static func captureGlide(path: [(Double, Double)], times: [Double], dwell: [Character],
							 candidates: [String], committed: String?, margin: Double) {
		guard KBSettings.glideCapture, let url = glideCaptureURL else { return }
		let pts = path.map { "[\(String(format: "%.3f", $0.0)),\(String(format: "%.3f", $0.1))]" }.joined(separator: ",")
		let ts = times.map { String(format: "%.4f", $0) }.joined(separator: ",")
		let cands = candidates.map { "\"\($0)\"" }.joined(separator: ",")
		let dwellStr = dwell.map { "\"\($0)\"" }.joined(separator: ",")
		let line = "{\"path\":[\(pts)],\"times\":[\(ts)],\"dwell\":[\(dwellStr)],\"cands\":[\(cands)]," +
				   "\"word\":\(committed.map { "\"\($0)\"" } ?? "null"),\"margin\":\(String(format: "%.3f", margin))}\n"
		guard let data = line.data(using: .utf8) else { return }
		if let h = try? FileHandle(forWritingTo: url) {
			defer { try? h.close() }
			_ = try? h.seekToEnd(); try? h.write(contentsOf: data)
		} else {
			try? data.write(to: url, options: .atomic)
		}
	}

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
		private var activeSince: Date?
		private var tick = 0

		private init() { snap = KBDiagnostics.read() }

		func clear() { lock.lock(); snap = Snapshot(); activeSince = nil; tick = 0; lock.unlock() }

		/// The model became resident — initial load or a lazy reload after a drop.
		func modelActivated(loadMs: Double) {
			lock.lock()
			snap.loadCount += 1
			snap.lastLoadMs = loadMs
			snap.modelActive = true
			snap.modelState = "active"
			snap.lastModelError = nil
			activeSince = Date()
			persistLocked()
			lock.unlock()
			KBDiagnostics.log.notice("model active (load \(Int(loadMs)) ms)")
		}

		/// Explain why the model is not active instead of reducing every failure mode
		/// to a silent nil. Persisted immediately because load/gate transitions are rare.
		func modelState(_ state: String, error: String? = nil, availableMB: Double? = nil) {
			lock.lock()
			snap.modelState = state
			snap.lastModelError = error
			if let availableMB { snap.lastGateAvailableMB = availableMB }
			persistLocked()
			lock.unlock()
			if let error {
				KBDiagnostics.log.error("model \(state, privacy: .public): \(error, privacy: .public)")
			} else if let availableMB {
				KBDiagnostics.log.notice("model \(state, privacy: .public) at \(availableMB, privacy: .public) MB available")
			} else {
				KBDiagnostics.log.notice("model \(state, privacy: .public)")
			}
		}

		/// Memory pressure fired; the engine dropped the model if it was resident.
		func memoryPressure(critical: Bool, modelWasActive: Bool) {
			lock.lock()
			if critical { snap.criticalCount += 1 } else { snap.warningCount += 1 }
			if modelWasActive {
				snap.dropCount += 1
				foldActiveLocked()
				snap.modelActive = false
				snap.modelState = critical ? "pressure-critical" : "pressure-warning"
			}
			sampleLocked()
			persistLocked()
			lock.unlock()
			KBDiagnostics.log.notice("pressure \(critical ? "critical" : "warning"), dropped \(modelWasActive ? "yes" : "no")")
		}

		/// One ranking pass where the neural prior scored the candidates. `changedTop1`
		/// = the blended winner differs from what the n-gram alone would have picked.
		/// Counter bumps only; piggybacks on the same 1-in-16 persist cadence as sample().
		func rankPass(changedTop1: Bool) {
			lock.lock()
			snap.neuralRankPasses += 1
			if changedTop1 { snap.neuralTop1Changed += 1 }
			tick += 1
			if tick % 16 == 0 { persistLocked() }
			lock.unlock()
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
		private func foldActiveLocked() {
			if let since = activeSince {
				snap.activeSeconds += Date().timeIntervalSince(since)
				activeSince = nil
			}
		}
		private func persistLocked() {
			var out = snap
			if let since = activeSince { out.activeSeconds += Date().timeIntervalSince(since) }  // include the open interval
			out.updated = Date()
			if let data = try? JSONEncoder().encode(out) { KBDiagnostics.store.set(data, forKey: KBDiagnostics.key) }
		}
	}
}
