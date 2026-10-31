import Foundation

// Lexicon: channel model + candidate generator.

final class Lexicon {

	/// Immutable/base, supplementary, and learned words are separate layers. Resetting
	/// personalization can therefore drop only learned words without damaging a v2
	/// fallback dictionary or contact/text-replacement words imported for this process.
	private var baseTrie = Trie()
	private var supplementaryTrie = Trie()
	private var personalTrie = Trie()
	/// The mmap'd bundle data; also used by NgramScorer. nil in the host app / tests.
	private(set) var langData: LangData?
	/// True when langData carries the v3 static trie section.
	private var staticTrie = false
	/// Personal-use frequency lifts for STATIC words — the mmap can't be mutated the
	/// way `Trie.bump` edits heap nodes. Only words the user actually types, but the
	/// KEY COUNT still grows one entry per distinct dictionary word ever typed, so it
	/// is capped (halve-and-drop, like UserModel) rather than left to accrete forever.
    // Native owns boosts; keep one converted copy (callers hold `lock`). Exporting the
    // table on every logFreq/completion call cost an O(boosts) bridge round-trip each time.
    private var boostCache: [String: Int]?
    private var boosts: [String: Int] {
        if let boostCache { return boostCache }
        let value = nativeVocabulary.boosts.mapValues(\.intValue)
        boostCache = value
        return value
    }
    private lazy var nativeVocabulary = KBVocabularyState(safety: safety?.native)

	/// Highest-frequency words, for the empty-context suggestion bar on a fresh install.
	private(set) var topWords: [String] = []

	/// Mutable trie layers, boosts, and load-time flags are written by the engine queue
	/// and read by dedicated decode/Glide queues. Every method below takes this lock;
	/// the mmap'd static trie itself is immutable, and no disk or model work is performed
	/// while the lock is held. (isProfane needs no lock: the safety map is immutable.)
	private let lock = NSLock()
	private var vocabularyEpoch: UInt64 = 0
	var vocabularyRevision: UInt64 { lock.lock(); defer { lock.unlock() }; return vocabularyEpoch }

	// The project-reviewed exact-match policy lives in the bundled `safety.kbguard`
	// binary, memory-mapped and hash-indexed. It filters generated candidates only;
	// typed input is never censored. nil only if the resource is missing in tests.
	private let safety = KBSafetyLexicon.bundled()

    /// The native safety lexicon: the shared engine and vocabulary state read their
    /// penalties and blocked terms from it directly.
    var nativeSafety: KBNativeSafetyLexicon? { safety?.native }

    /// Residual non-blocking penalties (in-dictionary demote terms), computed natively at load.
    /// Blocked words never reach ranking: the dictionary's blocked bitset excludes them during
    /// candidate generation and learning refuses them, so generated English candidates need
    /// no per-candidate safety lookup. Empty for the shipped pack.
    private var residualPenalties: [String: Double] = [:]
    func generatedPenalty(_ word: String) -> Double {
        residualPenalties.isEmpty ? 0 : residualPenalties[word] ?? 0
    }

#if DEBUG || KB_REFERENCE_DECODER_YES
    /// Reference mirror of generateCandidates' closest blocked match: its cost bounds recovery,
    /// so a typo aimed at a blocked word is left alone. Never a candidate.
    func closestBlockedCost(_ lw: String, maxCost: Double, taps: [KeyTap?]?) -> Double {
        lock.lock(); let ld = langData; lock.unlock()
        return ld?.swiftBlockedTrie?.search(lw, maxCost: maxCost, taps: taps).map(\.cost).min() ?? .infinity
    }
#endif

    /// A dictionary word that generation excludes as blocked. The typed literal is never
    /// censored, so the Swift pool builder re-adds it as its own exact match (as native).
    func isGenerationBlocked(_ lw: String) -> Bool {
        lock.lock(); let ld = langData; lock.unlock()
        guard let ld, let id = ld.trieWordID(lw) else { return false }
        return ld.isSwiftBlocked(id)
    }

