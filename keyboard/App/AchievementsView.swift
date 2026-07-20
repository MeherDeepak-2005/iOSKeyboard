import SwiftUI

private extension KBLeague {
	var displayColor: Color {
		switch self {
		case .bronze: Color(red: 0.69, green: 0.43, blue: 0.24)
		case .silver: Color(red: 0.58, green: 0.60, blue: 0.64)
		case .gold: Color(red: 0.82, green: 0.63, blue: 0.18)
		case .diamond: Color(red: 0.18, green: 0.68, blue: 0.86)
		}
	}
}

private struct LeagueMedal: View {
	let league: KBLeague
	var size: CGFloat = 44

	var body: some View {
		Circle()
			.fill(league.displayColor.opacity(0.72))
			.overlay {
				Circle().stroke(league.displayColor, lineWidth: max(3, size * 0.09))
			}
			.overlay(alignment: .topLeading) {
				Circle()
					.fill(.white.opacity(0.18))
					.frame(width: size * 0.46, height: size * 0.46)
					.padding(size * 0.15)
			}
			.frame(width: size, height: size)
			.accessibilityHidden(true)
	}
}

struct AchievementBanner: View {
	@State private var stats = KBStatsData()
	private var league: KBLeague { .league(for: stats.total) }

	var body: some View {
		NavigationLink {
			AchievementsView()
		} label: {
			HStack(spacing: 14) {
				LeagueMedal(league: league, size: 42)
				VStack(alignment: .leading, spacing: 5) {
					HStack(alignment: .firstTextBaseline, spacing: 6) {
						Text("\(league.rawValue) League")
							.font(.subheadline.weight(.semibold))
						Text("\(stats.total.formatted()) words")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					ProgressView(value: KBLeague.progress(for: stats.total))
						.tint(league.displayColor)
					Label("\(KBStats.displayStreak(stats))-day streak", systemImage: "flame.fill")
						.font(.caption)
						.foregroundStyle(.secondary)
						.symbolRenderingMode(.monochrome)
				}
			}
			.padding(.vertical, 3)
		}
		.accessibilityIdentifier("progress.banner")
		.onAppear { stats = KBStats.load() }
	}
}

struct AchievementsView: View {
	@State private var stats = KBStatsData()
	private let calendar = Calendar.autoupdatingCurrent

	private var league: KBLeague { .league(for: stats.total) }
	private var earned: Int { KBStats.trophies.filter { $0.isEarned(stats) }.count }

	var body: some View {
		ScrollView {
			VStack(spacing: 12) {
				leagueCard
				activityCard
				HStack(spacing: 10) {
					inputCard
					streakCard
				}
				trophySection
			}
			.padding(.horizontal, 16)
			.padding(.bottom, 24)
		}
		.background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
		.navigationTitle("Achievements")
		.navigationBarTitleDisplayMode(.large)
		.onAppear { stats = KBStats.load() }
	}

