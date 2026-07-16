import UIKit

// Emoji subsystem — extracted from Keyboard.swift for a production-style split.
// Emoji are Unicode text, not bundled images: the system's Apple Color Emoji font
// draws the glyphs, so we only ship code points and insert them through the same
// `onInsert` path as any character. No assets, no size cost.
//
// Add this file to BOTH targets (app + keyboard extension).

// MARK: - Recents (App Group-backed, shared across the frequent extension relaunches)

enum KBEmojiRecents {
	private static let key = "kb.emoji.recents"
	private static let cap = 30
	private static var store: UserDefaults { UserDefaults(suiteName: KBSettings.appGroup) ?? .standard }
	static func all() -> [String] { store.stringArray(forKey: key) ?? [] }
	static func add(_ e: String) {
		var list = all().filter { $0 != e }
		list.insert(e, at: 0)
		store.set(Array(list.prefix(cap)), forKey: key)
	}
}

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
	/// Scans the generated word->emoji map: the same binary data powers search and
	/// suggestion-bar emoji candidates.
	func search(_ query: String) -> [String] {
		guard mapCount > 0 else { return [] }
		let q = normalizedSearchTerm(query)
		guard !q.isEmpty else { return [] }
		let hasExactMatch = (0..<mapCount).contains {
			normalizedSearchTerm(string(u32(mapBase + 8 * $0))) == q
		}
		var hits: [(rank: Int, order: Int, emoji: String)] = []
		var seen = Set<String>()
		for i in 0..<mapCount {
			let w = string(u32(mapBase + 8 * i))
			let term = normalizedSearchTerm(w)
			let rank: Int?
			if term == q {
				rank = 0
			} else if term.hasPrefix(q), !hasExactMatch || term.count <= q.count + 3 {
				rank = 100 + term.count
			} else {
				rank = nil
			}
			guard let rank else { continue }
			let e = string(u32(mapBase + 8 * i + 4))
			guard seen.insert(e).inserted else { continue }
			hits.append((rank, i, e))
		}
		return hits.sorted {
			$0.rank == $1.rank ? $0.order < $1.order : $0.rank < $1.rank
		}.map(\.emoji)
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
// (emoji_atlas_v1_t<tilePx>_n<count>_os<iosMajor>.bin) so the reader maps it with
// CGDataProvider(url:) at offset 0, and a stale file (emoji.bin rebuilt, iOS major
// upgrade changing the artwork, different display scale) simply never matches — the
// grid falls back to live text rendering until the app regenerates.
final class EmojiAtlas {
	/// Logical tile side in points (matches the grid's glyph box); pixels = pt × scale.
	nonisolated static let pointSize: CGFloat = 36
	/// Glyph font inside a tile: 28 pt at display size — identical to the UILabel path
	/// it replaces, so atlas cells and text-fallback cells look the same.
	private nonisolated static let glyphFraction: CGFloat = 28.0 / 36.0

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
			  let provider = CGDataProvider(url: url as CFURL),
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
	private nonisolated static func fileName(tilePx: Int, count: Int) -> String {
		let os = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
		return "emoji_atlas_v1_t\(tilePx)_n\(count)_os\(os).bin"
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
		let url = dir.appendingPathComponent(fileName(tilePx: tile, count: count))
		return EmojiAtlas(url: url, tilePx: tile, count: count, store: store)
	}

	/// Process-wide instance (main thread only — UI paths). A failed load is NOT
	/// cached: the app may generate the file while this extension process is alive,
	/// so the next emoji-page open retries the map.
	private static var _shared: EmojiAtlas?
	static func loadShared(store: EmojiStore?, scale: CGFloat) -> EmojiAtlas? {
		if let a = _shared { return a }
		_shared = load(store: store, scale: scale)
		return _shared
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
		let tile = tilePx(for: scale)
		let count = totalEmoji(in: store)
		guard count > 0 else { return nil }
		let url = dir.appendingPathComponent(fileName(tilePx: tile, count: count))
		if FileManager.default.fileExists(atPath: url.path) { return url }

		// Sweep stale atlases (old emoji set, previous iOS major, other scales).
		if let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
			for f in entries where f.lastPathComponent.hasPrefix("emoji_atlas_") {
				try? FileManager.default.removeItem(at: f)
			}
		}

		// Write to a temp name, rename when complete — the extension can never map a
		// half-written file (the name-encoded size check would reject it anyway).
		let tmp = dir.appendingPathComponent("emoji_atlas_v1.tmp")
		FileManager.default.createFile(atPath: tmp.path, contents: nil)
		guard let handle = try? FileHandle(forWritingTo: tmp) else { return nil }
		let ok = rasterize(store, tilePx: tile, to: handle)
		try? handle.close()
		guard ok, let _ = try? FileManager.default.moveItem(at: tmp, to: url) else {
			try? FileManager.default.removeItem(at: tmp)
			return nil
		}
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

// MARK: - Cells

private final class EmojiCell: UICollectionViewCell {
	let label = UILabel()
	/// Atlas tiles render here instead of the label — a cropped CGImage from the
	/// mmap'd strip costs no CoreText glyph cache (see EmojiAtlas).
	private let imageView = UIImageView()
	private var highlightColor = UIColor.clear

	override var isHighlighted: Bool {
		didSet { contentView.backgroundColor = isHighlighted ? highlightColor : .clear }
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		label.textAlignment = .center
		label.font = .systemFont(ofSize: 28)
		label.translatesAutoresizingMaskIntoConstraints = false
		imageView.contentMode = .scaleAspectFit
		imageView.translatesAutoresizingMaskIntoConstraints = false
		contentView.layer.cornerRadius = 8
		contentView.layer.cornerCurve = .continuous
		contentView.clipsToBounds = true
		contentView.addSubview(label)
		contentView.addSubview(imageView)
		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
			imageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			imageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
			imageView.widthAnchor.constraint(equalToConstant: EmojiAtlas.pointSize),
			imageView.heightAnchor.constraint(equalToConstant: EmojiAtlas.pointSize)
		])
	}
	required init?(coder: NSCoder) { fatalError() }

	func configure(emoji: String, image: UIImage?, theme: KeyboardTheme) {
		if let image {
			imageView.image = image
			imageView.isHidden = false
			label.isHidden = true
			label.text = nil
		} else {
			label.text = emoji
			label.isHidden = false
			imageView.isHidden = true
			imageView.image = nil
		}
		highlightColor = theme.isDark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08)
		contentView.backgroundColor = isHighlighted ? highlightColor : .clear
	}
}

