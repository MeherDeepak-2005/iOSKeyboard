import UIKit

extension KeyboardViewController {
	// MARK: Key handling — the hot path

	/// Any action other than the single-Backspace undo (or the bar-undo) means the
	/// last autocorrect STOOD. Report it: acceptance is counter-evidence that resets
	/// the word's rejection tally, so one accidental undo can't slowly turn into a
	/// permanent keep. Called at the entry of every non-undo handler — exactly the
	/// moment the undo affordance expires.
	func resolveCorrectionAsAccepted() {
		if let c = lastCorrection, c.fromAutocorrect, activeLanguageMode == .english {
			engine.correctionStood(c.original)
		}
	}

	/// Moving on does not establish intent. Drop the pending sample without adapting.
	func resolveGlideUnverified() {
		if pendingGlideVerdict { pendingGlideVerdict = false; engine.glideUnverified() }
		KBStats.confirm(pendingGlideStatsID)
		pendingGlideStatsID = nil
	}

	func learnCommittedWord(context: [String], word: String) {
		guard activeLanguageMode == .english, permitsLearning else { return }
		engine.learn(context: context, word: word)
	}

	func recordReplacement(original: String, replacement: String) {
		guard activeLanguageMode == .english, permitsLearning else { return }
		engine.wordReplaced(original: original, with: replacement)
	}

	/// The user undid a correction: the next boundary must not redo it. Not tied to the
	/// recorder's or learning's field checks, which once left undos forgotten.
	func rejectCorrection(_ word: String) {
		guard activeLanguageMode == .english, !isSecureField else { return }
		engine.dontCorrect(word)
	}

	// MARK: Typing-quality benchmark hooks (aggregate counters in KBDiagnostics; no text)

	/// One physical screen tap. Called at the discrete key handlers, so a suggestion pick
	/// or a whole glide gesture is a single tap even though it produces many characters —
	/// exactly what makes the keystrokes-per-character ratio drop below 1.0.
	func noteTap(atUptime uptime: Double = ProcessInfo.processInfo.systemUptime) {
		guard !isSecureField else { return }
		KBDiagnostics.noteTap(atUptime: uptime)
	}

	/// Record a finalized word for the accuracy/speed counters, and settle the pending NWP
	/// opportunity. `autocorrected` is true only when the engine changed the typed word.
	func recordCommitMetrics(_ word: String, autocorrected: Bool, source: String? = nil) {
		let armed = nwpPredictionArmed
		nwpPredictionArmed = false
		guard !word.isEmpty, !isSecureField else { return }
		recordCommit(word, evidence: source ?? (autocorrected ? "automatic-unverified" : "literal-unverified"))
		KBDiagnostics.noteWordCommitted(chars: word.count + 1, autocorrected: autocorrected,
			predictionShown: armed, predictionHit: armed && nwpPredictedTop3.contains(word.lowercased()))
	}


    func noteProxyEdit() {
		documentRevision &+= 1
		generation &+= 1
		decodeSnapshot = nil
		presentedDecodeSnapshot = nil
		keyboard?.setKeyPriors([:])
	}

	/// Model selection happens only here, between words. The selected tier is then
	/// copied into every DecodeRequest until the next session boundary.
	func advanceWordSession() {
		let finishedSession = wordSessionID
		wordSessionID &+= 1
		currentWordBuffer = ""
		wordTaps.removeAll(keepingCapacity: true)
		typingTrace = TypingTrace()
		engine.discardModelSession(finishedSession)
		wordSessionModelTier = engine.preferredModelTier(for: activeLanguageMode)
	}

	@inline(__always)
	func insertIntoHost(_ text: String) {
		#if DEBUG || INTERNAL_GRU || INTERNAL_NSS
		let started = ProcessInfo.processInfo.systemUptime
		let signpost = KBDiagnostics.beginHostInsert()
		textDocumentProxy.insertText(text)
		KBDiagnostics.endHostInsert(signpost,
			milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
		#else
		// Shipping key path: no clocks, signposts, locks, dispatches, or model work
		// before the host edit.
		textDocumentProxy.insertText(text)
		#endif
	}


	@discardableResult
	func replaceHostSuffix(_ suffix: String, with replacement: String) -> Bool {
		lastReplaceDeleteCount = 0
		guard let initial = textDocumentProxy.documentContextBeforeInput else { return false }
		// Parsed words carry ASCII apostrophes; smart-punctuation hosts store ’ (folding is
		// one-to-one per Character), so replace the host's own spelling of the same word.
		let hostSuffix = String(initial.suffix(suffix.count))
		let matched = hostSuffix.count == suffix.count
			&& HostDocumentSnapshot.folded(hostSuffix) == HostDocumentSnapshot.folded(suffix) ? hostSuffix : suffix
		guard let plan = HostSuffixReplacementPlan(contextBeforeInput: initial,
				suffix: matched, replacement: replacement) else { return false }
		return plan.apply(initialContext: initial,
			deleteBackward: {
				textDocumentProxy.deleteBackward()
				lastReplaceDeleteCount += 1
				// An empty field reports nil; the plan reads that as the terminal state
				// for a first-word replacement rather than a stuck host.
				return textDocumentProxy.documentContextBeforeInput
			},
			insert: { insertIntoHost($0) })
	}
}
