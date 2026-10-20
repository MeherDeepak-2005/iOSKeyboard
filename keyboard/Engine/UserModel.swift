// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import Foundation

// UserModel: on-device personalization — extracted from Keyboardengine.swift.

// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
// MIGRATION-NOTE: Planned immutable PersonalizationView exports unigram/bigram/trigram counts, totals, adopted words, spelling confirmations and reset epoch; Swift remains the only mutable personal-data owner.
final class UserModel {
	private let storageURLOverride: URL?
	private var tri: [String: [String: Int]] = [:], triTot: [String: Int] = [:]
	private var bi:  [String: [String: Int]] = [:], biTot:  [String: Int] = [:]
	private var unigrams: [String: Int] = [:]
	private var unigramTotal = 0
	/// Explicit spelling confirmations come only from an autocorrect undo. They are
	/// persisted separately from ordinary use counts so repeated accidental typos do
	/// not become indistinguishable from a word the user deliberately defended.
	private var spellingConfirmations: [String: Int] = [:]
	private var modelEpoch = KBPersonalData.currentEpoch
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private struct LearnEvent { let context: [String]; let word: String }
	private var recentLearnEvents: [LearnEvent] = []

	/// The engine queue owns mutations while the Glide queues may read personalization.
	/// Every access therefore goes through this short-held lock; encoding and disk I/O
	/// always happen after a snapshot has been taken and never while the lock is held.
	private let lock = NSLock()

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	init(storageURL: URL? = nil) {
		storageURLOverride = storageURL
	}