private final class EmojiHeader: UICollectionReusableView {
	let label = UILabel()
	override init(frame: CGRect) {
		super.init(frame: frame)
		label.font = .systemFont(ofSize: 11, weight: .semibold)
		label.translatesAutoresizingMaskIntoConstraints = false
		addSubview(label)
		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
		])
	}
	required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Emoji page (browse palette)
//
// Gboard-style: a search pill on top, a VERTICALLY scrolling category-sectioned grid
// in the middle, and a bottom bar (ABC / globe / category tabs / delete). Shown as an
// overlay by KeyboardView. The grid is a compositional layout with an exact per-row
// column count, so rows are always full — the old horizontal flow layout dropped
// items when cell rounding disagreed with the column height.
//
// Search itself does NOT live here: tapping the pill hands off to KeyboardView's
// emoji-search mode, which reuses the REAL keyboard for typing (see EmojiSearchHeader)
// instead of a cramped in-overlay keypad.
final class EmojiKeyboardView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
	var onPick: ((String) -> Void)?
	var onDelete: (() -> Void)?
	var onABC: (() -> Void)?
	var onNextKeyboard: (() -> Void)?
	var onSearch: (() -> Void)?
	/// GIF button on the bottom bar — opens the KLIPY media panel (GIFs tab;
	/// stickers are a tab inside the panel).
	var onGIF: (() -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private var collection: UICollectionView!
	private let emptyLabel = UILabel()
	private let searchPill = UIButton(type: .system)
	private let bottomBar = UIView()
	private var tabButtons: [UIButton] = []
	private var activeTab = 0
	private let searchRowHeight: CGFloat = 42
	private let barHeight: CGFloat = 42

	/// Recents come from UserDefaults; the catalog comes from the mmap'd EmojiStore.
	/// If the bundled resource is missing, the view fails closed instead of shipping
	/// a stale in-code emoji catalog.
	private enum Section {
		case recents([String])
		case bundled(EmojiStore, Int)
	}
	private var sections: [Section] = []
	private let store: EmojiStore?
	private let explicitAtlas: EmojiAtlas?
	/// Lazy so the first cell resolves it in-window, where displayScale is real
	/// (it is 0 for a view that was never attached). nil → text-label fallback.
	private lazy var atlas: EmojiAtlas? =
		explicitAtlas ?? EmojiAtlas.loadShared(store: store, scale: traitCollection.displayScale)

	private func name(of s: Int) -> String {
		switch sections[s] {
		case .recents:                return "Recently Used"
		case .bundled(let st, let c): return st.name(c)
		}
	}
	private func icon(of s: Int) -> String {
		switch sections[s] {
		case .recents:                return "clock"
		case .bundled(let st, let c): return st.icon(c)
		}
	}
	private func emojiCount(in s: Int) -> Int {
		switch sections[s] {
		case .recents(let list):      return list.count
		case .bundled(let st, let c): return st.emojiCount(c)
		}
	}
	private func emoji(at ip: IndexPath) -> String {
		switch sections[ip.section] {
		case .recents(let list):      return list[ip.item]
		case .bundled(let st, let c): return st.emoji(c, ip.item)
		}
	}

	/// `store` and `atlas` are injectable for tests.
	init(theme: KeyboardTheme, showsGlobe: Bool,
		 store: EmojiStore? = EmojiStore.bundled, atlas: EmojiAtlas? = nil) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.store = store
		self.explicitAtlas = atlas
		super.init(frame: .zero)

		let recents = KBEmojiRecents.all()
		if !recents.isEmpty { sections.append(.recents(recents)) }
		if let store {
			sections.append(contentsOf: (0..<store.categoryCount).map { .bundled(store, $0) })
		}

		collection = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
		collection.backgroundColor = .clear
		collection.dataSource = self
		collection.delegate = self
		collection.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
		collection.register(EmojiHeader.self,
							forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
							withReuseIdentifier: "h")
		collection.showsVerticalScrollIndicator = false
		emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
		emptyLabel.textColor = theme.specialKeyText.withAlphaComponent(0.55)
		emptyLabel.textAlignment = .center
		emptyLabel.numberOfLines = 2
		emptyLabel.text = sections.isEmpty ? "Emoji data unavailable" : nil
		emptyLabel.isHidden = !sections.isEmpty
		collection.backgroundView = emptyLabel
		addSubview(collection)

		buildSearchPill()
		buildBottomBar()
		addSubview(searchPill)
		addSubview(bottomBar)
	}
	required init?(coder: NSCoder) { fatalError() }

	/// Vertical grid: N square cells per row (N from the live width), full rows always.
	private func makeLayout() -> UICollectionViewLayout {
		UICollectionViewCompositionalLayout { _, env in
			let width = max(1, env.container.effectiveContentSize.width - 12)
			let cols = max(6, Int(width / 46))
			let side = 1.0 / CGFloat(cols)
			let item = NSCollectionLayoutItem(layoutSize: .init(
				widthDimension: .fractionalWidth(side), heightDimension: .fractionalHeight(1)))
			let row = NSCollectionLayoutGroup.horizontal(layoutSize: .init(
				widthDimension: .fractionalWidth(1), heightDimension: .absolute(width * side)),
				subitems: [item])
			let sec = NSCollectionLayoutSection(group: row)
			sec.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 10, trailing: 6)
			let header = NSCollectionLayoutBoundarySupplementaryItem(
				layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(24)),
				elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
			sec.boundarySupplementaryItems = [header]
			return sec
		}
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		searchPill.frame = CGRect(x: 8, y: 5, width: bounds.width - 16, height: searchRowHeight - 10)
		bottomBar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
		collection.frame = CGRect(x: 0, y: searchRowHeight, width: bounds.width,
								  height: max(0, bounds.height - searchRowHeight - barHeight))
	}

	// MARK: Search pill (tap hands off to KeyboardView's emoji-search mode)

	private func buildSearchPill() {
		var cfg = UIButton.Configuration.plain()
		cfg.image = UIImage(systemName: "magnifyingglass",
							withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
		cfg.imagePadding = 6
		cfg.attributedTitle = AttributedString("Search emoji", attributes: AttributeContainer([
			.font: UIFont.systemFont(ofSize: 15),
			.foregroundColor: theme.keyText.withAlphaComponent(0.45)
		]))
		cfg.baseForegroundColor = theme.keyText.withAlphaComponent(0.45)
		cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
		searchPill.configuration = cfg
		searchPill.contentHorizontalAlignment = .leading
		searchPill.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 1, alpha: 0.55)
		searchPill.layer.cornerRadius = (searchRowHeight - 10) / 2
		searchPill.layer.cornerCurve = .continuous
		searchPill.isEnabled = store != nil          // no catalog → nothing to search
		searchPill.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)
	}

	// MARK: Collection data

	func numberOfSections(in cv: UICollectionView) -> Int { sections.count }
	func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { emojiCount(in: s) }
	func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
		let cell = cv.dequeueReusableCell(withReuseIdentifier: "e", for: ip) as! EmojiCell
		let e = emoji(at: ip)
		cell.configure(emoji: e, image: atlas?.image(for: e), theme: theme)
		return cell
	}
	func collectionView(_ cv: UICollectionView, viewForSupplementaryElementOfKind kind: String,
						at ip: IndexPath) -> UICollectionReusableView {
		let h = cv.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "h", for: ip) as! EmojiHeader
		h.label.text = name(of: ip.section).uppercased()
		h.label.textColor = theme.specialKeyText.withAlphaComponent(0.55)
		return h
	}
	func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
		let e = emoji(at: ip)
		onPick?(e)
		KBEmojiRecents.add(e)
	}

	/// Keep the active category tab tracking the topmost visible section.
	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		guard let top = collection.indexPathsForVisibleItems.min()?.section, top != activeTab else { return }
		setActiveTab(top)
	}

	// MARK: Bottom bar — ABC | (globe) | category tabs | delete

	private func buildBottomBar() {
		bottomBar.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.04)
		var leading: [UIButton] = [barButton(title: "ABC") { [weak self] in self?.onABC?() }]
		if showsGlobe { leading.append(barButton(symbol: "globe") { [weak self] in self?.onNextKeyboard?() }) }
		leading.append(barButton(title: "GIF") { [weak self] in self?.onGIF?() })

		let nav = UIStackView()
		nav.axis = .horizontal
		nav.distribution = .fillEqually
		for i in sections.indices {
			let b = barButton(symbol: icon(of: i), pointSize: 15) { [weak self] in
				self?.scrollTo(section: i)
			}
			tabButtons.append(b)
			nav.addArrangedSubview(b)
		}
		setActiveTab(0)
		let del = barButton(symbol: "delete.left") { [weak self] in self?.onDelete?() }

		let stack = UIStackView(arrangedSubviews: leading + [nav, del])
		stack.axis = .horizontal
		stack.spacing = 2
		stack.alignment = .fill
		nav.setContentHuggingPriority(.defaultLow, for: .horizontal)      // tabs take the slack
		for b in leading + [del] {
			b.setContentHuggingPriority(.required, for: .horizontal)
			b.widthAnchor.constraint(equalToConstant: 40).isActive = true
		}
		stack.translatesAutoresizingMaskIntoConstraints = false
		bottomBar.addSubview(stack)
		// Sub-required trailing: bottomBar is frame-laid, so its width is 0 on the first
		// Auto Layout pass and required 40pt children can't fit — see ClipboardPanel.
		let trailing = stack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -4)
		trailing.priority = .required - 1
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 4),
			trailing,
			stack.topAnchor.constraint(equalTo: bottomBar.topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor)
		])
	}

	private func scrollTo(section i: Int) {
		guard i < sections.count, emojiCount(in: i) > 0 else { return }
		setActiveTab(i)
		// Land the section HEADER at the top, not the first cell under it.
		if let attr = collection.layoutAttributesForSupplementaryElement(
			ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: i)) {
			let maxY = max(0, collection.contentSize.height - collection.bounds.height)
			collection.setContentOffset(CGPoint(x: 0, y: min(attr.frame.minY, maxY)), animated: false)
		} else {
			collection.scrollToItem(at: IndexPath(item: 0, section: i), at: .top, animated: false)
		}
	}

	private func setActiveTab(_ i: Int) {
		guard i < tabButtons.count else { return }
		tabButtons[activeTab].tintColor = theme.specialKeyText.withAlphaComponent(0.5)
		tabButtons[activeTab].backgroundColor = .clear
		activeTab = i
		let active = tabButtons[i]
		active.tintColor = theme.keyText
		active.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.08)
		active.layer.cornerRadius = 8
		active.layer.cornerCurve = .continuous
		// Once per category crossed, not per scroll tick: cheap footprint samples so
		// browsing the grid (glyph raster cache growth) is visible in health telemetry.
		KBDiagnostics.recorder.sample()
	}

	private func barButton(title: String? = nil, symbol: String? = nil,
						   pointSize: CGFloat = 16, action: @escaping () -> Void) -> UIButton {
		let b = UIButton(type: .system)
		if let title {
			b.setTitle(title, for: .normal)
			b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
		}
		if let symbol {
			b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)), for: .normal)
		}
		b.tintColor = theme.specialKeyText.withAlphaComponent(0.5)
		b.setTitleColor(theme.specialKeyText, for: .normal)
		b.addAction(UIAction { _ in action() }, for: .touchUpInside)
		return b
	}
}

