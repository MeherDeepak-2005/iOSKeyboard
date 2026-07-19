import SwiftUI
import Combine
import os

// ⚠️ This file must be a member of the APP target ONLY — never the keyboard
// extension. It uses UIApplication, which app extensions are not allowed to call.
// The settings here are written to the shared App Group (see KBSettings) and read
// by the keyboard extension on launch.

// MARK: - SwiftUI helpers on the shared accent model

extension KBAccent {
	func colors(dark: Bool) -> [Color] {
		let g = gradient(dark: dark)
		return [Color(uiColor: g.startColor), Color(uiColor: g.endColor)]
	}
	func linearGradient(dark: Bool) -> LinearGradient {
		LinearGradient(colors: colors(dark: dark), startPoint: .topLeading, endPoint: .bottomTrailing)
	}
	func representative(dark: Bool) -> Color { Color(uiColor: tint(dark: dark)) }
}

// MARK: - Settings store (publishes the shared App Group values to SwiftUI)

final class SettingsStore: ObservableObject {
	@Published var accentID: String     { didSet { KBSettings.accentID = accentID } }
	@Published var haptics:  Bool       { didSet { KBSettings.haptics = haptics } }

	init() {
		accentID = KBSettings.accentID
		haptics  = KBSettings.haptics
	}

	func reload() {
		accentID = KBSettings.accentID
		haptics = KBSettings.haptics
	}

	var accent: KBAccent { KBPalette.accent(id: accentID) }
}

// MARK: - Main page

struct ContentView: View {
	@StateObject private var store = SettingsStore()
	@Environment(\.colorScheme) private var scheme
	@Environment(\.scenePhase) private var scenePhase
	@State private var showResetConfirm = false
	@State private var showDeleteAllConfirm = false
	@State private var hasUsedKeyboard = KBSettings.hasUsedKeyboard

	var body: some View {
		NavigationStack {
			List {
				if !hasUsedKeyboard {
					Section {
						EnableKeyboardRow()
					}
				}
				Section("Status") {
					NavigationLink {
						SetupSupportView()
					} label: {
						SettingRow(icon: "keyboard",
								   tint: Color(uiColor: .systemBlue),
								   title: "Setup & Support",
								   value: keyboardStatusValue)
					}
				}

				Section {
					NavigationLink {
						ThemeStudioView()
					} label: {
						SettingRow(icon: "paintpalette.fill",
								   tint: Color(uiColor: .systemPurple),
								   title: "Appearance",
								   value: KBSettings.customThemeEnabled ? "Custom" : store.accent.name,
								   trailingGradient: KBSettings.customThemeEnabled ? nil : store.accent.linearGradient(dark: scheme == .dark))
					}
					.accessibilityIdentifier("settings.appearance")
					Toggle(isOn: $store.haptics) {
						iconLabel("hand.tap.fill",
								  tint: Color(uiColor: .systemOrange),
								  title: "Haptic Feedback")
					}
				} header: {
					Text("Keyboard")
				} footer: {
					Text("Haptics require a physical iPhone and may require Full Access. The status page shows the last state observed by the keyboard.")
				}

				Section("Personalization") {
					Button(role: .destructive) {
						showResetConfirm = true
					} label: {
						iconLabel("trash.fill", tint: .red, title: "Reset learned words")
					}
					Button(role: .destructive) {
						showDeleteAllConfirm = true
					} label: {
						iconLabel("externaldrive.badge.xmark", tint: .red, title: "Delete all keyboard data")
					}
				}

			Section("Privacy") {
				NavigationLink {
					PrivacyDataView()
					} label: {
						SettingRow(icon: "hand.raised.fill",
								   tint: Color(uiColor: .systemIndigo),
								   title: "Privacy & Data")
				}
				NavigationLink {
					ThirdPartyNoticesView()
				} label: {
					SettingRow(icon: "doc.text.fill",
							   tint: Color(uiColor: .systemGray),
							   title: "Third-Party Notices")
				}
			}

				#if DEBUG
				Section("Developer") {
					NavigationLink {
						DiagnosticsView()
					} label: {
						SettingRow(icon: "waveform.path.ecg",
								   tint: Color(uiColor: .systemGray),
								   title: "Keyboard health")
					}
				}
				#endif
			}
			.listStyle(.insetGrouped)
			.navigationTitle("Glyph")
			.navigationBarTitleDisplayMode(.large)
		}
		.environmentObject(store)
		.tint(Color(uiColor: .systemBlue))
		.onAppear { refreshInstallState() }
		.onChange(of: scenePhase) { _, phase in
			if phase == .active { refreshInstallState() }
		}
		.alert("Reset learned words?", isPresented: $showResetConfirm) {
			Button("Reset", role: .destructive, action: resetUserData)
			Button("Cancel", role: .cancel) { }
		} message: {
			Text("Clears all words you have typed, autocorrect history, and swipe-style adaptations. The base dictionary and other settings are not affected.")
		}
		.alert("Delete all keyboard data?", isPresented: $showDeleteAllConfirm) {
			Button("Delete All", role: .destructive, action: deleteAllData)
			Button("Cancel", role: .cancel) { }
		} message: {
			Text("Deletes learned language data, Glide adaptation, emoji recents, diagnostics, and custom appearance data. This cannot be undone.")
		}
	}

