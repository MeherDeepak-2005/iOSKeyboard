#if DEBUG
import SwiftUI

struct DesignLabSpec {
	enum Flow: String, CaseIterable {
		case home, appearance, achievements, language, media, keyboard
	}

	let flow: Flow
	let variant: Int

	static var commandLine: DesignLabSpec? {
		let args = CommandLine.arguments
		guard let flowIndex = args.firstIndex(of: "--design-flow"),
			  args.indices.contains(flowIndex + 1),
			  let flow = Flow(rawValue: args[flowIndex + 1]),
			  let variantIndex = args.firstIndex(of: "--design-variant"),
			  args.indices.contains(variantIndex + 1),
			  let variant = Int(args[variantIndex + 1]) else { return nil }
		return DesignLabSpec(flow: flow, variant: min(max(variant, 0), 9))
	}
}

private struct LabTokens {
	let name: String
	let radius: CGFloat
	let gap: CGFloat
	let rowHeight: CGFloat
	let contentInset: CGFloat
	let outline: Bool
	let accentWash: Bool
	let shadow: Bool
	let mediaColumns: Int

	static let variants: [LabTokens] = [
		.init(name: "Native compact", radius: 12, gap: 12, rowHeight: 50, contentInset: 16, outline: false, accentWash: false, shadow: false, mediaColumns: 2),
		.init(name: "Native soft", radius: 16, gap: 14, rowHeight: 52, contentInset: 16, outline: false, accentWash: true, shadow: false, mediaColumns: 2),
		.init(name: "Dense utility", radius: 9, gap: 9, rowHeight: 46, contentInset: 14, outline: true, accentWash: false, shadow: false, mediaColumns: 3),
		.init(name: "Airy rounded", radius: 20, gap: 18, rowHeight: 56, contentInset: 20, outline: false, accentWash: false, shadow: true, mediaColumns: 2),
		.init(name: "Accent rail", radius: 14, gap: 13, rowHeight: 52, contentInset: 16, outline: true, accentWash: true, shadow: false, mediaColumns: 3),
		.init(name: "Monochrome", radius: 12, gap: 12, rowHeight: 50, contentInset: 18, outline: true, accentWash: false, shadow: false, mediaColumns: 2),
		.init(name: "Layered", radius: 18, gap: 16, rowHeight: 54, contentInset: 18, outline: false, accentWash: true, shadow: true, mediaColumns: 2),
		.init(name: "Flat grouped", radius: 8, gap: 11, rowHeight: 48, contentInset: 14, outline: true, accentWash: false, shadow: false, mediaColumns: 3),
		.init(name: "Balanced", radius: 15, gap: 14, rowHeight: 52, contentInset: 16, outline: false, accentWash: true, shadow: false, mediaColumns: 2),
		.init(name: "Large touch", radius: 18, gap: 16, rowHeight: 58, contentInset: 18, outline: false, accentWash: false, shadow: true, mediaColumns: 2),
	]
}

struct DesignLabView: View {
	let spec: DesignLabSpec
	@Environment(\.colorScheme) private var scheme
	private var tokens: LabTokens { LabTokens.variants[spec.variant] }
	private var emerald: Color { Color(red: 0.12, green: 0.62, blue: 0.36) }

	var body: some View {
		ZStack(alignment: .bottomTrailing) {
			flow
			Text("V\(spec.variant + 1) · \(tokens.name)")
				.font(.caption2.weight(.semibold))
				.padding(.horizontal, 9)
				.padding(.vertical, 5)
				.background(.ultraThinMaterial, in: Capsule())
				.padding(8)
		}
		.tint(.blue)
	}

	@ViewBuilder private var flow: some View {
		switch spec.flow {
		case .home: labPage(title: "Glyph") { homeContent }
		case .appearance: labPage(title: "Appearance", back: true) { appearanceContent }
		case .achievements: labPage(title: "Achievements", back: true) { achievementsContent }
		case .language: languageContent
		case .media: mediaContent
		case .keyboard: keyboardContent
		}
	}

	private func labPage<Content: View>(title: String, back: Bool = false,
									@ViewBuilder content: () -> Content) -> some View {
		ScrollView {
			VStack(alignment: .leading, spacing: tokens.gap) {
				if back {
					Label("Glyph", systemImage: "chevron.left")
						.font(.body)
						.foregroundStyle(.blue)
				}
				Text(title).font(.largeTitle.bold())
				content()
			}
			.padding(.horizontal, tokens.contentInset)
			.padding(.top, 18)
			.padding(.bottom, 40)
		}
		.background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
	}

