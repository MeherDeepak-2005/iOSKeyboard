//
//  keyboardApp.swift
//  keyboard
//
//  Created by Meher Deepak on 21/06/26.
//

import SwiftUI

@main
struct keyboardApp: App {
	init() {
		#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-keyboard-runtime-url") {
            // A deterministic URL-field fixture, independent of onboarding/menu UI.
            KBSettings.preferredLanguageMode = .english
        }
		if ProcessInfo.processInfo.arguments.contains("-ui-testing-used-keyboard") {
			KBSettings.hasUsedKeyboard = true
		}
		// UI tests pin a panel-header arm ("unified", "stacked") or clear the pin ("random").
		let arguments = ProcessInfo.processInfo.arguments
		if let flag = arguments.firstIndex(of: "-panel-header"), arguments.indices.contains(flag + 1) {
			KBExperiments.panelHeaderOverride = PanelHeaderStyle(rawValue: arguments[flag + 1])
		}
		#endif
	}

    var body: some Scene {
        WindowGroup {
			#if DEBUG
			if ProcessInfo.processInfo.arguments.contains("-keyboard-runtime-host") {
				KeyboardRuntimeHostView()
			} else {
				ContentView()
			}
			#else
			ContentView()
			#endif
        }
    }
}

#if DEBUG
private struct KeyboardRuntimeHostView: View {
	@State private var text = ""
	@State private var contextIndex = 0
	@FocusState private var isFocused: Bool
	/// Sentences the keyboard comparison places before each typed word (KB_RUNTIME_CONTEXTS, JSON).
	private let contexts: [String] = ProcessInfo.processInfo.environment["KB_RUNTIME_CONTEXTS"]
		.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []

	var body: some View {
        VStack {
            HStack {
                Button("Send / clear") { text = ""; isFocused = true }
                    .accessibilityIdentifier("runtime.clear")
                Button("Copy sample") { UIPasteboard.general.string = "Clipboard sample" }
                    .accessibilityIdentifier("runtime.copy")
                Button("Next context") {
                    let context = contexts.isEmpty ? "" : contexts[contextIndex % contexts.count]
                    text = context.isEmpty ? "" : context + " "
                    contextIndex += 1
                    isFocused = true
                }
                .accessibilityIdentifier("runtime.next")
            }
            TextField("Type", text: $text)
                .keyboardType(ProcessInfo.processInfo.arguments.contains("-keyboard-runtime-url") ? .URL : .default)
                .autocorrectionDisabled(ProcessInfo.processInfo.arguments.contains("-keyboard-runtime-url"))
                .textFieldStyle(.roundedBorder)
                .padding(24)
                .accessibilityIdentifier("runtime.text")
                .focused($isFocused)
        }
        .onAppear { DispatchQueue.main.async { isFocused = true } }

	}
}
#endif
