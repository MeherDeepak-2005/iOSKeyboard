import UIKit

extension KeyboardViewController {
	// MARK: Glide typing

	/// The swipe lifted: decode → rerank → commit the winner (word + trailing space, with
	/// auto-space after letters and sentence-start capitalization), learn it, and leave the
	/// runner-up shapes on the bar as one-tap swaps. A single Backspace removes the whole
	/// glided word (`Correction` with empty original). Nothing commits on a rejected swipe.
	func handleGlide(_ path: [CGPoint], _ times: [TimeInterval], _ layout: GlideLayout) {
        let liftDocument = readHostDocument()
		let liftAt = ProcessInfo.processInfo.systemUptime
		let sessionID = activeGlideSessionID
		let publishedPrediction: GlidePrediction? = {
			guard let shown = displayedGlidePrediction,
				  shown.sessionID == sessionID,
				  path.count >= shown.pointCount,
				  let finalEndpoint = path.last else { return nil }
			var addedArc: CGFloat = 0
			let start = max(1, shown.pointCount)
			if start < path.count {
				for index in start..<path.count {
					addedArc += hypot(path[index].x - path[index - 1].x,
						path[index].y - path[index - 1].y)
				}
			}
			let endpointDelta = hypot(finalEndpoint.x - shown.endpoint.x,
				finalEndpoint.y - shown.endpoint.y)
			let materialThreshold = max(6, shown.pitch * 0.28)
			guard addedArc <= materialThreshold, endpointDelta <= materialThreshold else { return nil }
			return shown.prediction
		}()
		// Context cannot change while this finger is down. Reuse the one snapshot taken
		// when Glide began instead of making another host XPC read on lift. Never inspect
		// document text for a secure field.
		let secure = isSecureField
		let before = secure ? "" : activeGlideDocumentContext ?? textDocumentProxy.documentContextBeforeInput ?? ""
		let context = activeGlideDocumentContext == nil ? contextWords(before, max: 8) : activeGlideContext
		// Cancel any tap decode the provisional start letter triggered. The engine's
		// generation ticket also cooperatively stops a trie walk already in progress.
		invalidateSuggestionRequests(cancelEngineWork: true)
		resetEraseTracking()
		wordTaps.removeAll(keepingCapacity: true)
		guard !secure else { return }                    // no gliding passwords
		resolveCorrectionAsAccepted()
		resolveGlideUnverified()
		if publishedPrediction == nil, let sessionID {
			endGlidePreviewUI(clearStrip: false, cancelEngineSession: false)
			engine.finishGlideSession(sessionID, path: path, times: times, layout: layout) {
				[weak self] word, alternatives in
				guard let self else { return }
				guard let word else { self.scheduleSuggestions(); return }
				self.commitGlidedWord(word, alternatives: alternatives, context: context,
					documentContext: before, expectedDocument: liftDocument, liftAt: liftAt)
			}
			return
		}
		cancelGlidePreview(clearStrip: false)
		engine.glide(path: path, times: times, layout: layout, context: context,
			publishedPrediction: publishedPrediction) { [weak self] word, alternatives in
			guard let self else { return }
			guard let word else { self.scheduleSuggestions(); return }
			self.commitGlidedWord(word, alternatives: alternatives, context: context,
							   documentContext: before, expectedDocument: liftDocument, liftAt: liftAt)
		}
	}

	private func commitGlidedWord(_ word: String, alternatives: [String], context: [String]? = nil,
							   documentContext: String? = nil, expectedDocument: HostDocumentSnapshot? = nil,
                                   liftAt: TimeInterval) {
        guard let expectedDocument, let current = readHostDocument(),
            current.isAvailable, expectedDocument.matches(current) else {
            reconcileHostDocument()
            return
        }
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
        if let documentContext,
            textDocumentProxy.documentContextBeforeInput != documentContext { return }
		let ctx = documentContext ?? textDocumentProxy.documentContextBeforeInput ?? ""
		let autoShift = shouldAutoShift(ctx)
		let display = SuggestionCasePolicy.display(word, sentenceStart: autoShift)
		var text = display + " "
		if let last = ctx.last, isWordChar(last) { text = " " + text }
		insertIntoHost(text)
		noteProxyEdit()
		KBDiagnostics.logGlideCommit(ms: (ProcessInfo.processInfo.systemUptime - liftAt) * 1_000)

		// Everything below is bookkeeping after the visible insertion.
		// A glide finalizes a whole word from the one touch-down tap already counted in
		// handleInsert — so it is not re-counted as a tap here, which is exactly what drops
		// keystrokes-per-character below 1.0.
		recordCommitMetrics(word, autocorrected: false, source: "glide-unverified")
		learnCommittedWord(context: context ?? contextWords(ctx, max: 8), word: word)
		lastCorrection = Correction(original: "", corrected: display, trailing: " ", fromAutocorrect: false, recordedWordSessionID: wordSessionID)
		advanceWordSession()
		mode = .glided(display)
		pendingGlideVerdict = true
		KBStats.cancel(pendingGlideStatsID)
		pendingGlideStatsID = KBStats.noteProvisional(glided: true)
		let displayedAlternatives = alternatives.map {
			SuggestionCasePolicy.display($0, sentenceStart: autoShift)
		}
		setGlideSuggestionBar(winner: display, alternatives: displayedAlternatives)
		updateAutoShift()
	}

