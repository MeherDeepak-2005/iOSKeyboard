import Foundation
import Testing
@testable import keyboard

// NSS is the English decoder from the first word: a session begun while the engine is still
// starting already takes the "nss" tier, and only a model that cannot load falls back to n-gram.
// Reads the extension's own bundled files, so it runs wherever the host app embeds it.
struct NSSStartupTests {
	private func extensionResource(_ name: String) throws -> URL {
		let appex = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("demo_keyboard.appex"))
		return appex.appendingPathComponent(name)
	}

	@Test func bundledModelSelectsNSSDuringAndAfterStartup() throws {
		let engine = KeyboardEngine(languageDataURL: try extensionResource("langdata.bin"),
			neuralWordModelURL: try extensionResource("nss-english.nsslm"))
		// Still loading or already loaded: either way the first session asks for NSS.
		#expect(engine.preferredModelTier(for: .english) == .neuralSearchSpace)
		#expect(engine.preferredModelTier(for: .telugu) == .ngram)
		engine.initializationGroup.wait()
		#expect(engine.neuralWordModel != nil)
		#expect(engine.neuralSearchSpaceReady)
		#expect(engine.preferredModelTier(for: .english) == .neuralSearchSpace)
	}

	@Test func unloadableModelFallsBackToNgramOnceStarted() throws {
		let engine = KeyboardEngine(languageDataURL: try extensionResource("langdata.bin"),
			neuralWordModelURL: try extensionResource("missing.nsslm"))
		engine.initializationGroup.wait()
		#expect(engine.neuralWordModel == nil)
		#expect(engine.preferredModelTier(for: .english) == .ngram)
	}
}
