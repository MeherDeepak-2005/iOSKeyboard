import UIKit
import Darwin

// MARK: - EmojiAtlas: pre-rasterized emoji tiles served from an mmap'd file
//
// Why: drawing emoji as TEXT routes through CoreText's Apple Color Emoji renderer,
// which caches ~65 KB of DIRTY memory per rasterized glyph and releases it only on a
// memory warning — scrolling the whole catalog costs ~30 MB against the extension's
// ~60–70 MB jetsam ceiling (SwiftKey shipped NSCache swizzling to fight the same
// wall). The fix is the same trick this codebase uses for all its data: rasterize
// ONCE in the HOST app (multi-GB budget), write raw RGBA tiles to the App Group, and
// mmap the file in the extension. Cells then show cropped CGImages backed by CLEAN,
// evictable file pages — no glyph cache, no dirty growth, crisp at native scale.
//
// The file is pure pixels; the geometry lives in the NAME
// (emoji_atlas_v2_<catalog>_t<tilePx>_n<count>_os<iosMajor>.bin). The reader uses a
// read-only MAP_PRIVATE mapping, and a stale file (emoji.bin rebuilt, iOS major
// upgrade changing the artwork, different display scale) simply never matches — the
// grid falls back to live text rendering until the app regenerates.
final class EmojiAtlas {
	/// Logical tile side in points (matches the grid's glyph box); pixels = pt × scale.
	/// 47 pt (was 36) draws browse-grid emoji ~30% larger; the new size changes the file
	/// name, so the app regenerates the atlas and old tiles are never mapped.
	nonisolated static let pointSize: CGFloat = 47
	/// Glyph font inside a tile: 36.5 pt at display size — the same as `glyphFontSize`,
	/// so atlas cells and text-fallback cells look the same.
	private nonisolated static let glyphFraction: CGFloat = 28.0 / 36.0
	nonisolated static let glyphFontSize: CGFloat = pointSize * glyphFraction
	/// Browse-grid column pitch: the grid fits as many cells of at least this width as
	/// the row allows (6 on a 393 pt phone).
	nonisolated static let cellPitch: CGFloat = 60
	/// The search results strip keeps the old, compact size (44 pt cells).
	nonisolated static let compactPointSize: CGFloat = 36
	nonisolated static let compactGlyphFontSize: CGFloat = 28

	let count: Int
	private let tilePx: Int
	private let displayScale: CGFloat
	private let strip: CGImage
	/// Store-order lookup so recents and search results (strings, not grid indices)
	/// can be served from tiles too. ~1,300 short strings, a one-off walk at load.
	private let indexOf: [String: Int]

	private init?(url: URL, tilePx: Int, count: Int, store: EmojiStore) {
		guard tilePx > 0, count > 0,
			  let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
			  fileSize == count * tilePx * tilePx * 4,
			  let space = CGColorSpace(name: CGColorSpace.sRGB),
			  let provider = Self.mappedProvider(url: url, size: fileSize),
			  let strip = CGImage(width: tilePx, height: tilePx * count,
								  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tilePx * 4,
								  space: space,
								  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
								  provider: provider, decode: nil, shouldInterpolate: true,
								  intent: .defaultIntent)
		else { return nil }
		var map: [String: Int] = [:]
		map.reserveCapacity(count)
		var i = 0
		for c in 0..<store.categoryCount {
			for item in 0..<store.emojiCount(c) {
				map[store.emoji(c, item)] = i
				i += 1
			}
		}
		guard i == count else { return nil }
		self.tilePx = tilePx
		self.count = count
		self.displayScale = CGFloat(tilePx) / Self.pointSize
		self.strip = strip
		self.indexOf = map
	}

