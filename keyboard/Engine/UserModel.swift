import Foundation

// UserModel: on-device personalization — extracted from Keyboardengine.swift.

final class UserModel {
	private var tri: [String: [String: Int]] = [:], triTot: [String: Int] = [:]
	private var bi:  [String: [String: Int]] = [:], biTot:  [String: Int] = [:]
	private var unigrams: [String: Int] = [:]
	private var unigramTotal = 0

	/// All tables are written on the engine queue (learn/demote/prune) but READ from the
	/// main thread too: the space key's synchronous fast-autocorrect ranks candidates with
	/// the n-gram scorer inline, precisely so it never has to wait on the engine queue. So
	/// every access goes through this lock — held for dictionary lookups (microseconds),
	/// never across encoding or disk work.
	private let lock = NSLock()

	// MARK: Locked read API (safe from any thread)

	func uniCount(_ w: String) -> Int {
		lock.lock(); defer { lock.unlock() }
		return unigrams[w] ?? 0
	}
	/// The unigram-backoff inputs, read atomically: (count, total, distinct).
	func uniBackoff(_ w: String) -> (count: Int, total: Int, distinct: Int) {
		lock.lock(); defer { lock.unlock() }
		return (unigrams[w] ?? 0, unigramTotal, unigrams.count)
	}
	func biLookup(_ p: String, _ w: String) -> (count: Int, total: Int) {
		lock.lock(); defer { lock.unlock() }
		return (bi[p]?[w] ?? 0, biTot[p] ?? 0)
	}
	func triLookup(_ key: String, _ w: String) -> (count: Int, total: Int) {
		lock.lock(); defer { lock.unlock() }
		return (tri[key]?[w] ?? 0, triTot[key] ?? 0)
	}
	/// Copies are tiny: maxWordsPerContext caps each at 8 entries.
	func biDist(_ p: String) -> [String: Int] {
		lock.lock(); defer { lock.unlock() }
		return bi[p] ?? [:]
	}
	func triDist(_ key: String) -> [String: Int] {
		lock.lock(); defer { lock.unlock() }
		return tri[key] ?? [:]
	}
	func topUnigrams(_ limit: Int) -> [String] {
		lock.lock(); defer { lock.unlock() }
		return Array(unigrams.sorted { $0.value > $1.value }.prefix(limit).map(\.key))
	}
	/// COW snapshot for iteration off the lock (engine init's applyLearned).
	func unigramsSnapshot() -> [String: Int] {
		lock.lock(); defer { lock.unlock() }
		return unigrams
	}

	// Growth caps. Without them every committed word adds unigram + bigram + trigram
	// entries forever, and the whole file is reloaded into dirty heap dictionaries at
	// every keyboard launch — the extension's footprint creeps up across weeks of use.
	// Halve-and-drop pruning keeps habits (high counts survive halving) and sheds the
	// one-off long tail (count-1 entries vanish), so personalization quality is kept.
	private static let maxUnigrams = 4000
	private static let maxContexts = 2000          // per table (bi, tri)
	private static let maxWordsPerContext = 8

	/// Enforce the caps. Cheap when under them (four count checks). Returns whether
	/// anything was pruned so callers can persist the shrunk model.
	@discardableResult
	func pruneIfNeeded() -> Bool {
		lock.lock(); defer { lock.unlock() }
		return pruneLocked()
	}
	private func pruneLocked() -> Bool {
		var pruned = false
		if unigrams.count > Self.maxUnigrams {
			unigrams = unigrams.compactMapValues { $0 >= 2 ? $0 >> 1 : nil }
			if unigrams.count > Self.maxUnigrams {          // pathological: all counts high
				unigrams = Dictionary(uniqueKeysWithValues:
					unigrams.sorted { $0.value > $1.value }.prefix(Self.maxUnigrams).map { ($0.key, $0.value) })
			}
			unigramTotal = unigrams.values.reduce(0, +)
			pruned = true
		}
		if bi.count > Self.maxContexts { prune(&bi, totals: &biTot); pruned = true }
		if tri.count > Self.maxContexts { prune(&tri, totals: &triTot); pruned = true }
		return pruned
	}

