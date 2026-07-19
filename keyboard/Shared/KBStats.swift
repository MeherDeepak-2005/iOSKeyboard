import Foundation

// KBStats: typing gamification — words typed (tap vs glide), day streaks, leagues,
// trophies. The extension-side cost is deliberately tiny: an in-memory accumulator
// flushed to ONE small App Group JSON blob (≤ ~6 KB: 90 pruned days + lifetime
// totals) every `flushEvery` words, so the keystroke path never touches disk.
// Add this file to BOTH targets (extension writes, app reads).

struct KBDayStat: Codable, Equatable {
	var typed = 0        // words committed by tapping
	var glided = 0       // words committed by glide
	var total: Int { typed + glided }
}

struct KBStatsData: Codable, Equatable {
	/// "yyyy-MM-dd" → that day's counts. Pruned to `KBStats.keepDays` on flush —
	/// lifetime numbers live in the totals below, so pruning loses nothing the
	/// leagues/trophies need.
	var days: [String: KBDayStat] = [:]
	var totalTyped = 0
	var totalGlided = 0
	var bestDay = 0            // most words in a single calendar day
	var currentStreak = 0      // consecutive active days, today included
	var bestStreak = 0
	var lastActiveDay = ""     // day key of the most recent word
	var total: Int { totalTyped + totalGlided }
}

/// Lifetime-progression leagues (deliberately LOCAL — no server cohorts, no fake
/// competition): your league is a fact about your own history, so it can only go up.
enum KBLeague: String, CaseIterable {
	case bronze = "Bronze", silver = "Silver", gold = "Gold", diamond = "Diamond"

	/// Words that ENTER the league. ~1k words/day of normal messaging reaches
	/// Silver in under a week, Gold in a few weeks, Diamond in a season — steady,
	/// earnable pacing without being a giveaway.
	var floor: Int {
		switch self {
		case .bronze:  return 0
		case .silver:  return 5_000
		case .gold:    return 25_000
		case .diamond: return 100_000
		}
	}
	var next: KBLeague? {
		switch self {
		case .bronze: return .silver; case .silver: return .gold
		case .gold: return .diamond; case .diamond: return nil
		}
	}
	var symbol: String {
		switch self {
		case .bronze: return "trophy"
		case .silver: return "trophy.fill"
		case .gold: return "crown"
		case .diamond: return "crown.fill"
		}
	}
	/// Banner gradient (hex pairs) — bronze/silver/gold/diamond metallics.
	var gradient: (start: UInt32, end: UInt32) {
		switch self {
		case .bronze:  return (0xB0794A, 0x8A5A2E)
		case .silver:  return (0x9FA6B2, 0x6E7683)
		case .gold:    return (0xE8B93B, 0xC08F16)
		case .diamond: return (0x5AC8FA, 0x2F7CF6)
		}
	}

	static func league(for total: Int) -> KBLeague {
		allCases.last { total >= $0.floor } ?? .bronze
	}
	/// 0…1 progress from this league's floor to the next's (1 for Diamond).
	static func progress(for total: Int) -> Double {
		let l = league(for: total)
		guard let n = l.next else { return 1 }
		return min(1, max(0, Double(total - l.floor) / Double(n.floor - l.floor)))
	}
}

struct KBTrophy: Identifiable {
	let id: String
	let name: String
	let detail: String
	let symbol: String
	let isEarned: (KBStatsData) -> Bool
}

enum KBStats {
	static let flushEvery = 10        // words buffered before one blob write
	static let keepDays = 90
	private static let key = "kb.stats"
	private static var store: UserDefaults { KBSettings.sharedDefaults }

	// MARK: Storage

	static func load(from store: UserDefaults? = nil) -> KBStatsData {
		guard let data = (store ?? self.store).data(forKey: key),
			  let s = try? JSONDecoder().decode(KBStatsData.self, from: data) else { return KBStatsData() }
		return s
	}
	static func save(_ data: KBStatsData, to store: UserDefaults? = nil) {
		if let blob = try? JSONEncoder().encode(data) { (store ?? self.store).set(blob, forKey: key) }
	}

	// MARK: Day keys (fixed-format, calendar-aware)

