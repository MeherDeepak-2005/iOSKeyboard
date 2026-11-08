import UIKit

extension KeyboardView {
	// MARK: Emoji page (overlay collection view, not a key grid)

	func showEmoji() {
		// From the letters (not back from a search or another panel): an open, for the A/B counts.
		let opening = page == .letters && !isEmojiSearching && !isMediaSearching
		if isEmojiSearching { tearDownEmojiSearch() }   // emoji key pressed mid-search
		guard page != .emoji else { return }
		// Coming from the GIF/sticker panel: the switch thumb slides back from that tab.
		let previous = mediaView.map { PanelTab($0.kind) }
		discardMediaPanel()
		page = .emoji
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = []
		letterKeys = []                               // the removed keys are freed now, not when the panel closes (reload refills it)
		accessibilityElements = nil                   // the panel, not the removed keys
		suggestionBar.isHidden = true
		let ev = EmojiKeyboardView(theme: theme, showsGlobe: showsGlobe, from: previous)
		ev.onPick = { [weak self] in self?.onInsert?($0, nil) }
		ev.onDelete = { [weak self] in self?.onDelete?() }
		ev.onNextKeyboard = { [weak self] in self?.onNextKeyboard?() }
		ev.onABC = { [weak self] in self?.hideEmoji() }
		ev.onSearch = { [weak self] in self?.showEmojiSearch() }
		ev.onGIF = { [weak self] in self?.onOpenMedia?(.gifs) }
		ev.onStickers = { [weak self] in self?.onOpenMedia?(.stickers) }
		addSubview(ev)
		emojiView = ev
		onHeightChange?(true)                         // the taller browse height
		setNeedsLayout()
		if previous != nil { returnPanelMemory() }    // the GIF/sticker panel just went
		KBDiagnostics.recorder.sample()               // emoji page footprint shows up in health telemetry
		KBDiagnostics.noteSurface("emoji")
		if opening { KBDiagnostics.notePanelEvent(.open) }
	}
	private func hideEmoji() {
		emojiView?.removeFromSuperview()
		emojiView = nil
		page = .letters
		shift = .on                                   // sentences resume capitalized
		suggestionBar.isHidden = !showsSuggestions
		reload()
		onHeightChange?(true)                             // expansion released
		returnPanelMemory()
		KBDiagnostics.noteSurface("letters")
	}

	func showMedia(kind: KlipyKind, query: String? = nil, hasFullAccess: Bool) {
		mediaHasFullAccess = hasFullAccess
		let opening = page == .letters && !isEmojiSearching && !isMediaSearching
		if isEmojiSearching { tearDownEmojiSearch() }
		if isMediaSearching { tearDownMediaSearch() }
		let previous: PanelTab? = page == .emoji ? .emoji : nil
		emojiView?.removeFromSuperview(); emojiView = nil
		discardMediaPanel()
		page = .media
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = []
		letterKeys = []                               // the removed keys are freed now, not when the panel closes (reload refills it)
		accessibilityElements = nil                   // the panel, not the removed keys
		suggestionBar.isHidden = true
		let panel = MediaPanelView(theme: theme, showsGlobe: showsGlobe,
			hasFullAccess: hasFullAccess, kind: kind, query: query, from: previous)
		panel.onABC = { [weak self] in self?.hideMedia() }
		panel.onEmoji = { [weak self] in self?.showEmoji() }
		panel.onNextKeyboard = { [weak self] in self?.onNextKeyboard?() }
		panel.onSearch = { [weak self] in self?.showMediaSearch(kind: $0) }
		addSubview(panel)
		mediaView = panel
		onHeightChange?(true)
		setNeedsLayout()
		returnPanelMemory()                           // the emoji page or previous panel just went
		KBDiagnostics.noteSurface(kind.rawValue)
		if opening { KBDiagnostics.notePanelEvent(.open) }
	}

	private func hideMedia() {
		discardMediaPanel()
		if isMediaSearching { tearDownMediaSearch() }
		page = .letters
		suggestionBar.isHidden = !showsSuggestions
		reload()
		onHeightChange?(true)
		returnPanelMemory()
		KBDiagnostics.noteSurface("letters")
	}

	// MARK: Clipboard panel (overlay at deck height — the emoji-page pattern)

