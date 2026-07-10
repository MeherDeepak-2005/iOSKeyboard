import Foundation

// Lexicon: channel model + candidate generator — extracted from Keyboardengine.swift.

final class Lexicon {

	/// With v3 langdata the 60k-word dictionary is searched IN PLACE in the mmap'd
	/// static trie (clean, evictable pages), and this heap trie holds only adopted +
	/// contact words — dozens, not tens of thousands. With a v2 file the full vocab
	/// loads here as before.
	private let dynamicTrie = Trie()
	/// The mmap'd bundle data; also used by NgramScorer. nil in the host app / tests.
	private(set) var langData: LangData?
	/// True when langData carries the v3 static trie section.
	private var staticTrie = false
	/// Personal-use frequency lifts for STATIC words — the mmap can't be mutated the
	/// way `Trie.bump` edits heap nodes. Only words the user actually types, but the
	/// KEY COUNT still grows one entry per distinct dictionary word ever typed, so it
	/// is capped (halve-and-drop, like UserModel) rather than left to accrete forever.
	private var boosts: [String: Int] = [:]
	private static let maxBoosts = 3000
	/// Highest-frequency words, for the empty-context suggestion bar on a fresh install.
	private(set) var topWords: [String] = []

	// The exact-match blocklist now lives in the bundled `safety.kbguard` binary
	// (curated LDNOOBW en + Wiktionary te, 429 terms), memory-mapped and hash-indexed —
	// see KBSafetyLexicon. nil only if the resource is missing (host app / tests).
	private let safety = KBSafetyLexicon.bundled()

	// Substrings that essentially never occur inside an innocent English word, so a
	// containment check safely blocks COMPOUNDS the exact list misses — fuckface, shithole,
	// dickhead, cocksucker, shitshow, etc. Kept in code deliberately: substring matching is
	// a different strategy than the binary's exact hash lookup, and this list is narrow —
	// roots like "ass"/"cock"/"dick"/"hell" are NOT here because they hide inside
	// class / cockpit / dickens / hello (the Scunthorpe problem).
	private let profanityRoots = [
		"fuck", "shit", "cunt", "cocksuck", "dickhead", "faggot", "jackoff", "jerkoff", "gangbang",
	]
	// Innocent words that DO contain a root above (only "cunt" has real ones here).
	private let profanityAllowlist: Set<String> = ["scunthorpe"]

	func isProfane(_ w: String) -> Bool {
		let lw = w.lowercased()
		if profanityAllowlist.contains(lw) { return false }
		if safety?.isBlocked(lw) == true { return true }        // exact-match binary blocklist
		return profanityRoots.contains { lw.contains($0) }      // substring compounds
	}

	func contains(_ lw: String) -> Bool {
		(staticTrie && langData?.trieContains(lw) == true) || dynamicTrie.contains(lw)
	}
	func isPrefix(_ lw: String) -> Bool {
		(staticTrie && langData?.trieHasPrefix(lw) == true) || dynamicTrie.hasPrefix(lw)
	}
	func insert(_ lw: String, freq: Int) { dynamicTrie.insert(lw, freq: freq) }
	func wordID(_ lw: String) -> Int32? {
		staticTrie ? langData?.trieWordID(lw) : dynamicTrie.wordID(lw)
	}
	func corrections(for lw: String, maxCost: Double, taps: [KeyTap?]? = nil) -> [Candidate] {
		var out = dynamicTrie.search(lw, maxCost: maxCost, taps: taps)
		if staticTrie, let ld = langData {
			out += ld.trieSearch(lw, maxCost: maxCost, taps: taps).map(boosted)
		}
		return out
	}

	/// Next-character priors under the current prefix, for key-target resizing:
	/// log-scaled subtree max frequency, normalized to [0, 1] of the strongest child.
	/// Read straight off the mmap trie — no heap tables, no language-model call.
	func nextCharPriors(prefix lw: String) -> [Character: Double] {
		guard staticTrie, let ld = langData else { return [:] }
		let kids = ld.trieChildren(after: lw)
		guard let top = kids.map(\.maxFreq).max(), top > 0 else { return [:] }
		let denom = log(Double(top) + 1)
		var out: [Character: Double] = [:]
		out.reserveCapacity(kids.count)
		for (label, f) in kids where f > 0 {
			out[Character(UnicodeScalar(label))] = log(Double(f) + 1) / denom
		}
		return out
	}

