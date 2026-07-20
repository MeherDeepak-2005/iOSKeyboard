import Foundation

struct KBDayStat: Codable, Equatable, Sendable {
	var typed = 0
	var glided = 0
	var total: Int { typed + glided }
}

struct KBStatsData: Codable, Equatable, Sendable {
	var days: [String: KBDayStat] = [:]
	var totalTyped = 0
	var totalGlided = 0
	var bestDay = 0
	var currentStreak = 0
	var bestStreak = 0
	var lastActiveDay = ""
	var total: Int { totalTyped + totalGlided }
}

enum KBLeague: String, CaseIterable, Sendable {
	case bronze = "Bronze", silver = "Silver", gold = "Gold", diamond = "Diamond"
	var floor: Int {
		switch self { case .bronze: 0; case .silver: 5_000; case .gold: 25_000; case .diamond: 100_000 }
	}
	var next: KBLeague? {
		switch self { case .bronze: .silver; case .silver: .gold; case .gold: .diamond; case .diamond: nil }
	}
	var symbol: String {
		switch self { case .bronze: "trophy"; case .silver: "trophy.fill"; case .gold: "crown"; case .diamond: "crown.fill" }
	}
	static func league(for total: Int) -> KBLeague { allCases.last { total >= $0.floor } ?? .bronze }
	static func progress(for total: Int) -> Double {
		let current = league(for: total)
		guard let next = current.next else { return 1 }
		return min(1, max(0, Double(total - current.floor) / Double(next.floor - current.floor)))
	}
}

struct KBTrophy: Identifiable {
	let id: String
	let name: String
	let detail: String
	let symbol: String
	let metric: KeyPath<KBStatsData, Int>
	let threshold: Int
	func isEarned(_ data: KBStatsData) -> Bool { data[keyPath: metric] >= threshold }
}

enum KBStats {
	private static let key = "kb.stats.v2"
	private static let queue = DispatchQueue(label: "keyboard.stats", qos: .utility)
	private static let lock = NSLock()
	private static var provisional: [UUID: Bool] = [:]
	private static var cached: KBStatsData?
	private static var dirtyEvents = 0
	private static let flushEvery = 10

	static func load() -> KBStatsData {
		lock.lock(); defer { lock.unlock() }
		if let cached { return cached }
		guard let data = KBSettings.sharedDefaults.data(forKey: key),
			let decoded = try? JSONDecoder().decode(KBStatsData.self, from: data) else {
			return KBStatsData()
		}
		cached = decoded
		return decoded
	}

	static func noteCommitted(glided: Bool) {
		queue.async { mutate(glided: glided) }
	}

	static func noteProvisional(glided: Bool) -> UUID {
		let id = UUID()
		lock.lock(); provisional[id] = glided; lock.unlock()
		return id
	}

	static func confirm(_ id: UUID?) {
		guard let id else { return }
		lock.lock(); let glided = provisional.removeValue(forKey: id); lock.unlock()
		if let glided { queue.async { mutate(glided: glided) } }
	}

	static func cancel(_ id: UUID?) {
		guard let id else { return }
		lock.lock(); provisional[id] = nil; lock.unlock()
	}

	static func flush() {
		queue.async { persistIfNeeded(force: true) }
	}

	/// A cross-process reset can remove the persisted key while this process still has
	/// cached state. Drop that cache before any later flush can recreate deleted data.
	static func synchronizeAfterExternalReset() {
		guard KBSettings.sharedDefaults.object(forKey: key) == nil else { return }
		lock.lock()
		cached = KBStatsData()
		provisional.removeAll(keepingCapacity: false)
		dirtyEvents = 0
		lock.unlock()
	}

	#if DEBUG
	static func isProvisionalForTesting(_ id: UUID) -> Bool {
		lock.lock(); defer { lock.unlock() }
		return provisional[id] != nil
	}
	#endif

	static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
		let components = calendar.dateComponents([.year, .month, .day], from: date)
		return String(format: "%04d-%02d-%02d", components.year ?? 0,
			components.month ?? 0, components.day ?? 0)
	}

	static func apply(words: Int, glided: Bool, on data: inout KBStatsData,
		date: Date = Date(), calendar: Calendar = .current) {
		guard words > 0 else { return }
		let day = dayKey(date, calendar: calendar)
		var daily = data.days[day] ?? KBDayStat()
		if glided { daily.glided += words; data.totalGlided += words }
		else { daily.typed += words; data.totalTyped += words }
		data.days[day] = daily
		data.bestDay = max(data.bestDay, daily.total)
		if data.lastActiveDay != day {
			let yesterday = calendar.date(byAdding: .day, value: -1, to: date)
				.map { dayKey($0, calendar: calendar) } ?? ""
			data.currentStreak = data.lastActiveDay == yesterday ? data.currentStreak + 1 : 1
			data.bestStreak = max(data.bestStreak, data.currentStreak)
			data.lastActiveDay = day
		}
		for old in data.days.keys.sorted().prefix(max(0, data.days.count - 90)) { data.days[old] = nil }
	}

	static func displayStreak(_ data: KBStatsData, now: Date = Date(),
		calendar: Calendar = .current) -> Int {
		let today = dayKey(now, calendar: calendar)
		let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
			.map { dayKey($0, calendar: calendar) } ?? ""
		return data.lastActiveDay == today || data.lastActiveDay == yesterday
			? data.currentStreak : 0
	}

	private static func mutate(glided: Bool) {
		lock.lock()
		var data = cached ?? decodeStored()
		apply(words: 1, glided: glided, on: &data)
		cached = data
		dirtyEvents += 1
		let shouldFlush = dirtyEvents >= flushEvery
		lock.unlock()
		if shouldFlush { persistIfNeeded(force: false) }
	}

	private static func decodeStored() -> KBStatsData {
		guard let blob = KBSettings.sharedDefaults.data(forKey: key),
			let decoded = try? JSONDecoder().decode(KBStatsData.self, from: blob) else { return KBStatsData() }
		return decoded
	}

	private static func persistIfNeeded(force: Bool) {
		lock.lock()
		guard let data = cached, force || dirtyEvents >= flushEvery else { lock.unlock(); return }
		dirtyEvents = 0
		lock.unlock()
		if let blob = try? JSONEncoder().encode(data) { KBSettings.sharedDefaults.set(blob, forKey: key) }
	}

	static let trophies: [KBTrophy] = [
		KBTrophy(id: "first-steps", name: "First Steps", detail: "Enter 100 words",
			symbol: "figure.walk", metric: \KBStatsData.totalTyped, threshold: 100),
		KBTrophy(id: "wordsmith", name: "Wordsmith", detail: "Enter 10,000 words",
			symbol: "pencil.and.outline", metric: \KBStatsData.totalTyped, threshold: 10_000),
		KBTrophy(id: "glide", name: "Glide", detail: "Glide 500 words",
			symbol: "hand.draw.fill", metric: \KBStatsData.totalGlided, threshold: 500),
		KBTrophy(id: "week", name: "Week Streak", detail: "Reach a 7-day streak",
			symbol: "flame.fill", metric: \KBStatsData.bestStreak, threshold: 7),
		KBTrophy(id: "month", name: "Month Streak", detail: "Reach a 30-day streak",
			symbol: "calendar", metric: \KBStatsData.bestStreak, threshold: 30),
		KBTrophy(id: "best-day", name: "Big Day", detail: "Enter 1,000 words in one day",
			symbol: "bolt.fill", metric: \KBStatsData.bestDay, threshold: 1_000),
	]
}
