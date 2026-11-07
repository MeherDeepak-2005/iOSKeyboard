import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import keyboard

/// Speed and memory of the English engine as the keyboard drives it, with the extension's own
/// bundled dictionary and NSS model: one word session per word, a word-start prediction, one
/// decode per keystroke with tap offsets, then the same word glided twice: through the one-shot
/// API and as a live swipe (previews while the finger moves, the decision at lift). Every call
/// is awaited, so each latency is the full cost of that step. Opt-in (about a minute on a
/// phone): tools/perf/device_perf.sh sets TEST_RUNNER_KB_PERF=1 and parses the `KB_PERF` line.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KB_PERF"] == "1"))
struct EnginePerformanceBenchmark {
	/// Everyday chat and email English with a few typical slips, so decodes exercise corrections.
	static let sentences = [
		"hey are you free for lunch tomorrow or should we move it to friday",
		"i will send you the report as soon as i get back to my desk",
		"thanks for the help yesterday it made a huge difference",
		"can you call me when you get a chance i have a quick question",
		"we are running a little late but should be there in ten minutes",
		"did you see the game last night it was unbelievable",
		"please let me know if the meeting time works for everyone",
		"i think teh new design looks great but the colors need some work",
		"my flight lands at six so i can meet you for dinner after",
		"happy birthday hope you have a wonderful day with your family",
		"the package should arrive by wednesday according to the tracking page",
		"sorry i missed your call i was in a meeting all afternoon",
		"could you recieve the documents i sent this morning",
		"lets grab coffee next week and catch up on everything",
		"i am not sure what time the store closes on sunday",
		"the weather is supposed to be nice this weekend so we could go hiking",
		"remember to bring your laptop charger to the office tomorrow",
		"that sounds like a great plan count me in",
		"we need to finish the presentation before the client call on monday",
		"i just finished reading the book you recommended and loved it",
		"what do you want to do for the holidays this year",
		"the kids are asleep so we can finally watch the movie",
		"i definately want to visit that restaurant again",
		"is there anything else you need from me before the deadline",
		"good morning hope you slept well and are ready for a busy day",
		"my phone battery is almost dead so i might not reply for a while",
		"can we reschedule our appointment to later in the afternoon",
		"thank you so much for the beautiful flowers they made my day",
		"the train was delayed again so i will be working from home",
		"let me check my calendar and get back to you tonight"
	]