	private var leagueCard: some View {
		VStack(spacing: 10) {
			LeagueMedal(league: league, size: 72)
			Text(league.rawValue)
				.font(.title3.weight(.bold))
			Text("\(stats.total.formatted()) words")
				.font(.caption)
				.foregroundStyle(.secondary)
			progressBar(value: KBLeague.progress(for: stats.total), color: league.displayColor)
			if let next = league.next {
				Text("\(max(0, next.floor - stats.total).formatted()) words to \(next.rawValue)")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			HStack {
				ForEach(KBLeague.allCases, id: \.self) { tier in
					VStack(spacing: 5) {
						LeagueMedal(league: tier, size: 28)
							.opacity(tier.floor <= stats.total || tier == league ? 1 : 0.22)
						Text(tier.rawValue)
							.font(.caption2.weight(tier == league ? .semibold : .regular))
							.foregroundStyle(tier == league ? .primary : .tertiary)
					}
					.frame(maxWidth: .infinity)
				}
			}
			.padding(.top, 4)
		}
		.padding(20)
		.frame(maxWidth: .infinity)
		.background(cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}

	private var activityCard: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline) {
				Text("Last 14 days").font(.subheadline.weight(.semibold))
				Spacer()
				if let best = bestRecentDay, best.total > 0 {
					Text("Best day · \(best.date.formatted(.dateTime.weekday(.abbreviated))) · \(best.total.formatted()) words")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			HStack(alignment: .bottom, spacing: 7) {
				ForEach(Array(recentDays.enumerated()), id: \.offset) { index, day in
					RoundedRectangle(cornerRadius: 3, style: .continuous)
						.fill(index == bestRecentIndex && day.total > 0
							? Color(uiColor: .systemBlue) : Color(uiColor: .systemFill))
						.frame(maxWidth: .infinity)
						.frame(height: barHeight(day.total))
				}
			}
			.frame(height: 82, alignment: .bottom)
			HStack {
				Text("2 wks ago")
				Spacer()
				Text("today")
			}
			.font(.caption2)
			.foregroundStyle(.tertiary)
		}
		.padding(16)
		.background(cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}

	private var inputCard: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Tapped · Glided")
				.font(.caption)
				.foregroundStyle(.secondary)
			Text("\(stats.totalTyped.formatted()) · \(stats.totalGlided.formatted())")
				.font(.title3.weight(.bold))
				.monospacedDigit()
			GeometryReader { proxy in
				let total = max(1, stats.total)
				let typedWidth = proxy.size.width * CGFloat(stats.totalTyped) / CGFloat(total)
				HStack(spacing: 0) {
					Color(uiColor: .systemBlue).frame(width: typedWidth)
					league.displayColor
				}
				.clipShape(Capsule())
			}
			.frame(height: 4)
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}

	private var streakCard: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Streak")
				.font(.caption)
				.foregroundStyle(.secondary)
			Label("\(KBStats.displayStreak(stats)) days", systemImage: "flame.fill")
				.font(.title3.weight(.bold))
				.symbolRenderingMode(.monochrome)
				.foregroundStyle(.primary)
			Text("Best · \(stats.bestStreak) days")
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}

	private var trophySection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("TROPHIES · \(earned) OF \(KBStats.trophies.count)")
				.font(.caption)
				.foregroundStyle(.secondary)
				.padding(.horizontal, 16)
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
				ForEach(KBStats.trophies) { trophy in
					let isEarned = trophy.isEarned(stats)
					VStack(spacing: 7) {
						Image(systemName: trophy.symbol)
							.font(.system(size: 17, weight: .medium))
							.foregroundStyle(isEarned ? league.displayColor
								: Color(uiColor: .tertiaryLabel))
							.frame(width: 46, height: 46)
							.background((isEarned ? league.displayColor : Color(uiColor: .systemFill)).opacity(isEarned ? 0.24 : 1), in: Circle())
						Text(trophy.name)
							.font(.caption2.weight(.semibold))
							.multilineTextAlignment(.center)
							.lineLimit(2)
							.frame(minHeight: 28, alignment: .top)
						Text(trophy.detail)
							.font(.caption2)
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.minimumScaleFactor(0.75)
					}
					.padding(.horizontal, 5)
					.padding(.vertical, 12)
					.frame(maxWidth: .infinity)
					.background(cardBackground,
						in: RoundedRectangle(cornerRadius: 8, style: .continuous))
					.accessibilityElement(children: .combine)
				}
			}
		}
	}

	private var cardBackground: some ShapeStyle {
		Color(uiColor: .secondarySystemGroupedBackground)
	}

	private func progressBar(value: Double, color: Color) -> some View {
		GeometryReader { proxy in
			ZStack(alignment: .leading) {
				Capsule().fill(Color(uiColor: .systemFill))
				Capsule().fill(color).frame(width: proxy.size.width * max(0, min(1, value)))
			}
		}
		.frame(height: 4)
	}

	private var recentDays: [(date: Date, total: Int)] {
		let today = calendar.startOfDay(for: Date())
		return (0..<14).compactMap { offset in
			guard let date = calendar.date(byAdding: .day, value: offset - 13, to: today) else {
				return nil
			}
			return (date, stats.days[KBStats.dayKey(date, calendar: calendar)]?.total ?? 0)
		}
	}

	private var bestRecentIndex: Int? {
		recentDays.indices.max { recentDays[$0].total < recentDays[$1].total }
	}

	private var bestRecentDay: (date: Date, total: Int)? {
		guard let index = bestRecentIndex else { return nil }
		return recentDays[index]
	}

	private func barHeight(_ value: Int) -> CGFloat {
		let maximum = max(1, recentDays.map(\.total).max() ?? 1)
		return max(6, 82 * CGFloat(value) / CGFloat(maximum))
	}
}
