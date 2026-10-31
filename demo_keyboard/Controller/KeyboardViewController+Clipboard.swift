import UIKit

extension KeyboardViewController {
	// MARK: Clipboard — capture on panel open, insert from saved history

	/// Capture the current system pasteboard into history. Called ONLY when the user
	/// opens the clipboard panel — a deliberate action, so iOS's one "pasted from" notice
	/// reads as expected (there is no banner-free way to read arbitrary text; `changeCount`
	/// dedupe means at most one read per distinct copy). We never read on the type path,
	/// so copying elsewhere raises no banner and never stalls layout.
	///
	/// Hardening over afda5b4 (Improvements.md P0 §3): (1) never capture while a secure
	/// field is focused — password managers paste into those; (2) advance
	/// `consumedChangeCount` only AFTER a confirmed non-empty read, so a transient read
	/// failure retries on the next open instead of silently dropping the copy (the old
	/// code consumed first). Sensitive-content rejection (OTP / card numbers) and the
	/// retention TTL live in `KBClipboard.add`.
	func captureClipboardIfNeeded() {
		guard hasFullAccess, !isSecureField else { return }
		let pb = UIPasteboard.general
		let count = pb.changeCount
		guard count != KBClipboard.consumedChangeCount else { return }
		guard pb.hasStrings else { KBClipboard.consumedChangeCount = count; return }
		guard let text = pb.string,
			  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		KBClipboard.consumedChangeCount = count      // only after a confirmed read
		KBClipboard.add(text)
	}

    /// Explicit panel action. Sensitive text can be pasted, but KBClipboard.add
    /// refuses to retain it. No pasteboard contents are read during suggestion work.
	func handlePasteCurrentClipboard() {
		guard hasFullAccess, !isSecureField else { return }
		let pb = UIPasteboard.general
		guard pb.hasStrings, let text = pb.string,
			  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		KBClipboard.consumedChangeCount = pb.changeCount
		KBClipboard.add(text)
		handleClipboardPick(text)
	}

	/// A history row from the clipboard panel. Inserts and stays on the panel
	/// (multi-paste, Gboard-style). Never learned — clips aren't typing.
	func handleClipboardPick(_ text: String) {
        guard hasFullAccess, !isSecureField else { return }
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
		noteProxyEdit()
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		resetEraseTracking()
		wordTaps.removeAll(keepingCapacity: true)
		insertIntoHost(text)
		lastCorrection = nil
		updateAutoShift()
        scheduleSuggestions()
	}

	func invalidateDocumentSession() {
		fieldRevision &+= 1
		documentRevision &+= 1
		advanceWordSession()
		decodeSnapshot = nil
		presentedDecodeSnapshot = nil
		currentWordBuffer = ""
		currentContextBuffer.removeAll(keepingCapacity: true)
		wordTaps.removeAll(keepingCapacity: true)
		generation &+= 1
		engine.cancelSuggestions()
	}


