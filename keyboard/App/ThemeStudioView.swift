import SwiftUI
import PhotosUI

// One appearance surface for presets and custom keyboard colors.

struct ThemeStudioView: View {
	fileprivate enum Element: String, CaseIterable {
		case keys = "Keys", special = "Special", action = "Action", text = "Text", background = "Background"
	}
	private enum BGSlot: String, CaseIterable { case from = "From", to = "To" }

	@EnvironmentObject private var store: SettingsStore
	@Environment(\.colorScheme) private var scheme
	@State private var theme = KBSettings.customTheme ?? KBCustomTheme()
	@State private var enabled = KBSettings.customThemeEnabled
	@State private var selection: Element = .keys
	@State private var bgSlot: BGSlot = .from
	@State private var photoItem: PhotosPickerItem?
	@State private var hasPhoto = FileManager.default.fileExists(atPath: KBSettings.themePhotoURL?.path ?? "")

	/// The hue radio: 12 bases spanning the wheel plus black/white anchors.
	private static let hues: [UInt32] = [
		0xE53935, 0xF4732C, 0xF5B915, 0x7CB342, 0x2E9E5B, 0x16A89B,
		0x2F97EC, 0x3A5BD9, 0x7B4FD8, 0xC2185B, 0x8D6E63, 0x607D8B,
		0x1B1B1D, 0xFFFFFF,
	]
	private var isDark: Bool { scheme == .dark }

	var body: some View {
		List {
			Section("Theme") {
				presetCarousel
					.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 0))
			}

			Section {
				Toggle(isOn: $enabled) {
					Label("Custom Theme", systemImage: "paintbrush.pointed.fill")
				}
				.onChange(of: enabled) { _, on in
					KBSettings.customThemeEnabled = on
					if on { save() }
				}
			}

			Section("Preview") {
				DemoKeyboard(theme: previewTheme, hasPhoto: enabled && hasPhoto) { tapped in
					if enabled { selection = tapped }
				}
				.listRowInsets(EdgeInsets())
			}