	private nonisolated static func mappedProvider(url: URL, size: Int) -> CGDataProvider? {
		guard size > 0 else { return nil }
		let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
			guard let path else { return -1 }
			return open(path, O_RDONLY)
		}
		guard descriptor >= 0 else { return nil }
		defer { close(descriptor) }
		guard let mapping = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0),
			mapping != MAP_FAILED else { return nil }
		guard let provider = CGDataProvider(dataInfo: nil, data: mapping, size: size,
			releaseData: { _, data, length in
				munmap(UnsafeMutableRawPointer(mutating: data), length)
			}) else {
			munmap(mapping, size)
			return nil
		}
		return provider
	}

	/// The tile for an exact catalog emoji, or nil (caller falls back to text).
	/// `cropping` shares the file-backed provider — no bytes are read until render.
	func image(for emoji: String) -> UIImage? {
		guard let i = indexOf[emoji],
			  let tile = strip.cropping(to: CGRect(x: 0, y: CGFloat(i * tilePx),
												   width: CGFloat(tilePx), height: CGFloat(tilePx)))
		else { return nil }
		return UIImage(cgImage: tile, scale: displayScale, orientation: .up)
	}

	// MARK: Locating the file

	private nonisolated static func containerURL() -> URL? {
		FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KBSettings.appGroup)
	}
	private nonisolated static func fileName(tilePx: Int, count: Int,
		fingerprint: UInt64) -> String {
		let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
		return String(format: "emoji_atlas_v2_%016llx_t%d_n%d_os%d.bin",
			fingerprint, tilePx, count, os)
	}
	private nonisolated static func totalEmoji(in store: EmojiStore) -> Int {
		(0..<store.categoryCount).reduce(0) { $0 + store.emojiCount($1) }
	}
	private nonisolated static func tilePx(for scale: CGFloat) -> Int {
		Int((pointSize * max(scale, 1)).rounded())
	}

	/// Non-caching load, for tests and the shared path below.
	static func load(store: EmojiStore?, scale: CGFloat, in dir: URL? = nil) -> EmojiAtlas? {
		guard let store, let dir = dir ?? containerURL() else { return nil }
		let tile = tilePx(for: scale)
		let count = totalEmoji(in: store)
		let url = dir.appendingPathComponent(fileName(tilePx: tile, count: count,
			fingerprint: store.catalogFingerprint))
		return EmojiAtlas(url: url, tilePx: tile, count: count, store: store)
	}

	/// Process-wide instance (main thread only — UI paths). A failed load is NOT
	/// cached: the app may generate the file while this extension process is alive,
	/// so the next emoji-page open retries the map.
	private static var _shared: EmojiAtlas?
	private static var sharedIdentity: (fingerprint: UInt64, tilePx: Int)?
	static func loadShared(store: EmojiStore?, scale: CGFloat) -> EmojiAtlas? {
		guard let store else { return nil }
		let identity = (store.catalogFingerprint, tilePx(for: scale))
		if let a = _shared, let sharedIdentity,
			sharedIdentity.fingerprint == identity.0,
			sharedIdentity.tilePx == identity.1 { return a }
		_shared = load(store: store, scale: scale)
		sharedIdentity = _shared == nil ? nil : identity
		return _shared
	}

	/// Releases only the process mapping. The immutable file remains in the App Group
	/// and is mapped again on the next emoji-page open.
	static func purgeShared() {
		_shared = nil
		sharedIdentity = nil
	}

	// MARK: Generation (HOST APP ONLY)
	//
	// Rasterizing walks every glyph through the very CoreText cache this type exists
	// to keep out of the extension — never call it there. The app's budget shrugs it
	// off, and the write happens once per (emoji set, tile size, iOS major).

	@discardableResult
	nonisolated static func generateIfNeeded(store: EmojiStore? = EmojiStore.bundled,
										 scale: CGFloat, in dir: URL? = nil) -> URL? {
		guard let store, let dir = dir ?? containerURL() else { return nil }
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		let tile = tilePx(for: scale)
		let count = totalEmoji(in: store)
		guard count > 0 else { return nil }
		let url = dir.appendingPathComponent(fileName(tilePx: tile, count: count,
			fingerprint: store.catalogFingerprint))
		if FileManager.default.fileExists(atPath: url.path) { return url }

		// Sweep stale atlases (old emoji set, previous iOS major, other scales).
		if let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
			for f in entries where f.lastPathComponent.hasPrefix("emoji_atlas_") {
				try? FileManager.default.removeItem(at: f)
			}
		}

		// Write to a temp name, rename when complete — the extension can never map a
		// half-written file (the name-encoded size check would reject it anyway).
		let tmp = dir.appendingPathComponent(".emoji_atlas_\(UUID().uuidString).tmp")
		guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { return nil }
		defer { try? FileManager.default.removeItem(at: tmp) }
		guard let handle = try? FileHandle(forWritingTo: tmp) else { return nil }
		let ok = rasterize(store, tilePx: tile, to: handle)
		try? handle.close()
		guard ok else { return nil }
		if FileManager.default.fileExists(atPath: url.path) { return url }
		guard (try? FileManager.default.moveItem(at: tmp, to: url)) != nil else { return nil }
		return url
	}

	/// One reused RGBA buffer + CGContext; each emoji is cleared, drawn centered, and
	/// appended. Thread-safe off main (UIKit string drawing has been since iOS 4).
	private nonisolated static func rasterize(_ store: EmojiStore, tilePx tile: Int, to handle: FileHandle) -> Bool {
		var buf = [UInt8](repeating: 0, count: tile * tile * 4)
		return buf.withUnsafeMutableBytes { raw -> Bool in
			guard let base = raw.baseAddress,
				  let space = CGColorSpace(name: CGColorSpace.sRGB),
				  let ctx = CGContext(data: base, width: tile, height: tile,
									  bitsPerComponent: 8, bytesPerRow: tile * 4, space: space,
									  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
			else { return false }
			// UIKit string drawing expects a top-left-origin (flipped) context.
			ctx.translateBy(x: 0, y: CGFloat(tile))
			ctx.scaleBy(x: 1, y: -1)
			UIGraphicsPushContext(ctx)
			defer { UIGraphicsPopContext() }

			let T = CGFloat(tile)
			var failed = false
			for c in 0..<store.categoryCount {
				for item in 0..<store.emojiCount(c) where !failed {
					autoreleasepool {
						ctx.clear(CGRect(x: 0, y: 0, width: T, height: T))
						var font = UIFont.systemFont(ofSize: T * glyphFraction)
						var str = NSAttributedString(string: store.emoji(c, item), attributes: [.font: font])
						var sz = str.size()
						if sz.width > T || sz.height > T {          // wide glyphs (flags, families)
							font = font.withSize(font.pointSize * min(T / sz.width, T / sz.height))
							str = NSAttributedString(string: store.emoji(c, item), attributes: [.font: font])
							sz = str.size()
						}
						str.draw(at: CGPoint(x: (T - sz.width) / 2, y: (T - sz.height) / 2))
						do { try handle.write(contentsOf: Data(bytes: base, count: raw.count)) }
						catch { failed = true }
					}
				}
			}
			return !failed
		}
	}
}