	private static let dayFormatter: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "yyyy-MM-dd"
		return f
	}()
	static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

	// MARK: Pure mutation (unit-tested; storage-free)

	/// Fold `words` committed on `date` into `data`: day counts, lifetime totals,
	/// best-day, and the streak (same day = no change; yesterday-active = +1;
	/// anything older = reset to 1).
	static func apply(words: Int, glided: Bool, on data: inout KBStatsData,
					  date: Date = Date(), calendar: Calendar = .current) {
		guard words > 0 else { return }
		let day = dayKey(date)
		var d = data.days[day] ?? KBDayStat()
		if glided { d.glided += words; data.totalGlided += words }
		else { d.typed += words; data.totalTyped += words }
		data.days[day] = d
		data.bestDay = max(data.bestDay, d.total)

		if data.lastActiveDay != day {
			var yesterday = ""
			if let y = calendar.date(byAdding: .day, value: -1, to: date) { yesterday = dayKey(y) }
			data.currentStreak = (data.lastActiveDay == yesterday) ? data.currentStreak + 1 : 1
			data.bestStreak = max(data.bestStreak, data.currentStreak)
			data.lastActiveDay = day
		}

		if data.days.count > keepDays {
			// Keys sort chronologically (fixed yyyy-MM-dd) — drop the oldest overflow.
			for stale in data.days.keys.sorted().prefix(data.days.count - keepDays) {
				data.days[stale] = nil
			}
		}
	}

	/// The streak the APP should display: `currentStreak` is only valid if the user
	/// was active today or yesterday — older than that, the chain is already broken.
	static func displayStreak(_ data: KBStatsData, now: Date = Date(),
							  calendar: Calendar = .current) -> Int {
		let today = dayKey(now)
		var yesterday = ""
		if let y = calendar.date(byAdding: .day, value: -1, to: now) { yesterday = dayKey(y) }
		return (data.lastActiveDay == today || data.lastActiveDay == yesterday) ? data.currentStreak : 0
	}

	// MARK: Extension-side accumulator (main thread — key handlers)

	private static var pendingTyped = 0
	private static var pendingGlided = 0

	/// One committed word. Buffers in memory; hits the blob once per `flushEvery`.
	static func note(glided: Bool) {
		if glided { pendingGlided += 1 } else { pendingTyped += 1 }
		if pendingTyped + pendingGlided >= flushEvery { flush() }
	}

	/// Fold pending counts into the persisted blob. Called on the buffer filling and
	/// from viewWillDisappear, so a killed extension loses at most `flushEvery` words.
	static func flush() {
		guard pendingTyped + pendingGlided > 0 else { return }
		var data = load()
		if pendingTyped > 0 { apply(words: pendingTyped, glided: false, on: &data) }
		if pendingGlided > 0 { apply(words: pendingGlided, glided: true, on: &data) }
		pendingTyped = 0; pendingGlided = 0
		save(data)
	}

	// MARK: Trophies

	static let trophies: [KBTrophy] = [
		KBTrophy(id: "first-steps", name: "First Steps", detail: "Type 100 words",
				 symbol: "figure.walk", isEarned: { $0.total >= 100 }),
		KBTrophy(id: "chatterbox", name: "Chatterbox", detail: "Type 1,000 words",
				 symbol: "bubble.left.and.bubble.right.fill", isEarned: { $0.total >= 1_000 }),
		KBTrophy(id: "wordsmith", name: "Wordsmith", detail: "Type 10,000 words",
				 symbol: "pencil.and.outline", isEarned: { $0.total >= 10_000 }),
		KBTrophy(id: "novelist", name: "Novelist", detail: "Type 100,000 words",
				 symbol: "books.vertical.fill", isEarned: { $0.total >= 100_000 }),
		KBTrophy(id: "lift-off", name: "Lift Off", detail: "Glide 10 words",
				 symbol: "paperplane.fill", isEarned: { $0.totalGlided >= 10 }),
		KBTrophy(id: "smooth-operator", name: "Smooth Operator", detail: "Glide 500 words",
				 symbol: "wind", isEarned: { $0.totalGlided >= 500 }),
		KBTrophy(id: "glide-master", name: "Glide Master", detail: "Glide 5,000 words",
				 symbol: "hurricane", isEarned: { $0.totalGlided >= 5_000 }),
		KBTrophy(id: "warming-up", name: "Warming Up", detail: "3-day streak",
				 symbol: "flame", isEarned: { $0.bestStreak >= 3 }),
		KBTrophy(id: "week-wonder", name: "Week Wonder", detail: "7-day streak",
				 symbol: "flame.fill", isEarned: { $0.bestStreak >= 7 }),
		KBTrophy(id: "monthly-devotee", name: "Monthly Devotee", detail: "30-day streak",
				 symbol: "calendar", isEarned: { $0.bestStreak >= 30 }),
		KBTrophy(id: "century-club", name: "Century Club", detail: "100-day streak",
				 symbol: "100.circle.fill", isEarned: { $0.bestStreak >= 100 }),
		KBTrophy(id: "marathon-day", name: "Marathon Day", detail: "1,000 words in one day",
				 symbol: "bolt.fill", isEarned: { $0.bestDay >= 1_000 }),
	]
}
