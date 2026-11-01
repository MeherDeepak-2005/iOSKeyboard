import UIKit

extension KeyboardViewController {
	// MARK: Auto-capitalization — shift arms itself at sentence starts (stock behavior)

	func updateAutoShift() {
		let ctx = textDocumentProxy.documentContextBeforeInput
		keyboard?.setAutoShift(shouldAutoShift(ctx))
	}

	/// Field start, after a newline, or after sentence-ending punctuation + space.
	func shouldAutoShift(_ ctx: String?) -> Bool {
		guard let ctx, !ctx.isEmpty else { return true }
		if ctx.hasSuffix("\n") { return true }
		var s = Substring(ctx)
		var sawSpace = false
		while s.last == " " { sawSpace = true; s = s.dropLast() }
		if sawSpace, let l = s.last, ".!?".contains(l) { return true }
		return s.isEmpty        // only whitespace before the cursor
	}

	func handleDelete() {
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
		noteProxyEdit()
		if keyboard?.isRepeatingKey != true { noteTap() }
		// A single Backspace right after a correction undoes it back to the typed word.
		if let c = lastCorrection {
			// Validate the correction is still present in the document before undoing.
			// If the user selected-all and then backspaced, the field is empty and the
			// correction no longer exists; executing the undo path would insert the
			// original typed word ("coeevitjkn") into the now-cleared field.
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			let expected = c.corrected + c.trailing
			guard !expected.isEmpty, ctx.hasSuffix(expected) else {
				if pendingGlideVerdict {
					pendingGlideVerdict = false
					engine.glideRejected()
					KBStats.cancel(pendingGlideStatsID)
					pendingGlideStatsID = nil
				}
				lastCorrection = nil
				let erased = ctx.last
				textDocumentProxy.deleteBackward()
				traceErase(erased)
				if let erased, isWordChar(erased), !wordTaps.isEmpty { wordTaps.removeLast() }
				else { wordTaps.removeAll(keepingCapacity: true) }
				trackErase(of: erased)
				updateAutoShift()
				scheduleSuggestions()
				return
			}
			// #37: a glided word (empty original, not an autocorrect) being backspaced away is
			// a rejection — the engine drops its pending sample without moving the statistics.
			if pendingGlideVerdict, c.original.isEmpty, !c.fromAutocorrect {
				pendingGlideVerdict = false
				engine.glideRejected()
				KBStats.cancel(pendingGlideStatsID)
				pendingGlideStatsID = nil
			}
			lastCorrection = nil
			resetEraseTracking()
			wordTaps.removeAll(keepingCapacity: true)   // word rewritten — offsets no longer align
			typingTrace = TypingTrace()
			if permitsTypingData { KBDiagnostics.noteBackspace(erasedLetter: nil) }
			guard replaceHostSuffix(expected, with: c.original) else {
				updateAutoShift()
				scheduleSuggestions()
				return
			}
			// WMR: backspacing away a committed correction/pick/glide is the clearest
			// "user edited a word after committing it" signal. A reverted engine autocorrect
			// additionally counts toward the over-correction rate.
			recordTyping("undo", text: c.corrected, replacement: c.original, evidence: c.fromAutocorrect ? "explicit-autocorrect-undo" : "explicit-retraction", relatedWord: c.recordedWordSessionID)
			KBDiagnostics.noteWordModified(revertedCorrection: c.fromAutocorrect)
			// Walk back the exact learned replacement for every source (autocorrect,
			// completion, or Glide). Autocorrect additionally needs a session keep so
			// the next boundary does not immediately fight the user's undo.
			if !isSecureField, !c.corrected.isEmpty {
				recordReplacement(original: c.corrected, replacement: c.original)
			}
			if c.fromAutocorrect {
				rejectCorrection(c.original)
			}
			updateAutoShift()
			scheduleSuggestions()
			return
		}
		let erased = textDocumentProxy.documentContextBeforeInput?.last
		textDocumentProxy.deleteBackward()
		traceErase(erased)
		if let erased, isWordChar(erased), !wordTaps.isEmpty { wordTaps.removeLast() }
		else { wordTaps.removeAll(keepingCapacity: true) }
		trackErase(of: erased)
		updateAutoShift()
		scheduleSuggestions()
	}