	private var homeContent: some View {
		VStack(alignment: .leading, spacing: tokens.gap) {
			labCard {
				HStack(spacing: 13) {
					medal(size: 52)
					VStack(alignment: .leading, spacing: 5) {
						HStack { Text("Bronze League").font(.headline); Spacer(); Text("12,480 words").font(.caption).foregroundStyle(.secondary) }
						ProgressView(value: 0.62).tint(.brown)
						Label("6-day streak", systemImage: "flame.fill").font(.caption).foregroundStyle(.secondary)
					}
					Image(systemName: "chevron.right").foregroundStyle(.tertiary)
				}
			}
			labCard {
				HStack(spacing: 12) {
					Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
						.frame(width: 28, height: 28).background(.green, in: Circle())
					Text("Glyph is ready").font(.subheadline.weight(.semibold))
					Spacer()
					Image(systemName: "xmark").foregroundStyle(.tertiary)
				}
			}
			sectionLabel("KEYBOARD")
			labCard(padding: 0) {
				settingsRow("globe", tint: .blue, title: "Language", value: "English")
				Divider().padding(.leading, 50)
				settingsRow("paintpalette.fill", tint: .purple, title: "Appearance", value: "Emerald", swatch: emerald)
				Divider().padding(.leading, 50)
				settingsRow("hand.tap.fill", tint: .orange, title: "Haptic Feedback", toggle: true)
			}
			sectionLabel("LEARNED WORDS")
			labCard { Label("Reset learned words", systemImage: "trash").foregroundStyle(.red) }
		}
	}

