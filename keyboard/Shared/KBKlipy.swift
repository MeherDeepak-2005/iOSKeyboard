import Foundation
import CoreGraphics

// KBKlipy: minimal client for the KLIPY content API (docs.klipy.com) — GIFs and
// stickers, trending + search, with pagination. Callers gate on Full Access (the
// extension has no network without it). Add this file to BOTH targets.
//
// Response shape (verified against the published schema):
//   { result, data: { data: [items], current_page, per_page, has_next } }
// and each item carries file.{hd,md,sm,xs}.{gif,webp,jpg,mp4,webm} variants, each
// { url, width, height, size }.
//
// MEMORY LEDGER — why this client is shaped the way it is:
//   · One JSON page (24 items) ≈ 60–150 KB, parsed once and dropped; the retained
//     [KlipyMediaItem] array is a few KB of URLs/ints per page.
//   · PREVIEW picks the SMALLEST animated variant (xs/sm, webp before gif — webp
//     thumbs run ~40–150 KB where the same gif is 2–3×). Files stream to the disk
//     LRU (KBMediaCache); nothing is held as Data in this process.
//   · SEND picks the biggest gif (hd→md, universally pasteable); it is fetched only
//     on tap, straight to disk, and handed to the pasteboard from a mapped read.

enum KlipyKind: String {
	case gifs, stickers
	var displayName: String { self == .gifs ? "GIFs" : "Stickers" }
}

struct KlipyMediaItem {
	let id: String
	let title: String
	let previewURL: URL
	let previewPixelSize: CGSize
	let sendURL: URL
}

final class KlipyClient {
	static let shared = KlipyClient()

	private let session: URLSession
	init() {
		let c = URLSessionConfiguration.ephemeral
		c.urlCache = nil                       // no hidden in-memory cache: disk LRU is THE cache
		c.timeoutIntervalForRequest = 12
		session = URLSession(configuration: c)
	}

	var hasKey: Bool { !KBSettings.klipyAPIKey.isEmpty }

	/// Trending (query nil) or search. Completion on main: (items, hasNext) — empty
	/// items + hasNext false on any failure (the panel shows its error state).
	func fetch(_ kind: KlipyKind, query: String?, page: Int,
			   completion: @escaping ([KlipyMediaItem], Bool) -> Void) {
		let key = KBSettings.klipyAPIKey
		guard !key.isEmpty else { completion([], false); return }
		var comps = URLComponents(string:
			"https://api.klipy.com/api/v1/\(key)/\(kind.rawValue)/\(query == nil ? "trending" : "search")")!
		var q = [
			URLQueryItem(name: "page", value: String(page)),
			URLQueryItem(name: "per_page", value: "24"),
			URLQueryItem(name: "customer_id", value: KBSettings.klipyCustomerID),
		]
		if let query { q.append(URLQueryItem(name: "q", value: query)) }
		comps.queryItems = q
		guard let url = comps.url else { completion([], false); return }
		session.dataTask(with: url) { data, _, _ in
			let parsed = data.map(Self.parse) ?? ([], false)
			DispatchQueue.main.async { completion(parsed.0, parsed.1) }
		}.resume()
	}

	/// Pure and nonisolated so tests can feed fixture JSON without a session.
	nonisolated static func parse(_ data: Data) -> ([KlipyMediaItem], Bool) {
		guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			  let payload = root["data"] as? [String: Any],
			  let rows = payload["data"] as? [[String: Any]] else { return ([], false) }
		let hasNext = (payload["has_next"] as? Bool) ?? false
		let items: [KlipyMediaItem] = rows.compactMap { row in
			guard let file = row["file"] as? [String: Any],
				  // smallest animated thumb for cells; biggest gif for the pasteboard
				  let preview = variant(file, sizes: ["xs", "sm", "md", "hd"], formats: ["webp", "gif"]),
				  let send = variant(file, sizes: ["hd", "md", "sm", "xs"], formats: ["gif"])
			else { return nil }
			let id = (row["id"] as? Int).map(String.init) ?? (row["slug"] as? String) ?? preview.url.absoluteString
			return KlipyMediaItem(id: id,
								  title: (row["title"] as? String) ?? "",
								  previewURL: preview.url,
								  previewPixelSize: preview.size,
								  sendURL: send.url)
		}
		return (items, hasNext)
	}

	private nonisolated static func variant(_ file: [String: Any], sizes: [String], formats: [String])
		-> (url: URL, size: CGSize)? {
		for s in sizes {
			guard let bucket = file[s] as? [String: Any] else { continue }
			for f in formats {
				guard let v = bucket[f] as? [String: Any],
					  let raw = v["url"] as? String, let url = URL(string: raw) else { continue }
				let w = (v["width"] as? Double) ?? 0
				let h = (v["height"] as? Double) ?? 0
				return (url, CGSize(width: w, height: h))
			}
		}
		return nil
	}
}