	private func refreshInstallState() {
		hasUsedKeyboard = KBSettings.hasUsedKeyboard
	}

	private var keyboardStatusValue: String {
		guard let seen = KBSettings.keyboardLastSeenAt else { return "Not opened" }
		return Date().timeIntervalSince(seen) < 7 * 24 * 60 * 60 ? "Seen recently" : "Check status"
	}

	private func resetUserData() {
		KBPersonalData.resetLearning()
	}

	private func deleteAllData() {
		KBPersonalData.resetAll()
		store.reload()
	}

}

private struct SetupSupportView: View {
	@State private var access = KBSettings.lastFullAccess
	@State private var observedAt = KBSettings.lastFullAccessObservedAt
	@State private var lastSeen = KBSettings.keyboardLastSeenAt
	@State private var resetStatus = KBPersonalData.resetStatus

	var body: some View {
		List {
			Section("Keyboard") {
				statusRow("Last opened", value: lastSeen?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
				statusRow("Full Access", value: access ? "On" : "Off or unknown")
				if let observedAt {
					statusRow("Last checked", value: observedAt.formatted(date: .abbreviated, time: .shortened))
				}
				if resetStatus.requested > 0 {
					let value = resetStatus.failure != nil
						? "Storage cleanup failed"
						: (resetStatus.acknowledged >= resetStatus.requested
							? "Confirmed" : "Open the keyboard to finish")
					statusRow("Data reset", value: value)
				}
			}
			Section("Setup") {
				Button(action: openSettings) {
					Label("Open Keyboard Settings", systemImage: "gear")
				}
				Text("Add Glyph under Keyboards, then switch to it with the input-mode key. Open Glyph once in any text field to refresh the status above.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			Section("Troubleshooting") {
				troubleshooting("Glyph is missing", "Confirm it remains enabled in Keyboard Settings, then reopen the host app.")
				troubleshooting("iOS switches keyboards", "Secure fields and some managed apps can require the system keyboard. This is controlled by iOS.")
				troubleshooting("No haptic feedback", "Confirm Haptic Feedback is on, then test on a physical iPhone. iOS controls whether third-party keyboard feedback is available.")
			}
			Section("About") {
				statusRow("Version", value: version)
			}
		}
		.navigationTitle("Setup & Support")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear(perform: refresh)
	}

	private func refresh() {
		access = KBSettings.lastFullAccess
		observedAt = KBSettings.lastFullAccessObservedAt
		lastSeen = KBSettings.keyboardLastSeenAt
		resetStatus = KBPersonalData.resetStatus
	}

	private func openSettings() {
		guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
		UIApplication.shared.open(url)
	}

	private var version: String {
		let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
		let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
		return "\(short) (\(build))"
	}

	private func statusRow(_ title: String, value: String) -> some View {
		HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
	}

	private func troubleshooting(_ title: String, _ detail: String) -> some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(title).font(.subheadline.weight(.semibold))
			Text(detail).font(.footnote).foregroundStyle(.secondary)
		}
		.padding(.vertical, 2)
	}
}

