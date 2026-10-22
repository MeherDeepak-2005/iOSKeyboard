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
	@FocusState private var isFocused: Bool

	var body: some View {
        VStack {
            HStack {
                Button("Send / clear") { text = ""; isFocused = true }
                    .accessibilityIdentifier("runtime.clear")
                Button("Copy sample") { UIPasteboard.general.string = "Clipboard sample" }
                    .accessibilityIdentifier("runtime.copy")
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
