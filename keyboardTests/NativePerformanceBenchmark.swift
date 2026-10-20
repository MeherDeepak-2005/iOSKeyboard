import Foundation
#if !KB_BENCHMARK_CLI
import Testing
@testable import keyboard
#endif

/// Isolated optimized kernel benchmark. No shadow execution in timed operations.
/// Session setup/preparation is outside the timer except in the explicit init case.
nonisolated enum NativePerformanceHarness {
    static func seeds(_ url: URL) throws -> [IncrementalLexiconSeed] {
        guard let data = LangData(url: url, backend: .swiftReference), let seeds = data.incrementalSeeds(
            typedFirst: UInt8(ascii: "c"), firstTap: nil) else {
            throw NSError(domain: "NativeBenchmark", code: 1)
        }
        return seeds
    }
    static func native(_ seeds: [IncrementalLexiconSeed], prepared: KBIncrementalSeedSet? = nil) throws -> KBIncrementalSearch {
        if let prepared { return try KBIncrementalSearch(seedSet: prepared) }
        return try KBIncrementalSearch(words: seeds.map(\.word), spellings: seeds.map { Data($0.bytes) },
            logFrequencies: seeds.map { NSNumber(value: $0.logFreq) })
    }
    static func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[Int((Double(sorted.count - 1) * p).rounded(.up))]
    }
    static func elapsed(_ operation: () throws -> Int) rethrows -> (Double, Int) {
        let start = ProcessInfo.processInfo.systemUptime
        let count = try operation()
        return ((ProcessInfo.processInfo.systemUptime - start) * 1_000, count)
    }
    @inline(never) static func consume(_ evidence: [Candidate]) -> Int {
        var checksum = evidence.count
        for candidate in evidence {
            checksum &+= candidate.word.utf8.count + Int(candidate.cost * 1_000) + Int(candidate.logFreq * 100)
        }
        return checksum
    }
    static func requireParity(_ swift: [Candidate], _ cpp: [KBChannelCandidate]) throws {
        guard swift.count == cpp.count else { throw NSError(domain: "NativeBenchmark.coverage", code: 2) }
        for i in swift.indices {
            guard swift[i].word == cpp[i].word,
                  NativeDecoderParity.equal(swift[i].cost, cpp[i].cost),
                  NativeDecoderParity.equal(swift[i].logFreq, cpp[i].logFrequency) else {
                throw NSError(domain: "NativeBenchmark.evidence", code: 3)
            }
        }
    }
    static func run(url: URL, iterations: Int, environment: String, mappedSeeds: Bool = false) throws -> [String: Any] {
        let seeds = try seeds(url)
        let prepared: KBIncrementalSeedSet?
        if mappedSeeds {
            guard let data = LangData(url: url, compareNativeReads: true),
                  let set = try data.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil) else {
                throw NSError(domain: "NativeBenchmark.mappedSeeds", code: 4)
            }
            prepared = set
        } else { prepared = nil }
        var rows: [[String: Any]] = []
        var checksum = 0
        // Alternate backend order on every sample, warm up three samples per case.
        // The bridge path includes native evidence -> Swift Candidate conversion.
        for name in ["session_init", "session_init_decode_and_candidates", "append_one", "append_one_with_taps", "candidates_only",
                     "fresh_word_and_candidates", "backspace_rebuild_and_candidates"] {
            var times = [[Double](), [Double]()]
            for sample in 0..<(iterations + 3) {
                try autoreleasepool {
                    let swift = IncrementalDecodeSession(seeds: seeds, backend: .swiftReference)
                    let cpp = try native(seeds, prepared: prepared)
                    let before = name == "backspace_rebuild_and_candidates" || name == "candidates_only"
                        ? "coeevitjkn" : "coeevitjk"
                    if !name.hasPrefix("session_init") && name != "fresh_word_and_candidates" {
                        _ = swift.advance(to: before)
                        _ = try cpp.advanceNormalizedWord(before, tapOffsets: nil, tapValidity: nil)
                    }
                    let word = name == "backspace_rebuild_and_candidates" ? "coeevitjk" : "coeevitjkn"
                    let taps: [KeyTap?]? = name == "append_one_with_taps"
                        ? word.utf8.enumerated().map { $0.offset == word.utf8.count - 1 ? KeyTap(dx: 0.18, dy: -0.1) : nil } : nil
                    var createdSwift: IncrementalDecodeSession?
                    var createdNative: KBIncrementalSearch?
                    for backend in sample % 2 == 0 ? [0, 1] : [1, 0] {
                        let timing = try elapsed {
                            if name.hasPrefix("session_init") {
                                if backend == 0 {
                                    createdSwift = IncrementalDecodeSession(seeds: seeds, backend: .swiftReference)
                                    if name == "session_init" { return createdSwift!.seedCount }
                                    _ = createdSwift!.advance(to: word, taps: nil)
                                    return consume(createdSwift!.candidates(maxCost: 7.2))
                                }
                                createdNative = try native(seeds, prepared: prepared)
                                if name == "session_init" { return Int(createdNative!.seedCount) }
                                _ = try createdNative!.advanceNormalizedWord(word.lowercased(), tapOffsets: nil, tapValidity: nil)
                                return consume(try createdNative!.candidates(withMaxCost: 7.2).map {
                                    Candidate(word: $0.word, cost: $0.cost, logFreq: $0.logFrequency)
                                })
                            }
                            if name != "candidates_only" {
                                if backend == 0 { _ = swift.advance(to: word, taps: taps) }
                                else {
                                    let normalized = word.lowercased()
                                    let buffers = NativeTapBuffers(taps: taps, expectedCount: normalized.utf8.count)
                                    _ = try cpp.advanceNormalizedWord(normalized, tapOffsets: buffers?.offsets, tapValidity: buffers?.validity)
                                }
                            }
                            if name.hasPrefix("append_one") { return backend == 0 ? swift.typed.count : cpp.typed.utf8.count }
                            if backend == 0 { return consume(swift.candidates(maxCost: 7.2)) }
                            // Model the existing Swift public boundary, not just C++ computation.
                            let evidence = try cpp.candidates(withMaxCost: 7.2).map {
                                Candidate(word: $0.word, cost: $0.cost, logFreq: $0.logFrequency)
                            }
                            return consume(evidence)
                        }
                        checksum &+= timing.1
                        if sample >= 3 { times[backend].append(timing.0) }
                    }
                    if name.hasPrefix("session_init") {
                        if name == "session_init" {
                            _ = createdSwift!.advance(to: "c")
                            _ = try createdNative!.advanceNormalizedWord("c", tapOffsets: nil, tapValidity: nil)
                        }
                        try requireParity(createdSwift!.candidates(maxCost: 7.2), createdNative!.candidates(withMaxCost: 7.2))
                    }
                    if !name.hasPrefix("session_init") { try requireParity(swift.candidates(maxCost: 7.2), cpp.candidates(withMaxCost: 7.2)) }
                }
            }
            let s50 = percentile(times[0], 0.5), c50 = percentile(times[1], 0.5)
            rows.append(["case": name, "swift_p50_ms": s50, "native_bridge_p50_ms": c50,
                         "swift_p95_ms": percentile(times[0], 0.95), "native_bridge_p95_ms": percentile(times[1], 0.95),
                         "median_speedup": s50 / c50, "samples_per_backend": iterations])
        }
        let cells = seeds.reduce(0) { $0 + $1.bytes.count + 1 }
        return ["environment": environment, "optimization": "Swift -O; C++ optimized; no shadow execution",
                "native_seed_source": mappedSeeds ? "shared mapped native seed set" : "boxed Swift seeds copied through bridge",
                "seed_count": seeds.count, "dp_cells": cells, "three_double_buffers_bytes_each_backend": cells * 3 * 8,
                "rows": rows, "checksum": checksum,
                "scope": "retained English DP kernels with bridge; not whole decoder, NSS, neural inference or physical-device metrics"]
    }
    static func memoryRun(url: URL, backend: String) throws -> [String: Any] {
        if backend == "native_mapped" {
            guard let data = LangData(url: url, compareNativeReads: true),
                  let set = try data.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil) else {
                throw NSError(domain: "NativeBenchmark.mappedSeeds", code: 4)
            }
            let session = try KBIncrementalSearch(seedSet: set)
            _ = try session.advanceNormalizedWord("coeevitjkn", tapOffsets: nil, tapValidity: nil)
            let count = try session.candidates(withMaxCost: 7.2).count
            withExtendedLifetime((data, set, session)) {}
            return ["backend": backend, "seeds": set.seedCount, "dp_cells": set.cellCount, "candidate_count": count]
        }
        guard let data = LangData(url: url, backend: .swiftReference), var seeds = data.incrementalSeeds(
            typedFirst: UInt8(ascii: "c"), firstTap: nil) else {
            throw NSError(domain: "NativeBenchmark.memorySetup", code: 6)
        }
        let count = seeds.count, cells = seeds.reduce(0) { $0 + $1.bytes.count + 1 }
        let candidates: Int
        if backend == "swift" {
            let session = IncrementalDecodeSession(seeds: seeds, backend: .swiftReference)
            seeds.removeAll()
            _ = session.advance(to: "coeevitjkn")
            candidates = session.candidates(maxCost: 7.2).count
            withExtendedLifetime((data, session)) {}
        } else {
            let session = try native(seeds)
            seeds.removeAll()
            _ = try session.advanceNormalizedWord("coeevitjkn", tapOffsets: nil, tapValidity: nil)
            candidates = try session.candidates(withMaxCost: 7.2).count
            withExtendedLifetime((data, session)) {}
        }
        return ["backend": backend, "seeds": count, "dp_cells": cells, "candidate_count": candidates]
    }

    static func runInitialization(url: URL, iterations: Int, environment: String) throws -> [String: Any] {
        guard let data = LangData(url: url, compareNativeReads: true),
              let preparedSwift = data.incrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil),
              let preparedNative = try data.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil) else {
            throw NSError(domain: "NativeBenchmark.setup", code: 5)
        }
        var rows: [[String: Any]] = [], checksum = 0
        for name in ["seed_preparation", "prepared_session_init", "seed_selection_and_session_init",
                     "seed_selection_init_decode_and_candidates", "resource_open_and_validation"] {
            let backends = name == "seed_preparation" || name == "resource_open_and_validation"
                ? ["swift", "native_mapped"] : ["swift", "native_boxed", "native_mapped"]
            var samples = Dictionary(uniqueKeysWithValues: backends.map { ($0, [Double]()) })
            for sample in 0..<(iterations + 3) {
                for backend in sample % 2 == 0 ? backends : Array(backends.reversed()) {
                    try autoreleasepool {
                        // Hold every timed result until after the clock stops. Destruction
                        // and parity are outside timings for all three backends.
                        var swiftSeeds: [IncrementalLexiconSeed]?, nativeSeeds: KBIncrementalSeedSet?
                        var swiftSession: IncrementalDecodeSession?, nativeSession: KBIncrementalSearch?
                        var swiftResource: LangData?, nativeResource: KBPackedLexicon?
                        let timing = try elapsed {
                            if name == "resource_open_and_validation" {
                                if backend == "swift" {
                                    swiftResource = LangData(url: url, backend: .swiftReference)
                                    return swiftResource!.wordCount
                                }
                                let backing = try NSData(contentsOf: url, options: .alwaysMapped)
                                nativeResource = try KBPackedLexicon(backing: backing)
                                return Int(nativeResource!.wordCount)
                            }
                            if name == "seed_preparation" {
                                if backend == "swift" {
                                    swiftSeeds = data.incrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil)!
                                    return swiftSeeds!.count
                                }
                                nativeSeeds = try data.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil)!
                                return Int(nativeSeeds!.seedCount)
                            }
                            if backend == "native_mapped" {
                                nativeSeeds = name == "prepared_session_init" ? preparedNative
                                    : try data.nativeIncrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil)!
                                nativeSession = try KBIncrementalSearch(seedSet: nativeSeeds!)
                            } else {
                                swiftSeeds = name == "prepared_session_init" ? preparedSwift
                                    : data.incrementalSeeds(typedFirst: UInt8(ascii: "c"), firstTap: nil)!
                                if backend == "swift" { swiftSession = IncrementalDecodeSession(seeds: swiftSeeds!, backend: .swiftReference) }
                                else { nativeSession = try native(swiftSeeds!) }
                            }
                            if name == "seed_selection_init_decode_and_candidates" {
                                if let session = swiftSession {
                                    _ = session.advance(to: "coeevitjkn")
                                    return consume(session.candidates(maxCost: 7.2))
                                }
                                _ = try nativeSession!.advanceNormalizedWord("coeevitjkn", tapOffsets: nil, tapValidity: nil)
                                return consume(try nativeSession!.candidates(withMaxCost: 7.2).map {
                                    Candidate(word: $0.word, cost: $0.cost, logFreq: $0.logFrequency)
                                })
                            }
                            return swiftSession?.seedCount ?? Int(nativeSession!.seedCount)
                        }
                        checksum &+= timing.1
                        if sample >= 3 { samples[backend]!.append(timing.0) }
                        if let nativeSession {
                            let reference = IncrementalDecodeSession(seeds: preparedSwift, backend: .swiftReference)
                            _ = reference.advance(to: "coeevitjkn")
                            _ = try nativeSession.advanceNormalizedWord("coeevitjkn", tapOffsets: nil, tapValidity: nil)
                            try requireParity(reference.candidates(maxCost: 7.2), nativeSession.candidates(withMaxCost: 7.2))
                        }
                        withExtendedLifetime((swiftSeeds, nativeSeeds, swiftSession, nativeSession, swiftResource, nativeResource)) {}
                    }
                }
            }
            var row: [String: Any] = ["case": name, "samples_per_backend": iterations]
            for backend in backends {
                row[backend + "_p50_ms"] = percentile(samples[backend]!, 0.5)
                row[backend + "_p95_ms"] = percentile(samples[backend]!, 0.95)
            }
            rows.append(row)
        }
        return ["environment": environment, "seed_count": preparedSwift.count, "rows": rows, "checksum": checksum,
                "scope": "warm filesystem mapping/validation reported separately; seed preparation and creation included where named; no neural scorer or physical iPhone"]
    }
}

#if !KB_BENCHMARK_CLI
struct NativePerformanceBenchmark {
    @Test func isolatedReleaseKernelBenchmark() throws {
        let config = URL(fileURLWithPath: "/tmp/ioskeyboard-native-perf-config.json")
        guard FileManager.default.fileExists(atPath: config.path) else { return }
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let report = try NativePerformanceHarness.run(url: root.appendingPathComponent("keyboard/langdata.bin"),
            iterations: settings["iterations"] as? Int ?? 51,
            environment: "Release iOS simulator on Mac; isolated benchmark; not physical iPhone",
            mappedSeeds: settings["mapped_seeds"] as? Bool ?? false)
        let output = settings["output"] as! String
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
        print("NATIVE_PERFORMANCE " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        if let output = settings["initialization_output"] as? String {
            let initialization = try NativePerformanceHarness.runInitialization(url: root.appendingPathComponent("keyboard/langdata.bin"),
                iterations: settings["iterations"] as? Int ?? 51,
                environment: "Release iOS simulator on Mac; isolated initialization benchmark; not physical iPhone")
            try JSONSerialization.data(withJSONObject: initialization, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
            print("NATIVE_INITIALIZATION " + String(decoding: try JSONSerialization.data(withJSONObject: initialization, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
#endif
