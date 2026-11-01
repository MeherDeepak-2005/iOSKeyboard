import UIKit

extension KeyboardViewController {
	// MARK: Autocorrect (fast, non-blocking)

	@discardableResult
	func applyAutocorrectIfNeeded() -> Correction? {
		guard autocorrectionAllowed else { return nil }
		let snapshot: PresentedDecodeSnapshot
		if let current = currentPresentedDecodeSnapshot {
			snapshot = current
		} else {
			// A fast boundary can arrive before the asynchronous strip update. Only
			// Tenglish has a bounded synchronous fallback: one memory-mapped exact lookup.
			// English and neural work remain strictly off the host-insertion path.
			let request = makeDecodeRequest(currentWord: currentWordBuffer,
				context: currentContextBuffer, generation: generation)
			guard let canonical = engine.immediateBoundarySnapshot(request) else { return nil }
			let presented = SuggestionCasePolicy.present(canonical,
				sentenceStart: shouldAutoShift(textDocumentProxy.documentContextBeforeInput))
			decodeSnapshot = canonical
			presentedDecodeSnapshot = presented
			snapshot = presented
		}
		let word = snapshot.canonical.request.currentWord
		guard !word.isEmpty,
			  let correction = snapshot.correction,
			  correction != word else { return nil }
		// Use the same checked, grapheme-aware transaction as explicit suggestion picks.
		guard textDocumentProxy.selectedText?.isEmpty != false,
			replaceHostSuffix(word, with: correction) else {
			KBDiagnostics.noteIntegrityEvent("correction-host-mismatch")
			return nil
		}
		recordTyping("autocorrection", text: word, replacement: correction, evidence: "automatic-unverified")
		noteProxyEdit()
		recentCorrections.append((original: word, corrected: correction))
		if recentCorrections.count > 4 { recentCorrections.removeFirst() }
		return Correction(original: word, corrected: correction, trailing: "", fromAutocorrect: true, recordedWordSessionID: wordSessionID)
	}



	// MARK: Manual-fix detection (backspace-erase → retype, no one-tap undo involved)

	func resetEraseTracking() {
		erasedWord = ""
		erasedCrossedBoundary = false
		replacementStarted = false
	}

	/// Called for every plain backspace with the character that was just deleted.
	func trackErase(of char: Character?) {
		replacementStarted = false
		guard let char else { resetEraseTracking(); return }        // deleted at field start
		if isWordChar(char) {
			if erasedCrossedBoundary {
				// Deleting into the PREVIOUS word — that word is the erase target now.
				erasedWord = String(char)
				erasedCrossedBoundary = false
			} else {
				erasedWord.insert(char, at: erasedWord.startIndex)
			}
			if erasedWord.count > 24 { resetEraseTracking() }       // runaway delete, not a fix
		} else if !erasedWord.isEmpty {
			erasedCrossedBoundary = true
		}
	}

	/// First insert after a run of backspaces: typing that resumes INSIDE a word means
	/// the deletes were an intra-word edit ("jst" → backspace → "ust"), not a word
	/// swap — stop tracking rather than misread it.
	func trackReplacementStart(wasInsideWord: Bool) {
		guard !erasedWord.isEmpty, !replacementStarted else { return }
		replacementStarted = true
		if wasInsideWord { resetEraseTracking() }
	}

	/// A word is being committed where one was just erased. Two cases:
	/// the erased word was one of OUR corrections and the user retyped exactly what
	/// they had originally typed → a manual undo of autocorrect (register the
	/// rejection, walk the learning back); anything else → a hand-fix of their own
	/// word ("js" → "is"), which demotes the erased word.
	func resolveManualFix(_ committed: String) {
		defer { resetEraseTracking() }
		// Erased characters come from the host, which may store a correction's ' as ’.
		let erased = HostDocumentSnapshot.folded(erasedWord)
		guard erased.count >= 2, !committed.isEmpty,
			  erased.lowercased() != committed.lowercased(), !isSecureField else { return }
		if let hit = recentCorrections.last(where: { $0.corrected.lowercased() == erased.lowercased() }),
		   hit.original.lowercased() == committed.lowercased() {
			rejectCorrection(committed)
			decodeSnapshot = nil
			presentedDecodeSnapshot = nil
		}
		recordTyping("manual-replacement", text: erased, replacement: committed, evidence: "inferred-word-swap")
		recordReplacement(original: erased, replacement: committed)
	}
}