	func beginGlidePreview() {
        beginKeyboardEdit()
        defer { endKeyboardEdit() }
		// Starting another gesture leaves the previous result unlabelled.
		resolveGlideUnverified()
		invalidateSuggestionRequests(cancelEngineWork: true)
		glidePreviewGeneration &+= 1
		pendingGlidePreview = nil
		displayedGlidePrediction = nil
		engine.cancelGlidePreviews()
		guard hostConnectionReady, !isSecureField else {
			glidePreviewEnabled = false
			activeGlideDocumentContext = nil
			activeGlideContext.removeAll(keepingCapacity: true)
			activeGlideAutoShift = false
			keyboard?.setGlidePreview(nil)
			return
		}
		// Letter taps commit on touch-down for sub-frame latency. Crossing the Glide
		// threshold reclassifies that touch, so retract exactly that provisional start
		// letter before capturing context or decoding the path.
		textDocumentProxy.deleteBackward()
		noteProxyEdit()
		if !wordTaps.isEmpty { wordTaps.removeLast() }
		if !currentWordBuffer.isEmpty { currentWordBuffer.removeLast() }
		if !typingTrace.keystrokes.isEmpty { typingTrace.keystrokes.removeLast() }
		recordTyping("glide-began", evidence: "retract-provisional-letter")
		glidePreviewEnabled = true
		let before = textDocumentProxy.documentContextBeforeInput ?? ""
		activeGlideDocumentContext = before
		activeGlideContext = contextWords(before, max: 8)
		activeGlideAutoShift = shouldAutoShift(before)
		activeGlideSessionID = engine.beginGlideSession(context: activeGlideContext)
	}

	func handleGlidePreview(_ path: [CGPoint], _ times: [TimeInterval], _ layout: GlideLayout) {
		guard glidePreviewEnabled else { return }
		glidePreviewSequence &+= 1
		pendingGlidePreview = GlidePreviewRequest(
			path: path,
			times: times,
			layout: layout,
			sequence: glidePreviewSequence
		)
		startNextGlidePreviewIfNeeded()
	}

	private func startNextGlidePreviewIfNeeded() {
		guard !glidePreviewInFlight, let request = pendingGlidePreview,
			let sessionID = activeGlideSessionID else { return }
		pendingGlidePreview = nil
		glidePreviewInFlight = true
		let generation = glidePreviewGeneration
		let capitalize = activeGlideAutoShift
		engine.updateGlideSession(sessionID, path: request.path, times: request.times,
			layout: request.layout) { [weak self] update in
			guard let self else { return }
			self.glidePreviewInFlight = false
			guard generation == self.glidePreviewGeneration else {
				self.startNextGlidePreviewIfNeeded()
				return
			}
			// A newer path snapshot may have arrived while this decode was running.
			// Never flash the older winner; move directly to the newest queued path.
			if request.sequence == self.glidePreviewSequence,
			   let update, update.sessionID == self.activeGlideSessionID {
				let prediction = update.prediction
				let word = SuggestionCasePolicy.display(prediction.word,
					sentenceStart: capitalize)
				let alternatives = prediction.alternatives.prefix(2).map {
					SuggestionCasePolicy.display($0, sentenceStart: capitalize)
				}
				if let endpoint = request.path.last {
					self.displayedGlidePrediction = DisplayedGlidePrediction(
						prediction: prediction,
						sessionID: update.sessionID,
						revision: update.revision,
						pointCount: request.path.count,
						endpoint: endpoint,
						pitch: request.layout.xPitch)
				}
				self.keyboard?.setGlidePreview(word, alternatives: alternatives,
					confident: prediction.margin >= 0.75)
			} else if request.sequence == self.glidePreviewSequence {
				self.displayedGlidePrediction = nil
				self.keyboard?.setGlidePreview(nil)
			}
			self.startNextGlidePreviewIfNeeded()
		}
	}

	func cancelGlidePreview(clearStrip: Bool) {
		endGlidePreviewUI(clearStrip: clearStrip, cancelEngineSession: true)
	}

	private func endGlidePreviewUI(clearStrip: Bool, cancelEngineSession: Bool) {
		glidePreviewGeneration &+= 1
		glidePreviewSequence &+= 1
		pendingGlidePreview = nil
		if cancelEngineSession, let sessionID = activeGlideSessionID {
			engine.cancelGlideSession(sessionID)
		}
		activeGlideSessionID = nil
		activeGlideDocumentContext = nil
		activeGlideContext.removeAll(keepingCapacity: true)
		activeGlideAutoShift = false
		glidePreviewEnabled = false
		displayedGlidePrediction = nil
		if clearStrip { keyboard?.setGlidePreview(nil) }
	}
}
