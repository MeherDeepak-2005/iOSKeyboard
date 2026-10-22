import Foundation
import Testing
@testable import keyboard

nonisolated private final class CorrectionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CorrectionGateEvidence?
    func put(_ value: CorrectionGateEvidence?) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> CorrectionGateEvidence? { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
struct CorrectionCalibrationTests {
    @Test func smoothingExperimentsMatchNativeAndReferenceFormulas() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let lexicon = Lexicon()
        lexicon.load(from: root.appendingPathComponent("keyboard/langdata.bin"))
        let data = try #require(lexicon.languageDataSnapshot())
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("smoothing-parity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storage) }
        let user = UserModel(storageURL: storage)
        #expect(NgramScorer(user: user).smoothing == .wittenBell)
        let words = ["correction", "coercion", "coeevitjkn", "the", "can't"]
        let totalFrequency = (0..<data.wordCount).reduce(Double(data.wordCount)) { $0 + Double(data.freq($1)) }
        for smoothing in NgramSmoothing.allCases {
            let native = NgramScorer(user: user, smoothing: smoothing)
            let reference = NgramScorer(user: user, backend: .swiftReference, smoothing: smoothing)
            for scorer in [native, reference] {
                scorer.attach(data: data, resolveID: { lexicon.wordID($0) }, lexicon: lexicon)
            }
            for context in [[], ["possibly"], ["possibly", "receive"], ["definitely", "decided"]] {
                let actual = native.logProbs(words, context: context)
                let expected = reference.logProbs(words, context: context)
                for i in words.indices {
                    #expect(abs(actual[i] - expected[i]) < 1e-12)
                    if smoothing == .modifiedKneserNey { continue }
                    let id = lexicon.wordID(words[i])
                    var probability = (id.map { Double(data.freq(Int($0))) + 1 } ?? 0.5)
                        / (totalFrequency + (smoothing == .frequencyBackoff ? 0.5 : 0))
                    var hits: [(total: Int, entries: [(word: Int32, count: Int)])] = []
                    if let last = context.last.flatMap({ lexicon.wordID($0) }), let hit = data.bigrams(after: last) { hits.append(hit) }
                    if context.count >= 2, let a = lexicon.wordID(context[context.count - 2]),
                       let b = lexicon.wordID(context.last!), let hit = data.trigrams(after: a, b) { hits.append(hit) }
                    for hit in hits where hit.total > 0 && !hit.entries.isEmpty {
                        let count = Double(hit.entries.first { $0.word == id }?.count ?? 0)
                        let t = Double(hit.entries.count)
                        if smoothing == .wittenBell {
                            let n = Double(hit.total), weight = n / (n + t) * n / (n + 8)
                            // Unretained (pruned) context mass backs off rather than vanishing.
                            let retained = Double(min(hit.entries.reduce(0) { $0 + $1.count }, hit.total))
                            probability = weight * count / n + (n - weight * retained) / n * probability
                        } else {
                            let n = hit.entries.reduce(0.0) { $0 + Double($1.count) }
                            probability = (count + (t + 8) * probability) / (n + t + 8)
                        }
                    }
                    #expect(abs(actual[i] - log(probability)) < 1e-12)
                }
                #expect(native.nativeScoringFailure == nil)
            }
        }
    }

    @Test func candidateGapCannotBypassTypedOrSpatialGuards() {
        let policy = CorrectionPolicy(oovMargin: 3, realWordMargin: 5,
            closeRescueMargin: 1.5, closeRescueGap: 2, minimumCloseGap: 0)
        func gate(_ margin: Double, _ gap: Double?, allow: Bool = true,
                  kind: CorrectionGateEvidence.Kind = .close) -> CorrectionGateEvidence {
            CorrectionGateEvidence(typed: "typo", candidate: "type", kind: kind,
                typedMargin: margin, candidateGap: gap, spatialCost: 0.8, allowsCloseRescue: allow)
        }
        #expect(policy.accepts(gate(2, 3)))
        #expect(!policy.accepts(gate(2, 1)))
        #expect(!policy.accepts(gate(1, 8)))
        #expect(!policy.accepts(gate(2, 3, allow: false)))
        #expect(!policy.accepts(gate(2, 3, kind: .loose)))
        #expect(!policy.accepts(gate(4, 8, kind: .realWord)))
        #expect(policy.accepts(gate(6, nil, kind: .realWord)))
        #expect(CorrectionPolicy.baseline.accepts(gate(4, 0)))
        #expect(!CorrectionPolicy.baseline.accepts(gate(3, 10)))
        let cautious = CorrectionPolicy(oovMargin: 3, realWordMargin: 5,
            closeRescueMargin: 1.5, closeRescueGap: 2, minimumCloseGap: 0.5)
        #expect(!cautious.accepts(gate(8, 0.2)))
    }

    @Test func calibratedPolicyPreservesAmbiguousAndDistantInput() {
        let policy = CorrectionPolicy.calibrated
        func gate(margin: Double = 1, gap: Double? = 1, cost: Double = 0.8,
                  allows: Bool = true) -> CorrectionGateEvidence {
            CorrectionGateEvidence(typed: "typo", candidate: "type", kind: .close,
                typedMargin: margin, candidateGap: gap, spatialCost: cost, allowsCloseRescue: allows)
        }
        #expect(policy.accepts(gate()))
        #expect(policy.accepts(gate(gap: 0.5, cost: 1.2)))
        #expect(!policy.accepts(gate(margin: 0)))
        #expect(!policy.accepts(gate(gap: 0.49)))
        #expect(!policy.accepts(gate(cost: 1.21)))
        #expect(!policy.accepts(gate(allows: false)))
        #expect(!policy.accepts(gate(margin: 8, gap: 0.24)))
        #expect(policy.accepts(gate(margin: 8, gap: 0.25, cost: 2.8, allows: false)))
    }

    /// Audit attribution without weakening the existing severe-recovery goldens.
    @Test func severeRecoveryBaselineAndCalibratedPoliciesAreCompared() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let contexts = [[], ["possibly", "receive"], ["for", "definitely", "decided"],
                        ["could", "definitely", "receive"]]
        var baseline: [DecodeSnapshot] = []
        var rows: [[String: Any]] = []
        for (label, policy) in [("baseline", CorrectionPolicy.baseline),
                                ("calibrated", CorrectionPolicy.calibrated)] {
            let storage = FileManager.default.temporaryDirectory.appendingPathComponent("severe-audit-\(UUID().uuidString).json")
            let engine = KeyboardEngine(languageDataURL: root.appendingPathComponent("keyboard/langdata.bin"),
                correctionPolicy: policy, userModel: UserModel(storageURL: storage),
                smoothing: .modifiedKneserNey)
            for (index, context) in contexts.enumerated() {
                let request = DecodeRequest(fieldRevision: 1, documentRevision: UInt64(index + 1),
                    wordSessionID: UInt64(index + 1), generation: UInt64(index + 1), layoutRevision: 1,
                    currentWord: "coeevitjkn", context: context, taps: nil)
                let snapshot: DecodeSnapshot = await withCheckedContinuation { continuation in
                    engine.decode(request) { continuation.resume(returning: $0) }
                }
                if label == "baseline" { baseline.append(snapshot) }
                else {
                    #expect(snapshot.correction == baseline[index].correction)
                    #expect(snapshot.suggestions == baseline[index].suggestions)
                }
                rows.append(["policy": label, "context": context,
                    "suggestions": snapshot.suggestions,
                    "correction": snapshot.correction as Any? ?? NSNull(),
                    "golden_passes": snapshot.correction == "correction"
                        && snapshot.suggestions.first == "correction",
                    "candidates": snapshot.candidates.map {
                        ["word": $0.word, "spatial_cost": $0.spatialCost,
                         "log_frequency": $0.logFrequency, "ngram_log_probability": $0.logLanguageProbability]
                    }])
            }
            try? FileManager.default.removeItem(at: storage)
        }
        let report: [String: Any] = ["typed": "coeevitjkn", "gold": "correction", "rows": rows,
            "purpose": "Attribute the severe golden failure to MKN ranking rather than correction calibration; existing golden assertions remain unchanged."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("tools/evaluation/results/correction-calibration-2026-10-19/severe-baseline-audit.json"))
    }

    /// Optional offline full-engine replay. The input path is an evaluator fixture;
    /// gold labels never enter DecodeRequest or candidate generation.
    @Test func replayFrozenCalibrationRequests() async throws {
        struct Config: Decodable {
            let dataset: String
            let output: String
            let policy: CorrectionPolicy
            let incrementalEvery: Int?
            let smoothing: NgramSmoothing?
        }
        struct Case: Decodable {
            let id: Int
            let split: String
            let family: String
            let kind: String
            let typed: String
            let intended: String
            let context: [String]
        }
        struct Result: Encodable {
            let id: Int
            let split: String
            let family: String
            let kind: String
            let typed: String
            let intended: String
            let context: [String]
            let choice: String
            let suggestions: [String]
            let gate: CorrectionGateEvidence?
            let milliseconds: Double
            let incremental: Bool
            let candidates: [CandidateScore]
        }
        struct CandidateScore: Encodable {
            let word: String
            let spatialCost: Double
            let logFrequency: Double
            let logLanguageProbability: Double
        }
        let configURL = URL(fileURLWithPath: "/tmp/ioskeyboard-correction-calibration-config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
        let cases = try String(contentsOfFile: config.dataset, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map {
                try JSONDecoder().decode(Case.self, from: Data($0.utf8))
            }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let userURL = FileManager.default.temporaryDirectory.appendingPathComponent("calibration-user-\(UUID().uuidString).json")
        let capture = CorrectionCapture()
        let engine = KeyboardEngine(languageDataURL: root.appendingPathComponent("keyboard/langdata.bin"),
            correctionPolicy: config.policy, userModel: UserModel(storageURL: userURL),
            smoothing: config.smoothing ?? .wittenBell,
            correctionObserver: { capture.put($0) })
        defer { try? FileManager.default.removeItem(at: userURL) }
        let outputURL = URL(fileURLWithPath: config.output)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        var generation: UInt64 = 0
        for (index, item) in cases.enumerated() {
            let incremental = config.incrementalEvery.map { $0 > 0 && item.id % $0 == 0 } ?? false
            let words = incremental ? (1...item.typed.count).map { String(item.typed.prefix($0)) } : [item.typed]
            var last: DecodeSnapshot?
            let start = ProcessInfo.processInfo.systemUptime
            for word in words {
                capture.put(nil)
                generation += 1
                let request = DecodeRequest(fieldRevision: 1, documentRevision: generation,
                    wordSessionID: UInt64(item.id + 1), generation: generation, layoutRevision: 1,
                    currentWord: word, context: item.context, taps: nil, requestedModelTier: .ngram)
                let snapshot: DecodeSnapshot = await withCheckedContinuation { continuation in
                    engine.decode(request) { continuation.resume(returning: $0) }
                }
                #expect(snapshot.isValid(for: request))
                if let correction = snapshot.correction {
                    #expect(snapshot.suggestions.first == correction)
                }
                last = snapshot
            }
            let snapshot = try #require(last)
            let gate = capture.get()
            let choice = snapshot.correction ?? item.typed
            if let gate {
                #expect(choice == (config.policy.accepts(gate) ? gate.candidate : item.typed),
                    "policy/engine mismatch for \(item.id)")
            }
            let result = Result(id: item.id, split: item.split, family: item.family, kind: item.kind,
                typed: item.typed, intended: item.intended, context: item.context, choice: choice,
                suggestions: snapshot.suggestions, gate: gate,
                milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                incremental: incremental, candidates: snapshot.candidates.map {
                    CandidateScore(word: $0.word, spatialCost: $0.spatialCost,
                        logFrequency: $0.logFrequency, logLanguageProbability: $0.logLanguageProbability)
                })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try output.write(contentsOf: encoder.encode(result))
            try output.write(contentsOf: Data([10]))
            if (index + 1) % 250 == 0 { print("CORRECTION_REPLAY \(index + 1)/\(cases.count)") }
        }
        print("CORRECTION_REPLAY_COMPLETE \(cases.count) output=\(config.output)")
    }
}