	func handleInsert(_ ch: String, tap: KeyTap? = nil) {
        let isLetter = ch.count == 1 && ch.first.map(isWordChar) == true
        // A plain letter cannot replace earlier text. Insert it before any proxy
        // reads, then validate its expected document change when the edit finishes.
        beginKeyboardEdit(reconcileFirst: !isLetter)
        if isLetter { expectedLetterInsertion = ch }
        defer { endKeyboardEdit() }
		lastTeluguKeyContext = nil
		if ch.count == 1, let c = ch.first, isWordChar(c) {
			let wasInsideWord = !currentWordBuffer.isEmpty
			// Hot path: the host edit is the first meaningful operation. Everything
			// else is post-insert bookkeeping and asynchronous decode scheduling.
			insertIntoHost(ch)
			noteProxyEdit()
			wordTaps.append(tap)
			currentWordBuffer.append(c)
			trackReplacementStart(wasInsideWord: wasInsideWord)
			let acceptedCorrection = lastCorrection
			let unresolvedGlide = pendingGlideVerdict
			let acceptedGlideStatsID = pendingGlideStatsID
			lastCorrection = nil
			pendingGlideVerdict = false
			pendingGlideStatsID = nil
			let revision = documentRevision
			DispatchQueue.main.async { [weak self] in
				guard let self else { return }
				self.noteTap()          // counted off the host path — never before the insert
				if let acceptedCorrection, acceptedCorrection.fromAutocorrect,
				   self.activeLanguageMode == .english {
					self.engine.correctionStood(acceptedCorrection.original)
				}
				if unresolvedGlide { self.engine.glideUnverified() }
				KBStats.confirm(acceptedGlideStatsID)
				guard revision == self.documentRevision else { return }
				self.updateAutoShift()
				self.scheduleSuggestions()
			}
			return
		}

		noteTap()          // space / punctuation / other single-character key
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()

		// Double-space → period + space (stock shortcut). Only after a word, only in
		// normal prose fields, only within the double-tap window.
		if ch == " " {
			let now = ProcessInfo.processInfo.systemUptime
			if now - lastSpaceAt < 0.6 {
				let before = textDocumentProxy.documentContextBeforeInput ?? ""
				if before.hasSuffix(" "), let prev = before.dropLast().last,
				   isWordChar(prev), autocorrectionAllowed {
					textDocumentProxy.deleteBackward()
					insertIntoHost(". ")
					noteProxyEdit()
					advanceWordSession()
					wordTaps.removeAll(keepingCapacity: true)
					lastCorrection = nil
					lastSpaceAt = 0
					resetEraseTracking()
					updateAutoShift()
					scheduleSuggestions()
					return
				}
			}
			lastSpaceAt = now
		}

		if ch.count == 1, let u = ch.unicodeScalars.first, boundary.contains(u) {
			// Must run BEFORE autocorrect: a manual revert (erased our correction, retyped
			// the original) registers a rejection synchronously (dontCorrect → stateLock), so
			// the very commit that completes the revert is already exempt from re-correction.
			let typedWord = currentWordBuffer
			let decodeContext = currentDecodeSnapshot?.request.context ?? currentContextBuffer
			resolveManualFix(typedWord)
			var correction = applyAutocorrectIfNeeded()
			if correction == nil, activeLanguageMode == .english {
				engine.learnTouchProfile(word: typedWord, taps: wordTaps)
			}
			let committedWord = correction?.corrected ?? typedWord
			recordCommitMetrics(committedWord, autocorrected: correction != nil)
			// Never learn from secure fields — password fragments must not enter the
			// persisted personal model. (Stats ride the same gate: password words
			// shouldn't count toward streaks either.)
			if !committedWord.isEmpty, !isSecureField {
				learnCommittedWord(context: decodeContext, word: committedWord)
				KBStats.noteCommitted(glided: false)
			}
			// Punctuation right after an auto-inserted space: delete the space first
			// so punctuation lands directly after the word ("word." not "word .").
			// Only when the space was ours (lastCorrection?.trailing) — never touches
			// a space the user explicitly typed.
			if ch != " ", ch != "\n", lastCorrection?.trailing == " " {
				textDocumentProxy.deleteBackward()
			}
			insertIntoHost(ch)
			noteProxyEdit()
			correction?.trailing = ch
			lastCorrection = correction
			advanceWordSession()
			wordTaps.removeAll(keepingCapacity: true)
			currentWordBuffer = ""
		} else {
			lastCorrection = nil
			insertIntoHost(ch)
			noteProxyEdit()
			advanceWordSession()
			wordTaps.removeAll(keepingCapacity: true)
			currentWordBuffer = ""
		}
		updateAutoShift()
		scheduleSuggestions()
	}

	func handleKeyOutput(_ output: KeyOutput, tap: KeyTap?) {
		if case .text(let text) = output {
			handleInsert(text, tap: tap)
			return
		}
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
		guard activeLanguageMode == .telugu, !isSecureField else { return }
		noteTap()          // Telugu composition key (.text keys are counted inside handleInsert)
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		let before = textDocumentProxy.documentContextBeforeInput ?? ""
		let edit = TeluguComposer.edit(for: output, contextBeforeInput: before)
		guard edit.deleteBackwardCount > 0 || !edit.insertion.isEmpty else { return }
		for _ in 0..<edit.deleteBackwardCount { textDocumentProxy.deleteBackward() }
		if !edit.insertion.isEmpty { insertIntoHost(edit.insertion) }
		noteProxyEdit()
		lastTeluguKeyContext = before
		lastCorrection = nil
		wordTaps.removeAll(keepingCapacity: true)
		currentWordBuffer = trailingWord(applying: edit, to: before)
		updateAutoShift()
		scheduleSuggestions()
	}