	func showClipboard(hasFullAccess: Bool) {
		if isEmojiSearching { tearDownEmojiSearch() }
		if isMediaSearching { tearDownMediaSearch() }
		emojiView?.removeFromSuperview(); emojiView = nil
		discardMediaPanel()
		guard page != .clipboard else { return }
		page = .clipboard
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = []
		letterKeys = []                               // the removed keys are freed now, not when the panel closes (reload refills it)
		accessibilityElements = nil                   // the panel, not the removed keys
		suggestionBar.isHidden = true
		let panel = ClipboardPanelView(theme: theme, showsGlobe: showsGlobe, hasFullAccess: hasFullAccess)
		panel.onPick = { [weak self] in self?.onClipboardPick?($0) }
        panel.onPasteCurrent = { [weak self] in self?.onPaste?() }
		panel.onABC = { [weak self] in self?.hideClipboard() }
		panel.onNextKeyboard = { [weak self] in self?.onNextKeyboard?() }
		addSubview(panel)
		clipboardView = panel
		onHeightChange?(true)
		setNeedsLayout()
		returnPanelMemory()
		KBDiagnostics.noteSurface("clipboard")
	}

	private func hideClipboard() {
		clipboardView?.removeFromSuperview()
		clipboardView = nil
		page = .letters
		shift = .on
		suggestionBar.isHidden = !showsSuggestions
		reload()
		onHeightChange?(true)
		returnPanelMemory()
		KBDiagnostics.noteSurface("letters")
	}

	private func showMediaSearch(kind: KlipyKind) {
		guard page == .media, !isMediaSearching else { return }
		discardMediaPanel()
		isMediaSearching = true
		mediaSearchKind = kind
		mediaQuery = ""
		page = .letters
		shift = .off
		suggestionBar.isHidden = true
		let header = EmojiSearchHeader(theme: theme)
		header.placeholder = kind == .gifs ? "Search GIFs" : "Search stickers"
		// The header's own emoji results row stays empty; the media strip owns that row.
		header.emptyStatus = ""
		header.noResultsStatus = ""
		header.onCancel = { [weak self] in self?.exitMediaSearch(submit: false) }
		header.onClear = { [weak self] in self?.mediaQuery = ""; self?.refreshMediaSearch() }
		addSubview(header)
		mediaSearchHeader = header
		let strip = MediaSearchStrip(theme: theme, kind: kind, hasFullAccess: mediaHasFullAccess)
		addSubview(strip)
		mediaSearchStrip = strip
		reload(); refreshMediaSearch(); onHeightChange?(true); setNeedsLayout()
	}

	private func refreshMediaSearch() {
		mediaSearchHeader?.update(query: mediaQuery, results: [], showingRecents: true)
		mediaSearchStrip?.search(mediaQuery)
	}

	private func tearDownMediaSearch() {
		mediaSearchHeader?.removeFromSuperview(); mediaSearchHeader = nil
		mediaSearchStrip?.prepareForDismissal()
		mediaSearchStrip?.removeFromSuperview(); mediaSearchStrip = nil
		isMediaSearching = false
	}

	private func discardMediaPanel() {
		mediaView?.prepareForDismissal()
		mediaView?.removeFromSuperview()
		mediaView = nil
	}

