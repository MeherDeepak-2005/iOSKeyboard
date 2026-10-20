import Foundation
let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
if args.count > 3 && args[2] == "--memory" {
    let report = try NativePerformanceHarness.memoryRun(url: url, backend: args[3])
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
} else {
    let report: [String: Any]
    if args[2] == "--initialization" {
        report = try NativePerformanceHarness.runInitialization(url: url, iterations: 51,
            environment: "optimized macOS CLI; isolated initialization benchmark; not physical iPhone")
    } else {
        report = try NativePerformanceHarness.run(url: url, iterations: 51,
            environment: "optimized macOS CLI; matched input; not physical iPhone", mappedSeeds: args[2] == "--mapped")
    }
    let output = args[2].hasPrefix("--") ? args[3] : args[2]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
}
