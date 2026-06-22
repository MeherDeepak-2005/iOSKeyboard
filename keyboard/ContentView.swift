import SwiftUI

// ⚠️ This file must be a member of the APP target ONLY — never the keyboard
// extension. It uses UIApplication, which app extensions are not allowed to call.
// (That's why it lives here and not in the shared KeyboardView.swift.)

struct ContentView: View {
	@State private var typed = ""
	@State private var themeIndex = 0
	
	var body: some View {
		VStack(spacing: 0) {
			
			// ── Onboarding ──────────────────────────────────────────────
			VStack(spacing: 8) {
				Text("Enable the keyboard")
					.font(.headline)
				Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → demo_keyboard, then tap 🌐 in any app to switch to it.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
				
				Button("Open Settings") {
					if let url = URL(string: UIApplication.openSettingsURLString) {
						UIApplication.shared.open(url)
					}
				}
				.buttonStyle(.borderedProminent)
			}
			.padding()
		}
	}
}

#Preview {
	ContentView()
}
