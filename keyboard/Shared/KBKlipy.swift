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
//   · PREVIEW picks the smallest animated variant that can fill the 256 px decoder
//     target (webp before gif). This avoids enlarging a blurry 120 px thumbnail while
//     the decoded bitmap cap — and therefore resident memory — remains unchanged.
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
				  let preview = previewVariant(file),
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

	private nonisolated static func previewVariant(_ file: [String: Any])
		-> (url: URL, size: CGSize)? {
		let target: CGFloat = 256
		var largest: (url: URL, size: CGSize)?
		for sizeName in ["xs", "sm", "md", "hd"] {
			guard let bucket = file[sizeName] as? [String: Any],
				  let candidate = mediaVariant(bucket, formats: ["webp", "gif"])
			else { continue }
			largest = candidate
			if max(candidate.size.width, candidate.size.height) >= target { return candidate }
		}
		return largest
	}

	private nonisolated static func variant(_ file: [String: Any], sizes: [String], formats: [String])
		-> (url: URL, size: CGSize)? {
		for s in sizes {
			guard let bucket = file[s] as? [String: Any] else { continue }
			if let candidate = mediaVariant(bucket, formats: formats) { return candidate }
		}
		return nil
	}

	private nonisolated static func mediaVariant(_ bucket: [String: Any], formats: [String])
		-> (url: URL, size: CGSize)? {
		for format in formats {
			guard let value = bucket[format] as? [String: Any],
				  let raw = value["url"] as? String,
				  let url = URL(string: raw)
			else { continue }
			let width = (value["width"] as? Double) ?? 0
			let height = (value["height"] as? Double) ?? 0
			return (url, CGSize(width: width, height: height))
		}
		return nil
	}
}
