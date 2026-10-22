import Foundation
import Testing
import UIKit
@testable import keyboard

@MainActor
struct KeyboardConsistencyTests {
    private func state(_ before: String? = "typo", after: String? = "", selection: String? = nil,
                       hasText: Bool = true, id: UUID) -> HostDocumentSnapshot {
        .init(documentID: id, before: before, after: after, selection: selection, hasText: hasText)
    }

    @Test func immediateClearAfterOwnEditAndDuplicateCallbacks() {
        let id = UUID()
        var tracker = HostDocumentReconciler()
        let typed = state(id: id)
        #expect(tracker.observe(state("typ", id: id)) == .initial)
        tracker.beginKeyboardEdit()
        #expect(tracker.observe(typed) == .editing)
        tracker.endKeyboardEdit(typed)
        #expect(tracker.observe(typed) == .unchanged)
        #expect(tracker.observe(typed) == .unchanged)
        // No clock advance between the keyboard edit and the host's Send action.
        #expect(tracker.observe(state(nil, after: nil, hasText: false, id: id)) == .cleared)
        #expect(!tracker.needsRecovery)
        #expect(tracker.observe(state("", hasText: false, id: id)) == .unchanged)
    }

    @Test func cursorSelectionAndDocumentIdentityAreChanges() {
        let id = UUID()
        var tracker = HostDocumentReconciler()
        let typed = state(id: id)
        #expect(tracker.observe(typed) == .initial)
        let start = state("", after: "typo", id: id)
        #expect(tracker.observe(start) == .changed)
        #expect(!start.isEmpty)
        #expect(tracker.observe(state("", after: "typo", selection: "typo", id: id)) == .changed)
        #expect(tracker.observe(state(id: UUID())) == .changed)
        #expect(!typed.matches(start))
        #expect(!typed.matches(state(id: UUID())))
    }

    @Test func unavailableContextDoesNotMeanSentOrAcknowledgeAnEdit() {
        let id = UUID()
        var tracker = HostDocumentReconciler()
        let typed = state(id: id)
        #expect(tracker.observe(typed) == .initial)
        let unavailable = state(nil, after: nil, hasText: true, id: id)
        #expect(!unavailable.isAvailable)
        #expect(tracker.observe(unavailable) == .unavailable)
        #expect(tracker.snapshot == typed)
        tracker.beginKeyboardEdit()
        tracker.endKeyboardEdit(unavailable)
        #expect(tracker.snapshot == typed)
        #expect(tracker.observe(nil) == .unavailable)
        #expect(tracker.observe(state(nil, after: nil, id: UUID())) == .changed)
    }

    @Test func delayedResultCannotMatchClearedFieldOrAnotherDocument() {
        let id = UUID()
        let requestDocument = state(id: id)
        let cleared = state(nil, after: nil, hasText: false, id: id)
        #expect(!requestDocument.matches(cleared))
        #expect(!requestDocument.matches(state(id: UUID())))
        #expect(cleared.matches(state("", hasText: false, id: id)))
    }

    @Test func recoveryFindsClearWithoutCallbacksAndStops() async throws {
        let id = UUID()
        var tracker = HostDocumentReconciler()
        var host = state(id: id)
        #expect(tracker.observe(host) == .initial)
        var changes = 0
        var checks = 0
        let monitor = HostDocumentRecoveryMonitor {
            checks += 1
            if tracker.observe(host) == .cleared { changes += 1 }
        }
        monitor.setEnabled(tracker.needsRecovery)
        #expect(monitor.isRunning)
        host = state(nil, after: nil, hasText: false, id: id) // deliberately no callback
        try await Task.sleep(for: .milliseconds(450))
        #expect(changes == 1)
        #expect(checks >= 1)
        monitor.setEnabled(tracker.needsRecovery)
        #expect(!monitor.isRunning)
        let stoppedChecks = checks
        try await Task.sleep(for: .milliseconds(250))
        #expect(checks == stoppedChecks)
    }

