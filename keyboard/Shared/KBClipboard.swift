// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import Foundation

// KBClipboard: the clipboard-history store shared between app and extension.
//
// Text only, size-capped, App Group-backed (a small JSON file — items are too big
// for UserDefaults churn). Privacy contract: pasteboard CONTENTS are read only on
// an explicit user tap (Clipboard in the tools row); detection of "something new was
// copied" uses metadata alone (changeCount / hasStrings), which iOS does not surface
// as a paste. Add this file to BOTH targets.
//
// Hardening over the original afda5b4 implementation (Improvements.md P0 §3):
//  • Unpinned items EXPIRE (`retentionInterval`, 1h like Gboard); pins never expire.
//    Expiry is enforced at read AND persisted, so nothing lingers on disk past TTL.
//  • Obvious secrets are never retained — `isSensitive` rejects OTP-shaped codes and
//    Luhn-valid card numbers. (The controller additionally never captures in secure
//    fields and marks a change consumed only after a confirmed read — see
//    captureClipboardIfNeeded.)
//  • `add` reports whether it stored the text so callers can distinguish
//    saved / rejected without re-reading the file.

struct KBClipboardItem: Codable, Equatable {
	var text: String
	var pinned: Bool
	var date: Date
}

enum KBClipboard {
	static let maxItems = 50                  // unpinned history ring; pins ride above it
	static let maxPins = 10
	static let maxItemLength = 10_000         // clip pathological copies, keep the file small
	/// Unpinned items older than this are dropped (pins are exempt). Matches Gboard's
	/// one-hour clipboard window: long enough to be useful, short enough that a copied
	/// secret does not sit in the shared container indefinitely.
	static let retentionInterval: TimeInterval = 3600

	private static var store: UserDefaults { UserDefaults(suiteName: KBSettings.appGroup) ?? .standard }

	/// `override` is for tests; production uses the App Group container.
	static func fileURL(_ override: URL? = nil) -> URL {
		if let override { return override }
		let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KBSettings.appGroup)
			?? FileManager.default.temporaryDirectory
		return dir.appendingPathComponent("clipboard.json")
	}

	/// Live history with expired unpinned items removed. If anything expired, the pruned
	/// set is written back immediately so the TTL is a real on-disk guarantee, not just a
	/// display filter — a copied secret cannot outlive its window even if the user never
	/// interacts with the clipboard again after a capture.
	static func all(at url: URL? = nil, now: Date = Date()) -> [KBClipboardItem] {
		let stored = decode(at: url)
		let live = stored.filter { $0.pinned || now.timeIntervalSince($0.date) < retentionInterval }
		if live.count != stored.count { save(live, at: url) }
		return live
	}

	private static func decode(at url: URL?) -> [KBClipboardItem] {
		guard let data = try? Data(contentsOf: fileURL(url)),
			  let items = try? JSONDecoder().decode([KBClipboardItem].self, from: data) else { return [] }
		return items
	}

	private static func save(_ items: [KBClipboardItem], at url: URL?) {
		guard let data = try? JSONEncoder().encode(items) else { return }
		try? data.write(to: fileURL(url), options: .atomic)
	}

	/// Insert (or resurface) a copy. Dedupe by exact text — re-copying moves the item to
	/// the front and keeps its pin. Unpinned overflow drops oldest-first. Returns false
	/// (storing nothing) for blank or sensitive text. Expired unpinned items are pruned
	/// in the same pass.
	@discardableResult
	static func add(_ text: String, at url: URL? = nil, now: Date = Date()) -> Bool {
		let t = String(text.prefix(maxItemLength))
		guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSensitive(t) else { return false }
		var items = all(at: url, now: now)
		var pinned = false
		if let i = items.firstIndex(where: { $0.text == t }) {
			pinned = items[i].pinned
			items.remove(at: i)
		}
		items.insert(KBClipboardItem(text: t, pinned: pinned, date: now), at: 0)
		var unpinned = 0
		items = items.filter { item in
			if item.pinned { return true }
			unpinned += 1
			return unpinned <= maxItems
		}
		save(items, at: url)
		return true
	}

	static func togglePin(_ text: String, at url: URL? = nil) {
		var items = all(at: url)
		guard let i = items.firstIndex(where: { $0.text == text }) else { return }
		if !items[i].pinned, items.filter(\.pinned).count >= maxPins { return }
		items[i].pinned.toggle()
		// A freshly pinned item restarts its clock at pin time; unpinning lets it age
		// from now, not from an original copy that may already be past the window.
		items[i].date = Date()
		save(items, at: url)
	}

	static func remove(_ text: String, at url: URL? = nil) {
		save(all(at: url).filter { $0.text != text }, at: url)
	}

	static func clearUnpinned(at url: URL? = nil) {
		save(all(at: url).filter(\.pinned), at: url)
	}

	// MARK: Sensitive-content filter

	/// Text we refuse to retain even when the user opens the panel: one-time-passcodes
	/// and payment card numbers. Deliberately conservative and well-defined — password
	/// heuristics produce too many false positives, so passwords are handled instead by
	/// the controller's secure-field skip (they are typically pasted INTO secure fields,
	/// where capture never runs).
	static func isSensitive(_ text: String) -> Bool {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		// OTP: a bare 4–8 digit code (verification codes, PINs).
		if (4...8).contains(trimmed.count), trimmed.allSatisfy(\.isNumber) { return true }
		// Payment card: a 13–19 digit run (spaces/dashes allowed) that passes Luhn.
		let digits = trimmed.filter(\.isNumber)
		if (13...19).contains(digits.count),
		   trimmed.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }),
		   luhnValid(digits) {
			return true
		}
		return false
	}

	private static func luhnValid(_ digits: String) -> Bool {
		var sum = 0
		for (offset, ch) in digits.reversed().enumerated() {
			guard let d = ch.wholeNumberValue else { return false }
			if offset % 2 == 1 {
				let doubled = d * 2
				sum += doubled > 9 ? doubled - 9 : doubled
			} else {
				sum += d
			}
		}
		return sum % 10 == 0
	}

	// MARK: Capture bookkeeping

	/// The `UIPasteboard.changeCount` we have already captured. Persisted in the App
	/// Group so the constant extension relaunches don't re-read (and re-banner) the same
	/// copy. The controller advances this only AFTER a confirmed non-empty read, so a
	/// transient read failure retries instead of silently losing the item.
	static var consumedChangeCount: Int {
		get { store.integer(forKey: "kb.clip.consumed") }
		set { store.set(newValue, forKey: "kb.clip.consumed") }
	}
}