	/// Once a panel has gone, hand the memory its views and images freed back to iOS. The
	/// allocator otherwise keeps those pages for reuse, and jetsam still counts them against
	/// the keyboard. Off the main thread, after the panel's deferred releases have run.
	private func returnPanelMemory() {
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
			_ = malloc_zone_pressure_relief(nil, 0)
		}
	}

	private func exitMediaSearch(submit: Bool) {
		guard isMediaSearching else { return }
		let query = mediaQuery.trimmingCharacters(in: .whitespacesAndNewlines)
		mediaQuery = ""
		tearDownMediaSearch()
		showMedia(kind: mediaSearchKind, query: submit && !query.isEmpty ? query : nil,
			hasFullAccess: mediaHasFullAccess)
	}

	// MARK: Emoji search — the real deck types into a query (no mini keyboard)

	private func showEmojiSearch() {
		guard page == .emoji, !isEmojiSearching else { return }
		emojiView?.removeFromSuperview()
		emojiView = nil
		isEmojiSearching = true
		emojiQuery = ""
		page = .letters
		shift = .off                                  // emoji keywords are lowercase
		suggestionBar.isHidden = true
		let header = EmojiSearchHeader(theme: theme)
		header.onCancel = { [weak self] in self?.exitEmojiSearch(backToEmoji: true) }
		header.onClear = { [weak self] in
			guard let self else { return }
			emojiQuery = ""
			refreshEmojiSearch()
		}
		header.onPick = { [weak self] e in
			// Insert into the HOST document (stays in search, Gboard-style).
			KBDiagnostics.notePanelEvent(.pick)
			self?.onInsert?(e, nil)
			KBEmojiRecents.add(e)
		}
		addSubview(header)
		emojiSearchHeader = header
		reload()
		refreshEmojiSearch()
		onHeightChange?(true)
		setNeedsLayout()
	}

	/// Remove the search chrome without deciding what comes next (caller picks the page).
	private func tearDownEmojiSearch() {
		emojiSearchHeader?.removeFromSuperview()
		emojiSearchHeader = nil
		isEmojiSearching = false
		emojiQuery = ""
	}

	private func exitEmojiSearch(backToEmoji: Bool) {
		guard isEmojiSearching else { return }
		tearDownEmojiSearch()
		if backToEmoji {
			showEmoji()                               // fires onHeightChange itself
		} else {
			suggestionBar.isHidden = !showsSuggestions
			reload()
			onHeightChange?(true)
			setNeedsLayout()
		}
	}

	/// The user touched the host document directly (tapped the input field, moved the
	/// cursor): snap the emoji page or emoji search back to
	/// the letter deck, stock-style. Returns true when something was actually dismissed
	/// (the controller refreshes the suggestion bar only then).
	@discardableResult
	func dismissOverlaysIfActive() -> Bool {
		if isEmojiSearching { exitEmojiSearch(backToEmoji: false); return true }
		if isMediaSearching { tearDownMediaSearch(); page = .letters; reload(); return true }
		if page == .emoji { hideEmoji(); return true }
		if page == .media { hideMedia(); return true }
		if page == .clipboard { hideClipboard(); return true }
		return false
	}

	/// Keyboard extensions can be terminated without a recoverable warning. If one
	/// does arrive, remove media immediately and release the clean atlas mapping; the
	/// next emoji open remaps the already-generated file.
	func releaseTransientMediaForMemoryPressure() {
		_ = dismissOverlaysIfActive()
		EmojiAtlas.purgeShared()
		balloonPool.removeAll()
	}


	func refreshEmojiSearch() {
		guard let header = emojiSearchHeader else { return }
		let results = emojiQuery.isEmpty
			? KBEmojiRecents.all()
			: (EmojiStore.bundled?.search(emojiQuery) ?? [])
		header.update(query: emojiQuery, results: results, showingRecents: emojiQuery.isEmpty)
	}

	// While emoji search is active the deck's keys edit the query; otherwise they
	// pass straight through to the controller. All key actions route through these.
	func routeInsert(_ s: String, _ tap: KeyTap?) {
        suggestionBar.dismissTools()
		if isEmojiSearching {
			emojiQuery += s.lowercased()
			refreshEmojiSearch()
			return
		}
		if isMediaSearching {
			mediaQuery += s.lowercased()
			refreshMediaSearch()
			return
		}
		onInsert?(s, tap)
	}
	func routeOutput(_ output: KeyOutput, _ tap: KeyTap?) {
        suggestionBar.dismissTools()
		if isEmojiSearching || isMediaSearching {
			if case .text(let text) = output { routeInsert(text, tap) }
			return
		}
		onKeyOutput?(output, tap)
	}
	func routeDelete() {
        suggestionBar.dismissTools()
		if isEmojiSearching {
			// A live query: delete edits the query, never the host document.
			if !emojiQuery.isEmpty { emojiQuery.removeLast(); refreshEmojiSearch(); return }
			// Empty query: fall through to the host — the emoji just inserted from the
			// results strip stays erasable without leaving search.
		}
		if isMediaSearching, !mediaQuery.isEmpty {
			mediaQuery.removeLast(); refreshMediaSearch(); return
		}
		onDelete?()
	}
	func routeReturn() {
        suggestionBar.dismissTools()
		if isEmojiSearching { exitEmojiSearch(backToEmoji: true); return }
		if isMediaSearching { exitMediaSearch(submit: true); return }
		onReturn?()
	}

	/// After a space on the numbers/symbols page, snap back to letters (stock behavior).
	/// Guarded so it is a no-op — and never rebuilds — during ordinary letter typing.
	func returnToLettersFromSymbolPage() {
		guard page == .numbers || page == .symbols else { return }
		page = .letters
		reload()
	}
}
