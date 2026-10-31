import Foundation

// MARK: - GlideProfile (#37): runtime per-user glide adaptation
//
// The glide decoder has two calibration knobs — σ (the rerank temperature that converts
// grid-distance into nats so the LM can arbitrate only genuinely close shapes) and the
// commit GATE (the best shape cost that still counts as "traced something"). Both were
// grid-searched OFFLINE on synthetic swipes (tools/glide_eval) and, with #36, re-fit to
// captured real strokes via calibrate.py. #37 moves that fitting ON DEVICE and makes it
// continuous: it watches the user's OWN glides and nudges σ and the gate toward their hand.
//
//   • A sloppy glider's correct swipes carry higher shape cost → the mean rises → the gate
//     rises (so those correct swipes keep committing instead of being rejected as "nothing
//     traced") and σ grows (so the LM/frequency terms stay comparable to the shape term).
//   • A precise glider's costs are low → the gate tightens (junk smears stop committing)
//     and σ shrinks (shape dominates, as it should when the trace is clean).
//
// Safety (the reason #37 waited on #36's real data — "adapt now and you adapt toward noise"):
//   1. Supervised ONLY. Statistics move only when the user explicitly picks a different
//      candidate, whose intended word and shape cost are known, never on automatic commits.
//   2. Warm-up blend. Until `warmup` supervised samples exist the returned σ/gate are exactly
//      the baked defaults; the adapted value ramps in linearly, so a first odd stroke moves
//      nothing and the keyboard is identical to today's on a fresh install.
//   3. Hard clamps. σ ∈ [0.06, 0.30], gate ∈ [0.30, 0.60] — the profile can refine the
//      decoder for a user but can never wander into a degenerate regime.
//
// Thread-safety: self-contained behind `lock`, so the engine reads σ/gate from the concurrent
// glide pass and feeds samples from the main thread without touching the engine queue. The
// tiny Codable state persists to the App Group so a user's tuning survives across sessions.

final class GlideProfile {
	/// Baked grid-searched defaults — identical to the constants glide shipped with.
	static let baseGate  = 0.43

	/// EWMA of the CORRECT-word shape cost, seeded near the synthetic-harness correct-cost
	/// distribution (mean ~0.22, var ~0.006) so early on-device samples blend smoothly.
	private nonisolated struct State: Codable {
		var epoch: UInt64?
		var n = 0
		var mean = 0.22
		var varc = 0.006
	}
	private var state = State(epoch: KBPersonalData.currentEpoch)
	private let lock = NSLock()

	private static let key = "kb.glideprofile"
	private static var store: UserDefaults { KBSettings.sharedDefaults }
	private static let io = DispatchQueue(label: "keyboard.glideprofile.io", qos: .utility)

	// Adaptation constants.
	private static let alpha  = 0.12                 // EWMA rate — slow; no single stroke dominates
	private static let warmup = 12.0                 // supervised samples before adapted fully replaces default

	func load() {
		let epoch = KBPersonalData.currentEpoch
		guard let d = Self.store.data(forKey: Self.key),
			  var s = try? JSONDecoder().decode(State.self, from: d),
			  (s.epoch ?? epoch) == epoch else {
			reset(to: epoch)
			return
		}
		s.epoch = epoch
		lock.lock(); state = s; lock.unlock()
	}
	private func persist(_ s: State) {
		Self.io.async {
			guard let epoch = s.epoch,
				  let d = try? JSONEncoder().encode(s) else { return }
			KBPersonalData.withExclusiveStoreLock {
				guard KBPersonalData.currentEpoch == epoch else { return }
				Self.store.set(d, forKey: Self.key)
			}
		}
	}
	private func snapshot() -> State { lock.lock(); defer { lock.unlock() }; return state }

	/// Feed a known-correct shape cost from an explicitly selected alternative.
	func observeCorrect(cost: Double) {
		guard cost.isFinite, cost >= 0 else { return }
		let epoch = KBPersonalData.currentEpoch
		let s: State = {
			lock.lock(); defer { lock.unlock() }
			if state.epoch != epoch { state = State(epoch: epoch) }
            let values = KBNumericPolicy.glide([Double(state.n), state.mean, state.varc].map(NSNumber.init(value:)), cost: NSNumber(value: cost))
            state.n = values[0].intValue; state.mean = values[1].doubleValue; state.varc = values[2].doubleValue
			return state
		}()
		persist(s)
	}

	func reset(to epoch: UInt64 = KBPersonalData.currentEpoch) {
		lock.lock()
		state = State(epoch: epoch)
		lock.unlock()
	}

	/// 0 until the first sample, ramping to 1 at `warmup` — how much of the adapted value shows.
	private func blend(_ n: Int) -> Double { min(1.0, Double(n) / Self.warmup) }

	/// Per-user rerank temperature. Larger for a sloppy hand (LM stays in play), smaller for a
	/// precise one (shape dominates). Clamped so it can refine but never degenerate.
	var sigma: Double {
		let s = snapshot()
        return KBNumericPolicy.glide([Double(s.n), s.mean, s.varc].map(NSNumber.init(value:)), cost: nil)[0].doubleValue
	}
	/// Per-user commit gate = mean correct cost + ~2.7·std, i.e. leave the same headroom over
	/// the user's own correct-cost spread that the offline p95/scribble midpoint left over the
	/// synthetic one. Clamped to a safe band around the baked 0.43.
	var gate: Double {
		let s = snapshot()
        return KBNumericPolicy.glide([Double(s.n), s.mean, s.varc].map(NSNumber.init(value:)), cost: nil)[1].doubleValue
	}

	/// For diagnostics / a future health-screen readout.
	var summary: (sigma: Double, gate: Double, samples: Int) { (sigma, gate, snapshot().n) }
}
