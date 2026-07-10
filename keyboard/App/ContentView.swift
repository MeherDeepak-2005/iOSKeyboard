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
	@Published var fontID:   String     { didSet { KBSettings.font = KBFont(rawValue: fontID) ?? .system } }
	@Published var haptics:  Bool       { didSet { KBSettings.haptics = haptics } }

	init() {
		language = KBSettings.language
		accentID = KBSettings.accentID
		fontID   = KBSettings.font.rawValue
		haptics  = KBSettings.haptics
	}

	var accent: KBAccent { KBPalette.accent(id: accentID) }
	var font:   KBFont   { KBFont(rawValue: fontID) ?? .system }
}

/// SwiftUI font for a given KBFont (mirror of KBFont.uiFont for previews).
func previewFont(_ f: KBFont, size: CGFloat = 19) -> Font {
	switch f {
	case .system:  return .system(size: size)
	case .rounded: return .system(size: size, design: .rounded)
	case .serif:   return .system(size: size, design: .serif)
	case .mono:    return .system(size: size, design: .monospaced)
	case .jetBrains, .hack:
		if let fam = f.customFamily { return .custom(fam, size: size) }   // falls back if missing
		return .system(size: size)
	}
}

// MARK: - Main page

struct ContentView: View {
	@StateObject private var store = SettingsStore()
	@Environment(\.colorScheme) private var scheme

	private var isDark: Bool { scheme == .dark }

	var body: some View {
		NavigationStack {
			GeometryReader { geo in
				VStack(spacing: 0) {
					AdCarousel(colors: store.accent.colors(dark: isDark))
						.frame(height: geo.size.height * 0.20)   // ~20% reserved for ads

					List {
						Section("Customize") {
							languageRow
							NavigationLink {
								ThemesView()
							} label: {
								SettingRow(icon: "paintpalette.fill",
										   tint: store.accent.representative(dark: isDark),
										   title: "Themes",
										   value: store.accent.name,
										   trailingGradient: store.accent.linearGradient(dark: isDark))
							}
							NavigationLink {
								FontsView()
							} label: {
								SettingRow(icon: "textformat",
										   tint: store.accent.representative(dark: isDark),
										   title: "Fonts",
										   value: store.font.rawValue)
							}
							Toggle(isOn: $store.haptics) {
								iconLabel("hand.tap.fill",
										  tint: store.accent.representative(dark: isDark),
										  title: "Haptic Feedback")
							}
						}

						Section("Setup") {
							EnableKeyboardRow()
							NavigationLink {
								DiagnosticsView()
							} label: {
								SettingRow(icon: "waveform.path.ecg",
										   tint: store.accent.representative(dark: isDark),
										   title: "Keyboard health",
										   value: KBDiagnostics.read().modelActive ? "active" : nil)
							}
						}
					}
					.listStyle(.insetGrouped)
				}
			}
			.navigationTitle("My Keyboard")
			.navigationBarTitleDisplayMode(.inline)
		}
		.environmentObject(store)
		.tint(store.accent.representative(dark: isDark))
	}

	// Language is a dropdown (Menu). Only English is wired up today.
	private var languageRow: some View {
		Menu {
			ForEach(KBLanguage.allCases, id: \.self) { lang in
				Button {
					if lang.isAvailable { store.language = lang }
				} label: {
					if store.language == lang {
						Label(lang.rawValue, systemImage: "checkmark")
					} else if lang.isAvailable {
						Text(lang.rawValue)
					} else {
						Text("\(lang.rawValue) — coming soon")
					}
				}
				.disabled(!lang.isAvailable)
			}
		} label: {
			SettingRow(icon: "globe",
					   tint: store.accent.representative(dark: isDark),
					   title: "Language",
					   value: store.language.rawValue)
		}
	}
}

// MARK: - Keyboard health (reads the extension's App Group telemetry)

struct DiagnosticsView: View {
	@State private var snap = KBDiagnostics.read()
	@State private var verbose = KBDiagnostics.verbose
	private let log = Logger(subsystem: KBSettings.appGroup, category: "diag-app")

