import Foundation

// Noisy-channel engine, v2.
//   • First-letter weighting: changing a word's first letter is heavily penalized
//     in the spatial model (people rarely mistype the first key). This alone fixes
//     "might"->"night" without any language data.
//   • Trained trigram prior with stupid-backoff (trigram -> bigram -> unigram),
//     loaded from a bundled `ngrams.txt` at launch so it ships KNOWING context,
//     plus online learning on top. Frequency stays in the trie (logFreq); the LM
//     supplies context only, so frequency is never double-counted.
//
// Bundle two files in the keyboard EXTENSION target:
//   dictionary.txt   word <space/tab> frequency          (the lexicon)
//   ngrams.txt       w1 w2 [w3] <space/tab> count         (built from your corpus
//                                                          via build_ngrams.py)
// Without ngrams.txt the LM is empty but first-letter weighting still applies.

// MARK: - Spatial model:  -log P(typed_key | intended_key)

private enum KB {
	static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
	static let rowOffset: [Double] = [0.0, 0.25, 0.75]
	static let sigma = 1.0
	static let pos: [Character: (Double, Double)] = {
		var m: [Character: (Double, Double)] = [:]
		for (r, row) in rows.enumerated() {
			for (c, ch) in row.enumerated() { m[ch] = (Double(c) + rowOffset[r], Double(r)) }
		}
		return m
	}()
	static func subCost(_ intended: Character, _ typed: Character) -> Double {
		if intended == typed { return 0 }
		guard let a = pos[intended], let b = pos[typed] else { return 3.0 }
		let d2 = (a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)
		return min(3.0, d2 / (2 * sigma * sigma) + 0.3)
	}
}

// MARK: - Trie with weighted fuzzy search + first-letter weighting

struct Candidate { let word: String; let cost: Double; let logFreq: Double }

final class Trie {
	private final class Node {
		var children: [Character: Node] = [:]
		var word: String?
		var logFreq: Double = 0
	}
	private let root = Node()
	private static let insCost = 1.6
	private static let delCost = 1.6
	static var firstLetterPenalty = 2.5            // extra cost to change the first letter

	func insert(_ word: String, freq: Int) {
		var node = root
		for ch in word {
			if let next = node.children[ch] { node = next }
			else { let n = Node(); node.children[ch] = n; node = n }
		}
		node.word = word
		node.logFreq = log(Double(max(freq, 1)) + 1)
	}
	func contains(_ word: String) -> Bool {
		var node = root
		for ch in word { guard let next = node.children[ch] else { return false }; node = next }
		return node.word != nil
	}
	func bump(_ word: String) {
		var node = root
		for ch in word { guard let next = node.children[ch] else { return }; node = next }
		if node.word != nil { node.logFreq = log(exp(node.logFreq) + 1) }
	}

	func search(_ typed: String, maxCost: Double) -> [Candidate] {
		let chars = Array(typed)
		guard !chars.isEmpty else { return [] }
		var firstRow = [Double](repeating: 0, count: chars.count + 1)
		for i in 0...chars.count { firstRow[i] = Double(i) * Trie.insCost }
		var out: [Candidate] = []
		for (ch, child) in root.children {
			Trie.recurse(child, ch, 1, chars, firstRow, maxCost, &out)
		}
		return out
	}

	private static func recurse(_ node: Node, _ letter: Character, _ depth: Int,
								_ typed: [Character], _ prevRow: [Double],
								_ maxCost: Double, _ out: inout [Candidate]) {
		let n = typed.count
		var cur = [Double](repeating: 0, count: n + 1)
		cur[0] = prevRow[0] + delCost
		for col in 1..<(n + 1) {
			let ins = cur[col - 1] + insCost
			let del = prevRow[col] + delCost
			var s = KB.subCost(letter, typed[col - 1])
			if depth == 1, col == 1, letter != typed[0] { s += firstLetterPenalty }  // protect first letter
			cur[col] = min(ins, del, prevRow[col - 1] + s)
		}
		if let w = node.word, cur[n] <= maxCost {
			out.append(Candidate(word: w, cost: cur[n], logFreq: node.logFreq))
		}
		if (cur.min() ?? .infinity) <= maxCost {
			for (ch, child) in node.children { recurse(child, ch, depth + 1, typed, cur, maxCost, &out) }
		}
	}

	func completions(prefix: String, limit: Int) -> [Candidate] {
		var node = root
		for ch in prefix { guard let next = node.children[ch] else { return [] }; node = next }
		var out: [Candidate] = []
		collect(node, &out, cap: 256)
		return Array(out.sorted { $0.logFreq > $1.logFreq }.prefix(limit))
	}
	private func collect(_ node: Node, _ out: inout [Candidate], cap: Int) {
		if out.count >= cap { return }
		if let w = node.word { out.append(Candidate(word: w, cost: 0, logFreq: node.logFreq)) }
		for (_, child) in node.children { collect(child, &out, cap: cap) }
	}
}