private struct PrivacyDataView: View {
	var body: some View {
		List {
			Section("Typing") {
				Text("Typing, autocorrect, suggestions, and Glide are processed on your device. Glyph does not transmit the text you type to a server.")
			}
			Section("On-device storage") {
				privacyRow("Personalization", "Word and context counts used to improve suggestions. Stored in the shared app container until reset.")
				privacyRow("Appearance", "Theme choices remain on this device until changed or deleted.")
				privacyRow("Diagnostics", "Release builds store only aggregate latency, memory, and storage-health counters. Typed text is never included.")
			}
			Section("Full Access") {
				Text("The keyboard remains usable without Full Access. Full Access enables shared settings, on-device learning persistence, and haptics. It does not enable remote processing of typed text.")
			}
			Section("Control") {
				Text("Use Reset learned words to remove language personalization, or Delete all keyboard data to remove all user-generated data in the shared container. You can revoke Full Access at any time in iOS Settings.")
			}
			Section {
				Text("Effective July 19, 2026")
					.foregroundStyle(.secondary)
			}
		}
		.navigationTitle("Privacy & Data")
		.navigationBarTitleDisplayMode(.inline)
	}

	private func privacyRow(_ title: String, _ detail: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title).font(.subheadline.weight(.semibold))
			Text(detail).font(.footnote).foregroundStyle(.secondary)
		}
		.padding(.vertical, 3)
	}
}

private struct ThirdPartyNoticesView: View {
	private let notices: String = {
		guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
			  let value = try? String(contentsOf: url, encoding: .utf8) else {
			return "Third-party notices are unavailable in this build."
		}
		return value
	}()

	var body: some View {
		ScrollView {
			Text(notices)
				.font(.footnote)
				.frame(maxWidth: .infinity, alignment: .leading)
				.textSelection(.enabled)
				.padding(20)
		}
		.navigationTitle("Notices")
		.navigationBarTitleDisplayMode(.inline)
	}
}

// MARK: - Keyboard health (reads the extension's App Group telemetry)

struct DiagnosticsView: View {
	@State private var snap = KBDiagnostics.read()
	@State private var verbose = KBDiagnostics.verbose
	@State private var glideCapture = KBSettings.glideCapture
	private let log = Logger(subsystem: KBSettings.appGroup, category: "diag-app")

