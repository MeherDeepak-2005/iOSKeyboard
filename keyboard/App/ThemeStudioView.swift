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
	private var previewIsDark: Bool {
		usesCustom ? side == .dark : systemScheme == .dark
	}
	private var previewCustomTheme: KBCustomTheme? {
		guard usesCustom else { return nil }
		return previewIsDark ? themes.dark : themes.light
	}

	var body: some View {
		List {
			Section("Preview") {
				KeyboardAppearancePreview(
					accent: accent,
					customTheme: previewCustomTheme,
					dark: previewIsDark,
					languageMode: store.languageMode
				)
				.aspectRatio(390.0 / 242.0, contentMode: .fit)
				.listRowInsets(EdgeInsets())
				.listRowBackground(Color.clear)
			}

			ForEach(KBPalette.groups, id: \.title) { group in
				Section(group.title) {
					ScrollView(.horizontal) {
						HStack(spacing: 10) {
						ForEach(group.accents) { option in
							presetButton(option)
						}
						}
						.padding(.vertical, 2)
					}
					.scrollIndicators(.hidden)
					.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))
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
			VStack(spacing: 6) {
				themeMiniature(option)
				HStack(spacing: 4) {
					if selected {
						Image(systemName: "checkmark")
							.font(.caption2.weight(.bold))
							.foregroundStyle(Color(uiColor: .systemBlue))
					}
					Text(option.name)
						.font(.caption.weight(selected ? .semibold : .regular))
						.foregroundStyle(selected ? .primary : .secondary)
						.lineLimit(1)
				}
			}
			.padding(7)
			.frame(width: 108, height: 98)
			.background(Color(uiColor: .secondarySystemGroupedBackground),
				in: RoundedRectangle(cornerRadius: 8, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.stroke(selected ? Color(uiColor: .systemBlue) : .clear,
						lineWidth: selected ? 2 : 0)
			}
			.contentShape(Rectangle())
		} .buttonStyle(.plain)
		.accessibilityLabel("\(option.name) theme")
		.accessibilityValue(selected ? "Selected" : "")
	}

	private func themeMiniature(_ option: KBAccent) -> some View {
		let dark = systemScheme == .dark
		let theme = KeyboardTheme.preview(dark: dark, accent: option, customTheme: nil)
		let key = Color(uiColor: theme.key)
		let special = Color(uiColor: theme.specialKey)
		return VStack(spacing: 4) {
			HStack(spacing: 3) {
				ForEach(0..<4, id: \.self) { _ in
					RoundedRectangle(cornerRadius: 3).fill(key)
				}
			}
			HStack(spacing: 3) {
				RoundedRectangle(cornerRadius: 3).fill(special).frame(width: 16)
				RoundedRectangle(cornerRadius: 3).fill(key)
				RoundedRectangle(cornerRadius: 3)
					.fill(LinearGradient(colors: [Color(uiColor: theme.accentStart),
						Color(uiColor: theme.accentEnd)], startPoint: .leading, endPoint: .trailing))
					.frame(width: 18)
			}
		}
		.padding(9)
		.frame(height: 58)
		.background(Color(uiColor: theme.fallbackBackgroundTop),
			in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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

/// In-app appearance preview backed by the production UIKit renderer. iOS does not
/// allow an app to embed or drive its keyboard-extension process, so sharing the exact
/// view implementation is the deterministic equivalent without duplicating layout.
private struct KeyboardAppearancePreview: UIViewRepresentable {
	let accent: KBAccent
	let customTheme: KBCustomTheme?
	let dark: Bool
	let languageMode: KBLanguageMode

	func makeUIView(context: Context) -> KeyboardAppearancePreviewHost {
		KeyboardAppearancePreviewHost()
	}

	func updateUIView(_ host: KeyboardAppearancePreviewHost, context: Context) {
		host.update(accent: accent, customTheme: customTheme, dark: dark,
			languageMode: languageMode)
	}
}

private final class KeyboardAppearancePreviewHost: UIView {
	private struct Configuration: Equatable {
		let accentID: String
		let customTheme: KBCustomTheme?
		let dark: Bool
		let languageMode: KBLanguageMode
	}

	private let referenceWidth: CGFloat = 390
	private var configuration: Configuration?
	private var keyboard: KeyboardView?

	override init(frame: CGRect) {
		super.init(frame: frame)
		backgroundColor = .clear
		clipsToBounds = true
		isAccessibilityElement = true
		accessibilityLabel = "Keyboard appearance preview"
		accessibilityTraits = .image
	}

	required init?(coder: NSCoder) { fatalError() }

	func update(accent: KBAccent, customTheme: KBCustomTheme?, dark: Bool,
		languageMode: KBLanguageMode) {
		let next = Configuration(accentID: accent.id, customTheme: customTheme,
			dark: dark, languageMode: languageMode)
		guard next != configuration else { return }
		configuration = next

		keyboard?.removeFromSuperview()
		let theme = KeyboardTheme.preview(dark: dark, accent: accent,
			customTheme: customTheme)
		let keyboard = KeyboardView(theme: theme, showsGlobe: false,
			languageMode: languageMode)
		keyboard.setSuggestions(["might", "this", "type"], highlightPrimary: true)
		keyboard.setActionTitle("Done")
		keyboard.isUserInteractionEnabled = false
		keyboard.accessibilityElementsHidden = true
		addSubview(keyboard)
		self.keyboard = keyboard
		setNeedsLayout()
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		guard let keyboard, bounds.width > 0, bounds.height > 0 else { return }
		keyboard.transform = .identity
		let referenceSize = CGSize(width: referenceWidth, height: keyboard.keyboardHeight)
		keyboard.frame = CGRect(origin: .zero, size: referenceSize)
		keyboard.layoutIfNeeded()
		let scale = min(bounds.width / referenceSize.width,
			bounds.height / referenceSize.height)
		keyboard.transform = CGAffineTransform(scaleX: scale, y: scale)
		keyboard.center = CGPoint(x: bounds.midX, y: bounds.midY)
	}
}
