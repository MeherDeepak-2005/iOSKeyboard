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
		TextField("Type", text: $text)
			.textFieldStyle(.roundedBorder)
			.padding(24)
			.accessibilityIdentifier("runtime.text")
			.focused($isFocused)
			.onAppear {
				DispatchQueue.main.async { isFocused = true }
			}
	}
}
#endif