    @Test func letterAcknowledgementDetectsClearsAndSupportsClippedContext() {
        let id = UUID()
        let previous = state("hello", id: id)
        #expect(previous.acceptsInsertion("w", result: state("hellow", id: id)))
        #expect(previous.acceptsInsertion("w", result: state("ellow", id: id)))
        #expect(!previous.acceptsInsertion("w", result: state("w", id: id)))
        #expect(!previous.acceptsInsertion("w", result: state("hellow", after: "changed", id: id)))
        #expect(!previous.acceptsInsertion("w", result: state("hellow", id: UUID())))
        #expect(state("don", id: id).acceptsInsertion("'", result: state("don’", id: id)))
        #expect(state(nil, after: nil, hasText: false, id: id)
            .acceptsInsertion("h", result: state("h", id: id)))
    }

    @Test func nestedKeyboardTransactionKeepsFinalState() {
        let id = UUID()
        var tracker = HostDocumentReconciler()
        _ = tracker.observe(state(id: id))
        tracker.beginKeyboardEdit()
        tracker.beginKeyboardEdit()
        tracker.endKeyboardEdit(nil)
        #expect(tracker.observe(state("replacement", id: id)) == .editing)
        tracker.endKeyboardEdit(state("replacement", id: id))
        #expect(tracker.observe(state("replacement", id: id)) == .unchanged)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func button(_ id: String, in view: UIView) throws -> UIButton {
        try #require(descendants(view).first { $0.accessibilityIdentifier == id } as? UIButton)
    }

    @Test func toolsPreserveFreshSuggestionsAndRouteAllFourActions() throws {
        let bar = SuggestionBar(theme: .preview(dark: false, accent: KBPalette.system, customTheme: nil))
        bar.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        bar.setSuggestions(["old", "older", "oldest"])
        bar.layoutIfNeeded()
        let tools = try button("suggestion.tools", in: bar)
        #expect(tools.frame.width == 44)
        #expect(!descendants(bar).contains { $0.accessibilityIdentifier == "suggestion.paste" })
        #expect(!descendants(bar).contains { $0.accessibilityIdentifier == "suggestion.clipboard" })
        tools.sendActions(for: .touchUpInside)
        #expect(bar.showingTools)
        bar.setSuggestions(["fresh", "new", "next"])
        #expect(bar.showingTools)
        #expect(try button("suggestion.primary", in: bar).isHidden)
        tools.sendActions(for: .touchUpInside)
        #expect(!bar.showingTools)
        #expect(try button("suggestion.primary", in: bar).title(for: .normal) == "fresh")
        var picked: [KeyboardTool] = []
        bar.onSelectTool = { picked.append($0) }
        for tool in KeyboardTool.allCases {
            tools.sendActions(for: .touchUpInside)
            let action = try button("tools.\(tool.rawValue)", in: bar)
            #expect(!action.isHidden)
            action.sendActions(for: .touchUpInside)
            #expect(!bar.showingTools)
        }
        #expect(picked == KeyboardTool.allCases)
        #expect(bar.frame.height == 44)
    }

    @Test func typingDismissesToolsWithoutChangingHeight() throws {
        let keyboard = KeyboardView(theme: .preview(dark: true, accent: KBPalette.system, customTheme: nil))
        keyboard.frame = CGRect(x: 0, y: 0, width: 390, height: keyboard.keyboardHeight)
        keyboard.layoutIfNeeded()
        let height = keyboard.keyboardHeight
        try button("suggestion.tools", in: keyboard).sendActions(for: .touchUpInside)
        let bar = try #require(descendants(keyboard).first { $0 is SuggestionBar } as? SuggestionBar)
        let letter = try #require(descendants(keyboard).compactMap { $0 as? KeyButton }.first { $0.letterBase != nil })
        letter.trigger()
        #expect(!bar.showingTools)
        #expect(keyboard.keyboardHeight == height)
    }

    @Test func clipboardPasteIsExplicitRepeatableAndAccessGated() throws {
        let theme = KeyboardTheme.preview(dark: false, accent: KBPalette.system, customTheme: nil)
        let panel = ClipboardPanelView(theme: theme, showsGlobe: false, hasFullAccess: true, items: [])
        var pastes = 0
        panel.onPasteCurrent = { pastes += 1 }
        let paste = try button("clipboard.pasteCurrent", in: panel)
        #expect(paste.isEnabled)
        paste.sendActions(for: .touchUpInside)
        paste.sendActions(for: .touchUpInside)
        #expect(pastes == 2)
        let denied = ClipboardPanelView(theme: theme, showsGlobe: false, hasFullAccess: false,
            items: [.init(text: "hidden saved text", pinned: false, date: Date())])
        #expect(!(try button("clipboard.pasteCurrent", in: denied)).isEnabled)
        #expect(!descendants(denied).contains { ($0 as? UILabel)?.text == "hidden saved text" })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!KBClipboard.add("123456", at: url))
        #expect(KBClipboard.all(at: url).isEmpty)
    }

    @Test func absentInvalidAndSavedAppearancePreferences() throws {
        let suite = "keyboard-consistency-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(KBSettings.resolvedAccentID(in: defaults) == "system")
        #expect(defaults.object(forKey: "kb.accent") == nil)
        defaults.set("invalid", forKey: "kb.accent")
        #expect(KBSettings.resolvedAccentID(in: defaults) == "system")
        defaults.set("emerald", forKey: "kb.accent")
        #expect(KBSettings.resolvedAccentID(in: defaults) == "emerald")
    }

    @Test func settingsReloadDoesNotPersistFallback() {
        let defaults = KBSettings.sharedDefaults
        let saved = defaults.object(forKey: "kb.accent")
        defer {
            if let saved { defaults.set(saved, forKey: "kb.accent") }
            else { defaults.removeObject(forKey: "kb.accent") }
        }
        defaults.removeObject(forKey: "kb.accent")
        let store = SettingsStore()
        store.reload()
        #expect(store.accentID == "system")
        #expect(defaults.object(forKey: "kb.accent") == nil)
    }

    @Test func systemThemeAndCustomPreviewStayIndependent() {
        for dark in [false, true] {
            let theme = KeyboardTheme.preview(dark: dark, accent: KBPalette.system, customTheme: nil)
            #expect(theme.isDark == dark)
            #expect(theme.isSystemAppearance)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            theme.specialKey.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            #expect(abs(red - green) < 0.001 && abs(green - blue) < 0.001)
            let custom = KBCustomThemePair.defaults(accent: KBPalette.emerald)
            #expect(!KeyboardTheme.preview(dark: dark, accent: KBPalette.system,
                customTheme: dark ? custom.dark : custom.light).isSystemAppearance)
        }
    }

    @Test func modifiersMatchStockWidthAndLetterGeometryRemainsOnOriginalGrid() throws {
        for (width, idiom): (CGFloat, UIUserInterfaceIdiom) in [(320, .phone), (390, .phone),
            (440, .phone), (700, .phone), (1024, .pad)] {
            let keyboard = KeyboardView(theme: .preview(dark: false, accent: KBPalette.system, customTheme: nil))
            keyboard.traitOverrides.userInterfaceIdiom = idiom
            keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.keyboardHeight)
            keyboard.layoutIfNeeded()
            let metrics = KeyboardLayoutMetrics.resolve(width: width, idiom: keyboard.traitCollection.userInterfaceIdiom)
            let deckWidth = min(width - metrics.sidePadding * 2, metrics.maximumDeckWidth)
            let origin = (width - deckWidth) / 2
            let unit = (deckWidth - metrics.keySpacing * 9) / 10
            let letterInset = unit * 1.5 + metrics.keySpacing / 2
            let keys = descendants(keyboard).compactMap { $0 as? KeyButton }
            let shift = try #require(keys.first { $0.isShift })
            let delete = try #require(keys.first { $0.repeats })
            #expect(abs(shift.frame.width - unit * KeyWidth.modifierUnits) < 0.001)
            #expect(abs(delete.frame.width - unit * KeyWidth.modifierUnits) < 0.001)
            #expect(abs(shift.frame.minX - origin) < 0.001)
            #expect(abs(delete.frame.maxX - origin - deckWidth) < 0.001)
            for (index, letter) in "zxcvbnm".enumerated() {
                let key = try #require(keys.first { $0.letterBase == String(letter) })
                let expected = origin + letterInset + metrics.keySpacing + CGFloat(index) * (unit + metrics.keySpacing)
                #expect(abs(key.frame.minX - expected) < 0.001)
                #expect(!shift.frame.intersects(key.frame))
                #expect(!delete.frame.intersects(key.frame))
            }
            #expect(shift.role == .special && delete.role == .special)
            keyboard.setKeyPriors(["z": 1, "m": 1])
            for cap in [shift, delete] {
                for x in [cap.frame.minX + 0.1, cap.frame.maxX - 0.1] {
                    #expect(keyboard.keyLabelForTesting(at: CGPoint(x: x, y: cap.frame.midY)) == cap.accessibilityLabel)
                }
            }
            #expect(shift.accessibilityValue == "On")
            shift.trigger()
            #expect(shift.accessibilityValue == "Off")
            shift.trigger()
            #expect(shift.accessibilityLabel == "Caps Lock")
        }
    }

    @Test func bottomRowMatchesStockProportions() throws {
        let width: CGFloat = 393
        let keyboard = KeyboardView(theme: .preview(dark: false, accent: KBPalette.system, customTheme: nil),
            showsGlobe: false)
        keyboard.traitOverrides.userInterfaceIdiom = .phone
        keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.keyboardHeight)
        keyboard.layoutIfNeeded()
        let metrics = KeyboardLayoutMetrics.resolve(width: width, idiom: .phone)
        let deckWidth = width - metrics.sidePadding * 2
        let unit = (deckWidth - metrics.keySpacing * 9) / 10
        let keys = descendants(keyboard).compactMap { $0 as? KeyButton }
        let numbers = try #require(keys.first { $0.accessibilityLabel == "Numbers" })
        let emoji = try #require(keys.first { $0.accessibilityLabel == "Emoji" })
        let space = try #require(keys.first { $0.accessibilityLabel == "Space" })
        let ret = try #require(keys.first { $0.role == .accent })
        #expect(abs(numbers.frame.width - unit * KeyWidth.utilityUnits) < 0.001)
        #expect(abs(emoji.frame.width - unit * KeyWidth.utilityUnits) < 0.001)
        #expect(abs(ret.frame.width - unit * KeyWidth.returnUnits) < 0.001)
        // 393pt deck: 123 and emoji ≈ 42.5, space ≈ 186, return ≈ 91.6 — stock's split.
        #expect(abs(numbers.frame.width - 42.5) < 1)
        #expect(abs(space.frame.width - 186.4) < 1.5)
        #expect(abs(ret.frame.width - 91.6) < 1)
        #expect(abs(ret.frame.maxX - (metrics.sidePadding + deckWidth)) < 0.001)
    }

    @Test func mediaPanelExpandsAndSearchKeyStaysEnabled() throws {
        let keyboard = KeyboardView(theme: .preview(dark: true, accent: KBPalette.system, customTheme: nil))
        keyboard.frame = CGRect(x: 0, y: 0, width: 393, height: keyboard.keyboardHeight)
        keyboard.layoutIfNeeded()
        let lettersHeight = keyboard.keyboardHeight
        keyboard.setActionEnabled(false)              // empty host field: return disabled

        keyboard.showMedia(kind: .gifs, hasFullAccess: false)
        #expect(keyboard.keyboardHeight == lettersHeight + 88)

        keyboard.frame.size.height = keyboard.keyboardHeight
        keyboard.layoutIfNeeded()
        try button("media.search", in: keyboard).sendActions(for: .touchUpInside)
        #expect(descendants(keyboard).contains { $0 is MediaSearchStrip })
        let action = try #require(descendants(keyboard).compactMap { $0 as? KeyButton }
            .first { $0.role == .accent })
        #expect(action.accessibilityLabel == "search")
        #expect(!action.accessibilityTraits.contains(.notEnabled))

        _ = keyboard.dismissOverlaysIfActive()
        #expect(!descendants(keyboard).contains { $0 is MediaSearchStrip })
        let restored = try #require(descendants(keyboard).compactMap { $0 as? KeyButton }
            .first { $0.role == .accent })
        #expect(restored.accessibilityTraits.contains(.notEnabled))
        #expect(keyboard.keyboardHeight == lettersHeight)
    }

    @Test func returnUsesNeutralFillAndActionUsesBlue() throws {
        let theme = KeyboardTheme.preview(dark: false, accent: KBPalette.system, customTheme: nil)
        let keyboard = KeyboardView(theme: theme)
        let action = try #require(descendants(keyboard).compactMap { $0 as? KeyButton }.first { $0.role == .accent })
        let gradient = try #require(action.layer.sublayers?.first { $0 is CAGradientLayer } as? CAGradientLayer)
        #expect(NSArray(array: gradient.colors ?? []).isEqual(to: [theme.specialKey.cgColor, theme.specialKey.cgColor]))
        keyboard.setActionTitle("send")
        #expect(NSArray(array: gradient.colors ?? []).isEqual(to: [theme.accentStart.cgColor, theme.accentStart.cgColor]))
        keyboard.setActionTitle(nil)
        #expect(NSArray(array: gradient.colors ?? []).isEqual(to: [theme.specialKey.cgColor, theme.specialKey.cgColor]))
    }

    @Test func renderUpdatedKeyboardAndTools() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keyboard-consistency-renders")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            for width: CGFloat in [320, 390, 440, 700, 1024] {
                let theme = KeyboardTheme.preview(dark: dark, accent: KBPalette.system, customTheme: nil)
                let keyboard = KeyboardView(theme: theme)
                keyboard.traitOverrides.userInterfaceIdiom = width >= 1000 ? .pad : .phone
                keyboard.backgroundColor = theme.fallbackBackgroundTop
                keyboard.frame = CGRect(x: 0, y: 0, width: width, height: keyboard.keyboardHeight)
                keyboard.layoutIfNeeded()
                keyboard.frame.size.height = keyboard.keyboardHeight
                keyboard.layoutIfNeeded()
                keyboard.setSuggestions(["Hello", "I", "The"])
                for tools in [false, true] {
                    if tools { try button("suggestion.tools", in: keyboard).sendActions(for: .touchUpInside) }
                    let image = UIGraphicsImageRenderer(size: keyboard.bounds.size).image { keyboard.layer.render(in: $0.cgContext) }
                    try #require(image.pngData()).write(to: folder.appendingPathComponent("\(dark ? "dark" : "light")-\(Int(width))-\(tools ? "tools" : "words").png"))
                }
            }
        }
        print("KEYBOARD_CONSISTENCY_RENDERS=\(folder.path)")
    }
}
