import UIKit

extension KeyboardViewController {
	// MARK: Contextual action key — mirrors the host field's Return key (go / search / send …)

    func handleHostCallback() {
        let firstConnection = hostConnectionDidBecomeAvailable()
        let traitsChanged = updateInputTraits()
        let changed = reconcileHostDocument()
        if traitsChanged && !changed { resetDocumentPresentation() }
        if firstConnection || traitsChanged { scheduleSuggestions() }
        updateActionKey()
        updateAutoShift()
    }

    func readHostDocument() -> HostDocumentSnapshot? {
        guard hostConnectionReady, !isSecureField else { return nil }
        let proxy = textDocumentProxy
        return HostDocumentSnapshot(documentID: proxy.documentIdentifier,
            before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
            selection: proxy.selectedText, hasText: proxy.hasText)
    }

    /// Returns true after invalidating a stale document, including a clear inside
    /// what used to be the 500 ms suppression window.
    @discardableResult
    func reconcileHostDocument(_ state: HostDocumentSnapshot? = nil) -> Bool {
        let change = documentReconciler.observe(state ?? readHostDocument())
        switch change {
        case .changed, .cleared:
            resetDocumentPresentation()
            keyboard?.dismissOverlaysIfActive()
            scheduleSuggestions()
            updateActionKey()
            updateAutoShift()
            return true
        case .initial, .unchanged, .unavailable, .editing:
            updateRecoveryTimer()
            return false
        }
    }

    func resetDocumentPresentation() {
        invalidateDocumentSession()
        cancelGlidePreview(clearStrip: true)
        lastCorrection = nil
        recentCorrections.removeAll(keepingCapacity: true)
        resetEraseTracking()
        lastSpaceAt = 0
        resolveGlideUnverified()
        cursorModeActive = false
        nwpPredictedTop3.removeAll(keepingCapacity: true)
        nwpPredictionArmed = false
        mode = .predict
        presentationDocument = nil
        keyboard?.setKeyPriors([:])
        keyboard?.dismissTools()
        setSuggestionBar([])
    }

    private func updateRecoveryTimer() {
        let needed = hostConnectionReady && suggestionsAllowed && documentReconciler.needsRecovery
        if needed && recoveryMonitor == nil {
            recoveryMonitor = HostDocumentRecoveryMonitor { [weak self] in
                self?.reconcileHostDocument()
            }
        }
        recoveryMonitor?.setEnabled(needed)
    }

    /// Transactions suppress only reentrant callbacks from our own proxy calls.
    /// Their final observed state becomes the acknowledgement for later callbacks.
    func beginKeyboardEdit(reconcileFirst: Bool = true) {
        if reconcileFirst && documentReconciler.editDepth == 0 { reconcileHostDocument() }
        documentReconciler.beginKeyboardEdit()
        keyboard?.dismissTools()
    }

    func endKeyboardEdit() {
        let finalState = documentReconciler.editDepth == 1 ? readHostDocument() : nil
        var unexpectedInsertion = false
        if documentReconciler.editDepth == 1, let text = expectedLetterInsertion {
            expectedLetterInsertion = nil
            if let finalState, finalState.isAvailable {
                unexpectedInsertion = documentReconciler.snapshot?.acceptsInsertion(text, result: finalState) != true
            }
        }
        documentReconciler.endKeyboardEdit(finalState)
        if unexpectedInsertion || (finalState?.isEmpty == true && lastCorrection != nil) {
            resetDocumentPresentation()
            scheduleSuggestions()
        }
        updateRecoveryTimer()
    }

	/// UIInputViewController can be prewarmed without a live host connection, so proxy
	/// reads and prediction work start only after the host invokes an input callback.
	@discardableResult
	private func hostConnectionDidBecomeAvailable() -> Bool {
		let firstConnection = !hostConnectionReady
		if firstConnection {
			hostConnectionReady = true
			KBSettings.markKeyboardObserved(fullAccess: hasFullAccess)
			// Resolve the universal strip before the possible globe rebuild. The rebuilt
			// view reuses the same geometry, keeping the first connected frame stable.
			resolveSuggestionModeIfNeeded()
			let requiresSwitchKey = needsInputModeSwitchKey
			if showsGlobe != requiresSwitchKey {
				showsGlobe = requiresSwitchKey
				buildKeyboard()
			}
		}
		keyboard?.isUserInteractionEnabled = true
		keyboard?.accessibilityElementsHidden = false
		resolveSuggestionModeIfNeeded()

		if !supplementaryLexiconRequested {
			supplementaryLexiconRequested = true
			requestSupplementaryLexicon { [weak self] lexicon in
				self?.engine.importSupplementaryLexicon(lexicon.entries.map(\.documentText))
			}
		}
		if firstConnection {
			updateActionKey()
			updateAutoShift()
		}
		return firstConnection
	}
}