	func trailingWord(applying edit: TeluguHostEdit, to context: String) -> String {
		var simulated = context
		for _ in 0..<edit.deleteBackwardCount where !simulated.isEmpty { simulated.removeLast() }
		simulated.append(contentsOf: edit.insertion)
		return trailingWord(simulated)
	}

	/// Long-press alternatives replace the base glyph that was already inserted on
	/// touch-down. Keep the host edit first, then revise local touch/decode identity.
	func handleReplaceLastInput(base: String, with replacement: String) {
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
		guard !replacement.isEmpty else { return }
		if activeLanguageMode == .telugu, let originalContext = lastTeluguKeyContext {
			let normalizedBase = TeluguComposer.normalized(base)
			let normalizedReplacement = TeluguComposer.normalized(replacement)
			let baseScalars = Array(normalizedBase.unicodeScalars)
			let replacementScalars = Array(normalizedReplacement.unicodeScalars)
			if replacementScalars.starts(with: baseScalars) {
				let suffix = replacementScalars.dropFirst(baseScalars.count)
					.map(String.init).joined()
				if !suffix.isEmpty { insertIntoHost(suffix) }
			} else {
				// Pack-defined replacements that are not base+suffix are restricted to
				// standalone keys (for example Latin/Telugu digits).
				textDocumentProxy.deleteBackward()
				insertIntoHost(normalizedReplacement)
			}
			noteProxyEdit()
			currentWordBuffer = trailingWord(originalContext + normalizedReplacement)
			wordTaps.removeAll(keepingCapacity: true)
			lastCorrection = nil
			updateAutoShift()
			scheduleSuggestions()
			return
		}
		textDocumentProxy.deleteBackward()
		insertIntoHost(replacement)
		noteProxyEdit()
		if !currentWordBuffer.isEmpty,
		   replacement.allSatisfy({ isWordChar($0) }) {
			currentWordBuffer.removeLast()
			currentWordBuffer.append(contentsOf: replacement.map(canonical))
			if !wordTaps.isEmpty { wordTaps.removeLast() }
			wordTaps.append(nil)
		} else {
			currentWordBuffer = ""
			wordTaps.removeAll(keepingCapacity: true)
		}
		lastCorrection = nil
		updateAutoShift()
		scheduleSuggestions()
	}


	/// Space was inserted immediately on touch-down. Once the hold threshold wins,
	/// retract only that provisional space and freeze decoding until movement ends.
	func beginCursorMode() {
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
		guard !cursorModeActive else { return }
		cursorModeActive = true
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		lastCorrection = nil
		if textDocumentProxy.documentContextBeforeInput?.hasSuffix(" ") == true {
			textDocumentProxy.deleteBackward()
			noteProxyEdit()
		}
		advanceWordSession()
		currentWordBuffer = ""
		currentContextBuffer.removeAll(keepingCapacity: true)
		wordTaps.removeAll(keepingCapacity: true)
		resetEraseTracking()
		invalidateSuggestionRequests(cancelEngineWork: true)
		setSuggestionBar([])
	}

	func moveCursor(by offset: Int) {
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
		guard cursorModeActive, offset != 0 else { return }
		textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
		noteProxyEdit()
	}

	func endCursorMode() {
		guard cursorModeActive else { return }
		cursorModeActive = false
		advanceWordSession()
		updateAutoShift()
		scheduleSuggestions()
	}

	func handleReturn() {
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
		noteTap()
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		let typedWord = currentWordBuffer
		let decodeContext = currentDecodeSnapshot?.request.context ?? currentContextBuffer
		resolveManualFix(typedWord)
		var correction = applyAutocorrectIfNeeded()
		if correction == nil, activeLanguageMode == .english {
			engine.learnTouchProfile(word: typedWord, taps: wordTaps)
		}
		let committedWord = correction?.corrected ?? typedWord
		recordCommitMetrics(committedWord, autocorrected: correction != nil)
		if !committedWord.isEmpty, !isSecureField {
			learnCommittedWord(context: decodeContext, word: committedWord)
			KBStats.noteCommitted(glided: false)
		}
		insertIntoHost("\n")
		noteProxyEdit()
        if readHostDocument()?.isEmpty == true {
            resetDocumentPresentation()
            scheduleSuggestions()
            updateAutoShift()
            return
        }
		correction?.trailing = "\n"
		lastCorrection = correction
		advanceWordSession()
		wordTaps.removeAll(keepingCapacity: true)
		currentWordBuffer = ""
		updateAutoShift()
		scheduleSuggestions()
	}
}