    func nativeGenerationView() -> KBGenerationLexicon {
        lock.lock()
        langData?.prepareNativeTextMetadata()
        let view = KBGenerationLexicon(packed: staticTrie ? langData?.nativeCandidateLexicon : nil,
            base: baseTrie.native, supplementary: supplementaryTrie.native, personal: personalTrie.native,
            snapshot: nativeVocabulary.snapshot)
        lock.unlock()
        return view
    }

    /// Retain immutable native views under the lock, then run all traversal after
    /// unlocking. Learning uses copy-on-write if a Glide/decode still holds a view.
    func generateEnglishCandidates(typed: String, taps: [KeyTap?]?, successors: [String],
        prior: TrieSearchPrior?, retainedStatic: [Candidate]?, gruTier: Bool,
        shouldCancel: @escaping () -> Bool) throws -> KBGeneratedCandidates {
        let view = nativeGenerationView()
        var characterOffsets = [0]
        for ch in typed { characterOffsets.append(characterOffsets.last! + String(ch).utf8.count) }
        let buffers = NativeTapBuffers(taps: taps, expectedCount: typed.utf8.count)
        let funding = prior?.nativeFundingSnapshot()
        return try KBCandidateGenerator.generateWord(typed, lexicon: view,
            tapOffsets: buffers?.offsets, tapValidity: buffers?.validity,
            contextSuccessors: successors, successorLengths: successors.map { NSNumber(value: $0.count) },
            successorFirst: successors.map { $0.first.map(String.init) ?? "" },
            successorLast: successors.map { $0.last.map(String.init) ?? "" },
            characterOffsets: characterOffsets.map { NSNumber(value: $0) }, fundedWords: funding?.words, fundedBonuses: funding?.bonuses,
            retainedStatic: retainedStatic?.map(\.native), gruTier: gruTier, shouldCancel: shouldCancel)
    }

	func isProfane(_ w: String) -> Bool {
		safety?.isBlocked(w.lowercased()) == true
	}

	func safetyPenalty(_ word: String) -> Double {
		safety?.penalty(for: word) ?? 0
	}

	func isSafeToLearn(_ word: String) -> Bool {
		(safety?.action(for: word) ?? .allow) == .allow
	}

