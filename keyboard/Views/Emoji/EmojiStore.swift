import UIKit
import Darwin

// Emoji are Unicode text, not bundled images: the system's Apple Color Emoji font
// draws the glyphs, so only code points ship and they insert through the same
// `onInsert` path as any character — no assets, no size cost.

// MARK: - EmojiStore: zero-copy reader for `emoji.bin`
//
// The catalog used to be split from string literals into ~1,300 heap Strings on the
// emoji page's first open; the mapped file keeps it in clean, evictable pages and
// decodes ONE emoji per collection-view cell, on demand.
//
// Format v2 (all u32 little-endian): header (magic "KBEM", version, categoryCount
// C, stringCount N, mapCount M), C × (nameIdx, iconIdx, emojiStart, emojiCount)
// records, u32 × (N+1) byte offsets, M × (wordIdx, emojiIdx) word→emoji pairs
// sorted by word bytes, utf8 blob. v1 files have no map (M treated as 0, header
// 4 words instead of 5).
// nonisolated: immutable after init (mmap'd bytes + offsets), and ALREADY read off
// the main actor — the engine queue's word→emoji candidate lookup. Saying so lets
// background users (engine, atlas rasterizer) call it without actor hops.
nonisolated final class EmojiStore {
	private let data: Data
	let categoryCount: Int
	/// Stable catalog identity used to reject an atlas generated from different
	/// emoji bytes even when the two catalogs happen to contain the same count.
	let catalogFingerprint: UInt64
	private let stringCount: Int
	private let mapCount: Int
	private let catBase, offsBase, mapBase, blobBase: Int

	/// nil unless `emoji.bin` ships in the current target.
	static let bundled: EmojiStore? = {
		guard let url = Bundle.main.url(forResource: "emoji", withExtension: "bin") else { return nil }
		return EmojiStore(url: url)
	}()

	init?(url: URL) {
		guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= 16 else { return nil }
		func u32(_ off: Int) -> Int {
			Int(UInt32(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
		}
		guard u32(0) == 0x4B42454D else { return nil }               // magic "KBEM"
		let version = u32(4)
		guard version == 1 || version == 2 else { return nil }
		categoryCount = u32(8)
		stringCount   = u32(12)
		mapCount = version >= 2 ? u32(16) : 0
		catBase  = version >= 2 ? 20 : 16
		offsBase = catBase + 16 * categoryCount
		mapBase  = offsBase + 4 * (stringCount + 1)
		blobBase = mapBase + 8 * mapCount
		guard blobBase <= d.count else { return nil }
		var fingerprint: UInt64 = 0xcbf29ce484222325
		for byte in d { fingerprint = (fingerprint ^ UInt64(byte)) &* 0x100000001b3 }
		catalogFingerprint = fingerprint
		data = d
	}

	private func u32(_ off: Int) -> Int {
		Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }))
	}
	private func stringBytes(_ idx: Int) -> Data {
		let a = blobBase + u32(offsBase + 4 * idx), b = blobBase + u32(offsBase + 4 * (idx + 1))
		return data[a..<b]
	}
	private func string(_ idx: Int) -> String { String(decoding: stringBytes(idx), as: UTF8.self) }

	func name(_ cat: Int) -> String { string(u32(catBase + 16 * cat)) }
	func icon(_ cat: Int) -> String { string(u32(catBase + 16 * cat + 4)) }
	func emojiCount(_ cat: Int) -> Int { u32(catBase + 16 * cat + 12) }
	func emoji(_ cat: Int, _ item: Int) -> String {
		string(u32(catBase + 16 * cat + 8) + item)
	}

	/// The emoji mapped to an exact (lowercase) word, or nil. Binary search over the
	/// word→emoji table, comparing raw utf8 bytes to match the builder's sort order.
	func emoji(forWord lw: String) -> String? {
		guard mapCount > 0 else { return nil }
		let key = Array(lw.utf8)
		var lo = 0, hi = mapCount - 1
		while lo <= hi {
			let mid = (lo + hi) >> 1
			let wordIdx = u32(mapBase + 8 * mid)
			let cmp = compare(stringBytes(wordIdx), key)
			if cmp < 0 { lo = mid + 1 }
			else if cmp > 0 { hi = mid - 1 }
			else {
				var first = mid
				while first > 0,
					  compare(stringBytes(u32(mapBase + 8 * (first - 1))), key) == 0 {
					first -= 1
				}
				return string(u32(mapBase + 8 * first + 4))
			}
		}
		return nil
	}

	/// Emoji whose keyword matches `query`, ranked by exact then prefix.
	/// The generated map is normalized and byte-sorted, so one lower-bound lookup
	/// finds the complete prefix range without decoding/scanning unrelated keywords.
	func search(_ query: String) -> [String] {
		guard mapCount > 0 else { return [] }
		let q = normalizedSearchTerm(query)
		guard !q.isEmpty else { return [] }
		let key = Array(q.utf8)
		var index = lowerBound(key)
		var exact: [String] = []
		var prefixes: [(length: Int, order: Int, emoji: String)] = []
		var seen = Set<String>()
		while index < mapCount {
			let bytes = stringBytes(u32(mapBase + 8 * index))
			guard hasPrefix(bytes, key) else { break }
			let emoji = string(u32(mapBase + 8 * index + 4))
			if bytes.count == key.count {
				if seen.insert(emoji).inserted { exact.append(emoji) }
			} else {
				prefixes.append((bytes.count, index, emoji))
			}
			index += 1
		}
		let hasExact = !exact.isEmpty
		prefixes = prefixes.filter { !hasExact || $0.length <= key.count + 3 }
		prefixes.sort { $0.length == $1.length ? $0.order < $1.order : $0.length < $1.length }
		var result = exact
		for hit in prefixes where seen.insert(hit.emoji).inserted {
			result.append(hit.emoji)
			if result.count >= 120 { break }
		}
		return result
	}

	private func lowerBound(_ key: [UInt8]) -> Int {
		var low = 0, high = mapCount
		while low < high {
			let middle = (low + high) >> 1
			let word = stringBytes(u32(mapBase + 8 * middle))
			if compare(word, key) < 0 { low = middle + 1 } else { high = middle }
		}
		return low
	}

	private func hasPrefix(_ bytes: Data, _ prefix: [UInt8]) -> Bool {
		guard bytes.count >= prefix.count else { return false }
		var index = bytes.startIndex
		for byte in prefix {
			guard bytes[index] == byte else { return false }
			index = bytes.index(after: index)
		}
		return true
	}

	private func normalizedSearchTerm(_ text: String) -> String {
		text.lowercased().filter { $0.isLetter || $0.isNumber }
	}

	/// Lexicographic byte compare: <0 if `a` sorts before `b`, 0 if equal, >0 after.
	private func compare(_ a: Data, _ b: [UInt8]) -> Int {
		var i = a.startIndex, j = 0
		while i < a.endIndex, j < b.count {
			if a[i] != b[j] { return a[i] < b[j] ? -1 : 1 }
			i = a.index(after: i); j += 1
		}
		let ra = a.endIndex - i, rb = b.count - j
		return ra == rb ? 0 : (ra < rb ? -1 : 1)
	}
}