	private struct Stats: Encodable {
		let count: Int, mean: Double, p50: Double, p90: Double, p99: Double, max: Double
		init(_ samples: [Double]) {
			let sorted = samples.sorted()
			func at(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded(.up)))] }
			count = sorted.count
			mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
			p50 = at(0.5); p90 = at(0.9); p99 = at(0.99); max = sorted.last ?? 0
		}
	}

	private struct Pass: Encodable {
		let prediction: Stats, keystroke: Stats, glide: Stats
		/// A live swipe: its first preview, every preview, and the decision at lift.
		let swipeFirstPreview: Stats, swipePreview: Stats, swipeFinish: Stats
		let footprintAfterMB: Double
	}

	private struct Report: Encodable {
		let initMs: Double, firstDecodeMs: Double
		let baselineMB: Double, afterInitMB: Double, afterFirstDecodeMB: Double, peakMB: Double
		let cold: Pass, warm: Pass
	}

	/// SplitMix64: deterministic tap noise, so every run decodes the same touches.
	private struct Noise {
		var state: UInt64
		mutating func next() -> Double {
			state &+= 0x9E3779B97F4A7C15
			var z = state
			z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
			z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
			return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
		}
		mutating func gaussian(_ sigma: Double) -> Double {
			let u = max(next(), 1e-12), v = next()
			return sigma * sqrt(-2 * log(u)) * cos(2 * .pi * v)
		}
	}

	private static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

	private func extensionResource(_ name: String) throws -> URL {
		let appex = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("demo_keyboard.appex"))
		return appex.appendingPathComponent(name)
	}

	private func decode(_ engine: KeyboardEngine, _ request: DecodeRequest) async -> Double {
		let started = ProcessInfo.processInfo.systemUptime
		_ = await withCheckedContinuation { (continuation: CheckedContinuation<DecodeSnapshot, Never>) in
			engine.decode(request) { continuation.resume(returning: $0) }
		}
		return (ProcessInfo.processInfo.systemUptime - started) * 1_000
	}

	/// A swipe through the word's key centers with hand noise, sampled every 8 ms.
	private func swipe(_ word: String, layout: GlideLayout, noise: inout Noise) -> ([CGPoint], [TimeInterval])? {
		let points = word.compactMap { letter in layout.centers.first { $0.letter == letter }?.point }
		guard points.count == word.count, points.count >= 2 else { return nil }
		var path: [CGPoint] = [], times: [TimeInterval] = []
		for (from, to) in zip(points, points.dropFirst()) {
			let steps = max(4, Int(hypot(to.x - from.x, to.y - from.y) / 4))
			for step in 0..<steps {
				let t = CGFloat(step) / CGFloat(steps)
				path.append(CGPoint(x: from.x + (to.x - from.x) * t + CGFloat(noise.gaussian(1.5)),
					y: from.y + (to.y - from.y) * t + CGFloat(noise.gaussian(1.5))))
				times.append(Double(times.count) * 0.008)
			}
		}
		path.append(points[points.count - 1]); times.append(Double(times.count) * 0.008)
		return (path, times)
	}

	private func glide(_ engine: KeyboardEngine, word: String, context: [String],
					   layout: GlideLayout, noise: inout Noise) async -> Double? {
		guard let (path, times) = swipe(word, layout: layout, noise: &noise) else { return nil }
		let started = ProcessInfo.processInfo.systemUptime
		_ = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
			engine.glide(path: path, times: times, layout: layout, context: context) { word, _ in
				continuation.resume(returning: word)
			}
		}
		return (ProcessInfo.processInfo.systemUptime - started) * 1_000
	}

	/// The keyboard's live path: one session per swipe, a preview every 5 samples (40 ms of
	/// finger travel, the deck's 35 ms preview interval), then the decision at lift.
	private func streamedSwipe(_ engine: KeyboardEngine, word: String, context: [String],
							   layout: GlideLayout, noise: inout Noise) async -> (previews: [Double], finish: Double)? {
		guard let (path, times) = swipe(word, layout: layout, noise: &noise), path.count > 5 else { return nil }
		let id = engine.beginGlideSession(context: context)
		var previews: [Double] = []
		for end in stride(from: 5, to: path.count, by: 5) {
			let started = ProcessInfo.processInfo.systemUptime
			await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
				engine.updateGlideSession(id, path: Array(path[..<end]), times: Array(times[..<end]), layout: layout) { _ in
					continuation.resume()
				}
			}
			previews.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
		}
		let started = ProcessInfo.processInfo.systemUptime
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			engine.finishGlideSession(id, path: path, times: times, layout: layout) { _, _ in continuation.resume() }
		}
		return (previews, (ProcessInfo.processInfo.systemUptime - started) * 1_000)
	}

	@Test func typingReplaySpeedAndMemory() async throws {
		// An idle phone dims and locks partway through; a dimming phone stalls the host for ~0.3 s.
		await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
		defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }
		let baseline = KBDiagnostics.footprintBytes()
		var peak = baseline
		let started = ProcessInfo.processInfo.systemUptime
		let engine = KeyboardEngine(languageDataURL: try extensionResource("langdata.bin"),
			neuralWordModelURL: try extensionResource("nss-english.nsslm"))
		engine.initializationGroup.wait()
		let initMs = (ProcessInfo.processInfo.systemUptime - started) * 1_000
		let afterInit = KBDiagnostics.footprintBytes()
		let tier = engine.preferredModelTier(for: .english)
		#expect(tier == .neuralSearchSpace)

		let pitch = CGSize(width: 37, height: 54)
		let centers: [(letter: Character, point: CGPoint)] = KB.rows.joined().compactMap { letter in
			guard let grid = KB.grid(for: letter) else { return nil }
			return (letter, CGPoint(x: 20 + CGFloat(grid.0) * pitch.width, y: 30 + CGFloat(grid.1) * pitch.height))
		}
		let layout = GlideLayout(centers: centers, xPitch: pitch.width, yPitch: pitch.height)

		var session: UInt64 = 0, document: UInt64 = 0, generation: UInt64 = 0
		func request(_ word: String, _ context: [String], _ taps: [KeyTap?]?) -> DecodeRequest {
			document &+= 1; generation &+= 2
			return DecodeRequest(fieldRevision: 1, documentRevision: document, wordSessionID: session,
				generation: generation, layoutRevision: 1, currentWord: word, context: context,
				taps: taps, languageMode: .english, requestedModelTier: tier)
		}
		// The keyboard slides up before its first word: decode once it is on screen.
		try await Task.sleep(nanoseconds: 300_000_000)
		session &+= 1
		let firstDecodeMs = await decode(engine, request("", [], nil))
		let afterFirstDecode = KBDiagnostics.footprintBytes()

		func replay() async -> Pass {
			var prediction: [Double] = [], keystroke: [Double] = [], glides: [Double] = []
			var firstPreviews: [Double] = [], previews: [Double] = [], finishes: [Double] = []
			var noise = Noise(state: 0x5EED)
			for sentence in Self.sentences {
				var context: [String] = []
				for word in sentence.split(separator: " ").map(String.init) {
					session &+= 1
					prediction.append(await decode(engine, request("", context, nil)))
					var taps: [KeyTap?] = []
					for index in word.indices {
						taps.append(KeyTap(dx: max(-0.45, min(0.45, noise.gaussian(0.18))),
							dy: max(-0.45, min(0.45, noise.gaussian(0.15)))))
						keystroke.append(await decode(engine, request(String(word[...index]), context, taps)))
						peak = max(peak, KBDiagnostics.footprintBytes())
					}
					if let ms = await glide(engine, word: word, context: context, layout: layout, noise: &noise) {
						glides.append(ms)
					}
					if let swipe = await streamedSwipe(engine, word: word, context: context, layout: layout, noise: &noise) {
						if let first = swipe.previews.first { firstPreviews.append(first) }
						previews += swipe.previews; finishes.append(swipe.finish)
						peak = max(peak, KBDiagnostics.footprintBytes())
					}
					context = Array((context + [word]).suffix(8))
				}
			}
			return Pass(prediction: Stats(prediction), keystroke: Stats(keystroke), glide: Stats(glides),
				swipeFirstPreview: Stats(firstPreviews), swipePreview: Stats(previews), swipeFinish: Stats(finishes),
				footprintAfterMB: Self.megabytes(KBDiagnostics.footprintBytes()))
		}
		let cold = await replay()
		let warm = await replay()

		let report = Report(initMs: initMs, firstDecodeMs: firstDecodeMs,
			baselineMB: Self.megabytes(baseline), afterInitMB: Self.megabytes(afterInit),
			afterFirstDecodeMB: Self.megabytes(afterFirstDecode), peakMB: Self.megabytes(peak),
			cold: cold, warm: warm)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		print("KB_PERF " + String(decoding: try encoder.encode(report), as: UTF8.self))
	}

	/// The key deck the extension builds on the main thread before it can show anything.
	@MainActor @Test func keyboardViewBuildTime() throws {
		var samples: [Double] = []
		let before = KBDiagnostics.footprintBytes()
		var views: [KeyboardView] = []
		for index in 0..<11 {
			let started = ProcessInfo.processInfo.systemUptime
			let keyboard = KeyboardView(theme: .preview(dark: index % 2 == 0, accent: KBPalette.system, customTheme: nil))
			keyboard.frame.size.width = 393
			keyboard.setShowsSuggestions(true)
			keyboard.frame.size.height = keyboard.keyboardHeight
			keyboard.layoutIfNeeded()
			samples.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
			views.append(keyboard)
		}
		let perViewMB = Self.megabytes(KBDiagnostics.footprintBytes() &- before) / Double(views.count)
		let build = Stats(Array(samples.dropFirst()))
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		print("KB_PERF_VIEW " + String(decoding: try encoder.encode(["firstMs": samples[0], "p50Ms": build.p50,
			"maxMs": build.max, "perViewMB": perViewMB]), as: UTF8.self))
	}
}