	var body: some View {
		List {
			Section {
				row("Neural model", snap.modelActive ? "active" : "inactive")
				row("Times loaded", "\(snap.loadCount)")
				row("Times dropped", "\(snap.dropCount)")
				row("Active for", duration(snap.activeSeconds))
				row("Last load", snap.lastLoadMs > 0 ? "\(Int(snap.lastLoadMs)) ms" : "—")
			} header: {
				Text("Neural model")
			} footer: {
				Text("Measured inside the keyboard extension during your last typing session, not live.")
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
		log.notice("diag active=\(snap.modelActive) loads=\(snap.loadCount) drops=\(snap.dropCount) activeSec=\(Int(snap.activeSeconds)) peakMB=\(Int(snap.peakFootprintMB)) limitMB=\(Int(snap.limitMB)) warn=\(snap.warningCount) crit=\(snap.criticalCount)")
	}
	private func row(_ title: String, _ value: String) -> some View {
		HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
	}
	private func mb(_ v: Double) -> String { String(format: "%.1f MB", v) }
	private func duration(_ s: Double) -> String {
		if s <= 0 { return "—" }
		return s < 60 ? "\(Int(s)) s" : String(format: "%.1f min", s / 60)
	}
}

// MARK: - Ad carousel (placeholder for future monetization)

struct AdCarousel: View {
	let colors: [Color]
	@State private var page = 0
	private let slides = ["Your ad here", "Promote your app", "Sponsored space"]
	private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

	var body: some View {
		TabView(selection: $page) {
			ForEach(slides.indices, id: \.self) { i in
				RoundedRectangle(cornerRadius: 22, style: .continuous)
					.fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
					.overlay(
						VStack(spacing: 4) {
							Image(systemName: "megaphone.fill").font(.title2)
							Text(slides[i]).font(.headline)
							Text("Ad space · tap to learn more").font(.caption2).opacity(0.85)
						}
						.foregroundStyle(.white)
					)
					.padding(.horizontal)
					.tag(i)
			}
		}
		.tabViewStyle(.page(indexDisplayMode: .automatic))
		.onReceive(timer) { _ in
			withAnimation { page = (page + 1) % slides.count }
		}
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

// MARK: - Themes page (categorized gradients)

struct ThemesView: View {
	@EnvironmentObject private var store: SettingsStore
	@Environment(\.colorScheme) private var scheme
	private var isDark: Bool { scheme == .dark }
	private let columns = [GridItem(.adaptive(minimum: 72), spacing: 14)]

	// Keyboard surface for the current mode, so each swatch previews the accent in context.
	private var kbBackground: Color {
		Color(uiColor: isDark ? UIColor(hex: 0x1D1D21) : UIColor(hex: 0xECECF3))
	}

	var body: some View {
		List {
			Section {
				Text("Each accent colours the action button and key highlights. Swatches preview in your current \(isDark ? "Dark" : "Light") mode — switch your phone's appearance to see the other.")
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
			ForEach(KBPalette.groups, id: \.title) { group in
				Section(group.title) {
					LazyVGrid(columns: columns, spacing: 14) {
						ForEach(group.accents) { accent in
							swatch(accent)
						}
					}
					.padding(.vertical, 8)
				}
			}
		}
		.navigationTitle("Themes")
		.navigationBarTitleDisplayMode(.inline)
	}

	// A swatch = the accent's action-button chip sitting on the current keyboard surface.
	private func swatch(_ accent: KBAccent) -> some View {
		let selected = store.accentID == accent.id
		return VStack(spacing: 6) {
			RoundedRectangle(cornerRadius: 15, style: .continuous)
				.fill(kbBackground)
				.frame(width: 66, height: 66)
				.overlay(
					Capsule()
						.fill(accent.linearGradient(dark: isDark))
						.frame(width: 46, height: 38)
						.overlay {
							if selected {
								Image(systemName: "checkmark")
									.font(.system(size: 17, weight: .bold))
									.foregroundStyle(.white)
							}
						}
				)
				.overlay(
					RoundedRectangle(cornerRadius: 15, style: .continuous)
						.stroke(accent.representative(dark: isDark), lineWidth: selected ? 2.5 : 0)
				)
			Text(accent.name).font(.caption2).foregroundStyle(.secondary)
		}
		.contentShape(Rectangle())
		.onTapGesture { withAnimation(.snappy) { store.accentID = accent.id } }
	}
}

// MARK: - Fonts page

struct FontsView: View {
	@EnvironmentObject private var store: SettingsStore
	@Environment(\.colorScheme) private var scheme

	var body: some View {
		List {
			Section {
				Text("The quick brown fox")
					.font(previewFont(store.font, size: 26))
					.frame(maxWidth: .infinity, alignment: .center)
					.padding(.vertical, 8)
			} header: {
				Text("Preview")
			}

			Section("Font") {
				ForEach(KBFont.allCases, id: \.self) { font in
					Button {
						store.fontID = font.rawValue
					} label: {
						HStack {
							VStack(alignment: .leading, spacing: 2) {
								Text(font.rawValue)
									.font(previewFont(font, size: 19))
									.foregroundStyle(.primary)
								Text(font.subtitle)
									.font(.caption2)
									.foregroundStyle(.secondary)
							}
							Spacer()
							if store.fontID == font.rawValue {
								Image(systemName: "checkmark")
									.foregroundStyle(store.accent.representative(dark: scheme == .dark))
									.fontWeight(.semibold)
							}
						}
					}
					.buttonStyle(.plain)
				}
			}
		}
		.navigationTitle("Fonts")
		.navigationBarTitleDisplayMode(.inline)
	}
}

// MARK: - Enable-keyboard onboarding (app target only — uses UIApplication)

struct EnableKeyboardRow: View {
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Enable the keyboard")
				.font(.subheadline.weight(.semibold))
			Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → demo_keyboard. Then tap 🌐 in any app to switch to it. For haptics, also turn on Allow Full Access.")
				.font(.caption)
				.foregroundStyle(.secondary)
			Button("Open Settings") {
				if let url = URL(string: UIApplication.openSettingsURLString) {
					UIApplication.shared.open(url)
				}
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.small)
		}
		.padding(.vertical, 4)
	}
}

#Preview {
	ContentView()
}