	private func prune(_ table: inout [String: [String: Int]], totals: inout [String: Int]) {
		var next: [String: [String: Int]] = [:]
		next.reserveCapacity(table.count / 2)
		for (ctx, words) in table {
			var kept = words.compactMapValues { $0 >= 2 ? $0 >> 1 : nil }
			if kept.count > Self.maxWordsPerContext {
				kept = Dictionary(uniqueKeysWithValues:
					kept.sorted { $0.value > $1.value }.prefix(Self.maxWordsPerContext).map { ($0.key, $0.value) })
			}
			if !kept.isEmpty { next[ctx] = kept }
		}
		if next.count > Self.maxContexts {                  // pathological: still over after halving
			next = Dictionary(uniqueKeysWithValues:
				next.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }
					.prefix(Self.maxContexts).map { ($0.key, $0.value) })
		}
		table = next
		totals = table.mapValues { $0.values.reduce(0, +) }
	}

	private lazy var storeURL: URL = {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("kb_model.json")
	}()
	/// Encoding + disk write run here, OFF the engine's barrier. `save()` snapshots the
	/// model under the barrier (cheap, consistent) and hands the write to this serial
	/// queue, so the space key's `autocorrection()` never blocks behind a JSON write.
	private let ioQueue = DispatchQueue(label: "keyboard.usermodel.io", qos: .utility)

	/// `context` and `word` must already be lowercased.
	func learn(context ctx: [String], word lw: String) {
		lock.lock(); defer { lock.unlock() }
		unigrams[lw, default: 0] += 1; unigramTotal += 1
		if let p = ctx.last {
			bi[p, default: [:]][lw, default: 0] += 1; biTot[p, default: 0] += 1
		}
		if ctx.count >= 2 {
			let k = ctx[ctx.count - 2] + " " + ctx[ctx.count - 1]
			tri[k, default: [:]][lw, default: 0] += 1; triTot[k, default: 0] += 1
		}
	}

	/// Walk back one learned use of a word the user actively replaced — undoing the
	/// unigram credit a mistaken commit gave it.
	func demote(_ lw: String) {
		lock.lock(); defer { lock.unlock() }
		guard let c = unigrams[lw] else { return }
		unigrams[lw] = c > 1 ? c - 1 : nil
		unigramTotal = max(0, unigramTotal - 1)
	}

	/// On-disk shape. Older files carry extra keys (`keptCounts`, `kept`) from when
	/// rejections persisted — JSONDecoder ignores unknown keys, so they load fine and
	/// the keys vanish on the next save.
	private struct Snapshot: Codable {
		var tri: [String: [String: Int]]; var bi: [String: [String: Int]]
		var uni: [String: Int]
	}
	func load() {
		guard let data = try? Data(contentsOf: storeURL),
			  let m = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
		lock.lock()
		tri = m.tri; bi = m.bi; unigrams = m.uni
		triTot = tri.mapValues { $0.values.reduce(0, +) }
		biTot  = bi.mapValues  { $0.values.reduce(0, +) }
		unigramTotal = unigrams.values.reduce(0, +)
		// Models persisted before the caps existed shrink here, once, at load — the
		// launch footprint drops immediately and the pruned file is written back.
		let pruned = pruneLocked()
		lock.unlock()
		if pruned { save() }
	}
	func save() {
		// Snapshot under the lock (COW references — O(1)); encode on the caller (cheap,
		// in-memory, off the lock); only the slow disk write goes to the I/O queue, keeping
		// it off the engine queue the space key's decisions can depend on. Serial queue =
		// writes stay ordered, last one wins.
		lock.lock()
		let m = Snapshot(tri: tri, bi: bi, uni: unigrams)
		lock.unlock()
		guard let data = try? JSONEncoder().encode(m) else { return }
		let url = storeURL
		ioQueue.async { try? data.write(to: url) }
	}
}

