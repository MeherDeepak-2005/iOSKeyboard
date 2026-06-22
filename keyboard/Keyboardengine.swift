import UIKit

// All text work, split so NOTHING can block a keystroke:
//   - Autocorrect: one word, fast, runs synchronously on MAIN (boundaries only).
//   - Suggestions: completions are slow → background queue, and the controller
//     debounces them so fast typing never queues them up.
// Two separate UITextChecker instances so main and background never collide.

final class KeyboardEngine {

	private let language = "en_US"

	private let autoChecker = UITextChecker()                       // MAIN only
	private let bgQueue = DispatchQueue(label: "keyboard.suggestions")
	private let bgChecker = UITextChecker()                         // bgQueue only

	private var bigrams: [String: [String: Int]] = [:]             // touched on bgQueue only
	private var unigrams: [String: Int] = [:]
	private let maxBigramKeys = 4000

	private lazy var storeURL: URL = {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("kb_model.json")
	}()

	init() {
		bgQueue.async { [weak self] in
			guard let self else { return }
			self.load()
			if self.unigrams.isEmpty { self.seed() }
		}
	}

	// MARK: Autocorrect — synchronous, main thread, one word. NO blocking sync.

	func autocorrection(for word: String, previous: String?) -> String? {
		guard word.count >= 3,
			  word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return nil }
		let ns = word as NSString
		let full = NSRange(location: 0, length: ns.length)
		let mis = autoChecker.rangeOfMisspelledWord(in: word, range: full, startingAt: 0, wrap: false, language: language)
		if mis.location == NSNotFound { return nil }                 // spelled right -> fast bail (common case)
		if UITextChecker.hasLearnedWord(word) { return nil }
		guard let top = autoChecker.guesses(forWordRange: mis, in: word, language: language)?.first else { return nil }
		guard editDistance(word.lowercased(), top.lowercased()) <= 2 else { return nil }
		return matchCase(of: word, to: top)
	}

	func dontCorrect(_ word: String) { UITextChecker.learnWord(word) }

	// MARK: Suggestions — background, never on the keystroke path

	func suggestions(currentWord: String, previous: String?, completion: @escaping ([String]) -> Void) {
		bgQueue.async { [weak self] in
			guard let self else { return }
			let result = currentWord.isEmpty ? self.nextWords(after: previous)
											 : self.completions(for: currentWord)
			DispatchQueue.main.async { completion(result) }
		}
	}

	func learn(previous: String?, word: String) {
		let allowed = CharacterSet.lowercaseLetters.union(CharacterSet(charactersIn: "'"))
		let w = word.lowercased()
		guard w.count >= 2, w.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return }
		bgQueue.async { [weak self] in
			guard let self else { return }
			self.unigrams[w, default: 0] += 1
			if let p = previous?.lowercased(), !p.isEmpty {
				self.bigrams[p, default: [:]][w, default: 0] += 1
			}
			self.trim()
			self.save()
		}
	}

	// MARK: Internals (bgQueue only)

	private func completions(for partial: String) -> [String] {
		let ns = partial as NSString
		let range = NSRange(location: 0, length: ns.length)
		var out = bgChecker.completions(forPartialWordRange: range, in: partial, language: language) ?? []
		let mis = bgChecker.rangeOfMisspelledWord(in: partial, range: range, startingAt: 0, wrap: false, language: language)
		if mis.location != NSNotFound,
		   let g = bgChecker.guesses(forWordRange: mis, in: partial, language: language)?.first {
			out.insert(g, at: 0)
		}
		var seen = Set<String>(); var list: [String] = []
		for s in out where seen.insert(s.lowercased()).inserted {
			list.append(s); if list.count == 3 { break }
		}
		return list
	}

	private func nextWords(after previous: String?) -> [String] {
		if let p = previous?.lowercased(), let map = bigrams[p] {
			let top = map.sorted { $0.value > $1.value }.prefix(3).map(\.key)
			if !top.isEmpty { return Array(top) }
		}
		return Array(unigrams.sorted { $0.value > $1.value }.prefix(3).map(\.key))
	}

	private func seed() {
		let common = ["the","to","and","a","i","you","is","it","that","of","in","for","on","do","have",
					  "this","with","be","are","what","we","can","just","they","my","but","so","if","me",
					  "your","all","get","like","good","now","how","when","there","not"]
		for (i, w) in common.enumerated() { unigrams[w] = common.count - i }
	}

	private func trim() {
		guard bigrams.count > maxBigramKeys else { return }
		let leastUsed = bigrams.sorted { $0.value.values.reduce(0,+) < $1.value.values.reduce(0,+) }
		for (k, _) in leastUsed.prefix(bigrams.count - maxBigramKeys) { bigrams.removeValue(forKey: k) }
	}

	private struct Model: Codable { var bigrams: [String: [String: Int]]; var unigrams: [String: Int] }
	private func load() {
		guard let data = try? Data(contentsOf: storeURL),
			  let m = try? JSONDecoder().decode(Model.self, from: data) else { return }
		bigrams = m.bigrams; unigrams = m.unigrams
	}
	private func save() {
		if let data = try? JSONEncoder().encode(Model(bigrams: bigrams, unigrams: unigrams)) {
			try? data.write(to: storeURL)
		}
	}
}

// MARK: - Free helpers

private func editDistance(_ s1: String, _ s2: String) -> Int {
	let a = Array(s1), b = Array(s2)
	if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
	var prev = Array(0...b.count)
	var cur = [Int](repeating: 0, count: b.count + 1)
	for i in 1...a.count {
		cur[0] = i
		for j in 1...b.count {
			cur[j] = a[i-1] == b[j-1] ? prev[j-1] : Swift.min(prev[j-1], prev[j], cur[j-1]) + 1
		}
		swap(&prev, &cur)
	}
	return prev[b.count]
}

private func matchCase(of source: String, to target: String) -> String {
	guard let f = source.first, f.isUppercase else { return target }
	return target.prefix(1).uppercased() + target.dropFirst()
}