	// MARK: Locked read API (safe from any thread)

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func uniCount(_ w: String) -> Int {
		lock.lock(); defer { lock.unlock() }
		return unigrams[w] ?? 0
	}
	/// The unigram-backoff inputs, read atomically: (count, total, distinct).
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func uniBackoff(_ w: String) -> (count: Int, total: Int, distinct: Int) {
		lock.lock(); defer { lock.unlock() }
		return (unigrams[w] ?? 0, unigramTotal, unigrams.count)
	}
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func biLookup(_ p: String, _ w: String) -> (count: Int, total: Int) {
		lock.lock(); defer { lock.unlock() }
		return (bi[p]?[w] ?? 0, biTot[p] ?? 0)
	}
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func triLookup(_ key: String, _ w: String) -> (count: Int, total: Int) {
		lock.lock(); defer { lock.unlock() }
		return (tri[key]?[w] ?? 0, triTot[key] ?? 0)
	}
	/// Copies are tiny: maxWordsPerContext caps each at 8 entries.
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func biDist(_ p: String) -> [String: Int] {
		lock.lock(); defer { lock.unlock() }
		return bi[p] ?? [:]
	}
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func triDist(_ key: String) -> [String: Int] {
		lock.lock(); defer { lock.unlock() }
		return tri[key] ?? [:]
	}
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func topUnigrams(_ limit: Int) -> [String] {
		lock.lock(); defer { lock.unlock() }
		return Array(unigrams.sorted { $0.value > $1.value }.prefix(limit).map(\.key))
	}
	/// COW snapshot for iteration off the lock (engine init's applyLearned).
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func unigramsSnapshot() -> [String: Int] {
		lock.lock(); defer { lock.unlock() }
		return unigrams
	}
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func spellingConfirmationCount(_ word: String) -> Int {
		lock.lock(); defer { lock.unlock() }
		return spellingConfirmations[word] ?? 0
	}
	/// Number of distinct preceding words with which this spelling was actually used.
	/// This is queried only at the rare OOV-adoption threshold, so the bounded scan is
	/// preferable to maintaining another persistent index on every key boundary.
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func contextDiversity(for word: String, stoppingAt limit: Int = 2) -> Int {
		lock.lock(); defer { lock.unlock() }
		var count = 0
		for distribution in bi.values where distribution[word] != nil {
			count += 1
			if count >= limit { break }
		}
		return count
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func confirmSpelling(_ word: String) {
		lock.lock(); defer { lock.unlock() }
		let current = KBPersonalData.currentEpoch
		if modelEpoch != current { clearLocked(epoch: current) }
		spellingConfirmations[word] = min((spellingConfirmations[word] ?? 0) + 1, 8)
		if spellingConfirmations.count > 512 {
			spellingConfirmations = spellingConfirmations.compactMapValues { $0 >= 2 ? $0 - 1 : nil }
		}
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
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func pruneIfNeeded() -> Bool {
		lock.lock(); defer { lock.unlock() }
		return pruneLocked()
	}
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
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

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
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

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private func storeURL(for epoch: UInt64) -> URL? {
		storageURLOverride ?? KBPersonalData.modelURL(for: epoch)
	}
	private var legacyStoreURL: URL? {
		storageURLOverride == nil ? KBPersonalData.legacyModelURL : nil
	}
	/// Encoding + disk write run here, OFF the engine's barrier. `save()` snapshots the
	/// model under the barrier (cheap, consistent) and hands the write to this serial
	/// queue, so the space key's `autocorrection()` never blocks behind a JSON write.
	private let ioQueue = DispatchQueue(label: "keyboard.usermodel.io", qos: .utility)

	/// `context` and `word` must already be lowercased.
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func learn(context ctx: [String], word lw: String) {
		lock.lock(); defer { lock.unlock() }
		let current = KBPersonalData.currentEpoch
		if modelEpoch != current { clearLocked(epoch: current) }
		unigrams[lw, default: 0] += 1; unigramTotal += 1
		if let p = ctx.last {
			bi[p, default: [:]][lw, default: 0] += 1; biTot[p, default: 0] += 1
		}
		if ctx.count >= 2 {
			let k = ctx[ctx.count - 2] + " " + ctx[ctx.count - 1]
			tri[k, default: [:]][lw, default: 0] += 1; triTot[k, default: 0] += 1
		}
		recentLearnEvents.append(LearnEvent(context: ctx, word: lw))
		if recentLearnEvents.count > 64 { recentLearnEvents.removeFirst() }
	}

	/// Walk back the exact recent context contribution when possible. The old model
	/// decremented only the unigram, leaving the same mistake reinforced in bi/trigrams.
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func demote(_ lw: String) {
		lock.lock(); defer { lock.unlock() }
		let current = KBPersonalData.currentEpoch
		if modelEpoch != current { clearLocked(epoch: current); return }
		if decrement(&unigrams, key: lw) {
			unigramTotal = max(0, unigramTotal - 1)
		}
		guard let index = recentLearnEvents.lastIndex(where: { $0.word == lw }) else { return }
		let event = recentLearnEvents.remove(at: index)
		if let previous = event.context.last {
			decrementNested(&bi, totals: &biTot, context: previous, word: lw)
		}
		if event.context.count >= 2 {
			let context = event.context[event.context.count - 2] + " " + event.context[event.context.count - 1]
			decrementNested(&tri, totals: &triTot, context: context, word: lw)
		}
	}

	@discardableResult
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private func decrement(_ table: inout [String: Int], key: String) -> Bool {
		guard let value = table[key] else { return false }
		table[key] = value > 1 ? value - 1 : nil
		return true
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private func decrementNested(_ table: inout [String: [String: Int]],
							 totals: inout [String: Int], context: String, word: String) {
		guard var words = table[context], let value = words[word] else { return }
		words[word] = value > 1 ? value - 1 : nil
		if words.isEmpty { table[context] = nil; totals[context] = nil }
		else { table[context] = words; totals[context] = max(0, (totals[context] ?? 0) - 1) }
	}

	/// On-disk shape. Older files carry extra keys (`keptCounts`, `kept`) from when
	/// rejections persisted — JSONDecoder ignores unknown keys, so they load fine and
	/// the keys vanish on the next save.
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private nonisolated struct Snapshot: Codable {
		var version: Int?
		var epoch: UInt64?
		var tri: [String: [String: Int]]; var bi: [String: [String: Int]]
		var uni: [String: Int]
		var confirmed: [String: Int]?
	}
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func load() {
		let current = KBPersonalData.currentEpoch
		guard let primary = storeURL(for: current) else {
			KBDiagnostics.recorder.storageFailure(operation: "personal-container-unavailable")
			reset(to: current)
			return
		}
		let legacy = legacyStoreURL
		let source: URL? = FileManager.default.fileExists(atPath: primary.path)
			? primary
			: legacy.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
		guard let source else {
			reset(to: current)
			return
		}
		do {
			let data = try Data(contentsOf: source, options: .mappedIfSafe)
			guard data.count <= 4_000_000 else { throw StoreError.invalidShape }
			let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
			guard (decoded.version ?? 1) <= 2,
				  (decoded.epoch ?? current) == current,
				  decoded.uni.count <= Self.maxUnigrams * 2,
				  decoded.bi.count <= Self.maxContexts * 2,
				  decoded.tri.count <= Self.maxContexts * 2 else {
				throw StoreError.invalidShape
			}
			install(decoded, current: current, migratedLegacy: source == legacy)
		} catch {
			KBPersonalData.withExclusiveStoreLock {
				try? FileManager.default.removeItem(at: source)
			}
			KBDiagnostics.recorder.storageFailure(operation: "personal-model-read")
			reset(to: current)
		}
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private enum StoreError: Error { case invalidShape }

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private func install(_ m: Snapshot, current: UInt64, migratedLegacy: Bool) {
		lock.lock()
		modelEpoch = current
		tri = sanitize(m.tri); bi = sanitize(m.bi)
		unigrams = m.uni.filter { isValidWord($0.key) && $0.value > 0 }
		spellingConfirmations = (m.confirmed ?? [:]).filter {
			isValidWord($0.key) && $0.value > 0
		}
		triTot = tri.mapValues { $0.values.reduce(0, +) }
		biTot  = bi.mapValues  { $0.values.reduce(0, +) }
		unigramTotal = unigrams.values.reduce(0, +)
		// Models persisted before the caps existed shrink here, once, at load — the
		// launch footprint drops immediately and the pruned file is written back.
		let pruned = pruneLocked()
		lock.unlock()
		if pruned || migratedLegacy { save() }
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private func sanitize(_ table: [String: [String: Int]]) -> [String: [String: Int]] {
		var result: [String: [String: Int]] = [:]
		result.reserveCapacity(min(table.count, Self.maxContexts))
		for (context, words) in table where context.count <= 130 {
			let valid = words.filter { isValidWord($0.key) && $0.value > 0 }
			if !valid.isEmpty { result[context] = valid }
		}
		return result
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private func isValidWord(_ word: String) -> Bool {
		!word.isEmpty && word.count <= 64
			&& word.allSatisfy { $0.isLetter || $0 == "'" }
	}
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func save() {
		// Snapshot under the lock (COW references — O(1)); encoding and the atomic write
		// both run on the I/O queue. The epoch and cross-process file lock make reset win
		// over an already queued save from an older keyboard process.
		lock.lock()
		let epoch = modelEpoch
		let m = Snapshot(version: 2, epoch: epoch, tri: tri, bi: bi, uni: unigrams,
			confirmed: spellingConfirmations)
		lock.unlock()
		guard let url = storeURL(for: epoch) else {
			KBDiagnostics.recorder.storageFailure(operation: "personal-container-unavailable")
			return
		}
		ioQueue.async {
			let data: Data
			do { data = try JSONEncoder().encode(m) }
			catch {
				KBDiagnostics.recorder.storageFailure(operation: "personal-model-encode")
				return
			}
			KBPersonalData.withExclusiveStoreLock {
				guard KBPersonalData.currentEpoch == epoch else { return }
				do {
					try data.write(to: url,
						options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
				} catch {
					KBDiagnostics.recorder.storageFailure(operation: "personal-model-write")
				}
			}
		}
	}

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func reset(to epoch: UInt64 = KBPersonalData.currentEpoch) {
		lock.lock()
		clearLocked(epoch: epoch)
		lock.unlock()
	}

	/// Deterministic test seam; production never waits for persistence on an input path.
	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	func waitForPendingIO() { ioQueue.sync {} }

	// MIGRATION: planned SWIFT_IOS | stage=platform | target=IOSPlatform
	// MIGRATION-NOTE: Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data.
	private func clearLocked(epoch: UInt64) {
		tri.removeAll(keepingCapacity: false)
		triTot.removeAll(keepingCapacity: false)
		bi.removeAll(keepingCapacity: false)
		biTot.removeAll(keepingCapacity: false)
		unigrams.removeAll(keepingCapacity: false)
		spellingConfirmations.removeAll(keepingCapacity: false)
		unigramTotal = 0
		recentLearnEvents.removeAll(keepingCapacity: false)
		modelEpoch = epoch
	}
}
