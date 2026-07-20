import SwiftUI

struct AchievementBanner: View {
	@State private var stats = KBStatsData()
	private var league: KBLeague { .league(for: stats.total) }

	var body: some View {
		NavigationLink {
			AchievementsView()
		} label: {
			HStack(spacing: 12) {
				Image(systemName: league.symbol)
					.font(.system(size: 18, weight: .semibold))
					.foregroundStyle(leagueColor)
					.frame(width: 34, height: 34)
				VStack(alignment: .leading, spacing: 5) {
					Text("\(league.rawValue) League").font(.subheadline.weight(.semibold))
					ProgressView(value: KBLeague.progress(for: stats.total)).tint(leagueColor)
					Text("\(stats.total.formatted()) words entered · \(KBStats.displayStreak(stats))-day streak")
						.font(.caption).foregroundStyle(.secondary)
				}
			}
			.padding(.vertical, 3)
		}
		.accessibilityIdentifier("progress.banner")
		.onAppear { stats = KBStats.load() }
	}

	private var leagueColor: Color {
		switch league {
		case .bronze: Color(red: 0.58, green: 0.36, blue: 0.20)
		case .silver: Color(uiColor: .systemGray)
		case .gold: Color(red: 0.78, green: 0.57, blue: 0.08)
		case .diamond: Color(uiColor: .systemCyan)
		}
	}
}

struct AchievementsView: View {
	@State private var stats = KBStatsData()
	private var league: KBLeague { .league(for: stats.total) }
	private var earned: Int { KBStats.trophies.filter { $0.isEarned(stats) }.count }

	var body: some View {
		List {
			Section("League") {
				VStack(alignment: .leading, spacing: 10) {
					Label("\(league.rawValue) League", systemImage: league.symbol).font(.headline)
					ProgressView(value: KBLeague.progress(for: stats.total))
					if let next = league.next {
						Text("\(max(0, next.floor - stats.total).formatted()) words to \(next.rawValue)")
							.font(.caption).foregroundStyle(.secondary)
					}
				}
				.padding(.vertical, 4)
			}
			Section("Words entered") {
				metric("Tapped", value: stats.totalTyped, symbol: "keyboard")
				metric("Glided", value: stats.totalGlided, symbol: "hand.draw.fill")
				metric("Best day", value: stats.bestDay, symbol: "bolt.fill")
				metric("Best streak", value: stats.bestStreak, symbol: "flame.fill", suffix: " days")
			}
			Section("Trophies · \(earned) of \(KBStats.trophies.count)") {
				ForEach(KBStats.trophies) { trophy in
					let isEarned = trophy.isEarned(stats)
					HStack(spacing: 12) {
						Image(systemName: trophy.symbol)
							.foregroundStyle(isEarned ? Color.accentColor : Color.secondary)
							.frame(width: 28)
						VStack(alignment: .leading, spacing: 2) {
							Text(trophy.name)
							Text(trophy.detail).font(.caption).foregroundStyle(.secondary)
						}
						Spacer()
						Image(systemName: isEarned ? "checkmark.circle.fill" : "lock.fill")
							.foregroundStyle(isEarned ? Color.green : Color.secondary)
					}
				}
			}
		}
		.navigationTitle("Progress")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear { stats = KBStats.load() }
	}

	private func metric(_ title: String, value: Int, symbol: String, suffix: String = "") -> some View {
		HStack {
			Label(title, systemImage: symbol)
			Spacer()
			Text(value.formatted() + suffix).foregroundStyle(.secondary).monospacedDigit()
		}
	}
}
