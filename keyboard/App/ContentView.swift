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
	@Published var language: KBLanguage { didSet { KBSettings.language = language } }
	@Published var accentID: String     { didSet { KBSettings.accentID = accentID } }
	@Published var haptics:  Bool       { didSet { KBSettings.haptics = haptics } }

	init() {
		language = KBSettings.language
		accentID = KBSettings.accentID
		haptics  = KBSettings.haptics
	}

	var accent: KBAccent { KBPalette.accent(id: accentID) }
}

// MARK: - Main page

struct ContentView: View {
	@StateObject private var store = SettingsStore()
	@Environment(\.colorScheme) private var scheme
	@Environment(\.displayScale) private var displayScale
	@Environment(\.scenePhase) private var scenePhase
	@State private var showResetConfirm = false
	@State private var hasUsedKeyboard = KBSettings.hasUsedKeyboard
	@State private var hasFullAccess = KBSettings.lastFullAccess
	@State private var showLanguagePicker = false

	var body: some View {
		NavigationStack {
			List {
				AchievementBanner()
					.frame(height: 78)
					.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
					.listRowBackground(Color.clear)

				if !hasUsedKeyboard {
					Section {
						EnableKeyboardRow()
					}
				}

				Section {
					languageRow
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
					if hasUsedKeyboard && !hasFullAccess {
						Text("Haptic feedback requires Full Access for third-party keyboards.")
					}
				}

				Section("Personalization") {
					Button(role: .destructive) {
						showResetConfirm = true
					} label: {
						iconLabel("trash.fill", tint: .red, title: "Reset learned words")
					}
				}

				#if DEBUG
				Section("Developer") {
					NavigationLink {
						DiagnosticsView()
					} label: {
						SettingRow(icon: "waveform.path.ecg",
								   tint: Color(uiColor: .systemGray),
								   title: "Keyboard health",
								   value: KBDiagnostics.read().modelActive ? "Active" : nil)
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
		.task {
			// Pre-rasterize the emoji atlas for the extension (one-off per emoji set /
			// display scale / iOS major). The keyboard falls back to live text glyphs —
			// and their CoreText memory cost — until this has run once.
			let scale = displayScale
			Task.detached(priority: .utility) { EmojiAtlas.generateIfNeeded(scale: scale) }
		}
		.onAppear { refreshInstallState() }
		.onChange(of: scenePhase) { _, phase in
			if phase == .active { refreshInstallState() }
		}
		.sheet(isPresented: $showLanguagePicker) {
			LanguagePickerSheet()
				.environmentObject(store)
				.presentationDetents([.height(280)])
				.presentationDragIndicator(.visible)
		}
		.alert("Reset learned words?", isPresented: $showResetConfirm) {
			Button("Reset", role: .destructive, action: resetUserData)
			Button("Cancel", role: .cancel) { }
		} message: {
			Text("Clears all words you have typed, autocorrect history, and swipe-style adaptations. The base dictionary and other settings are not affected.")
		}
	}

	private func refreshInstallState() {
		hasUsedKeyboard = KBSettings.hasUsedKeyboard
		hasFullAccess = KBSettings.lastFullAccess
	}

	private func resetUserData() {
		if let url = KBSettings.userModelURL { try? FileManager.default.removeItem(at: url) }
		KBSettings.sharedDefaults.removeObject(forKey: "kb.glideprofile")
	}

	// Only English is wired up today; the sheet keeps future languages discoverable
	// without pretending disabled choices are working settings.
	private var languageRow: some View {
		Button { showLanguagePicker = true } label: {
			SettingRow(icon: "globe",
					   tint: Color(uiColor: .systemBlue),
					   title: "Language",
					   value: store.language.rawValue)
				.frame(maxWidth: .infinity, alignment: .leading)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.accessibilityIdentifier("settings.language")
	}
}

private struct LanguagePickerSheet: View {
	@EnvironmentObject private var store: SettingsStore
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Language")
				.font(.headline)
				.padding(.horizontal, 20)
				.padding(.top, 16)
				.padding(.bottom, 8)
			ForEach(KBLanguage.allCases, id: \.self) { language in
				Button {
					guard language.isAvailable else { return }
					store.language = language
					dismiss()
				} label: {
					HStack(spacing: 12) {
						VStack(alignment: .leading, spacing: 2) {
							Text(language.rawValue)
							Text(language.subtitle)
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						Spacer()
						if !language.isAvailable {
							Text("Coming soon")
								.font(.caption2.weight(.medium))
								.foregroundStyle(.secondary)
								.padding(.horizontal, 8)
								.padding(.vertical, 4)
								.background(.quaternary, in: Capsule())
						} else if store.language == language {
							Image(systemName: "checkmark")
								.fontWeight(.semibold)
								.foregroundStyle(.tint)
						}
					}
					.padding(.horizontal, 20)
					.frame(height: 58)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.accessibilityIdentifier("language.\(language.rawValue.lowercased())")
				.disabled(!language.isAvailable)
				if language != KBLanguage.allCases.last { Divider().padding(.leading, 20) }
			}
			Spacer(minLength: 0)
		}
	}
}

// MARK: - Keyboard health (reads the extension's App Group telemetry)

struct DiagnosticsView: View {
	@State private var snap = KBDiagnostics.read()
	@State private var verbose = KBDiagnostics.verbose
	@State private var glideCapture = KBSettings.glideCapture
	@State private var neural = KBSettings.neuralRescorer
	private let log = Logger(subsystem: KBSettings.appGroup, category: "diag-app")

	var body: some View {
		List {
			Section {
				row("Neural model", snap.modelState ?? (snap.modelActive ? "active" : "inactive"))
				if let available = snap.lastGateAvailableMB {
					row("Headroom at last gate", mb(available))
				}
				if let error = snap.lastModelError {
					Text(error)
						.font(.footnote)
						.foregroundStyle(.red)
						.textSelection(.enabled)
				}
				row("Times loaded", "\(snap.loadCount)")
				row("Times dropped", "\(snap.dropCount)")
				row("Active for", duration(snap.activeSeconds))
				row("Last load", snap.lastLoadMs > 0 ? "\(Int(snap.lastLoadMs)) ms" : "—")
				row("Ranking passes scored", "\(snap.neuralRankPasses)")
				row("Changed the top pick", helpfulRate)
			} header: {
				Text("Neural model")
			} footer: {
				Text("Measured inside the keyboard extension during your last typing session, not live. \"Changed the top pick\" counts passes where blending the neural score reordered the winner vs the n-gram alone — the model's live helpfulness rate.")
			}

			Section {
				row("Peak footprint", mb(snap.peakFootprintMB))
				row("Lowest headroom", snap.minAvailableMB > 0 ? mb(snap.minAvailableMB) : "—")
				row("Inferred kill limit", snap.limitMB > 0 ? mb(snap.limitMB) : "—")
				row("Memory warnings", "\(snap.warningCount)")
				row("Critical events", "\(snap.criticalCount)")
			} header: {
				Text("Memory (jetsam)")
			} footer: {
				Text("iOS kills the extension near the inferred limit. The model is dropped on pressure and reloaded later.")
			}

			Section {
				Toggle("Verbose ranking log", isOn: $verbose)
					.onChange(of: verbose) { _, on in KBDiagnostics.verbose = on }
			} header: {
				Text("Live logging")
			} footer: {
				Text("Logs every candidate's neural vs n-gram score as you type. Watch it live in Console.app (pick your device) or run:\nlog stream --predicate 'subsystem == \"group.com.swiftuimasterclass.keyboard\"' --level info")
					.textSelection(.enabled)
			}

			Section {
				Toggle("Neural rescorer", isOn: $neural)
					.onChange(of: neural) { _, on in KBSettings.neuralRescorer = on }
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
				Text("The neural rescorer loads only with measured headroom and is dropped under memory pressure. Check the Memory section for its actual device footprint. Glide capture records your real swipes to glide_capture.jsonl in the App Group container for offline calibration (tools/glide_eval/calibrate.py) — on-device only, never uploaded. Restart the keyboard after changing these.")
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

	private var helpfulRate: String {
		guard snap.neuralRankPasses > 0 else { return "—" }
		let pct = 100.0 * Double(snap.neuralTop1Changed) / Double(snap.neuralRankPasses)
		return "\(snap.neuralTop1Changed) (\(String(format: "%.0f", pct))%)"
	}

	private func reload() {
		snap = KBDiagnostics.read()
		log.notice("diag active=\(snap.modelActive) loads=\(snap.loadCount) drops=\(snap.dropCount) activeSec=\(Int(snap.activeSeconds)) peakMB=\(Int(snap.peakFootprintMB)) limitMB=\(Int(snap.limitMB)) warn=\(snap.warningCount) crit=\(snap.criticalCount)")
	}
	private func row(_ title: String, _ value: String) -> some View {
		HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
	}
	private func mb(_ v: Double) -> String { String(format: "%.1f MB", v) }
	/// Human-readable size of the glide capture file, or nil if it doesn't exist / is empty.
	private func glideCaptureSize(_ url: URL) -> String? {
		guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
			  let bytes = attrs[.size] as? Int, bytes > 0 else { return nil }
		return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
	}
	private func duration(_ s: Double) -> String {
		if s <= 0 { return "—" }
		return s < 60 ? "\(Int(s)) s" : String(format: "%.1f min", s / 60)
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
