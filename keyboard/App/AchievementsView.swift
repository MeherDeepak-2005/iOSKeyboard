import SwiftUI
import Charts

// Achievements — the gamification surface. The banner replaces the old ad carousel
// on the home screen (league + streak at a glance); tapping it opens the full page:
// 14-day typing graph (tap vs glide), league progress, stats, and the trophy case.
// Reads the KBStats blob the extension maintains; the app never writes it.

// MARK: - Banner (home screen, ex-ad slot)

struct AchievementBanner: View {
	@State private var stats = KBStatsData()

	private var league: KBLeague { KBLeague.league(for: stats.total) }
	private var streak: Int { KBStats.displayStreak(stats) }

	var body: some View {
		NavigationLink {
			AchievementsView()
		} label: {
			banner
		}
		.buttonStyle(.plain)
		.accessibilityIdentifier("achievements.banner")
		.onAppear { stats = KBStats.load() }
	}

	private var banner: some View {
		let g = league.gradient
		let leagueGradient = LinearGradient(
			colors: [Color(uiColor: UIColor(hex: g.start)), Color(uiColor: UIColor(hex: g.end))],
			startPoint: .topLeading,
			endPoint: .bottomTrailing)
		return HStack(spacing: 12) {
			ZStack {
				Circle()
					.fill(leagueGradient)
					.frame(width: 42, height: 42)
					Image(systemName: league.symbol)
					.font(.system(size: 18, weight: .semibold))
					.foregroundStyle(.white)
			}
			VStack(alignment: .leading, spacing: 4) {
				Text("\(league.rawValue) League")
					.font(.subheadline.weight(.semibold))
				HStack(spacing: 8) {
					ProgressView(value: KBLeague.progress(for: stats.total))
						.tint(Color(uiColor: UIColor(hex: g.end)))
					Text("\(stats.total.formatted())")
						.font(.caption.monospacedDigit())
						.foregroundStyle(.secondary)
				}
				Label("\(streak)-day streak", systemImage: "flame.fill")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer(minLength: 4)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
		}
	}
}

// MARK: - Full page

struct AchievementsView: View {
	@State private var stats = KBStatsData()

	private var league: KBLeague { KBLeague.league(for: stats.total) }

	/// Last 14 days, oldest → newest, zero-filled so the chart never has gaps.
	private var recentDays: [(label: String, typed: Int, glided: Int)] {
		let cal = Calendar.current
		let fmt = DateFormatter()
		fmt.dateFormat = "d/M"
		return (0..<14).reversed().compactMap { back in
			guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { return nil }
			let stat = stats.days[KBStats.dayKey(day)] ?? KBDayStat()
			return (fmt.string(from: day), stat.typed, stat.glided)
		}
	}

	private var glidePercent: Int {
		stats.total > 0 ? Int((Double(stats.totalGlided) / Double(stats.total) * 100).rounded()) : 0
	}

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 14) {
				leagueCard
				sectionHeader("Last 14 days")
				chart
				sectionHeader("Your numbers")
				LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
					statTile("keyboard", "Tapped", stats.totalTyped.formatted())
					statTile("hand.draw.fill", "Glided", "\(stats.totalGlided.formatted()) · \(glidePercent)%")
					statTile("bolt.fill", "Best day", stats.bestDay.formatted())
					statTile("flame.fill", "Best streak", "\(stats.bestStreak) days")
				}
				sectionHeader("Trophies · \(earnedTrophyCount) of \(KBStats.trophies.count)")
				trophyGrid
			}
			.padding(.horizontal, 16)
			.padding(.bottom, 24)
		}
		.background(Color(uiColor: .systemGroupedBackground))
		.navigationTitle("Achievements")
		.navigationBarTitleDisplayMode(.large)
		.onAppear { stats = KBStats.load() }
	}

	private var earnedTrophyCount: Int { KBStats.trophies.filter { $0.isEarned(stats) }.count }

	private var leagueCard: some View {
		let g = league.gradient
		let next = league.next
		return VStack(spacing: 8) {
			Image(systemName: league.symbol)
				.font(.system(size: 38, weight: .semibold))
				.foregroundStyle(LinearGradient(colors: [Color(uiColor: UIColor(hex: g.start)),
														 Color(uiColor: UIColor(hex: g.end))],
												startPoint: .top, endPoint: .bottom))
			Text("\(league.rawValue) League")
				.font(.title3.bold())
			if let next {
				ProgressView(value: KBLeague.progress(for: stats.total))
					.tint(Color(uiColor: UIColor(hex: g.end)))
				Text("\(max(0, next.floor - stats.total).formatted()) words to \(next.rawValue)")
					.font(.caption)
					.foregroundStyle(.secondary)
			} else {
				Text("Top league — nothing above Diamond.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity)
		.padding(16)
		.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
		}
	}

	private var chart: some View {
		Chart {
			ForEach(recentDays, id: \.label) { day in
				BarMark(x: .value("Day", day.label), y: .value("Words", day.typed))
					.foregroundStyle(by: .value("Kind", "Tapped"))
				BarMark(x: .value("Day", day.label), y: .value("Words", day.glided))
					.foregroundStyle(by: .value("Kind", "Glided"))
			}
		}
		.chartForegroundStyleScale(["Tapped": Color.accentColor, "Glided": Color.orange])
		.chartXAxis {
			AxisMarks { value in
				// 14 labels don't fit — every other one keeps it readable.
				if value.index % 2 == 0 { AxisValueLabel() }
				AxisGridLine()
			}
		}
		.frame(height: 140)
		.padding(12)
		.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}

	private func sectionHeader(_ title: String) -> some View {
		Text(title.uppercased())
			.font(.caption.weight(.semibold))
			.foregroundStyle(.secondary)
			.padding(.horizontal, 2)
	}

	private func statTile(_ icon: String, _ title: String, _ value: String) -> some View {
		VStack(alignment: .leading, spacing: 7) {
			HStack(spacing: 6) {
			Image(systemName: icon)
				.frame(width: 18)
				.foregroundStyle(.secondary)
				Text(title)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Text(value)
				.font(.headline.monospacedDigit())
				.lineLimit(1)
				.minimumScaleFactor(0.8)
		}
		.frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
		.padding(12)
		.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}

	private var trophyGrid: some View {
		LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
			ForEach(KBStats.trophies) { trophy in
				let earned = trophy.isEarned(stats)
				VStack(spacing: 6) {
					Image(systemName: trophy.symbol)
						.font(.system(size: 22, weight: .semibold))
						.frame(height: 28)
						.foregroundStyle(earned ? Color.yellow.gradient : Color.gray.opacity(0.45).gradient)
					Text(trophy.name)
						.font(.caption.bold())
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: .infinity)
				.frame(height: 74)
				.background(
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.fill(Color(uiColor: .secondarySystemGroupedBackground))
				)
				.opacity(earned ? 1 : 0.75)
			}
		}
		.padding(.vertical, 6)
	}
}