	func contains(_ lw: String) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return (staticTrie && langData?.trieContains(lw) == true)
			|| baseTrie.contains(lw) || supplementaryTrie.contains(lw) || personalTrie.contains(lw)
	}
	/// True only for words in the immutable corpus (static mmap trie). Used to filter
	/// user-count boosts in next-word predictions so only dictionary words get personalized
	/// ranking — OOV strings, adopted typos, and contact names don't flood suggestions.
	func isStaticWord(_ lw: String) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return (staticTrie && langData?.trieContains(lw) == true) || (!staticTrie && baseTrie.contains(lw))
	}
	/// Standard English clitics. A string that is <lexicon word> + one of these is a
	/// valid contraction even when the CONTRACTION itself is missing from the corpus
	/// vocab ("when's", "mustn't" — the 60k list carries only the frequent ones).
	private static let clitics = ["'s", "'re", "'ll", "'ve", "'d", "'m", "n't"]

	/// True when `lw` parses as a known word + standard clitic. Autocorrect uses this
	/// to protect OOV contractions from being "corrected" to their base ("when's" →
	/// "when" was a live bug: OOV + the always-correct fallback flattened the 's).
	func isContractionForm(_ lw: String) -> Bool {
		guard lw.contains("'") else { return false }
		for suffix in Self.clitics where lw.hasSuffix(suffix) {
			let base = String(lw.dropLast(suffix.count))
			if base.count >= 1, base.allSatisfy({ $0.isLetter }), contains(base) { return true }
		}
		return false
	}

	/// The contraction an apostrophe-less OOV string restores to ("dont" → "don't"),
	/// or nil. Corpus-validated first (at most count-1 exact trie walks under the
	/// lock); falls back to SYNTHESIS for contractions the 60k vocab is missing —
	/// "whens" → "when's" has no trie entry to validate against, so without the
	/// fallback the OOV correction machinery flattened it to "when".
	func apostropheRestoration(of lw: String) -> String? {
		lock.lock(); let data = staticTrie ? langData : nil; lock.unlock()
		let hit = data?.trieApostropheRestoration(of: lw)?.word
		if let hit { return hit }
		return Self.syntheticContraction(of: lw)
	}

	/// Bases that take a synthesized 's contraction. CLOSED class — wh-words,
	/// pronouns, and deictics only. An open rule ("any word + s → word's") would
	/// turn every OOV plural into a possessive ("lexicons" → "lexicon's").
	private static let sContractionBases: Set<String> = [
		"when", "where", "why", "how", "who", "what", "that", "there", "here",
		"it", "he", "she", "one", "everyone", "everybody", "everything",
		"someone", "somebody", "something", "anyone", "anybody", "anything",
		"nobody", "nothing",
	]
	/// Auxiliaries whose n't contraction is missing from the vocab (don't/can't/
	/// isn't and friends are corpus words and restore via the trie).
	private static let ntContractionBases: Set<String> = [
		"must", "might", "need", "ought", "dare", "shall",
	]
	static func syntheticContraction(of lw: String) -> String? {
		guard !lw.contains("'") else { return nil }
		if lw.count >= 3, lw.hasSuffix("s"), sContractionBases.contains(String(lw.dropLast())) {
			return String(lw.dropLast()) + "'s"
		}
		if lw.count >= 4, lw.hasSuffix("nt"), ntContractionBases.contains(String(lw.dropLast(2))) {
			return String(lw.dropLast(2)) + "n't"
		}
		return nil
	}
	func insert(_ lw: String, freq: Int) {
		lock.lock(); defer { lock.unlock() }
		supplementaryTrie.insert(lw, freq: freq)
		vocabularyEpoch &+= 1
        nativeVocabulary.supplementary(lw, frequency: freq, glide: Self.isGlideSpelling(lw))
	}

	func glideDynamicWords(limit: Int) -> [String] {
		lock.lock(); defer { lock.unlock() }
        return nativeVocabulary.dynamicWords(UInt(max(0, limit)))
	}

	private static func isGlideSpelling(_ word: String) -> Bool {
		word.count >= 2 && word.utf8.allSatisfy {
			($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || $0 == KB.apostrophe
		}
	}
	func wordID(_ lw: String) -> Int32? {
		lock.lock(); defer { lock.unlock() }
		return staticTrie ? langData?.trieWordID(lw) : baseTrie.wordID(lw)
	}
	/// Immutable mmap snapshot for the dedicated Glide queues. The reference is copied
	/// under the lock; all trie/ngram bytes are read-only after bundle loading completes.
	func languageDataSnapshot() -> LangData? {
		lock.lock(); defer { lock.unlock() }
		return staticTrie ? langData : nil
	}
	func corrections(for lw: String, maxCost: Double, taps: [KeyTap?]? = nil,
					 prior: TrieSearchPrior? = nil,
					 shouldCancel: (() -> Bool)? = nil) -> [Candidate] {
		lock.lock()
		let data = staticTrie ? langData : nil
		let boostSnapshot = boosts
		var out = staticTrie ? [] : baseTrie.search(lw, maxCost: maxCost,
			taps: taps, prior: prior).map(boosted)
		out += supplementaryTrie.search(lw, maxCost: maxCost, taps: taps)
		out += personalTrie.search(lw, maxCost: maxCost, taps: taps)
		lock.unlock()
		if let data {
			out += data.trieSearch(lw, maxCost: maxCost, taps: taps, prior: prior,
				shouldCancel: shouldCancel).map { Self.applying(boostSnapshot, to: $0) }
		}
		return out
	}

	/// Static words with one extra leading letter before the typed word (bove → above), boosted
	/// like `corrections`. Mirrors native generateCandidates beside a retained search.
	func missingFirstLetterCorrections(for lw: String, maxCost: Double, taps: [KeyTap?]? = nil,
		shouldCancel: (() -> Bool)? = nil) -> [Candidate] {
		lock.lock()
		let data = staticTrie ? langData : nil
		let boostSnapshot = boosts
		lock.unlock()
		guard let data else { return [] }
		return data.trieSearch(lw, maxCost: maxCost, taps: taps, shouldCancel: shouldCancel,
			missingFirstOnly: true).map { Self.applying(boostSnapshot, to: $0) }
	}

	/// Static words whose first letter is a spelling confusion of the typed one (emminent →
	/// imminent), boosted like `corrections`. Mirrors native generateCandidates beside a retained search.
	func firstLetterVariantCorrections(for lw: String, maxCost: Double, taps: [KeyTap?]? = nil,
		shouldCancel: (() -> Bool)? = nil) -> [Candidate] {
		let bytes = Array(lw.utf8)
		guard bytes.count >= 2 else { return [] }
		let roots = Set((UInt8(ascii: "a")...UInt8(ascii: "z")).filter {
			$0 != bytes[0] && $0 != bytes[1] && KB.spellingConfusion($0, bytes[0])
		})
		lock.lock()
		let data = staticTrie ? langData : nil
		let boostSnapshot = boosts
		lock.unlock()
		guard let data, !roots.isEmpty else { return [] }
		return data.trieSearch(lw, maxCost: maxCost, taps: taps, shouldCancel: shouldCancel,
			roots: roots).map { Self.applying(boostSnapshot, to: $0) }
	}

	/// Creates the retained static search state once per word. A nil result means the
	/// pack is legacy/missing or the explicit state cap was exceeded; callers must use
	/// the full trie walk in that case rather than silently reducing candidate recall.
	func makeIncrementalDecodeSession(typedFirst: UInt8,
		firstTap: KeyTap?, typedSecond: UInt8 = 0, maxCost: Double = 3.6) -> IncrementalDecodeSession? {
		lock.lock()
		let data = staticTrie ? langData : nil
		let boostSnapshot = boosts
		lock.unlock()
        if let data, data.backend == .cpp {
            // Immutable snapshot taken under the existing lock. Same boosts and
            // word-session lifetime as the reference; no independent personal DB.
            do {
                guard let seeds = try data.nativeIncrementalSeeds(typedFirst: typedFirst,
                    firstTap: firstTap, boosts: boostSnapshot, typedSecond: typedSecond, maxCost: maxCost) else { return nil }
                return try IncrementalDecodeSession(nativeSeeds: seeds)
            } catch {
                // A rejected native session retains the established full-trie
                // fallback; never silently reduce coverage to fit a seed cap.
                return nil
            }
        }
        guard let seeds = data?.incrementalSeeds(typedFirst: typedFirst,
			firstTap: firstTap, typedSecond: typedSecond, maxCost: maxCost) else { return nil }
		let adjusted = seeds.map { seed -> IncrementalLexiconSeed in
			guard let boost = boostSnapshot[seed.word] else { return seed }
			return IncrementalLexiconSeed(word: seed.word, bytes: seed.bytes,
				logFreq: log(exp(seed.logFreq) + Double(boost)))
		}
		return IncrementalDecodeSession(seeds: adjusted, backend: .swiftReference)
	}

	/// Mutable/supplementary layers stay small and are searched conventionally. The
	/// large immutable retained state is C++-owned through `IncrementalDecodeSession`.
	func mutableCorrections(for lw: String, maxCost: Double,
		taps: [KeyTap?]? = nil) -> [Candidate] {
		lock.lock(); defer { lock.unlock() }
		var out = staticTrie ? [] : baseTrie.search(lw, maxCost: maxCost,
			taps: taps).map(boosted)
		out += supplementaryTrie.search(lw, maxCost: maxCost, taps: taps)
		out += personalTrie.search(lw, maxCost: maxCost, taps: taps)
		return out
	}

	/// Wide-radius recovery includes mutable words under the lock, then searches the
	/// immutable mapped corpus using a brief personalization snapshot. The same prior
	/// funds terminal candidates in every vocabulary source.
	func broadCorrections(for lw: String, maxCost: Double, taps: [KeyTap?]? = nil,
						  prior: TrieSearchPrior? = nil,
						  shouldCancel: (() -> Bool)? = nil) -> [Candidate] {
		lock.lock()
		let mutable = supplementaryTrie.search(lw, maxCost: maxCost, taps: taps, prior: prior)
			+ personalTrie.search(lw, maxCost: maxCost, taps: taps, prior: prior)
		guard staticTrie, let ld = langData else {
			let base = baseTrie.search(lw, maxCost: maxCost, taps: taps, prior: prior)
			lock.unlock(); return base + mutable
		}
		let snap = boosts   // COW snapshot — O(1) under the lock
		lock.unlock()
		return ld.trieSearch(lw, maxCost: maxCost, taps: taps, prior: prior,
			shouldCancel: shouldCancel).map { Self.applying(snap, to: $0) } + mutable
	}

	/// Next-character priors under the current prefix, for key-target resizing:
	/// log-scaled subtree max frequency, normalized to [0, 1] of the strongest child.
	/// Read straight off the mmap trie — no heap tables, no language-model call.
	func nextCharPriors(prefix lw: String) -> [Character: Double] {
		lock.lock(); let ld0 = staticTrie ? langData : nil; lock.unlock()
		guard let ld = ld0 else { return [:] }
		let kids = ld.trieChildren(after: lw)
        let values = KBNumericPolicy.characterPriors(kids.map { NSNumber(value: $0.maxFreq) })
        return Dictionary(uniqueKeysWithValues: zip(kids.map { Character(UnicodeScalar($0.label)) }, values.map(\.doubleValue)).filter { $0.1 > 0 })
	}

	/// The frequency term a word carries in ranking (nil when unknown).
	func logFreq(of lw: String) -> Double? {
		lock.lock(); defer { lock.unlock() }
		if staticTrie, let ld = langData, let id = ld.trieWordID(lw) {
			let base = log(Double(max(ld.freq(Int(id)), 1)) + 1)
			guard let b = boosts[lw] else { return base }
			return log(exp(base) + Double(b))
		}
		if let base = baseTrie.logFreq(lw) {
			guard let b = boosts[lw] else { return base }
			return log(exp(base) + Double(b))
		}
		return supplementaryTrie.logFreq(lw) ?? personalTrie.logFreq(lw)
	}
	func completions(prefix lw: String, limit: Int) -> [Candidate] {
		lock.lock()
		let data = staticTrie ? langData : nil
		let boostSnapshot = boosts
		var out = staticTrie ? [] : baseTrie.completions(prefix: lw, limit: limit).map(boosted)
		out += supplementaryTrie.completions(prefix: lw, limit: limit)
		out += personalTrie.completions(prefix: lw, limit: limit)
		lock.unlock()
		if let data {
			out += data.trieCompletions(prefix: lw, limit: limit)
				.map { Self.applying(boostSnapshot, to: $0) }
		}
		return Array(out.sorted { $0.logFreq > $1.logFreq }.prefix(limit))
	}

	private static func applying(_ boosts: [String: Int], to candidate: Candidate) -> Candidate {
		guard let boost = boosts[candidate.word] else { return candidate }
		return Candidate(word: candidate.word, cost: candidate.cost,
			logFreq: log(exp(candidate.logFreq) + Double(boost)))
	}

	/// Personal-use lift on a static word's frequency term — mirrors what `Trie.bump`
	/// does to heap nodes: each use adds one effective count. Caller must hold `lock`.
	private func boosted(_ c: Candidate) -> Candidate {
		guard let b = boosts[c.word] else { return c }
		return Candidate(word: c.word, cost: c.cost, logFreq: log(exp(c.logFreq) + Double(b)))
	}

	/// Adoption: known words get their frequency bumped; unknown words enter the
	/// dynamic trie once the user has typed them `adoptAfter` times.
	func noteUse(of lw: String, timesUsed: Int, adoptAfter: Int,
				 allowAdoption: Bool = false) {
		lock.lock(); defer { lock.unlock() }
        boostCache = nil
        if nativeVocabulary.note(lw, count: timesUsed, allowAdoption: allowAdoption, threshold: adoptAfter,
            glide: Self.isGlideSpelling(lw), packed: staticTrie ? langData?.nativeCandidateLexicon : nil,
            base: baseTrie.native, supplementary: supplementaryTrie.native, personal: personalTrie.native) { vocabularyEpoch &+= 1 }
	}

	func resetPersonalization() {
		lock.lock()
		vocabularyEpoch &+= 1
		personalTrie = Trie()
        nativeVocabulary.resetPersonalization()
        boostCache = nil
		lock.unlock()
	}

	/// Capitalize a cold-start opener (the empty bar is a sentence start): the→The,
	/// i→I, i'm→I'm.
	private func sentenceCase(_ w: String) -> String {
		guard let f = w.first else { return w }
		return f.uppercased() + w.dropFirst()
	}

	func loadFromBundle() {
		load(from: Bundle.main.url(forResource: "langdata", withExtension: "bin"))
	}

	/// Explicit resource seam for deterministic engine tests and offline tools. The
	/// shipping engine calls `loadFromBundle()` and follows the same implementation.
	func load(from url: URL?) {
		if let url, let ld = LangData(url: url) {
			// Exclude blocked words from candidate generation before any search can run.
			if let safety, let native = ld.nativeCandidateLexicon {
				native.installBlocked(fromSafety: safety.native)
				residualPenalties = native.residualPenalties(fromSafety: safety.native).mapValues(\.doubleValue)
			}
			if let safety { ld.installSwiftBlocked(safety.native.blockedTerms) }
			lock.lock(); langData = ld; lock.unlock()
			if ld.hasTrie {
				// v3: the dictionary is searched in place — nothing to copy to the heap.
				lock.lock(); staticTrie = true; lock.unlock()
				// Cold-start bar: prefer SENTENCE-INITIAL words (v4 starters) — openers
				// like "I, The, I'm, You" — over global frequency, which surfaces
				// mid-sentence function words (and, of, to). Capitalize: the empty bar is
				// a sentence start. Falls back to top-frequency for a pre-v4 file.
				let starterIDs = ld.starterIDs(limit: 24)
				if !starterIDs.isEmpty {
					topWords = starterIDs.map { sentenceCase(ld.word($0)) }
						.filter { !isProfane($0) }.prefix(8).map { $0 }
				} else {
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
				}
			} else {
				// v2 fallback: materialize the vocab into a LOCAL heap trie, then swap it in
				// under the lock — never hold the lock for the 60k-word build (a keystroke's
				// main-thread fast path would stall behind it at launch).
				let t = Trie()
				var top: [(String, Int)] = []
				ld.forEachWord { word, freq, id in
					t.insert(word, freq: freq, id: id)
					if !isProfane(word) {
						top.append((word, freq))
						if top.count > 32 { top.sort { $0.1 > $1.1 }; top.removeLast(16) }
					}
				}
				lock.lock(); baseTrie = t; lock.unlock()
				topWords = top.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
			}
		} else {
			let seed = "the be to of and a in that have i it for not on with he as you do at this but his by from they we say her she or an will my one all would there their what so up out if about who get which go me when make can like time no just him know take people into year your good some could them see other than then now look only come its over think also back after use two how our work first well way even new want because any these give day most us is are was word".split(separator: " ")
			let t = Trie()
			for (i, w) in seed.enumerated() { t.insert(String(w), freq: seed.count - i) }
			lock.lock(); baseTrie = t; lock.unlock()
			topWords = seed.prefix(8).map(String.init)
		}
	}
}