			if enabled {
				Section(selection.rawValue) {
					Picker("Editing", selection: $selection) {
						ForEach(Element.allCases, id: \.self) { Text($0.rawValue) }
					}
					.pickerStyle(.menu)

					if selection == .background {
						Picker("Gradient stop", selection: $bgSlot) {
							ForEach(BGSlot.allCases, id: \.self) { Text($0.rawValue) }
						}
						.pickerStyle(.segmented)
					}

					hueRadio
					shadeRow
					ColorPicker("Fine-tune", selection: customBinding, supportsOpacity: false)
				}

				if selection == .background {
					Section("Photo") {
						PhotosPicker(selection: $photoItem, matching: .images) {
							Label(hasPhoto ? "Replace Photo" : "Choose Photo", systemImage: "photo.on.rectangle")
						}
						if hasPhoto {
							Button(role: .destructive) {
								if let url = KBSettings.themePhotoURL { try? FileManager.default.removeItem(at: url) }
								hasPhoto = false
								theme.usesPhoto = false
								save()
							} label: {
								Label("Remove Photo", systemImage: "trash")
							}
						}
					}
				}

				Section {
					Toggle(isOn: $theme.dark) {
						Label("Dark Contrast", systemImage: "moon.fill")
					}
					.onChange(of: theme.dark) { _, _ in save() }
				}
			}
		}
		.navigationTitle("Appearance")
		.navigationBarTitleDisplayMode(.inline)
		.onChange(of: photoItem) { _, item in
			guard let item else { return }
			Task { await importPhoto(item) }
		}
	}

	private var previewTheme: KBCustomTheme {
		guard !enabled else { return theme }
		let gradient = store.accent.gradient(dark: isDark)
		var value = KBCustomTheme()
		value.keys = isDark ? 0x3A3A3E : 0xFFFFFF
		value.special = isDark ? 0x2D2D31 : 0xDDE1EA
		value.text = isDark ? 0xF2F2F4 : 0x1B1B1D
		value.bgStart = isDark ? 0x202023 : 0xECEAF0
		value.bgEnd = isDark ? 0x18181A : 0xDDDCE2
		value.accentStart = gradient.start
		value.accentEnd = gradient.end
		value.dark = isDark
		return value
	}

	private var presetCarousel: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 10) {
				ForEach(KBPalette.all) { accent in
					presetSwatch(accent)
				}
			}
			.padding(.trailing, 16)
		}
	}

	private func presetSwatch(_ accent: KBAccent) -> some View {
		let selected = !enabled && store.accentID == accent.id
		return Button {
			withAnimation(.snappy) {
				enabled = false
				KBSettings.customThemeEnabled = false
				store.accentID = accent.id
			}
		} label: {
			VStack(spacing: 5) {
				miniKeyboard(accent)
					.frame(width: 70, height: 46)
					.overlay {
						if selected {
							Image(systemName: "checkmark.circle.fill")
								.font(.system(size: 15, weight: .bold))
								.foregroundStyle(.white)
								.shadow(radius: 1)
						}
					}
					.overlay {
						RoundedRectangle(cornerRadius: 8, style: .continuous)
							.strokeBorder(selected ? Color.accentColor : .primary.opacity(0.10), lineWidth: selected ? 2 : 1)
					}
				Text(accent.name)
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
		}
		.buttonStyle(.plain)
	}

	private func miniKeyboard(_ accent: KBAccent) -> some View {
		let key = isDark ? Color.white.opacity(0.20) : Color.white.opacity(0.88)
		let special = isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
		return ZStack {
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.fill(isDark ? Color(uiColor: .secondarySystemBackground) : Color(uiColor: .systemGray5))
			VStack(spacing: 3) {
				ForEach(0..<3, id: \.self) { row in
					HStack(spacing: 2) {
						ForEach(0..<(row == 1 ? 7 : 8), id: \.self) { _ in
							RoundedRectangle(cornerRadius: 2).fill(key).frame(height: 6)
						}
					}
				}
				HStack(spacing: 3) {
					RoundedRectangle(cornerRadius: 3).fill(special).frame(width: 13, height: 6)
					RoundedRectangle(cornerRadius: 3).fill(key).frame(height: 6)
					RoundedRectangle(cornerRadius: 3)
						.fill(accent.linearGradient(dark: isDark))
						.frame(width: 17, height: 6)
				}
			}
			.padding(6)
		}
	}

	// MARK: Color plumbing

	private var currentHex: UInt32 {
		switch selection {
		case .keys: return theme.keys
		case .special: return theme.special
		case .action: return theme.accentStart
		case .text: return theme.text
		case .background: return bgSlot == .from ? theme.bgStart : theme.bgEnd
		}
	}

	private func apply(_ hex: UInt32) {
		switch selection {
		case .keys: theme.keys = hex
		case .special: theme.special = hex
		case .action:
			// One pick drives the action gradient: end = the same hue, 18% darker.
			theme.accentStart = hex
			theme.accentEnd = Self.shade(hex, factor: 0.82)
		case .text: theme.text = hex
		case .background:
			if bgSlot == .from { theme.bgStart = hex } else { theme.bgEnd = hex }
			theme.usesPhoto = false     // picking a color opts out of the photo
		}
		save()
	}

	private var customBinding: Binding<Color> {
		Binding(
			get: { Color(uiColor: UIColor(hex: currentHex)) },
			set: { apply(Self.hex(of: UIColor($0))) }
		)
	}

	private func save() {
		KBSettings.customTheme = theme
		if enabled { KBSettings.customThemeEnabled = true }
	}

	// MARK: Hue radio + shades

	private var hueRadio: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 10)], spacing: 10) {
			ForEach(Self.hues, id: \.self) { hue in
				let selected = sameHueFamily(hue, currentHex)
				Circle()
					.fill(Color(uiColor: UIColor(hex: hue)))
					.overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
					.overlay(
						Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
					)
					.frame(width: 34, height: 34)
					.onTapGesture { apply(hue) }
			}
		}
		.padding(.vertical, 4)
	}

	/// Five shades of the CURRENT color's hue, dark → light. Picking a hue above
	/// then a shade here is the two-step "color + its shades" radio flow.
	private var shadeRow: some View {
		HStack(spacing: 10) {
			ForEach([0.45, 0.70, 1.0, 1.35, 1.75], id: \.self) { factor in
				let shade = Self.shade(currentHex, factor: factor)
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(Color(uiColor: UIColor(hex: shade)))
					.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
					.frame(height: 34)
					.overlay {
						if shade == currentHex {
							Image(systemName: "checkmark")
								.font(.caption.bold())
								.foregroundStyle(KeyboardTheme.luminance(shade) > 0.6 ? .black : .white)
						}
					}
					.onTapGesture { apply(shade) }
			}
		}
	}

	// MARK: Photo import (heavy downscale at save time)

	private func importPhoto(_ item: PhotosPickerItem) async {
		guard let data = try? await item.loadTransferable(type: Data.self),
			  let image = UIImage(data: data),
			  let url = KBSettings.themePhotoURL else { return }
		// Cap at keyboard pixel size (~2.5x of 390×300pt). Decoded in the extension
		// this is ≤ ~1.5 MB — the "heavily downsized" contract that keeps it cheap.
		let maxSide: CGFloat = 980
		let scale = min(1, maxSide / max(image.size.width, image.size.height))
		let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
		let small = UIGraphicsImageRenderer(size: target, format: {
			let f = UIGraphicsImageRendererFormat()
			f.scale = 1
			return f
		}()).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
		guard let jpeg = small.jpegData(compressionQuality: 0.72) else { return }
		try? jpeg.write(to: url, options: .atomic)
		theme.usesPhoto = true
		hasPhoto = true
		photoItem = nil
		save()
	}

	// MARK: Hex helpers

	static func shade(_ hex: UInt32, factor: Double) -> UInt32 {
		var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
		UIColor(hex: hex).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
		// factor < 1 darkens; > 1 lightens toward pastel (raise brightness, ease saturation).
		let nb = min(1, b * factor)
		let ns = factor > 1 ? max(0, s - (factor - 1) * 0.45) : s
		return Self.hex(of: UIColor(hue: h, saturation: ns, brightness: nb, alpha: 1))
	}

	static func hex(of color: UIColor) -> UInt32 {
		var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
		color.getRed(&r, green: &g, blue: &b, alpha: &a)
		func c(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
		return c(r) << 16 | c(g) << 8 | c(b)
	}

	private func sameHueFamily(_ a: UInt32, _ b: UInt32) -> Bool {
		var ha: CGFloat = 0, hb: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, al: CGFloat = 0
		UIColor(hex: a).getHue(&ha, saturation: &s, brightness: &v, alpha: &al)
		UIColor(hex: b).getHue(&hb, saturation: &s, brightness: &v, alpha: &al)
		return abs(ha - hb) < 0.03
	}
}