	func handlePick(_ s: String) {
        guard hostConnectionReady, let shown = presentationDocument,
            let current = readHostDocument(), current.isAvailable, shown.matches(current) else {
            reconcileHostDocument()
            return
        }
        documentReconciler.beginKeyboardEdit()
        keyboard?.dismissTools()
        defer { endKeyboardEdit() }
		noteProxyEdit()
		noteTap()              // tapping the suggestion bar is one physical tap
		resetEraseTracking()   // picking from the bar is its own flow with its own signals
		wordTaps.removeAll(keepingCapacity: true)

		// Emoji suggestion (last slot, word→emoji match): replace the typed word with
		// the emoji and learn nothing — it isn't a spelling. No trailing space, matching
		// stock QuickType. A letterless string is unambiguously the emoji candidate.
		if !s.isEmpty, !s.contains(where: { $0.isLetter }) {
			resolveCorrectionAsAccepted()
			if case .complete(let partial) = mode {
				guard replaceHostSuffix(partial, with: s) else { return }
			} else {
				insertIntoHost(s)
			}
			KBEmojiRecents.add(s)
			lastCorrection = nil
			updateAutoShift()
			scheduleSuggestions()
			return
		}

		// Every pick except the bar-undo means any pending autocorrect stood.
		let pickMode: (label: String, replacing: String) = {
			switch mode {
			case .complete(let partial): return ("complete", partial)
			case .predict: return ("predict", "")
			case .revert(let original): return ("revert", original)
			case .glided(let committed): return ("glided", committed)
			}
		}()
		if case .revert(let original) = mode, s == original {} else { resolveCorrectionAsAccepted() }
		switch mode {
		case .complete(let partial):
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			guard replaceHostSuffix(partial, with: s + " ") else { return }
			recordTyping("suggestion-pick", text: pickMode.replacing, replacement: s, evidence: "explicit-selection")
			learnCommittedWord(context: ctx, word: s)
			if !isSecureField { KBStats.noteCommitted(glided: false) }
			// Swapping the typed word for a different suggestion is strong evidence the
			// typed word was a mistake — lift its keep protection and walk back a use.
			// This is the "typed mjght, then picked might" healing path.
			if partial.lowercased() != s.lowercased() {
				recordReplacement(original: partial, replacement: s)
			}
			// A completion pick finalizes a word the user chose (not an engine autocorrect).
			recordCommitMetrics(s, autocorrected: false)
			lastCorrection = Correction(original: partial, corrected: s, trailing: " ", fromAutocorrect: false, recordedWordSessionID: wordSessionID)
			advanceWordSession()
		case .predict:
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			insertIntoHost(s + " ")
			recordTyping("prediction-pick", replacement: s, evidence: "explicit-selection")
			learnCommittedWord(context: ctx, word: s)
			if !isSecureField { KBStats.noteCommitted(glided: false) }
			// Tapping a next-word prediction: a finalized word and, if it was armed, a direct NWP hit.
			recordCommitMetrics(s, autocorrected: false)
			advanceWordSession()
			lastCorrection = nil        // nothing the user "typed" to revert to
		case .revert(let original):
			let ctx = textDocumentProxy.documentContextBeforeInput ?? ""
			if s == original, let corrected = lastCompleteWord(ctx) {
				guard replaceHostSuffix(corrected + " ", with: original + " ") else { return }
				recordTyping("undo", text: corrected, replacement: original, evidence: "explicit-autocorrect-undo", relatedWord: lastCorrection?.recordedWordSessionID)
				rejectCorrection(original)
				recordReplacement(original: corrected, replacement: original)
				// Tapping the undo chip edits an already-committed (auto)corrected word.
				KBDiagnostics.noteWordModified(revertedCorrection: true)
			} else {
				insertIntoHost(s + " ")
			}
			lastCorrection = nil
		case .glided(let committed):
			let correctedWordID = lastCorrection?.recordedWordSessionID
			// Swap the glided word for one of its shape alternatives: replace word + its
			// trailing space, learn the replacement, heal the wrong learn (Gboard-style).
			// #37: the picked alternative is the TRUE word — feed its shape cost as the
			// correct sample so the decoder learns to rank the user's real intent higher.
			let oldAlternatives: [String]
			if case .glide(_, let alternatives) = suggestionPresentation {
				oldAlternatives = alternatives
			} else {
				oldAlternatives = []
			}
			let ctx = contextWords(textDocumentProxy.documentContextBeforeInput ?? "", max: 8)
			let replacement = SuggestionCasePolicy.display(s,
				sentenceStart: shouldAutoShift(textDocumentProxy.documentContextBeforeInput))
			guard replaceHostSuffix(committed + " ", with: replacement + " ") else { return }
			if pendingGlideVerdict { pendingGlideVerdict = false; engine.glideCorrected(to: s) }
			KBStats.confirm(pendingGlideStatsID)
			pendingGlideStatsID = nil
			recordTyping("glide-selection", text: committed, replacement: s, evidence: "explicit-selection", relatedWord: correctedWordID)
			learnCommittedWord(context: ctx, word: s)
			if committed.lowercased() != s.lowercased() {
				recordReplacement(original: committed, replacement: s)
			}
			lastCorrection = Correction(original: "", corrected: replacement, trailing: " ", fromAutocorrect: false, recordedWordSessionID: correctedWordID)
			// Swapping a committed glide word for an alternative edits an already-committed word.
			if committed.lowercased() != s.lowercased() {
				KBDiagnostics.noteWordModified(revertedCorrection: false)
			}
			mode = .glided(replacement)          // further swaps keep working
			let alternatives = uniqueWords([committed] + oldAlternatives, excluding: replacement)
			setGlideSuggestionBar(winner: replacement, alternatives: alternatives)
			updateAutoShift()
			return                               // keep the alternatives on the bar
		}
		KBDiagnostics.logPick(mode: pickMode.label, replacing: pickMode.replacing, with: s,
			contextTail: String((textDocumentProxy.documentContextBeforeInput ?? "").suffix(24)),
			deletes: lastReplaceDeleteCount, inserted: true)
		updateAutoShift()
		scheduleSuggestions()
	}
}
