import UIKit
import ImageIO

// KBMediaCache: disk-LRU media cache + downsampled decoders — the clean-memory
// backbone of the GIF/sticker panel. Add this file to BOTH targets.
//
// MEMORY LEDGER — every path here is designed against the extension's ~60–70 MB
// jetsam ceiling (the same doctrine as EmojiAtlas):
//   · Downloads STREAM to disk via downloadTask — response bytes never pool as
//     Data in this process. Cache lives in the App Group, capped at 50 MB, LRU
//     by file modification date (touched on every hit).
//   · Decoding goes through CGImageSource over the FILE (mapped, not loaded) with
//     kCGImageSourceShouldCache=false, and every image is created as a THUMBNAIL
//     capped at the display pixel size — a 120 px cell frame is 120·120·4 ≈ 57 KB
//     dirty, regardless of how large the gif is.
//   · An animating grid keeps ONE decoded frame per visible cell (~9–12 cells →
//     ~0.7 MB) plus one in-flight decode. Naive UIImage.animatedImage decoding of
//     every frame of every visible gif would be 100 MB+ — instant jetsam.

enum KBMediaCache {
	nonisolated static let diskCap = 50 * 1024 * 1024

	private static let session: URLSession = {
		let c = URLSessionConfiguration.ephemeral
		c.urlCache = nil
		c.timeoutIntervalForRequest = 20
		return URLSession(configuration: c)
	}()

	nonisolated static var dir: URL {
		let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KBSettings.appGroup)
			?? FileManager.default.temporaryDirectory
		let d = base.appendingPathComponent("media-cache", isDirectory: true)
		try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
		return d
	}

	nonisolated static func localURL(for remote: URL) -> URL {
		var h: UInt64 = 0xcbf29ce484222325                 // FNV-1a over the absolute URL
		for b in remote.absoluteString.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
		let ext = remote.pathExtension.isEmpty ? "bin" : remote.pathExtension
		return dir.appendingPathComponent(String(format: "%016llx.%@", h, ext))
	}

	/// Fetch-to-file. Completion on main with the local URL (nil on failure). A hit
	/// costs one stat + an mtime touch; a miss streams to disk and prunes the LRU.
	static func fetch(_ remote: URL, completion: @escaping (URL?) -> Void) {
		let local = localURL(for: remote)
		if FileManager.default.fileExists(atPath: local.path) {
			try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: local.path)
			completion(local)
			return
		}
		session.downloadTask(with: remote) { tmp, _, _ in
			var result: URL?
			if let tmp {
				try? FileManager.default.removeItem(at: local)
				if (try? FileManager.default.moveItem(at: tmp, to: local)) != nil { result = local }
			}
			pruneIfNeeded()
			DispatchQueue.main.async { completion(result) }
		}.resume()
	}

	/// Drop oldest files until the cache sits at 80% of cap. Runs on the download
	/// callback thread — pure FileManager work, never blocks the keyboard.
	nonisolated private static func pruneIfNeeded() {
		let fm = FileManager.default
		guard let files = try? fm.contentsOfDirectory(
			at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
		var entries = files.compactMap { url -> (url: URL, size: Int, date: Date)? in
			guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
			else { return nil }
			return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
		}
		var total = entries.reduce(0) { $0 + $1.size }
		guard total > diskCap else { return }
		entries.sort { $0.date < $1.date }
		for e in entries {
			guard total > diskCap * 8 / 10 else { break }
			try? fm.removeItem(at: e.url)
			total -= e.size
		}
	}

	/// First frame, downsampled: the ONLY full-strength decode primitive the panel
	/// uses. `maxPixel` caps the longer side, so cost is display-bound, not
	/// content-bound (a 480 px gif and a 4K gif both decode to ≤ maxPixel²·4 bytes).
	nonisolated static func firstFrame(_ file: URL, maxPixel: Int) -> UIImage? {
		KBAnimatedSource(fileURL: file)?.frame(at: 0, maxPixel: maxPixel)
	}
}

/// Per-cell on-demand frame decoder for animated previews. Holds the mapped
/// CGImageSource (clean memory) and decodes ONE downsampled frame at a time —
/// the caller owns exactly one UIImage per cell; nothing else is retained
/// (kCGImageSourceShouldCache is false, so ImageIO keeps no frame cache either).
/// nonisolated: pure ImageIO over an immutable file mapping, callable off-main.
nonisolated final class KBAnimatedSource {
	private let src: CGImageSource
	let frameCount: Int

	init?(fileURL: URL) {
		let opts = [kCGImageSourceShouldCache: false] as CFDictionary
		guard let s = CGImageSourceCreateWithURL(fileURL as CFURL, opts) else { return nil }
		src = s
		frameCount = max(1, CGImageSourceGetCount(s))
	}

	/// Seconds to hold frame `i` (gif/webp delay, floored the way browsers do).
	func delay(at i: Int) -> Double {
		guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 0.1 }
		let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
		let webp = props[kCGImagePropertyWebPDictionary] as? [CFString: Any]
		let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
			?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
			?? (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
			?? (webp?[kCGImagePropertyWebPDelayTime] as? Double)
			?? 0.1
		return max(0.05, d)
	}

	func frame(at i: Int, maxPixel: Int) -> UIImage? {
		let opts = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceThumbnailMaxPixelSize: maxPixel,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,     // decode NOW, at thumb size — not lazily at full size
		] as CFDictionary
		guard i < frameCount,
			  let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts) else { return nil }
		return UIImage(cgImage: cg)
	}
}