// MARK: - Engine

final class KeyboardEngine {

	private let queue = DispatchQueue(label: "keyboard.engine", attributes: .concurrent)
	private let trie = Trie()

	// base = bundled ngrams.txt (read-only, never persisted); learn = user delta (persisted).
	private var baseTri: [String: [String: Int]] = [:], baseTriTot: [String: Int] = [:]
	private var baseBi:  [String: [String: Int]] = [:], baseBiTot:  [String: Int] = [:]
	private var learnTri: [String: [String: Int]] = [:], learnTriTot: [String: Int] = [:]
	private var learnBi:  [String: [String: Int]] = [:], learnBiTot:  [String: Int] = [:]
	private var unigrams: [String: Int] = [:]
	private var unigramTotal = 0
	private var kept = Set<String>()

	// Tunables.
	private let maxCost = 2.8
	private let lmWeight = 1.0
	private let freqWeight = 0.3
	private let adoptAfter = 3

	private lazy var storeURL: URL = {
		let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir.appendingPathComponent("kb_model.json")
	}()

	init() {
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.loadDictionary()
			self.loadNgrams()
			self.loadLearned()
			self.applyLearned()
		}
	}

	// MARK: Autocorrect (fast read on a word boundary)

	func autocorrection(for word: String, context: [String]) -> String? {
		guard word.count >= 3 else { return nil }
		let lw = word.lowercased()
		return queue.sync {
			if trie.contains(lw) || kept.contains(lw) { return nil }
			let cands = trie.search(lw, maxCost: maxCost)
			guard let best = bestCandidate(cands, context: context), best != lw else { return nil }
			return matchCase(of: word, to: best)
		}
	}

	func dontCorrect(_ word: String) {
		let lw = word.lowercased()
		queue.async(flags: .barrier) { [weak self] in
			self?.kept.insert(lw); self?.trie.insert(lw, freq: 5); self?.save()
		}
	}

	// MARK: Suggestions (background)

	func suggestions(currentWord: String, context: [String], completion: @escaping ([String]) -> Void) {
		queue.async { [weak self] in
			guard let self else { return }
			let r = currentWord.isEmpty ? self.nextWords(context: context)
										: self.completeOrCorrect(currentWord, context: context)
			DispatchQueue.main.async { completion(r) }
		}
	}

	func learn(context: [String], word: String) {
		let lw = word.lowercased()
		guard lw.count >= 1, lw.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
		let ctx = context.map { $0.lowercased() }
		queue.async(flags: .barrier) { [weak self] in
			guard let self else { return }
			self.unigrams[lw, default: 0] += 1; self.unigramTotal += 1
			if let p = ctx.last {
				self.learnBi[p, default: [:]][lw, default: 0] += 1; self.learnBiTot[p, default: 0] += 1
			}
			if ctx.count >= 2 {
				let k = ctx[ctx.count - 2] + " " + ctx[ctx.count - 1]
				self.learnTri[k, default: [:]][lw, default: 0] += 1; self.learnTriTot[k, default: 0] += 1
			}
			if self.trie.contains(lw) { self.trie.bump(lw) }
			else if self.unigrams[lw]! >= self.adoptAfter { self.trie.insert(lw, freq: self.unigrams[lw]!) }
			self.save()
		}
	}

	// MARK: Language model — trigram -> bigram -> unigram (base + learned combined)

	private func logProb(_ word: String, context: [String]) -> Double {
		let w = word.lowercased()
		let n = context.count
		if n >= 2 {
			let k = context[n - 2].lowercased() + " " + context[n - 1].lowercased()
			let c = (baseTri[k]?[w] ?? 0) + (learnTri[k]?[w] ?? 0)
			let t = (baseTriTot[k] ?? 0) + (learnTriTot[k] ?? 0)
			if c > 0, t > 0 { return log(Double(c) / Double(t)) }
		}
		if n >= 1 {
			let p = context[n - 1].lowercased()
			let c = (baseBi[p]?[w] ?? 0) + (learnBi[p]?[w] ?? 0)
			let t = (baseBiTot[p] ?? 0) + (learnBiTot[p] ?? 0)
			if c > 0, t > 0 { return log(0.4 * Double(c) / Double(t)) }       // backoff weight
		}
		let u = Double((unigrams[w] ?? 0) + 1)
		return log(0.16 * u / Double(unigramTotal + unigrams.count + 1))      // 0.4^2 backoff
	}

	private func score(_ c: Candidate, context: [String]) -> Double {
		-c.cost + lmWeight * logProb(c.word, context: context) + freqWeight * c.logFreq
	}
	private func bestCandidate(_ cands: [Candidate], context: [String]) -> String? {
		cands.max(by: { score($0, context: context) < score($1, context: context) })?.word
	}
	private func completeOrCorrect(_ partial: String, context: [String]) -> [String] {
		let p = partial.lowercased()
		var byWord: [String: Double] = [:]
		for c in trie.completions(prefix: p, limit: 12) + trie.search(p, maxCost: maxCost) {
			byWord[c.word] = max(byWord[c.word] ?? -.infinity, score(c, context: context))
		}
		return byWord.sorted { $0.value > $1.value }.prefix(3).map { matchCase(of: partial, to: $0.key) }
	}
	private func nextWords(context: [String]) -> [String] {
		let n = context.count
		if n >= 2 {
			let k = context[n - 2].lowercased() + " " + context[n - 1].lowercased()
			let top = merged(baseTri[k], learnTri[k]).prefix(3)
			if !top.isEmpty { return Array(top) }
		}
		if n >= 1 {
			let top = merged(baseBi[context[n - 1].lowercased()], learnBi[context[n - 1].lowercased()]).prefix(3)
			if !top.isEmpty { return Array(top) }
		}
		return Array(unigrams.sorted { $0.value > $1.value }.prefix(3).map(\.key))
	}
	private func merged(_ a: [String: Int]?, _ b: [String: Int]?) -> [String] {
		var m = a ?? [:]
		for (k, v) in (b ?? [:]) { m[k, default: 0] += v }
		return m.sorted { $0.value > $1.value }.map(\.key)
	}

	// MARK: Loading + persistence

	private func loadDictionary() {
		if let url = Bundle.main.url(forResource: "dictionary", withExtension: "txt"),
		   let text = try? String(contentsOf: url, encoding: .utf8) {
			for line in text.split(separator: "\n") {
				let p = line.split { $0 == " " || $0 == "\t" }
				guard let w = p.first else { continue }
				trie.insert(String(w).lowercased(), freq: p.count > 1 ? Int(p[1]) ?? 1 : 1)
			}
		} else {
			let seed = "the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us is are was word".split(separator: " ")
			for (i, w) in seed.enumerated() { trie.insert(String(w), freq: seed.count - i) }
		}
	}

	private func loadNgrams() {
		guard let url = Bundle.main.url(forResource: "ngrams", withExtension: "txt"),
			  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
		for line in text.split(separator: "\n") {
			let t = line.split { $0 == " " || $0 == "\t" }.map(String.init)
			guard t.count >= 3, let c = Int(t.last!) else { continue }
			let words = t.dropLast().map { $0.lowercased() }
			if words.count == 2 {
				baseBi[words[0], default: [:]][words[1], default: 0] += c; baseBiTot[words[0], default: 0] += c
			} else if words.count == 3 {
				let k = words[0] + " " + words[1]
				baseTri[k, default: [:]][words[2], default: 0] += c; baseTriTot[k, default: 0] += c
			}
		}
	}

	private struct Model: Codable {
		var tri: [String: [String: Int]]; var bi: [String: [String: Int]]
		var uni: [String: Int]; var kept: [String]
	}
	private func loadLearned() {
		guard let data = try? Data(contentsOf: storeURL),
			  let m = try? JSONDecoder().decode(Model.self, from: data) else { return }
		learnTri = m.tri; learnBi = m.bi; unigrams = m.uni; kept = Set(m.kept)
		learnTriTot = learnTri.mapValues { $0.values.reduce(0, +) }
		learnBiTot  = learnBi.mapValues  { $0.values.reduce(0, +) }
		unigramTotal = unigrams.values.reduce(0, +)
	}
	private func applyLearned() {
		for w in kept { trie.insert(w, freq: 5) }
		for (w, c) in unigrams {
			if trie.contains(w) { for _ in 0..<min(c, 50) { trie.bump(w) } }
			else if c >= adoptAfter { trie.insert(w, freq: c) }
		}
	}
	private func save() {
		let m = Model(tri: learnTri, bi: learnBi, uni: unigrams, kept: Array(kept))
		if let data = try? JSONEncoder().encode(m) { try? data.write(to: storeURL) }
	}
}

private func matchCase(of source: String, to target: String) -> String {
	guard let f = source.first, f.isUppercase else { return target }
	return target.prefix(1).uppercased() + target.dropFirst()
}