// MARK: - Interactive demo keyboard (SwiftUI, app-side only)

private struct DemoKeyboard: View {
	let theme: KBCustomTheme
	let hasPhoto: Bool
	let onTap: (ThemeStudioView.Element) -> Void
	private typealias Element = ThemeStudioView.Element

	private let rows = ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"]

	var body: some View {
		VStack(spacing: 7) {
			ForEach(rows, id: \.self) { row in
				HStack(spacing: 5) {
					if row.count == 7 { specialKey("shift.fill") }
					ForEach(Array(row), id: \.self) { ch in
						letterKey(String(ch))
					}
					if row.count == 7 { specialKey("delete.left") }
				}
			}
			HStack(spacing: 5) {
				specialKey("123", wide: true)
				letterKey("space", flex: true)
				actionKey()
			}
		}
		.padding(10)
		.background(background)
		.contentShape(Rectangle())
		.onTapGesture { onTap(.background) }   // taps that miss every key hit the deck
	}

	@ViewBuilder private var background: some View {
		if theme.usesPhoto && hasPhoto, let url = KBSettings.themePhotoURL,
		   let img = UIImage(contentsOfFile: url.path) {
			Image(uiImage: img).resizable().scaledToFill().clipped()
		} else {
			LinearGradient(colors: [Color(uiColor: UIColor(hex: theme.bgStart)),
									Color(uiColor: UIColor(hex: theme.bgEnd))],
						   startPoint: .top, endPoint: .bottom)
		}
	}

	private var textColor: Color { Color(uiColor: UIColor(hex: theme.text)) }

	private func letterKey(_ label: String, flex: Bool = false) -> some View {
		RoundedRectangle(cornerRadius: 7, style: .continuous)
			.fill(Color(uiColor: UIColor(hex: theme.keys)))
			.frame(maxWidth: flex ? .infinity : 30, minHeight: 38)
			.overlay(Text(label).font(.system(size: label.count > 1 ? 12 : 15)).foregroundStyle(textColor))
			.onTapGesture { onTap(.keys) }
			.onLongPressGesture(minimumDuration: 0.2) { onTap(.text) }
	}

	private func specialKey(_ symbol: String, wide: Bool = false) -> some View {
		RoundedRectangle(cornerRadius: 7, style: .continuous)
			.fill(Color(uiColor: UIColor(hex: theme.special)))
			.frame(width: wide ? 52 : 40, height: 38)
			.overlay(
				Group {
					if symbol.contains(".") { Image(systemName: symbol).font(.system(size: 14)) }
					else { Text(symbol).font(.system(size: 12, weight: .semibold)) }
				}
				.foregroundStyle(textColor)
			)
			.onTapGesture { onTap(.special) }
	}

	private func actionKey() -> some View {
		let glyph: Color = KeyboardTheme.luminance(theme.accentEnd) > 0.6 ? .black : .white
		return RoundedRectangle(cornerRadius: 19, style: .continuous)
			.fill(LinearGradient(colors: [Color(uiColor: UIColor(hex: theme.accentStart)),
										  Color(uiColor: UIColor(hex: theme.accentEnd))],
								 startPoint: .top, endPoint: .bottom))
			.frame(width: 74, height: 38)
			.overlay(Image(systemName: "return").font(.system(size: 14, weight: .semibold)).foregroundStyle(glyph))
			.onTapGesture { onTap(.action) }
	}
}
