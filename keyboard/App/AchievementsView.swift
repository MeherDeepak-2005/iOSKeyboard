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
		.onAppear { stats = KBStats.load() }
	}

	private var banner: some View {
		let g = league.gradient
		return RoundedRectangle(cornerRadius: 22, style: .continuous)
			.fill(LinearGradient(colors: [Color(uiColor: UIColor(hex: g.start)),
										  Color(uiColor: UIColor(hex: g.end))],
								 startPoint: .topLeading, endPoint: .bottomTrailing))
			.overlay(
				HStack(spacing: 14) {
					Image(systemName: league.symbol)
						.font(.system(size: 34, weight: .semibold))
					VStack(alignment: .leading, spacing: 3) {
						Text("\(league.rawValue) League")
							.font(.headline)
						Text("\(stats.total.formatted()) words typed")
							.font(.caption)
							.opacity(0.9)
						ProgressView(value: KBLeague.progress(for: stats.total))
							.tint(.white)
							.frame(maxWidth: 180)
					}
					Spacer()
					VStack(spacing: 2) {
						Image(systemName: "flame.fill")
							.font(.title3)
						Text("\(streak)")
							.font(.system(.title3, design: .rounded).bold())
						Text("day streak")
							.font(.system(size: 9))
							.opacity(0.85)
					}
					Image(systemName: "chevron.right")
						.font(.footnote.bold())
						.opacity(0.7)
				}
				.foregroundStyle(.white)
				.padding(.horizontal, 18)
			)
			.padding(.horizontal)
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
		List {
			Section {
				leagueCard
			}
			Section("Last 14 days") {
				chart
			}
			Section("Your numbers") {
				statRow("keyboard", "Words typed", stats.totalTyped.formatted())
				statRow("hand.draw.fill", "Words glided", "\(stats.totalGlided.formatted()) (\(glidePercent)%)")
				statRow("bolt.fill", "Best day", "\(stats.bestDay.formatted()) words")
				statRow("flame.fill", "Best streak", "\(stats.bestStreak) days")
			}
			Section("Trophies") {
				trophyGrid
			}
		}
		.navigationTitle("Achievements")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear { stats = KBStats.load() }
	}

	private var leagueCard: some View {
		let g = league.gradient
		let next = league.next
		return VStack(spacing: 10) {
			Image(systemName: league.symbol)
				.font(.system(size: 44, weight: .semibold))
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
		.padding(.vertical, 8)
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
		.frame(height: 190)
		.padding(.vertical, 6)
	}

	private func statRow(_ icon: String, _ title: String, _ value: String) -> some View {
		HStack {
			Image(systemName: icon)
				.frame(width: 26)
				.foregroundStyle(.secondary)
			Text(title)
			Spacer()
			Text(value)
				.foregroundStyle(.secondary)
				.font(.callout.monospacedDigit())
		}
	}

	private var trophyGrid: some View {
		LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 14) {
			ForEach(KBStats.trophies) { trophy in
				let earned = trophy.isEarned(stats)
				VStack(spacing: 6) {
					Image(systemName: trophy.symbol)
						.font(.system(size: 26, weight: .semibold))
						.frame(height: 32)
						.foregroundStyle(earned ? Color.yellow.gradient : Color.gray.opacity(0.45).gradient)
					Text(trophy.name)
						.font(.caption.bold())
						.multilineTextAlignment(.center)
					Text(trophy.detail)
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: .infinity)
				.padding(.vertical, 10)
				.background(
					RoundedRectangle(cornerRadius: 12, style: .continuous)
						.fill(earned ? Color.yellow.opacity(0.12) : Color.gray.opacity(0.08))
				)
				.opacity(earned ? 1 : 0.75)
			}
		}
		.padding(.vertical, 6)
	}
}
