import SwiftUI
import Combine
import StoreKit
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
	@Published var languageMode: KBLanguageMode { didSet { KBSettings.preferredLanguageMode = languageMode } }

	init() {
		accentID = KBSettings.accentID
		haptics  = KBSettings.haptics
		languageMode = KBSettings.preferredLanguageMode
	}

	func reload() {
		accentID = KBSettings.accentID
		haptics = KBSettings.haptics
		languageMode = KBSettings.preferredLanguageMode
	}

	var accent: KBAccent { KBPalette.accent(id: accentID) }
}

// MARK: - Main page

struct ContentView: View {
	@StateObject private var store = SettingsStore()
	@StateObject private var commercial = CommercialStore()
	@Environment(\.colorScheme) private var scheme
	@Environment(\.displayScale) private var displayScale
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
				if hasUsedKeyboard {
					Section {
						CommercialHomeCarousel(commercial: commercial)
							.listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
							.listRowBackground(Color.clear)
							.listRowSeparator(.hidden)
					}
					Section("Progress") {
						AchievementBanner()
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
					LanguagePickerRow(selection: $store.languageMode)
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
					Text("Haptics require a physical iPhone and follow the device's system haptic settings. The status page shows the last state observed by the keyboard.")
				}

				if hasUsedKeyboard {
					Section("Rewards") {
						NavigationLink {
							RewardCenterView(store: commercial)
						} label: {
							SettingRow(icon: "gift.fill",
									   tint: Color(uiColor: .systemPink),
									   title: "Offers & Theme Rewards")
						}
					}
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

				#if DEBUG || INTERNAL_NEURAL
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
		.task(id: displayScale) {
			// CoreText retains every rendered color glyph. Generate the immutable atlas
			// in the host app, then let the extension map its clean file-backed pages.
			let scale = displayScale
			_ = await Task.detached(priority: .utility) {
				EmojiAtlas.generateIfNeeded(scale: scale)
			}.value
		}
		.onAppear { refreshInstallState() }
		.task { await commercial.refresh() }
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

private struct CommercialHomeCarousel: View {
	@ObservedObject var commercial: CommercialStore

	var body: some View {
		ScrollView(.horizontal) {
			HStack(spacing: 10) {
				NavigationLink {
					RewardCenterView(store: commercial)
				} label: {
					carouselCard(title: "Theme rewards", subtitle: "Offers and unlocks",
						symbol: "gift.fill", colors: [.pink, .purple])
				}
				NavigationLink {
					ThemeStudioView()
				} label: {
					carouselCard(title: "Theme collection", subtitle: "Browse appearance",
						symbol: "paintpalette.fill", colors: [.teal, .blue])
				}
			}
			.padding(.horizontal, 20)
		}
		.scrollIndicators(.hidden)
		.frame(height: 108)
	}

	private func carouselCard(title: String, subtitle: String, symbol: String,
						  colors: [Color]) -> some View {
		HStack(spacing: 14) {
			Image(systemName: symbol)
				.font(.system(size: 24, weight: .semibold))
				.frame(width: 36)
			VStack(alignment: .leading, spacing: 4) {
				Text(title).font(.headline)
				Text(subtitle).font(.subheadline).opacity(0.82)
			}
			Spacer(minLength: 4)
			Image(systemName: "chevron.right").font(.caption.weight(.bold)).opacity(0.7)
		}
		.foregroundStyle(.white)
		.padding(16)
		.frame(width: 270, height: 100)
		.background(
			LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
			in: RoundedRectangle(cornerRadius: 8, style: .continuous)
		)
	}
}

private struct RewardCenterView: View {
	@ObservedObject var store: CommercialStore

	var body: some View {
		List {
			Section("Available") {
				if store.products.isEmpty && store.campaigns.isEmpty {
					Text(store.storeError ?? "No offers available right now.")
						.foregroundStyle(.secondary)
				}
				ForEach(store.products, id: \.id) { product in
					Button {
						Task { await store.purchase(product) }
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 3) {
								Text(product.displayName).foregroundStyle(.primary)
								Text(product.description).font(.footnote).foregroundStyle(.secondary)
							}
							Spacer()
							Text(store.purchasedProductIDs.contains(product.id)
								 ? "Owned" : product.displayPrice)
								.font(.subheadline.weight(.semibold))
						}
					}
					.disabled(store.purchasedProductIDs.contains(product.id))
				}
			}

			Section {
				ForEach(OfferInterest.allCases) { interest in
					Toggle(isOn: Binding(
						get: { store.interests.contains(interest) },
						set: { store.setInterest(interest, enabled: $0) }
					)) {
						Label(interest.title, systemImage: interest.symbol)
					}
				}
			} header: {
				Text("Interests")
			} footer: {
				Text("Offer matching uses only choices made here, saved merchants, and confirmed offer activity. Typed text, host-app identity, and installed apps are never used.")
			}
		}
		.navigationTitle("Offers & Rewards")
		.navigationBarTitleDisplayMode(.inline)
		.refreshable { await store.refresh() }
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
				Text("The keyboard remains usable without Full Access. Full Access enables shared settings, on-device learning persistence, and media search. Haptics stay local. Only a GIF or Sticker query you explicitly submit is sent to KLIPY; surrounding typed text is never included.")
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
	// NEURAL_DEBUG_TELEMETRY_REMOVE
	#if DEBUG || INTERNAL_NEURAL
	@State private var neural = KBDiagnostics.readNeuralDebug()
	#endif
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

			// NEURAL_DEBUG_TELEMETRY_REMOVE
			#if DEBUG || INTERNAL_NEURAL
			Section {
				if let neural {
					row("State", neural.state)
					if let detail = neural.detail, !detail.isEmpty {
						Text(detail)
							.font(.caption)
							.foregroundStyle(.secondary)
							.textSelection(.enabled)
					}
					row("Tier", neural.modelTier)
					row("Active", neural.isActive ? "Yes" : "No")
					row("Model ready", neural.isReady ? "Yes" : "No")
					row("Top-pick changes", "\(neural.topPickChangeCount)")
					row("Last ranking", neural.updated.formatted(
						date: .abbreviated, time: .standard))
					if let ngram = neural.ngramTopPick, let final = neural.finalTopPick {
						row("Top pick", "\(ngram) → \(final)")
					}
					if let typed = neural.typedWord { row("Last input", typed) }
					if !neural.contextTail.isEmpty {
						row("Context", neural.contextTail.joined(separator: " "))
					}
					ForEach(neural.rows.prefix(8)) { candidate in
						VStack(alignment: .leading, spacing: 4) {
							HStack {
								Text("#\(candidate.finalRank) \(candidate.word)")
									.font(.subheadline.weight(.semibold))
								Spacer()
								Text("n-gram #\(candidate.ngramRank)")
									.font(.caption.monospacedDigit())
									.foregroundStyle(.secondary)
							}
							Text(String(format:
								"score %.2f → %.2f · spatial %.2f · LM %.2f · neural %.2f",
								candidate.ngramScore, candidate.finalScore,
								candidate.spatialCost, candidate.ngramLogProbability,
								candidate.neuralLogProbability))
								.font(.caption2.monospacedDigit())
								.foregroundStyle(.secondary)
						}
					}
				} else {
					Text("No neural ranking has been recorded in this Debug build.")
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Neural model (DEBUG)")
			} footer: {
				Text("Debug-only App Group telemetry. It stores the latest input, short context, and candidate scores locally. Remove this section and the marked DEBUG hooks before model promotion.")
					.textSelection(.enabled)
			}
			#endif

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
				Button("Reset", role: .destructive) { resetDiagnostics() }
			}
		}
		.navigationTitle("Keyboard health")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear(perform: reload)
	}

