import SwiftUI

/// Preset-first appearance editor. All edits remain local until Apply, so navigating
/// back is a real cancel operation and the running extension never observes half a theme.
struct ThemeStudioView: View {
	private enum AppearanceSide: String, CaseIterable {
		case light = "Light"
		case dark = "Dark"
	}

	@EnvironmentObject private var store: SettingsStore
	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) private var systemScheme
	@State private var accentID = KBSettings.accentID
	@State private var usesCustom = KBSettings.customThemeEnabled
	@State private var themes = KBSettings.customThemes
		?? KBCustomThemePair.defaults(accent: KBSettings.accent)
	@State private var side: AppearanceSide = .light
	@State private var advancedExpanded = false

	private var accent: KBAccent { KBPalette.accent(id: accentID) }
	private var issues: [String] {
		guard usesCustom else { return [] }
		return Self.contrastIssues(in: themes.light, label: "Light")
			+ Self.contrastIssues(in: themes.dark, label: "Dark")
	}

	var body: some View {
		List {
			ForEach(KBPalette.groups, id: \.title) { group in
				Section(group.title) {
					LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 12) {
						ForEach(group.accents) { option in
							presetButton(option)
						}
					}
					.padding(.vertical, 6)
				}
			}

			Section {
				DisclosureGroup(isExpanded: $advancedExpanded) {
					Toggle("Use custom colors", isOn: $usesCustom)
						.onChange(of: usesCustom) { _, enabled in
							if enabled {
								themes = KBCustomThemePair.defaults(accent: accent)
							}
						}

					if usesCustom {
						Picker("Appearance", selection: $side) {
							ForEach(AppearanceSide.allCases, id: \.self) { Text($0.rawValue) }
						}
						.pickerStyle(.segmented)
						colorRows
						Button("Reset custom colors") {
							themes = KBCustomThemePair.defaults(accent: accent)
						}
					}
				} label: {
					Label("Advanced Colors", systemImage: "slider.horizontal.3")
				}
			} footer: {
				if let issue = issues.first {
					Label(issue, systemImage: "exclamationmark.triangle.fill")
						.foregroundStyle(.red)
				}
			}
		}
		.navigationTitle("Appearance")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .confirmationAction) {
				Button("Apply", action: apply)
					.fontWeight(.semibold)
					.disabled(!issues.isEmpty)
			}
		}
		.onAppear {
			side = systemScheme == .dark ? .dark : .light
		}
	}

	private func presetButton(_ option: KBAccent) -> some View {
		let selected = !usesCustom && accentID == option.id
		return Button {
			accentID = option.id
			usesCustom = false
		} label: {
			VStack(spacing: 7) {
				ZStack {
					RoundedRectangle(cornerRadius: 8, style: .continuous)
						.fill(option.linearGradient(dark: systemScheme == .dark))
						.frame(height: 42)
					if selected {
						Image(systemName: "checkmark.circle.fill")
							.font(.title3)
							.foregroundStyle(.white)
					}
				}
				Text(option.name)
					.font(.caption)
					.foregroundStyle(.primary)
					.lineLimit(1)
			}
			.contentShape(Rectangle())
		} .buttonStyle(.plain)
		.accessibilityLabel("\(option.name) theme")
		.accessibilityValue(selected ? "Selected" : "")
	}

	@ViewBuilder private var colorRows: some View {
		ColorPicker("Letter keys", selection: color(\.keys), supportsOpacity: false)
		ColorPicker("Modifier keys", selection: color(\.special), supportsOpacity: false)
		ColorPicker("Action start", selection: color(\.accentStart), supportsOpacity: false)
		ColorPicker("Action end", selection: color(\.accentEnd), supportsOpacity: false)
		ColorPicker("Key text", selection: color(\.text), supportsOpacity: false)
		ColorPicker("Background top", selection: color(\.bgStart), supportsOpacity: false)
		ColorPicker("Background bottom", selection: color(\.bgEnd), supportsOpacity: false)
	}

	private func color(_ keyPath: WritableKeyPath<KBCustomTheme, UInt32>) -> Binding<Color> {
		Binding(
			get: { Color(uiColor: UIColor(hex: selectedTheme[keyPath: keyPath])) },
			set: { newValue in
				var value = selectedTheme
				value[keyPath: keyPath] = Self.hex(UIColor(newValue))
				value.dark = side == .dark
				selectedTheme = value
			}
		)
	}

	private var selectedTheme: KBCustomTheme {
		get { side == .dark ? themes.dark : themes.light }
		nonmutating set {
			if side == .dark { themes.dark = newValue } else { themes.light = newValue }
		}
	}

	private func apply() {
		KBSettings.applyAppearance(
			accentID: accentID,
			customThemes: themes,
			enabled: usesCustom
		)
		store.accentID = accentID
		dismiss()
	}

	private static func hex(_ color: UIColor) -> UInt32 {
		var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
		guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 0 }
		func channel(_ value: CGFloat) -> UInt32 {
			UInt32(min(255, max(0, (value * 255).rounded())))
		}
		return channel(red) << 16 | channel(green) << 8 | channel(blue)
	}

	private static func contrastIssues(in theme: KBCustomTheme, label: String) -> [String] {
		let pairs = [
			("letter keys", theme.keys),
			("modifier keys", theme.special),
			("background", theme.bgStart),
			("background", theme.bgEnd),
		]
		return pairs.compactMap { role, fill in
			contrast(theme.text, fill) < 4.5
				? "\(label) \(role) need stronger text contrast."
				: nil
		}
	}

	private static func contrast(_ first: UInt32, _ second: UInt32) -> Double {
		let a = relativeLuminance(first)
		let b = relativeLuminance(second)
		return (max(a, b) + 0.05) / (min(a, b) + 0.05)
	}

	private static func relativeLuminance(_ value: UInt32) -> Double {
		func linear(_ byte: UInt32) -> Double {
			let component = Double(byte) / 255
			return component <= 0.04045
				? component / 12.92
				: pow((component + 0.055) / 1.055, 2.4)
		}
		return 0.2126 * linear((value >> 16) & 0xFF)
			+ 0.7152 * linear((value >> 8) & 0xFF)
			+ 0.0722 * linear(value & 0xFF)
	}
}
