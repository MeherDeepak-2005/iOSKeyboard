import Foundation
import Testing
@testable import keyboard

/// Replays the project's severe-typo golden through the actual Swift decoder.
/// Optional trained artifacts are configured outside the checkout. No expected word
/// is injected into candidate generation or neural scores.
@MainActor
struct SevereTypoBenchmark {
    @Test func coeevitjknWithAndWithoutNeuralScorer() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let contexts: [[String]] = [[], ["auto"], ["possibly", "receive"],
            ["for", "definitely", "decided"], ["could", "definitely", "receive"]]
        let configURL = URL(fileURLWithPath: "/tmp/ioskeyboard-severe-benchmark-config.json")
        var configurations: [(String, NeuralLanguagePrior?)] = [("ngram", nil)]
        var neuralStatus = "not_run_missing_trained_model_and_matching_tokenizer"
        if FileManager.default.fileExists(atPath: configURL.path) {
            struct Config: Decodable {
                let kind: String
                let model: String
                let tokenizer: String
                let scoreModel: String?
            }
            let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
            let url = URL(fileURLWithPath: config.model)
            let tokenizer = URL(fileURLWithPath: config.tokenizer)
            try #require(FileManager.default.fileExists(atPath: url.path))
            try #require(FileManager.default.fileExists(atPath: tokenizer.path))
            try #require(!config.model.contains("ioskeyboard-gru-test-fixture"),
                "random plumbing fixture must not be reported as a trained scorer")
            let compiled = url.pathExtension == "mlmodelc"
            let prior: NeuralLanguagePrior
            if config.kind == "gru" {
                prior = GRULanguagePrior(compiledURL: compiled ? url : nil,
                    packageURL: compiled ? nil : url, tokenizerURL: tokenizer,
                    scorePackageURL: config.scoreModel.map { URL(fileURLWithPath: $0) })
            } else {
                try #require(config.kind == "transformer")
                prior = CoreMLNeuralLanguagePrior(compiledURL: compiled ? url : nil,
                    packageURL: compiled ? nil : url, tokenizerURL: tokenizer)
            }
            var waited = 0.0
            while !prior.isReady, waited < 60 {
                try await Task.sleep(nanoseconds: 200_000_000); waited += 0.2
            }
            try #require(prior.isReady, "configured neural model did not become ready")
            configurations.append((config.kind + "_scorer_only", prior))
            neuralStatus = "ran_configured_scorer_without_neural_search_prior"
        }
        var rows: [[String: Any]] = []
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }
        for (mode, prior) in configurations {
            for context in contexts {
                let engine = KeyboardEngine(languageDataURL: root.appendingPathComponent("keyboard/langdata.bin"),
                    rescorer: prior)
                let tier = prior?.modelTier ?? .ngram
                var timings: [Double] = [], snapshots: [DecodeSnapshot] = []
                for repetition in 0...30 {
                    let request = DecodeRequest(fieldRevision: 1, documentRevision: UInt64(repetition + 1),
                        wordSessionID: 1, generation: UInt64(repetition + 1), layoutRevision: 1,
                        currentWord: "coeevitjkn", context: context, taps: nil, requestedModelTier: tier)
                    let start = ProcessInfo.processInfo.systemUptime
                    let snapshot: DecodeSnapshot = await withCheckedContinuation { continuation in
                        engine.decode(request) { continuation.resume(returning: $0) }
                    }
                    timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    snapshots.append(snapshot)
                }
                let last = try #require(snapshots.last)
                let warm = Array(timings.dropFirst())
                let rank = last.candidates.firstIndex { $0.word == "correction" }
                let evidence: [[String: Any]] = last.candidates.map {
                    ["word": $0.word, "score": $0.score, "spatial_cost": $0.spatialCost,
                     "ngram_log_probability": $0.logLanguageProbability,
                     "neural_log_probability": $0.neuralLogProbability.map { $0 as Any } ?? NSNull(),
                     "source": $0.source.rawValue]
                }
                let row: [String: Any] = ["mode": mode, "context": context,
                    "suggestions": last.suggestions, "correction": last.correction as Any? ?? NSNull(),
                    "correction_candidate_rank": rank.map { ($0 + 1) as Any } ?? NSNull(),
                    "correct_commits": snapshots.filter { $0.correction == "correction" }.count,
                    "replays": snapshots.count, "first_decode_ms": timings[0],
                    "warm_p50_ms": percentile(warm, 0.5), "warm_p95_ms": percentile(warm, 0.95),
                    "warm_p99_ms": percentile(warm, 0.99), "candidates": evidence]
                rows.append(row)
                print("SEVERE_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: row,
                    options: [.sortedKeys]), as: UTF8.self))
                if prior == nil {
                    #expect(snapshots.allSatisfy { $0.correction == "correction" })
                    #expect(snapshots.allSatisfy { $0.suggestions.first == "correction" })
                }
                prior?.discardSession(1)
            }
        }
        let report: [String: Any] = ["typed": "coeevitjkn", "intended": "correction",
            "environment": "iOS simulator; no touch offsets; model load excluded; first decode includes queued engine initialization",
            "neural_status": neuralStatus, "rows": rows]
        let destination = root.appendingPathComponent("tools/evaluation/results")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("coeevitjkn-simulator.json"))
    }
}
