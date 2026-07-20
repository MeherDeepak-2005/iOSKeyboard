import UIKit
import ImageIO

enum KBMediaCache {
	static let diskCap = 20 * 1024 * 1024
	static let individualFileCap = 12 * 1024 * 1024
	private static let ioQueue = DispatchQueue(label: "keyboard.media.cache", qos: .utility)
	private static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.urlCache = nil
		configuration.timeoutIntervalForResource = 20
		configuration.httpMaximumConnectionsPerHost = 2
		return URLSession(configuration: configuration)
	}()

	static var directory: URL {
		let base = FileManager.default.containerURL(
			forSecurityApplicationGroupIdentifier: KBSettings.appGroup)
			?? FileManager.default.temporaryDirectory
		let directory = base.appendingPathComponent("media-cache", isDirectory: true)
		try? FileManager.default.createDirectory(at: directory,
			withIntermediateDirectories: true)
		return directory
	}

	static func localURL(for remote: URL) -> URL {
		var hash: UInt64 = 0xcbf29ce484222325
		for byte in remote.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
		let ext = remote.pathExtension.isEmpty ? "bin" : remote.pathExtension
		return directory.appendingPathComponent(String(format: "%016llx.%@", hash, ext))
	}

	@discardableResult
	static func fetch(_ remote: URL, completion: @escaping (URL?) -> Void) -> URLSessionDownloadTask? {
		guard remote.scheme?.lowercased() == "https" else { completion(nil); return nil }
		let local = localURL(for: remote)
		if let size = fileSize(local), size > 0, size <= individualFileCap {
			ioQueue.async { try? FileManager.default.setAttributes([.modificationDate: Date()],
				ofItemAtPath: local.path) }
			completion(local)
			return nil
		}
		let task = session.downloadTask(with: remote) { temporary, response, error in
			var result: URL?
			defer { DispatchQueue.main.async { completion(result) } }
			let http = response as? HTTPURLResponse
			let mime = http?.mimeType?.lowercased() ?? ""
			let expectedBytes = http?.expectedContentLength ?? NSURLSessionTransferSizeUnknown
			guard error == nil, let temporary, http?.statusCode == 200,
				mime.hasPrefix("image/"),
				(expectedBytes == NSURLSessionTransferSizeUnknown
					|| expectedBytes <= Int64(individualFileCap)),
				let size = fileSize(temporary), size > 0, size <= individualFileCap else { return }
			do {
				try? FileManager.default.removeItem(at: local)
				try FileManager.default.moveItem(at: temporary, to: local)
				result = local
				ioQueue.async { pruneIfNeeded() }
			} catch { result = nil }
		}
		task.resume()
		return task
	}

	static func purge() {
		ioQueue.async { try? FileManager.default.removeItem(at: directory) }
	}

	private static func fileSize(_ url: URL) -> Int? {
		(try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
	}

	private static func pruneIfNeeded() {
		let manager = FileManager.default
		guard let files = try? manager.contentsOfDirectory(at: directory,
			includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
		var entries = files.compactMap { url -> (URL, Int, Date)? in
			guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
			else { return nil }
			return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
		}
		var total = entries.reduce(0) { $0 + $1.1 }
		guard total > diskCap else { return }
		entries.sort { $0.2 < $1.2 }
		for entry in entries where total > diskCap * 3 / 4 {
			try? manager.removeItem(at: entry.0)
			total -= entry.1
		}
	}
}

final class KBAnimatedSource {
	private let source: CGImageSource
	let frameCount: Int

	init?(fileURL: URL) {
		guard let source = CGImageSourceCreateWithURL(fileURL as CFURL,
			[kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
		self.source = source
		self.frameCount = max(1, CGImageSourceGetCount(source))
	}

	func delay(at index: Int) -> Double {
		guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
			as? [CFString: Any] else { return 0.1 }
		let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
		let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any]
		let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
			?? gif?[kCGImagePropertyGIFDelayTime] as? Double
			?? webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double
			?? webp?[kCGImagePropertyWebPDelayTime] as? Double ?? 0.1
		return max(0.06, delay)
	}

	func frame(at index: Int, maxPixel: Int) -> UIImage? {
		guard index < frameCount else { return nil }
		let options = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceThumbnailMaxPixelSize: maxPixel,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
		] as CFDictionary
		guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { return nil }
		return UIImage(cgImage: image)
	}
}
