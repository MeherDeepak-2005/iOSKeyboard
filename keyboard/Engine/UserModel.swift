import Foundation

/// Platform persistence and synchronization. All live count/learning/undo/keep
/// policy is owned by the shared native Personalization object.
final class UserModel {
    private let storageURLOverride: URL?
    private let state = KBPersonalState()
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "keyboard.usermodel.io", qos: .utility)
    private var nativeCountsCache: KBPersonalCounts?
    private static let maxUnigrams = 4000, maxContexts = 2000
    init(storageURL: URL? = nil) { storageURLOverride = storageURL }
    private func locked<T>(_ operation: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return operation() }
    private func ensureEpoch() {
        let epoch = KBPersonalData.currentEpoch
        if state.epoch != epoch { state.reset(epoch); nativeCountsCache = nil }
    }
    func nativeCountsSnapshot() -> KBPersonalCounts {
        locked { if let nativeCountsCache { return nativeCountsCache }; let value = state.snapshot(); nativeCountsCache = value; return value }
    }
    func uniCount(_ word: String) -> Int { locked { state.count(word) } }
    func biLookup(_ previous: String, _ word: String) -> (count: Int, total: Int) {
        locked { let row = state.bigrams[previous] ?? [:]; return (row[word]?.intValue ?? 0, row.values.reduce(0) { $0 + $1.intValue }) }
    }
    func triLookup(_ context: String, _ word: String) -> (count: Int, total: Int) {
        locked { let row = state.trigrams[context] ?? [:]; return (row[word]?.intValue ?? 0, row.values.reduce(0) { $0 + $1.intValue }) }
    }
    func biDist(_ previous: String) -> [String: Int] { locked { (state.bigrams[previous] ?? [:]).mapValues(\.intValue) } }
    func triDist(_ context: String) -> [String: Int] { locked { (state.trigrams[context] ?? [:]).mapValues(\.intValue) } }
    func unigramsSnapshot() -> [String: Int] { locked { state.unigrams.mapValues(\.intValue) } }
    func isKept(_ word: String) -> Bool { locked { state.kept(word) } }
    func releaseKeep(_ word: String) { locked { state.releaseKeep(word) } }
    func allowsAdoption(_ word: String, count: Int, lexicon: KBGenerationLexicon) -> Bool { locked { state.allowsAdoption(word, count: count, lexicon: lexicon) } }
    func confirmSpelling(_ word: String) { locked { ensureEpoch(); state.confirm(word) } }
    // Drop the cached snapshot BEFORE mutating: while it is held, native copy-on-write
    // must deep-copy the whole personal model on every learning event.
    @discardableResult func pruneIfNeeded() -> Bool { locked { nativeCountsCache = nil; return state.prune() } }
    func learn(context: [String], word: String) { locked { ensureEpoch(); nativeCountsCache = nil; state.learn(word, context: context) } }
    func demote(_ word: String) { locked { let priorEpoch = state.epoch; ensureEpoch(); nativeCountsCache = nil; if priorEpoch == state.epoch { state.demote(word) } } }

    private func storeURL(for epoch: UInt64) -> URL? { storageURLOverride ?? KBPersonalData.modelURL(for: epoch) }
    private var legacyStoreURL: URL? { storageURLOverride == nil ? KBPersonalData.legacyModelURL : nil }
    private struct Snapshot: Codable {
        var version: Int?; var epoch: UInt64?
        var tri: [String: [String: Int]]; var bi: [String: [String: Int]]
        var uni: [String: Int]; var confirmed: [String: Int]?
    }
    private enum StoreError: Error { case invalidShape }
    func load() {
        let current = KBPersonalData.currentEpoch
        guard let primary = storeURL(for: current) else { KBDiagnostics.recorder.storageFailure(operation: "personal-container-unavailable"); reset(to: current); return }
        let legacy = legacyStoreURL
        let source = FileManager.default.fileExists(atPath: primary.path) ? primary : legacy.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard let source else { reset(to: current); return }
        do {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            guard data.count <= 4_000_000 else { throw StoreError.invalidShape }
            let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
            guard (decoded.version ?? 1) <= 2, (decoded.epoch ?? current) == current,
                  decoded.uni.count <= Self.maxUnigrams * 2, decoded.bi.count <= Self.maxContexts * 2,
                  decoded.tri.count <= Self.maxContexts * 2 else { throw StoreError.invalidShape }
            install(decoded, current: current, migratedLegacy: source == legacy)
        } catch {
            KBPersonalData.withExclusiveStoreLock { try? FileManager.default.removeItem(at: source) }
            KBDiagnostics.recorder.storageFailure(operation: "personal-model-read"); reset(to: current)
        }
    }
    private func valid(_ word: String) -> Bool { !word.isEmpty && word.count <= 64 && word.allSatisfy { $0.isLetter || $0 == "'" } }
    private func sanitize(_ table: [String: [String: Int]]) -> [String: [String: Int]] {
        var out: [String: [String: Int]] = [:]
        for (context, words) in table where context.count <= 130 {
            let row = words.filter { valid($0.key) && $0.value > 0 }; if !row.isEmpty { out[context] = row }
        }
        return out
    }
    private func install(_ snapshot: Snapshot, current: UInt64, migratedLegacy: Bool) {
        let bi = sanitize(snapshot.bi), tri = sanitize(snapshot.tri)
        let counts = KBPersonalCounts(unigrams: snapshot.uni.filter { valid($0.key) && $0.value > 0 }.mapValues { NSNumber(value: $0) },
            bigramWords: bi.mapValues { Array($0.keys) }, bigramCounts: bi.mapValues { $0.values.map { NSNumber(value: $0) } },
            trigramWords: tri.mapValues { Array($0.keys) }, trigramCounts: tri.mapValues { $0.values.map { NSNumber(value: $0) } })
        let changed: Bool = locked {
            nativeCountsCache = nil
            state.install(counts, confirmed: (snapshot.confirmed ?? [:]).filter { valid($0.key) && $0.value > 0 }.mapValues { NSNumber(value: $0) }, epoch: current)
            return state.prune()
        }
        if changed || migratedLegacy { save() }
    }
    func save() {
        let snapshot: Snapshot = locked { Snapshot(version: 2, epoch: state.epoch,
            tri: state.trigrams.mapValues { $0.mapValues(\.intValue) }, bi: state.bigrams.mapValues { $0.mapValues(\.intValue) },
            uni: state.unigrams.mapValues(\.intValue), confirmed: state.confirmed.mapValues(\.intValue)) }
        let epoch = snapshot.epoch!
        guard let url = storeURL(for: epoch) else { KBDiagnostics.recorder.storageFailure(operation: "personal-container-unavailable"); return }
        ioQueue.async {
            let data: Data
            do { data = try JSONEncoder().encode(snapshot) } catch { KBDiagnostics.recorder.storageFailure(operation: "personal-model-encode"); return }
            KBPersonalData.withExclusiveStoreLock {
                guard KBPersonalData.currentEpoch == epoch else { return }
                do { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                catch { KBDiagnostics.recorder.storageFailure(operation: "personal-model-write") }
            }
        }
    }
    func reset(to epoch: UInt64 = KBPersonalData.currentEpoch) { locked { state.reset(epoch); nativeCountsCache = nil } }
    func waitForPendingIO() { ioQueue.sync {} }
}
