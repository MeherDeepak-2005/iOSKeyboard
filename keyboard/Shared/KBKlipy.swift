import Foundation
import CoreGraphics

enum KlipyKind: String, CaseIterable, Sendable {
	case gifs, stickers
	var displayName: String { self == .gifs ? "GIFs" : "Stickers" }
}

struct KlipyMediaItem: Equatable, Sendable {
	let id: String
	let title: String
	let previewURL: URL
	let previewPixelSize: CGSize
	let sendURL: URL
}

final class KlipyClient {
	static let shared = KlipyClient()
	private let session: URLSession

	init(session: URLSession? = nil) {
		if let session { self.session = session; return }
		let configuration = URLSessionConfiguration.ephemeral
		configuration.urlCache = nil
		configuration.timeoutIntervalForRequest = 12
		configuration.timeoutIntervalForResource = 20
		configuration.httpMaximumConnectionsPerHost = 2
		self.session = URLSession(configuration: configuration)
	}

	var hasKey: Bool {
		KBSettings.klipyMediaEnabled && !KBSettings.klipyAPIKey.isEmpty
			&& KBSettings.klipyContentFilterApproved
	}

	@discardableResult
	func fetch(_ kind: KlipyKind, query: String?, page: Int,
		completion: @escaping ([KlipyMediaItem], Bool) -> Void) -> URLSessionDataTask? {
		let key = KBSettings.klipyAPIKey
		guard let url = Self.requestURL(apiKey: key, kind: kind, query: query, page: page) else {
			completion([], false)
			return nil
		}
		let task = session.dataTask(with: url) { data, response, error in
			let http = response as? HTTPURLResponse
			let mime = http?.mimeType?.lowercased() ?? ""
			let parsed: ([KlipyMediaItem], Bool)
			if error == nil, http?.statusCode == 200,
			   mime == "application/json" || mime == "text/json",
			   let data, data.count <= 2_000_000 {
				parsed = Self.parse(data)
			} else {
				parsed = ([], false)
			}
			DispatchQueue.main.async { completion(parsed.0, parsed.1) }
		}
		task.resume()
		return task
	}

	static func requestURL(apiKey key: String, kind: KlipyKind, query: String?, page: Int) -> URL? {
		// Search-only integration: ad endpoints and ad-targeting parameters are never used.
		guard !key.isEmpty, (1...100).contains(page),
			key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
		guard let query else { return nil }
		let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
		guard !trimmed.isEmpty else { return nil }
		guard var components = URLComponents(string:
			"https://api.klipy.com/api/v1/\(key)/\(kind.rawValue)/search") else { return nil }
		components.queryItems = [
			URLQueryItem(name: "page", value: String(page)),
			URLQueryItem(name: "per_page", value: "20"),
			URLQueryItem(name: "q", value: trimmed),
		]
		return components.url
	}

	static func parse(_ data: Data) -> ([KlipyMediaItem], Bool) {
		guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let payload = root["data"] as? [String: Any],
			let rows = payload["data"] as? [[String: Any]] else { return ([], false) }
		let items = rows.compactMap { row -> KlipyMediaItem? in
			guard let files = row["file"] as? [String: Any],
				let preview = previewVariant(files),
				let send = variant(files, sizes: ["hd", "md", "sm", "xs"], formats: ["gif"])
			else { return nil }
			let id = (row["id"] as? Int).map(String.init)
				?? row["slug"] as? String ?? preview.url.absoluteString
			return KlipyMediaItem(id: id, title: row["title"] as? String ?? "",
				previewURL: preview.url, previewPixelSize: preview.size, sendURL: send.url)
		}
		return (items, payload["has_next"] as? Bool ?? false)
	}

	private static func previewVariant(_ files: [String: Any]) -> (url: URL, size: CGSize)? {
		var largest: (url: URL, size: CGSize)?
		for size in ["xs", "sm", "md", "hd"] {
			guard let bucket = files[size] as? [String: Any],
				let candidate = mediaVariant(bucket, formats: ["webp", "gif"]) else { continue }
			largest = candidate
			if max(candidate.size.width, candidate.size.height) >= 256 { return candidate }
		}
		return largest
	}

	private static func variant(_ files: [String: Any], sizes: [String], formats: [String])
		-> (url: URL, size: CGSize)? {
		for size in sizes {
			guard let bucket = files[size] as? [String: Any],
				let candidate = mediaVariant(bucket, formats: formats) else { continue }
			return candidate
		}
		return nil
	}

	private static func mediaVariant(_ bucket: [String: Any], formats: [String])
		-> (url: URL, size: CGSize)? {
		for format in formats {
			guard let value = bucket[format] as? [String: Any],
				let raw = value["url"] as? String, let url = URL(string: raw),
				url.scheme?.lowercased() == "https" else { continue }
			return (url, CGSize(width: value["width"] as? Double ?? 0,
				height: value["height"] as? Double ?? 0))
		}
		return nil
	}
}