// MARK: - EmojiSearchHeader (Gboard-style: search rides the REAL keyboard)
//
// Shown by KeyboardView above the normal letter deck while emoji search is active:
// a back button, the live query in a pill (with blinking caret + inline clear), and
// a horizontal strip of results. Typing goes through the real keys — KeyboardView
// routes inserts/deletes into the query instead of the host document — so there is
// no cramped mini keyboard, and every typing nicety (popups, multitouch) just works.
final class EmojiSearchHeader: UIView {
	static let height: CGFloat = 86     // 38 search row + 48 results row

	var onCancel: (() -> Void)?
	var onClear: (() -> Void)?
	var onPick: ((String) -> Void)?

	// Wording knobs so the media (GIF/sticker) search can ride the same header.
	var placeholder = "Search emoji"
	var emptyStatus = "Type to search emoji"
	var noResultsStatus = "No emoji found"

	private let theme: KeyboardTheme
	private let atlas: EmojiAtlas?
	private let pill = UIView()
	private let queryLabel = UILabel()
	private let caret = UIView()
	// The caret rides the text: at the pill's start while the placeholder shows
	// (nothing typed yet), after the query once there is one. Toggled in update().
	private var caretAtStart: NSLayoutConstraint!
	private var caretAfterText: NSLayoutConstraint!
	private let clearButton = UIButton(type: .system)
	private let resultsScroll = UIScrollView()
	private let resultsStack = UIStackView()
	private let statusLabel = UILabel()
	private let resultCap = 60          // plenty to swipe through; keeps the strip cheap