	private var appearanceContent: some View {
		VStack(alignment: .leading, spacing: tokens.gap) {
			sectionLabel("THEME")
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 10) {
					ForEach(Array([Color.gray, Color.black, Color.blue, emerald, Color.pink].enumerated()), id: \.offset) { index, color in
						VStack(spacing: 6) {
							miniKeyboard(color: color, selected: index == 3)
							Text(["System", "Graphite", "Ocean", "Emerald", "Rose"][index]).font(.caption2).foregroundStyle(.secondary)
						}
					}
			}
		}
		labCard { HStack { Text("Custom Theme"); Spacer(); Toggle("", isOn: .constant(true)).labelsHidden() } }
		keyboardPreview
		Picker("", selection: .constant(0)) {
			Text("Keys").tag(0); Text("Special").tag(1); Text("Action").tag(2); Text("Labels").tag(3); Text("Background").tag(4)
		}.pickerStyle(.segmented)
		labCard {
			HStack(spacing: 14) {
				ForEach([Color.white, Color(red: 0.92, green: 0.88, blue: 0.8), Color(red: 0.82, green: 0.85, blue: 0.9), Color.gray, Color(red: 0.25, green: 0.18, blue: 0.22), Color(red: 0.12, green: 0.2, blue: 0.28)], id: \.self) { color in
					Circle().fill(color).frame(width: 36, height: 36).overlay(Circle().stroke(.primary.opacity(0.12)))
				}
			}
		}
		}
	}

	private var achievementsContent: some View {
		VStack(spacing: tokens.gap) {
			labCard {
				VStack(spacing: 10) {
					medal(size: 76)
					Text("Bronze").font(.title2.bold())
					Text("12,480 words").foregroundStyle(.secondary)
					ProgressView(value: 0.62).tint(.brown)
					Text("7,520 words to Silver").font(.caption).foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity)
			}
			labCard {
				VStack(alignment: .leading, spacing: 12) {
					HStack { Text("Last 14 days").font(.headline); Spacer(); Text("Best · Tue · 1,204").font(.caption).foregroundStyle(.secondary) }
					HStack(alignment: .bottom, spacing: 7) {
						ForEach([12, 25, 19, 39, 31, 11, 45, 51, 34, 60, 82, 47, 55, 67], id: \.self) { value in
							RoundedRectangle(cornerRadius: 3).fill(value == 82 ? Color.blue : Color.secondary.opacity(0.18)).frame(height: CGFloat(value))
						}
					}
					.frame(height: 86, alignment: .bottom)
				}
			}
			HStack(spacing: tokens.gap) {
				statTile("Tapped · Glided", "8,912 · 3,568", symbol: "keyboard")
				statTile("Streak", "6 days", symbol: "flame.fill")
			}
			sectionLabel("TROPHIES · 5 OF 8").frame(maxWidth: .infinity, alignment: .leading)
			LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
				ForEach(Array(["character.cursor.ibeam", "pencil.line", "book", "scribble", "flame", "calendar", "infinity", "mountain.2"].enumerated()), id: \.offset) { index, symbol in
					VStack(spacing: 7) {
						Image(systemName: symbol).frame(width: 42, height: 42).background(index < 5 ? Color.orange.opacity(0.28) : Color.secondary.opacity(0.12), in: Circle())
						Text(["First Words", "Wordsmith", "Lexicon", "Glide", "Streak", "Month", "Glide Pro", "Marathon"][index]).font(.system(size: 10, weight: .semibold)).lineLimit(2)
					}
					.frame(maxWidth: .infinity).padding(.vertical, 10)
					.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: tokens.radius))
				}
			}
		}
	}

	private var languageContent: some View {
		ZStack(alignment: .bottom) {
			labPage(title: "Glyph") { homeContent }.brightness(-0.28).allowsHitTesting(false)
			VStack(alignment: .leading, spacing: 14) {
				Capsule().fill(.secondary.opacity(0.3)).frame(width: 38, height: 5).frame(maxWidth: .infinity)
				Text("Language").font(.title2.bold())
				ForEach(Array(KBLanguage.allCases.enumerated()), id: \.offset) { index, language in
					HStack {
						Text(language.rawValue).foregroundStyle(index == 0 ? .primary : .secondary)
						Spacer()
						if index == 0 { Image(systemName: "checkmark").foregroundStyle(.blue) }
						else { Text("Coming soon").font(.caption2).padding(.horizontal, 8).padding(.vertical, 4).background(.secondary.opacity(0.1), in: Capsule()) }
					}
					.frame(height: tokens.rowHeight)
					if index < 2 { Divider() }
				}
				.padding(.horizontal, 14)
				.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: tokens.radius))
			}
			.padding(tokens.contentInset)
			.padding(.bottom, 18)
			.background(Color(uiColor: .systemBackground), in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
		}
		.ignoresSafeArea(edges: .bottom)
	}

	private var mediaContent: some View {
		VStack(spacing: 0) {
			Spacer(minLength: 200)
			VStack(spacing: 8) {
				HStack(spacing: 6) {
					Text("ABC").font(.subheadline.bold()).padding(.horizontal, 12).frame(height: 36).background(.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
					Picker("", selection: .constant(0)) { Text("GIFs").tag(0); Text("Stickers").tag(1) }.pickerStyle(.segmented).frame(width: 158)
					HStack { Image(systemName: "magnifyingglass"); Text("Search").foregroundStyle(.secondary); Spacer() }
						.font(.subheadline).padding(.horizontal, 10).frame(height: 36).background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
				}
				LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: tokens.mediaColumns), spacing: 6) {
					ForEach(0..<9) { index in
						RoundedRectangle(cornerRadius: tokens.radius)
							.fill([Color.orange, .purple, .mint, .pink, .blue, .cyan][index % 6].gradient)
							.aspectRatio(tokens.mediaColumns == 2 ? 1.55 : 1, contentMode: .fit)
							.overlay(alignment: .bottomLeading) { Text(["Excited", "Slow clap", "Mind blown", "Happy dance", "Facepalm", "No way"][index % 6]).font(.caption2.bold()).foregroundStyle(.white).padding(7) }
					}
				}
				Text("Powered by KLIPY").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
			}
			.padding(8)
			.background(Color(uiColor: .secondarySystemBackground))
		}
		.background(Color(uiColor: scheme == .dark ? .black : .systemGroupedBackground).ignoresSafeArea())
	}

	private var keyboardContent: some View {
		VStack(spacing: 0) {
			VStack(alignment: .leading) {
				Spacer()
				Text("Lunch tomorrow?").padding(10).background(.secondary.opacity(0.16), in: Capsule())
			}.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
			VStack(spacing: 7) {
				HStack {
					ForEach(["this", "Might", "right"], id: \.self) { word in
						Text(word).frame(maxWidth: .infinity).frame(height: 34)
							.background(word == "Might" ? Color.white.opacity(scheme == .dark ? 0.17 : 0.55) : .clear, in: RoundedRectangle(cornerRadius: min(15, tokens.radius)))
					}
				}
				ForEach(["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"], id: \.self) { row in
					HStack(spacing: 5) {
						ForEach(Array(row), id: \.self) { key in
							Text(String(key)).font(.title3).frame(maxWidth: .infinity).frame(height: 44)
								.background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: row == "ZXCVBNM" ? tokens.radius : max(5, tokens.radius - 8)))
						}
					}
				}
				HStack(spacing: 6) {
					Text("123").frame(width: 62); Image(systemName: "face.smiling").frame(width: 42)
					Text("space").frame(maxWidth: .infinity)
					Text("send").foregroundStyle(.white).frame(width: 76).background(.blue.gradient, in: Capsule())
				}.frame(height: 44)
			}
			.padding(6)
			.background(Color(uiColor: .secondarySystemBackground))
		}
		.background(Color(uiColor: scheme == .dark ? .black : .systemBackground).ignoresSafeArea())
	}

	private func labCard<Content: View>(padding: CGFloat = 14, @ViewBuilder content: () -> Content) -> some View {
		content()
			.padding(padding)
			.background(tokens.accentWash ? emerald.opacity(scheme == .dark ? 0.07 : 0.035) : Color.clear)
			.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: tokens.radius, style: .continuous))
			.overlay { if tokens.outline { RoundedRectangle(cornerRadius: tokens.radius).stroke(.primary.opacity(0.08)) } }
			.shadow(color: tokens.shadow ? .black.opacity(0.08) : .clear, radius: 8, y: 3)
	}

	private func settingsRow(_ icon: String, tint: Color, title: String, value: String? = nil,
							 swatch: Color? = nil, toggle: Bool = false) -> some View {
		HStack(spacing: 12) {
			Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
				.frame(width: 30, height: 30).background(tint, in: RoundedRectangle(cornerRadius: 7))
			Text(title)
			Spacer()
			if let value { Text(value).foregroundStyle(.secondary) }
			if let swatch { Circle().fill(swatch).frame(width: 18, height: 18) }
			if toggle { Toggle("", isOn: .constant(true)).labelsHidden() }
			else if value != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
		}
		.padding(.horizontal, 14)
		.frame(height: tokens.rowHeight)
	}

	private func sectionLabel(_ text: String) -> some View {
		Text(text).font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
	}

	private func medal(size: CGFloat) -> some View {
		Circle().fill(LinearGradient(colors: [Color(red: 0.89, green: 0.67, blue: 0.49), .brown], startPoint: .top, endPoint: .bottom))
			.frame(width: size, height: size)
			.overlay(Circle().stroke(Color.brown.opacity(0.45), lineWidth: max(3, size * 0.08)))
	}

	private func miniKeyboard(color: Color, selected: Bool) -> some View {
		RoundedRectangle(cornerRadius: tokens.radius)
			.fill(color.opacity(scheme == .dark ? 0.28 : 0.18))
			.frame(width: 92, height: 66)
			.overlay {
				VStack(spacing: 4) {
					HStack(spacing: 3) { ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.55)).frame(width: 14, height: 9) } }
					HStack(spacing: 3) { RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.35)).frame(width: 20, height: 9); RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.45)).frame(width: 28, height: 9); RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 18, height: 9) }
				}
			}
			.overlay(RoundedRectangle(cornerRadius: tokens.radius).stroke(selected ? Color.blue : .primary.opacity(0.06), lineWidth: selected ? 2 : 1))
	}

	private var keyboardPreview: some View {
		VStack(spacing: 5) {
			ForEach(["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"], id: \.self) { row in
				HStack(spacing: 4) {
					ForEach(Array(row), id: \.self) { key in
						Text(String(key)).font(.caption).frame(maxWidth: .infinity).frame(height: 34).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6))
					}
				}
			}
			HStack { Text("123"); Spacer(); Text("space"); Spacer(); Text("return").foregroundStyle(.white).padding(.horizontal, 14).background(emerald, in: Capsule()) }.font(.caption).frame(height: 34)
		}
		.padding(8)
		.background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: tokens.radius))
	}

	private func statTile(_ title: String, _ value: String, symbol: String) -> some View {
		labCard {
			VStack(alignment: .leading, spacing: 6) {
				Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
				Text(value).font(.title3.bold()).minimumScaleFactor(0.7)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}
}
#endif