	var body: some View {
		List {
			Section {
				row("Peak footprint", mb(snap.peakFootprintMB))
				row("Lowest headroom", snap.minAvailableMB > 0 ? mb(snap.minAvailableMB) : "—")
				row("Inferred kill limit", snap.limitMB > 0 ? mb(snap.limitMB) : "—")
				row("Memory warnings", "\(snap.warningCount)")
				row("Critical events", "\(snap.criticalCount)")
			} header: {
				Text("Memory (jetsam)")
			} footer: {
				Text("iOS can terminate a keyboard extension under memory pressure. These counters contain no typed text.")
			}

			Section("Latency histograms") {
				row("Host insert p95", latency(snap.hostInsertLatencyBins, 0.95))
				row("Tap decode p95", latency(snap.tapDecodeLatencyBins, 0.95))
				row("Glide preview p95", latency(snap.glidePreviewLatencyBins, 0.95))
				row("Glide final p95", latency(snap.glideFinalLatencyBins, 0.95))
				row("Lift to insert p95", latency(snap.glideCommitLatencyBins, 0.95))
			}

			Section {
				Toggle("Verbose ranking log", isOn: $verbose)
					.onChange(of: verbose) { _, on in KBDiagnostics.verbose = on }
			} header: {
				Text("Live logging")
			} footer: {
				Text("Debug builds can log private candidate ranking locally. This facility is compiled out of Release builds.")
					.textSelection(.enabled)
			}

			Section {
				Toggle("Glide capture (debug)", isOn: $glideCapture)
					.onChange(of: glideCapture) { _, on in KBSettings.glideCapture = on }
				if let url = KBDiagnostics.glideCaptureURL,
				   let size = glideCaptureSize(url) {
					ShareLink(item: url) {
						Label("Export glide capture (\(size))", systemImage: "square.and.arrow.up")
					}
				} else {
					Text("No glide capture yet — enable the toggle, swipe some words, then reopen.")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Advanced")
			} footer: {
				Text("Glide capture records swipes to glide_capture.jsonl in the App Group container for offline calibration — on-device only and never uploaded. Restart the keyboard after changing this setting.")
					.textSelection(.enabled)
			}

			Section {
				if snap.updated == .distantPast {
					Text("No data yet — type with the keyboard, then reopen this screen.")
						.foregroundStyle(.secondary)
				} else {
					row("Updated", snap.updated.formatted(date: .abbreviated, time: .shortened))
				}
				Button("Refresh") { reload() }
				Button("Reset", role: .destructive) { KBDiagnostics.reset(); snap = KBDiagnostics.read() }
			}
		}
		.navigationTitle("Keyboard health")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear(perform: reload)
	}

	private func reload() {
		snap = KBDiagnostics.read()
		log.notice("diag peakMB=\(Int(snap.peakFootprintMB)) limitMB=\(Int(snap.limitMB)) warn=\(snap.warningCount) crit=\(snap.criticalCount)")
	}
	private func row(_ title: String, _ value: String) -> some View {
		HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
	}
	private func mb(_ v: Double) -> String { String(format: "%.1f MB", v) }
	private func latency(_ bins: [Int]?, _ fraction: Double) -> String {
		KBDiagnostics.percentile(bins, fraction: fraction) ?? "—"
	}
	/// Human-readable size of the glide capture file, or nil if it doesn't exist / is empty.
	private func glideCaptureSize(_ url: URL) -> String? {
		guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
			  let bytes = attrs[.size] as? Int, bytes > 0 else { return nil }
		return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
	}
}

// MARK: - Reusable rows

/// Icon chip + title, no trailing content. Used as a Toggle's label.
func iconLabel(_ icon: String, tint: Color, title: String) -> some View {
	HStack(spacing: 12) {
		Image(systemName: icon)
			.font(.system(size: 15, weight: .semibold))
			.foregroundStyle(.white)
			.frame(width: 30, height: 30)
			.background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
		Text(title)
	}
}

struct SettingRow: View {
	let icon: String
	let tint: Color
	let title: String
	var value: String? = nil
	var trailingGradient: LinearGradient? = nil

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: icon)
				.font(.system(size: 15, weight: .semibold))
				.foregroundStyle(.white)
				.frame(width: 30, height: 30)
				.background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
			Text(title)
			Spacer()
			if let value {
				Text(value).foregroundStyle(.secondary)
			}
			if let trailingGradient {
				Circle().fill(trailingGradient).frame(width: 18, height: 18)
			}
		}
	}
}

// MARK: - Enable-keyboard onboarding (app target only — uses UIApplication)

struct EnableKeyboardRow: View {
	var body: some View {
		Button {
				if let url = URL(string: UIApplication.openSettingsURLString) {
					UIApplication.shared.open(url)
				}
		} label: {
			HStack(spacing: 12) {
				Image(systemName: "keyboard.badge.ellipsis")
					.font(.system(size: 16, weight: .semibold))
					.foregroundStyle(.white)
					.frame(width: 32, height: 32)
					.background(Color(uiColor: .systemGreen), in: RoundedRectangle(cornerRadius: 8))
				VStack(alignment: .leading, spacing: 2) {
					Text("Enable Glyph")
						.font(.subheadline.weight(.semibold))
					Text("Add the keyboard in Settings, then use it once.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Image(systemName: "arrow.up.forward")
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
			}
		}
		.buttonStyle(.plain)
		.padding(.vertical, 2)
	}
}

#Preview {
	ContentView()
}