	private func reload() {
		snap = KBDiagnostics.read()
		// NEURAL_DEBUG_TELEMETRY_REMOVE
		#if DEBUG || INTERNAL_NEURAL
		neural = KBDiagnostics.readNeuralDebug()
		#endif
		log.notice("diag peakMB=\(Int(snap.peakFootprintMB)) limitMB=\(Int(snap.limitMB)) warn=\(snap.warningCount) crit=\(snap.criticalCount)")
	}
	private func resetDiagnostics() {
		KBDiagnostics.reset()
		reload()
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

private struct LanguagePickerRow: View {
	@Binding var selection: KBLanguageMode
	private var selectedHealth: LanguagePackHealth {
		KBSettings.languagePackHealth(for: selection)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 12) {
				Image(systemName: "character.book.closed.fill")
					.font(.system(size: 15, weight: .semibold))
					.foregroundStyle(.white)
					.frame(width: 30, height: 30)
					.background(Color(uiColor: .systemTeal),
						in: RoundedRectangle(cornerRadius: 7, style: .continuous))
				Text("Language")
				Spacer()
				Picker("Language", selection: $selection) {
					ForEach(KBLanguageMode.allCases) { mode in
						let health = KBSettings.languagePackHealth(for: mode)
						Text(health.isReady ? mode.displayName
							 : "\(mode.displayName) · \(health.conciseDetail)")
							.tag(mode)
							.accessibilityIdentifier("language.\(mode.rawValue)")
					}
				}
				.labelsHidden()
				.pickerStyle(.menu)
				.accessibilityIdentifier("settings.language")
			}
			if !selectedHealth.isReady {
				Text(selectedHealth.detail)
					.font(.caption)
					.foregroundStyle(.secondary)
					.padding(.leading, 42)
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
