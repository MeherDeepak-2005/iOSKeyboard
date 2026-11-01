import Foundation
import Darwin

/// Local research data, separate from aggregate diagnostics. No network transport.
/// Commit events are observations, NEVER supervised labels by themselves.
enum KBTypingRecorder {
    struct Candidate: Codable {
        var word: String
        var score: Double?
        var spatialCost: Double?
        var logLanguageProbability: Double?
        var neuralLogProbability: Double?
        var typedWordMargin: Double?
        var source: String
    }
    /// One letter of a word as it was typed: the key, its landing offset in key widths, and
    /// the gap to the previous key. Erased letters are removed, so a committed word's
    /// keystrokes line up with its typed literal.
    struct Keystroke: Codable {
        var key: String
        var dx: Double?
        var dy: Double?
        var intervalMs: Double?
    }
    /// Schema 2 adds typing speed and per-key evidence (see docs/typing-recorder.md):
    /// `intervalMs` on keys, `typed`/`keystrokes`/`durationMs`/`backspaces` on commits,
    /// and `key-fix` events (a letter erased and retyped inside its word).
    struct Event: Codable {
        var schema = 2
        var id = UUID().uuidString
        var time = Date()
        var uptime: Double
        var process: String
        var session: UInt64
        var word: UInt64
        var relatedWord: UInt64?
        var layout: UInt64
        var kind: String
        var text: String?
        var replacement: String?
        var evidence: String?
        var candidates: [String]?
        var dx: Double?
        var dy: Double?
        var touchID: String?
        var intervalMs: Double?
        var typed: String?
        var keystrokes: [Keystroke]?
        var durationMs: Double?
        var backspaces: Int?
        var confidence: Double?
        var candidateEvidence: [Candidate]?
        var model: String
        var requestedModel: String?
        var language: String
        var build: String
    }
    private static let queue = DispatchQueue(label: "keyboard.typing-records", qos: .utility)
    private static let admission = NSLock()
    private static var pending = 0
    private static var buffer: [(Event, String, UInt64)] = [] // queue-owned
    private static var scheduled = false
    private static let maxBytes = 5 * 1_024 * 1_024 // two generations, at most 10 MiB
    private static let enabledKey = "kb.typing.capture"
    private static let generationKey = "kb.typing.generation"
    static let processID = UUID().uuidString
    static var enabled: Bool { KBSettings.sharedDefaults.bool(forKey: enabledKey) }
    private static var generation: String { KBSettings.sharedDefaults.string(forKey: generationKey) ?? "initial" }
    private static var directory: URL? { KBPersonalData.containerURL?.appendingPathComponent("typing-recordings", isDirectory: true) }
    private enum Failure: Error { case unavailable, lock, disabled }

    /// File lock is fail-closed: reset/export/writes never proceed without serialization.
    private static func locked<T>(_ body: () throws -> T) throws -> T {
        guard let root = KBPersonalData.containerURL else { throw Failure.unavailable }
        let fd = open(root.appendingPathComponent(".typing-recordings.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.lock }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure.lock }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static func setEnabled(_ value: Bool) {
        do {
            try locked {
                KBSettings.sharedDefaults.set(UUID().uuidString, forKey: generationKey)
                KBSettings.sharedDefaults.set(value, forKey: enabledKey)
            }
        } catch { KBDiagnostics.noteIntegrityEvent("capture-control-failed") }
    }

    static func record(_ event: Event) {
        let token = generation, epoch = KBPersonalData.currentEpoch
        guard enabled else { return }
        guard event.uptime.isFinite, (event.dx?.isFinite ?? true), (event.dy?.isFinite ?? true),
              (event.intervalMs?.isFinite ?? true), (event.durationMs?.isFinite ?? true),
              (event.text?.count ?? 0) <= 64, (event.replacement?.count ?? 0) <= 64,
              (event.typed?.count ?? 0) <= 64, (event.keystrokes?.count ?? 0) <= 64,
              (event.candidates?.count ?? 0) <= 3,
              event.candidates?.allSatisfy({ $0.count <= 64 }) != false else {
            KBDiagnostics.noteIntegrityEvent("capture-invalid-event-drop")
            return
        }
        admission.lock()
        guard pending < 512 else {
            admission.unlock()
            KBDiagnostics.noteIntegrityEvent("capture-backpressure-drop")
            return
        }
        pending += 1
        admission.unlock()
        queue.async {
            buffer.append((event, token, epoch))
            if buffer.count >= 32 { writeBuffer() }
            if !scheduled {
                scheduled = true
                queue.asyncAfter(deadline: .now() + 0.5) {
                    scheduled = false
                    writeBuffer()
                }
            }
        }
    }

    static func flush() { queue.async { writeBuffer() } }

    private static func writeBuffer() {
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        defer {
            admission.lock(); pending -= batch.count; admission.unlock()
        }
        do {
            try locked {
                guard enabled, let dir = directory else { return }
                let token = generation, epoch = KBPersonalData.currentEpoch
                var data = Data()
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                for (event, capturedToken, capturedEpoch) in batch where capturedToken == token && capturedEpoch == epoch {
                    data.append(try encoder.encode(event)); data.append(0x0A)
                }
                guard !data.isEmpty else { return }
                try prepareDirectory(dir)
                try pruneExpired(dir)
                let current = dir.appendingPathComponent("current.jsonl")
                let previous = dir.appendingPathComponent("previous.jsonl")
                let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size + data.count > maxBytes {
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    if FileManager.default.fileExists(atPath: current.path) { try FileManager.default.moveItem(at: current, to: previous) }
                }
                if !FileManager.default.fileExists(atPath: current.path) {
                    try data.write(to: current, options: protectedWriteOptions)
                } else {
                    let handle = try FileHandle(forWritingTo: current)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: data)
                }
            }
        } catch { KBDiagnostics.noteIntegrityEvent("capture-write-failed") }
    }

    private static var protectedWriteOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtection]
        #else
        return [.atomic]
        #endif
    }
    private static func prepareDirectory(_ url: URL) throws {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private static func pruneExpired(_ dir: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) {
            if let created = try url.resourceValues(forKeys: [.creationDateKey]).creationDate,
               Date().timeIntervalSince(created) > 7 * 86_400 {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Invalidates queued events before deletion. Removing records also stops collection.
    @discardableResult static func clear() -> Bool {
        do {
            try locked {
                KBSettings.sharedDefaults.set(false, forKey: enabledKey)
                KBSettings.sharedDefaults.set(UUID().uuidString, forKey: generationKey)
                if let dir = directory, FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.removeItem(at: dir)
                }
            }
            return true
        } catch {
            KBDiagnostics.noteIntegrityEvent("capture-delete-failed")
            return false
        }
    }

    /// Produces a snapshot separate from the live recording; sharing it requires an explicit ShareLink action.
    static func export(completion: @escaping (URL?) -> Void) {
        queue.async {
            writeBuffer()
            let output: URL?
            do {
                output = try locked {
                    guard let dir = directory else { throw Failure.unavailable }
                    try prepareDirectory(dir)
                    try pruneExpired(dir)
                    var data = Data()
                    for name in ["previous.jsonl", "current.jsonl"] {
                        let url = dir.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: url.path) { data.append(try Data(contentsOf: url)) }
                    }
                    guard !data.isEmpty else { return nil }
                    let url = dir.appendingPathComponent("export.jsonl")
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                    return url
                }
            } catch {
                KBDiagnostics.noteIntegrityEvent("capture-export-failed")
                output = nil
            }
            DispatchQueue.main.async { completion(output) }
        }
    }
}
