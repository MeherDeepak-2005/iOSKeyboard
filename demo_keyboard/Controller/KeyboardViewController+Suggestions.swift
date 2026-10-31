import UIKit

extension KeyboardViewController {
	// MARK: Universal suggestion strip
	// Keep the same strip and tools available in every host field. Prediction and
	// automatic replacement are separate: secure text is never decoded or learned,
	// and showing suggestions must not start rewriting URLs, addresses or numbers.




	/// Resolve once per presentation so the strip and tools retain stable geometry.
	func resolveSuggestionModeIfNeeded() {
		guard !suggestionModeResolved else { return }
		suggestionModeResolved = true

		// Previous field-based hiding, retained for future reference:
		// let allowed = autocorrectionAllowed
		// suggestionsVisible = allowed
		// keyboard?.setShowsSuggestions(allowed)
		// if !allowed { setSuggestionBar([]) }

		suggestionsVisible = true
		keyboard?.setShowsSuggestions(true)
		if let h = heightConstraint, let kb = keyboard, h.constant != kb.keyboardHeight {
			h.constant = kb.keyboardHeight
		}
	}

	func updateActionKey() {
		keyboard?.setActionTitle(actionTitle(for: textDocumentProxy.returnKeyType ?? .default))
		let automatic = textDocumentProxy.enablesReturnKeyAutomatically ?? false
		keyboard?.setActionEnabled(!automatic || textDocumentProxy.hasText)
	}

	@discardableResult
	func updateInputTraits() -> Bool {
		let kind: KeyboardInputKind
		switch textDocumentProxy.keyboardType ?? .default {
		case .emailAddress: kind = .email
		case .URL: kind = .url
		case .webSearch: kind = .webSearch
		case .twitter: kind = .twitter
		case .numbersAndPunctuation: kind = .numbersAndPunctuation
		case .numberPad, .asciiCapableNumberPad: kind = .numberPad
		case .decimalPad: kind = .decimalPad
		case .phonePad: kind = .phonePad
		default: kind = .standard
		}
		guard kind != fieldInputKind else { return false }
		fieldInputKind = kind
		layoutRevision &+= 1
		keyboard?.setInputKind(kind)
		keyboard?.glideEnabled = activeLanguageMode == .english
		return true
	}


	/// Preserve the durable preference while resolving a safe mode for this extension
	/// session. This may hash language resources, so callers are deliberately limited to
	/// lifecycle/configuration callbacks rather than key handlers.
	@discardableResult
	func refreshConfiguredLanguageMode() -> Bool {
		let preferred = KBSettings.preferredLanguageMode
		let available = preferred.isRuntimeAvailable
		let changed = preferred != configuredLanguageMode
			|| available != configuredLanguageModeAvailable
		configuredLanguageMode = preferred
		configuredLanguageModeAvailable = available
		return changed
	}

	/// Map the host text field's Return key style to a label. nil → plain newline glyph.
	private func actionTitle(for type: UIReturnKeyType) -> String? {
		switch type {
		case .go:                       return "go"
		case .search, .google, .yahoo:  return "search"
		case .send:                     return "send"
		case .join:                     return "join"
		case .next:                     return "next"
		case .route:                    return "route"
		case .done:                     return "done"
		case .continue:                 return "continue"
		case .emergencyCall:            return "SOS"
		case .default:                  return nil   // plain return → newline glyph
		@unknown default:               return nil
		}
	}

	// MARK: Suggestions — versioned, background-computed

	func scheduleSuggestions() {
		generation &+= 1
		let requestGeneration = generation
		refreshSuggestions(requestGeneration: requestGeneration)
	}

	func invalidateSuggestionRequests(cancelEngineWork: Bool = false) {
		generation &+= 1
		decodeSnapshot = nil
		presentedDecodeSnapshot = nil
		if cancelEngineWork { engine.cancelSuggestions() }
	}