	init(theme: KeyboardTheme, atlas: EmojiAtlas? = nil) {
		self.theme = theme
		self.atlas = atlas
		super.init(frame: .zero)

		// Row 1: back chevron + query pill.
		let back = UIButton(type: .system)
		back.setImage(UIImage(systemName: "arrow.left",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
		back.tintColor = theme.specialKeyText
		back.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
		back.translatesAutoresizingMaskIntoConstraints = false
		addSubview(back)

		pill.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 1, alpha: 0.55)
		pill.layer.cornerRadius = 16
		pill.layer.cornerCurve = .continuous
		pill.translatesAutoresizingMaskIntoConstraints = false
		addSubview(pill)

		let glass = UIImageView(image: UIImage(systemName: "magnifyingglass",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)))
		glass.tintColor = theme.keyText.withAlphaComponent(0.45)
		glass.translatesAutoresizingMaskIntoConstraints = false
		pill.addSubview(glass)

		queryLabel.font = .systemFont(ofSize: 16)
		queryLabel.translatesAutoresizingMaskIntoConstraints = false
		queryLabel.setContentHuggingPriority(.required, for: .horizontal)
		queryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		pill.addSubview(queryLabel)

		caret.backgroundColor = theme.isDark ? UIColor(hex: 0xECECF0) : theme.keyText
		caret.layer.cornerRadius = 1
		caret.translatesAutoresizingMaskIntoConstraints = false
		pill.addSubview(caret)

		clearButton.setImage(UIImage(systemName: "xmark.circle.fill",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)), for: .normal)
		clearButton.tintColor = theme.keyText.withAlphaComponent(0.35)
		clearButton.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
		clearButton.translatesAutoresizingMaskIntoConstraints = false
		pill.addSubview(clearButton)