	/// The frequency term a word carries in ranking (nil when unknown).
	func logFreq(of lw: String) -> Double? {
		if staticTrie, let ld = langData, let id = ld.trieWordID(lw) {
			let base = log(Double(max(ld.freq(Int(id)), 1)) + 1)
			guard let b = boosts[lw] else { return base }
			return log(exp(base) + Double(b))
		}
		return dynamicTrie.logFreq(lw)
	}
	func completions(prefix lw: String, limit: Int) -> [Candidate] {
		var out = dynamicTrie.completions(prefix: lw, limit: limit)
		if staticTrie, let ld = langData {
			out += ld.trieCompletions(prefix: lw, limit: limit).map(boosted)
		}
		return Array(out.sorted { $0.logFreq > $1.logFreq }.prefix(limit))
	}

	/// Personal-use lift on a static word's frequency term — mirrors what `Trie.bump`
	/// does to heap nodes: each use adds one effective count.
	private func boosted(_ c: Candidate) -> Candidate {
		guard let b = boosts[c.word] else { return c }
		return Candidate(word: c.word, cost: c.cost, logFreq: log(exp(c.logFreq) + Double(b)))
	}

	/// Adoption: known words get their frequency bumped; unknown words enter the
	/// dynamic trie once the user has typed them `adoptAfter` times.
	func noteUse(of lw: String, timesUsed: Int, adoptAfter: Int) {
		if staticTrie, langData?.trieContains(lw) == true {
			boosts[lw] = min((boosts[lw] ?? 0) + 1, 100)
			// Bound the key count: halve every entry, drop what falls to zero. Habits
			// (high boosts) survive; one-off words shed. Rare (only past the cap).
			if boosts.count > Self.maxBoosts {
				boosts = boosts.compactMapValues { $0 >= 2 ? $0 >> 1 : nil }
			}
		} else if dynamicTrie.contains(lw) {
			dynamicTrie.bump(lw)
		} else if timesUsed >= adoptAfter {
			dynamicTrie.insert(lw, freq: timesUsed)
		}
	}

	func loadFromBundle() {
		if let url = Bundle.main.url(forResource: "langdata", withExtension: "bin"),
		   let ld = LangData(url: url) {
			langData = ld
			if ld.hasTrie {
				// v3: the dictionary is searched in place — nothing to copy to the heap.
				// Top words for the fresh-install bar: scan the freq array (ints only),
				// materialize just the winners.
				staticTrie = true
				var top: [(id: Int, f: Int)] = []
				for id in 0..<ld.wordCount {
					let f = ld.freq(id)
					if top.count < 32 {
						top.append((id, f))
						if top.count == 32 { top.sort { $0.f > $1.f } }
					} else if f > top[top.count - 1].f {
						top[top.count - 1] = (id, f)
						var i = top.count - 1
						while i > 0, top[i].f > top[i - 1].f { top.swapAt(i, i - 1); i -= 1 }
					}
				}
				topWords = Array(top.map { ld.word($0.id) }.filter { !isProfane($0) }.prefix(8))
			} else {
				// v2 fallback: materialize the vocab into the heap trie as before.
				var top: [(String, Int)] = []
				ld.forEachWord { word, freq, id in
					dynamicTrie.insert(word, freq: freq, id: id)
					if !isProfane(word) {
						top.append((word, freq))
						if top.count > 32 { top.sort { $0.1 > $1.1 }; top.removeLast(16) }
					}
				}
				topWords = top.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
			}
		} else {
			let seed = "the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us is are was word".split(separator: " ")
			for (i, w) in seed.enumerated() { dynamicTrie.insert(String(w), freq: seed.count - i) }
			topWords = seed.prefix(8).map(String.init)
		}
	}
}