	private func refreshSuggestions(requestGeneration: UInt64) {
		guard requestGeneration == generation else { return }
		guard suggestionsAllowed else {
			decodeSnapshot = nil
			presentedDecodeSnapshot = nil
			setSuggestionBar([])
			return
		}
        let document = readHostDocument()
        if documentReconciler.editDepth == 0, reconcileHostDocument(document) { return }
        guard let document, document.isAvailable else {
            setSuggestionBar([])
            return
        }
		let gen = requestGeneration
		let ctx = document.before ?? ""
		let current = trailingWord(ctx)
		let revert = !document.isEmpty && lastCorrection?.fromAutocorrect == true ? lastCorrection?.original : nil
		let context = contextWords(ctx, max: 8)
		currentWordBuffer = current
		currentContextBuffer = context
		let request = makeDecodeRequest(currentWord: current, context: context, generation: gen)
		engine.decode(request) { [weak self] snapshot in
			guard let self, gen == self.generation,
				  snapshot.isValid(for: request) else { return }
            guard self.hostConnectionReady, let currentDocument = self.readHostDocument(),
                currentDocument.isAvailable, document.matches(currentDocument) else {
                self.reconcileHostDocument()
                return
            }
            self.presentationDocument = document
			let presented = SuggestionCasePolicy.present(snapshot,
				sentenceStart: self.shouldAutoShift(ctx))
			self.decodeSnapshot = snapshot
			self.presentedDecodeSnapshot = presented
			self.keyboard.setKeyPriors(snapshot.nextCharacterPriors)
			if current.isEmpty {
				if let revert {
					self.mode = .revert(revert)
					self.setSuggestionBar([revert] + presented.suggestions.prefix(2).map(\.text))
				} else {
					self.mode = .predict
                    let words = presented.suggestions.map(\.text)
                    self.setSuggestionBar(words)
                    self.nwpPredictedTop3 = Set(words.prefix(3).map { $0.lowercased() })
                    self.nwpPredictionArmed = !context.isEmpty && !self.nwpPredictedTop3.isEmpty
				}
			} else {
				self.mode = .complete(current)
				let exactPrimary = presented.suggestions.first?.isExactTypedCandidate == true
				self.setSuggestionBar(presented.suggestions.map(\.text), typedPrefix: current,
					highlightPrimary: presented.correction != nil || exactPrimary)
			}
		}
	}

	func makeDecodeRequest(currentWord: String, context: [String],
								   generation: UInt64) -> DecodeRequest {
		let taps = wordTaps.count == currentWord.count ? wordTaps : nil
		return DecodeRequest(fieldRevision: fieldRevision,
			documentRevision: documentRevision,
			wordSessionID: wordSessionID,
			generation: generation,
			layoutRevision: layoutRevision,
			currentWord: currentWord,
			context: context,
			taps: activeLanguageMode == .english ? taps : nil,
			languageMode: activeLanguageMode,
			requestedModelTier: wordSessionModelTier)
	}

	func setSuggestionBar(_ suggestions: [String], typedPrefix: String? = nil,
							  highlightPrimary: Bool = false) {
		suggestionPresentation = .ranked(words: suggestions, prefix: typedPrefix,
			highlightPrimary: highlightPrimary)
		keyboard?.setSuggestions(suggestions, typedPrefix: typedPrefix,
			highlightPrimary: highlightPrimary)
	}

	func setGlideSuggestionBar(winner: String, alternatives: [String]) {
        presentationDocument = readHostDocument()
		suggestionPresentation = .glide(winner: winner, alternatives: alternatives)
		keyboard?.setGlideResult(winner, alternatives: alternatives)
	}

	func applySuggestionPresentation(to keyboard: KeyboardView) {
		switch suggestionPresentation {
		case .ranked(let words, let prefix, let highlightPrimary):
			keyboard.setSuggestions(words, typedPrefix: prefix,
				highlightPrimary: highlightPrimary)
		case .glide(let winner, let alternatives):
			keyboard.setGlideResult(winner, alternatives: alternatives)
		}
	}

	func uniqueWords(_ words: [String], excluding excluded: String) -> [String] {
		var seen = Set([excluded.lowercased()])
		return words.filter { seen.insert($0.lowercased()).inserted }
	}
}