		// Row 2: horizontal results strip (or a status line when there's nothing to show).
		resultsStack.axis = .horizontal
		resultsStack.spacing = 2
		resultsStack.translatesAutoresizingMaskIntoConstraints = false
		resultsScroll.showsHorizontalScrollIndicator = false
		resultsScroll.translatesAutoresizingMaskIntoConstraints = false
		resultsScroll.addSubview(resultsStack)
		addSubview(resultsScroll)

		statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
		statusLabel.textColor = theme.specialKeyText.withAlphaComponent(0.5)
		statusLabel.translatesAutoresizingMaskIntoConstraints = false
		addSubview(statusLabel)

		NSLayoutConstraint.activate([
			back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
			back.centerYAnchor.constraint(equalTo: topAnchor, constant: 19),
			back.widthAnchor.constraint(equalToConstant: 36),
			back.heightAnchor.constraint(equalToConstant: 36),

			pill.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
			pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
			pill.centerYAnchor.constraint(equalTo: topAnchor, constant: 19),
			pill.heightAnchor.constraint(equalToConstant: 32),

			glass.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 11),
			glass.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

			queryLabel.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 7),
			queryLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
			queryLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -8),

			caret.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
			caret.widthAnchor.constraint(equalToConstant: 2),
			caret.heightAnchor.constraint(equalToConstant: 18),

			clearButton.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
			clearButton.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
			clearButton.widthAnchor.constraint(equalToConstant: 28),
			clearButton.heightAnchor.constraint(equalToConstant: 28),

			resultsScroll.topAnchor.constraint(equalTo: topAnchor, constant: 38),
			resultsScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
			resultsScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
			resultsScroll.heightAnchor.constraint(equalToConstant: 48),

			resultsStack.topAnchor.constraint(equalTo: resultsScroll.contentLayoutGuide.topAnchor),
			resultsStack.bottomAnchor.constraint(equalTo: resultsScroll.contentLayoutGuide.bottomAnchor),
			resultsStack.leadingAnchor.constraint(equalTo: resultsScroll.contentLayoutGuide.leadingAnchor),
			resultsStack.trailingAnchor.constraint(equalTo: resultsScroll.contentLayoutGuide.trailingAnchor),
			resultsStack.heightAnchor.constraint(equalTo: resultsScroll.frameLayoutGuide.heightAnchor),

			statusLabel.centerYAnchor.constraint(equalTo: resultsScroll.centerYAnchor),
			statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
		])
		caretAtStart = caret.trailingAnchor.constraint(equalTo: queryLabel.leadingAnchor, constant: -1)
		caretAfterText = caret.leadingAnchor.constraint(equalTo: queryLabel.trailingAnchor, constant: 1)
		caretAtStart.isActive = true                 // the query starts empty
	}
	required init?(coder: NSCoder) { fatalError() }

	override func didMoveToWindow() {
		super.didMoveToWindow()
		guard window != nil else { return }
		caret.alpha = 1
		UIView.animate(withDuration: 0.55, delay: 0.3, options: [.repeat, .autoreverse, .allowUserInteraction]) {
			self.caret.alpha = 0
		}
	}

	/// Refresh the query text and results strip. Empty query shows recents (labeled),
	/// so the strip is never a dead zone.
	func update(query: String, results: [String], showingRecents: Bool) {
		if query.isEmpty {
			queryLabel.text = placeholder
			queryLabel.textColor = theme.keyText.withAlphaComponent(0.45)
			clearButton.isHidden = true
			caretAfterText.isActive = false          // deactivate first — never both at once
			caretAtStart.isActive = true             // caret blinks BEFORE the placeholder
		} else {
			queryLabel.text = query
			queryLabel.textColor = theme.keyText
			clearButton.isHidden = false
			caretAtStart.isActive = false
			caretAfterText.isActive = true
		}

		resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
		for e in results.prefix(resultCap) {
			let b = UIButton(type: .system)
			// Atlas tile when available — same clean-memory path as the grid; text
			// glyphs otherwise (bounded: at most `resultCap` per refresh).
			if let img = atlas?.image(for: e) {
				b.setImage(img.withRenderingMode(.alwaysOriginal), for: .normal)
			} else {
				b.setTitle(e, for: .normal)
				b.titleLabel?.font = .systemFont(ofSize: 28)
			}
			b.widthAnchor.constraint(equalToConstant: 44).isActive = true
			b.addAction(UIAction { [weak self] _ in self?.onPick?(e) }, for: .touchUpInside)
			resultsStack.addArrangedSubview(b)
		}
		resultsScroll.setContentOffset(.zero, animated: false)

		if results.isEmpty {
			statusLabel.text = showingRecents ? emptyStatus : noResultsStatus
			statusLabel.isHidden = false
		} else {
			statusLabel.isHidden = true
		}
	}
}
