import Foundation

// KBClipboard: the clipboard-history store shared between app and extension.
//
// Text only, size-capped, App Group-backed (a small JSON file — items are too big
// for UserDefaults churn). Privacy contract: pasteboard CONTENTS are read only on
// an explicit user tap (the strip's paste chip); detection of "something new was
// copied" uses metadata alone (changeCount / hasStrings), which iOS does not
// surface to the user as a paste. Add this file to BOTH targets.

struct KBClipboardItem: Codable, Equatable {
	var text: String
	var pinned: Bool
	var date: Date
}

enum KBClipboard {
	static let maxItems = 50                  // unpinned history ring; pins ride above it
	static let maxPins = 10
	static let maxItemLength = 10_000         // clip pathological copies, keep the file small

	private static var store: UserDefaults { KBSettings.sharedDefaults }

	/// `override` is for tests; production uses the App Group container.
	static func fileURL(_ override: URL? = nil) -> URL {
		if let override { return override }
		let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KBSettings.appGroup)
			?? FileManager.default.temporaryDirectory
		return dir.appendingPathComponent("clipboard.json")
	}

	static func all(at url: URL? = nil) -> [KBClipboardItem] {
		guard let data = try? Data(contentsOf: fileURL(url)),
			  let items = try? JSONDecoder().decode([KBClipboardItem].self, from: data) else { return [] }
		return items
	}

	private static func save(_ items: [KBClipboardItem], at url: URL?) {
		guard let data = try? JSONEncoder().encode(items) else { return }
		try? data.write(to: fileURL(url), options: .atomic)
	}

	/// Insert (or resurface) a copy. Dedupe by exact text — re-copying moves the item
	/// to the front and keeps its pin. Unpinned overflow drops oldest-first.
	static func add(_ text: String, at url: URL? = nil) {
		let t = String(text.prefix(maxItemLength))
		guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		var items = all(at: url)
		var pinned = false
		if let i = items.firstIndex(where: { $0.text == t }) {
			pinned = items[i].pinned
			items.remove(at: i)
		}
		items.insert(KBClipboardItem(text: t, pinned: pinned, date: Date()), at: 0)
		var unpinned = 0
		items = items.filter { item in
			if item.pinned { return true }
			unpinned += 1
			return unpinned <= maxItems
		}
		save(items, at: url)
	}

	static func togglePin(_ text: String, at url: URL? = nil) {
		var items = all(at: url)
		guard let i = items.firstIndex(where: { $0.text == text }) else { return }
		if !items[i].pinned, items.filter(\.pinned).count >= maxPins { return }
		items[i].pinned.toggle()
		save(items, at: url)
	}

	static func remove(_ text: String, at url: URL? = nil) {
		save(all(at: url).filter { $0.text != text }, at: url)
	}

	static func clearUnpinned(at url: URL? = nil) {
		save(all(at: url).filter(\.pinned), at: url)
	}

	// MARK: Capture bookkeeping

	/// The `UIPasteboard.changeCount` we have already captured. Persisted in the App
	/// Group so the constant extension relaunches don't re-read (and re-banner) the
	/// same copy. Compared BEFORE any contents read — see the controller's
	/// captureClipboardIfNeeded.
	static var consumedChangeCount: Int {
		get { store.integer(forKey: "kb.clip.consumed") }
		set { store.set(newValue, forKey: "kb.clip.consumed") }
	}
}
