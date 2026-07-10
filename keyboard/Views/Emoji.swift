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

struct EmojiCategory { let name: String; let icon: String; let emojis: [String] }

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
final class EmojiStore {
	private let data: Data
	let categoryCount: Int
	private let stringCount: Int
	private let mapCount: Int
	private let catBase, offsBase, mapBase, blobBase: Int

	/// nil unless `emoji.bin` ships in the current target — EmojiData.categories
	/// below remains as the fallback.
	static let bundled: EmojiStore? = {
		guard let url = Bundle.main.url(forResource: "emoji", withExtension: "bin") else { return nil }
		return EmojiStore(url: url)
	}()

	private init?(url: URL) {
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
			else { return string(u32(mapBase + 8 * mid + 4)) }
		}
		return nil
	}

	/// Emoji whose keyword matches `query`, prefix matches first. Scans the (small,
	/// ~150-entry) word→emoji map — the same table that powers word→emoji suggestions.
	/// Coverage is only as wide as that keyword table; a fuller emoji keyword index can
	/// be added to emoji.bin later without touching this call site.
	func search(_ query: String) -> [String] {
		guard mapCount > 0 else { return [] }
		let q = query.lowercased()
		guard !q.isEmpty else { return [] }
		var prefix: [String] = [], contains: [String] = []
		var seen = Set<String>()
		for i in 0..<mapCount {
			let w = string(u32(mapBase + 8 * i))
			guard w.contains(q) else { continue }
			let e = string(u32(mapBase + 8 * i + 4))
			guard seen.insert(e).inserted else { continue }
			if w.hasPrefix(q) { prefix.append(e) } else { contains.append(e) }
		}
		return prefix + contains
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

// MARK: - Fallback catalog for a missing `emoji.bin`
//
// The literals themselves are clean text-segment bytes, but `categories` materializes
// ~1,300 heap Strings — which is exactly why the mmap'd EmojiStore is preferred. Lazy:
// untouched when the binary resource is present.
enum EmojiData {
	static let categories: [EmojiCategory] = [
		EmojiCategory(name: "Smileys & People", icon: "face.smiling", emojis:
			"😀 😃 😄 😁 😆 😅 😂 🤣 🥲 😊 😇 🙂 🙃 😉 😌 😍 🥰 😘 😗 😙 😚 😋 😛 😝 😜 🤪 🤨 🧐 🤓 😎 🥳 🤩 😏 😒 😞 😔 😟 😕 🙁 ☹️ 😣 😖 😫 😩 🥺 😢 😭 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😱 😨 😰 😥 😓 🤗 🤔 🤭 🤫 🤥 😶 😐 😑 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😵 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕 👋 🤚 ✋ 🖖 👌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🙏 💪 🦶 🦵 👀 👁 👅 👄 🧠".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Animals & Nature", icon: "pawprint", emojis:
			"🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐒 🐔 🐧 🐦 🐤 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🐛 🦋 🐌 🐞 🐜 🦗 🕷 🐢 🐍 🦎 🦖 🦕 🐙 🦑 🦐 🦀 🐡 🐠 🐟 🐬 🐳 🐋 🦈 🐊 🐅 🐆 🦓 🦍 🐘 🦏 🐫 🦒 🐃 🐂 🐄 🐎 🐖 🐏 🐑 🐐 🌵 🎄 🌲 🌳 🌴 🌱 🌿 ☘️ 🍀 🎍 🌾 🌺 🌻 🌹 🌷 🌸 🌼 🌞 🌝 🌚 ⭐️ 🌟 ✨ ⚡️ 🔥 🌈 ☀️ ⛅️ ☁️ 🌧 ⛈ ❄️ ☃️ 💧 🌊".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Food & Drink", icon: "fork.knife", emojis:
			"🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶 🌽 🥕 🧄 🧅 🥔 🍠 🥐 🍞 🥖 🥨 🧀 🥚 🍳 🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🥪 🌮 🌯 🥗 🍝 🍜 🍲 🍣 🍱 🍛 🍤 🍙 🍚 🍥 🥟 🍦 🍰 🎂 🍮 🍭 🍬 🍫 🍿 🍩 🍪 ☕️ 🍵 🥤 🧃 🍺 🍻 🥂 🍷 🥃 🍸 🍹 🧉".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Activity", icon: "figure.run", emojis:
			"⚽️ 🏀 🏈 ⚾️ 🥎 🎾 🏐 🏉 🥏 🎱 🏓 🏸 🏒 🏑 🥍 🏏 🥅 ⛳️ 🏹 🎣 🥊 🥋 🎽 ⛸ 🥌 🛷 🎿 ⛷ 🏂 🏋️ 🤼 🤸 ⛹️ 🤺 🤾 🏌️ 🏇 🧘 🏄 🏊 🤽 🚣 🚴 🚵 🎪 🎭 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🎷 🎺 🎸 🎻 🎲 🎯 🎳 🎮 🎰 🧩 🏆 🥇 🥈 🥉 🏅".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Travel & Places", icon: "car", emojis:
			"🚗 🚕 🚙 🚌 🚎 🏎 🚓 🚑 🚒 🚐 🚚 🚛 🚜 🛴 🚲 🛵 🏍 🚨 🚔 🚍 🚘 🚖 🚡 🚠 🚟 🚃 🚋 🚝 🚄 🚅 🚈 🚂 🚆 🚇 🚊 🚉 ✈️ 🛫 🛬 💺 🚁 🚀 🛸 🚤 ⛵️ 🛶 🚢 ⚓️ 🗺 🗽 🗼 🏰 🏯 🏟 🎡 🎢 🎠 ⛲️ 🏖 🏝 ⛰ 🏔 🗻 🌋 🏕 ⛺️ 🏠 🏡 🏘 🏢 🏬 🏦 🏨 🏪 🏫 🏩 💒 🏛 ⛪️ 🕌 🕍 🛕".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Objects", icon: "lightbulb", emojis:
			"⌚️ 📱 💻 ⌨️ 🖥 🖨 🖱 💽 💾 💿 📷 📸 📹 🎥 📞 ☎️ 📟 📺 📻 ⏱ ⏰ 🕰 ⌛️ ⏳ 📡 🔋 🔌 💡 🔦 🕯 🧯 💸 💵 💴 💶 💷 💰 💳 🧾 💎 ⚖️ 🔧 🔨 🛠 🔩 ⚙️ 🧰 🧲 🔫 💣 🔪 🚬 ⚰️ 🏺 🔮 📿 💈 🔭 🔬 🕳 💊 💉 🩸 🌡 🧷 🧵 🧶 👓 🕶 🌂 ☂️ 🧳 🎒 👜 👛 👝 🛍 🎁 🎈 🎏 🎀 🎉 🎊".split(separator: " ").map(String.init)),
		EmojiCategory(name: "Symbols", icon: "heart", emojis:
			"❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💯 ✅ ❌ ❎ ➕ ➖ ➗ ✖️ ♾ 💲 ™️ ©️ ®️ 〰️ ➰ ➿ 🔚 🔙 🔛 🔝 🔜 ✔️ ☑️ 🔘 🔴 🟠 🟡 🟢 🔵 🟣 ⚫️ ⚪️ 🟤 🔺 🔻 🔸 🔹 🔶 🔷 🔳 🔲 ▪️ ▫️ ◼️ ◻️ ⬛️ ⬜️ 🟥 🟧 🟨 🟩 🟦 🟪 ⭐️ 🌟 ❓ ❗️ ‼️ ⁉️ 💤 🎵 🎶".split(separator: " ").map(String.init)),
	]
}

// MARK: - Cells

private final class EmojiCell: UICollectionViewCell {
	let label = UILabel()
	override init(frame: CGRect) {
		super.init(frame: frame)
		label.textAlignment = .center
		label.font = .systemFont(ofSize: 30)
		label.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(label)
		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
		])
	}
	required init?(coder: NSCoder) { fatalError() }
}

private final class EmojiHeader: UICollectionReusableView {
	let label = UILabel()
	override init(frame: CGRect) {
		super.init(frame: frame)
		label.font = .systemFont(ofSize: 12, weight: .semibold)
		label.translatesAutoresizingMaskIntoConstraints = false
		addSubview(label)
		NSLayoutConstraint.activate([
			label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
			label.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}
	required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Emoji page
//
// A horizontally-scrolling, category-sectioned grid with a bottom bar (ABC / globe /
// search / category quick-nav / delete). Shown as an overlay by KeyboardView; the
// collection view handles its own scrolling and taps, so KeyboardView's key
// touch-handling never sees it. Tapping search swaps the bottom bar for a compact
// keypad and filters to a single results section.
final class EmojiKeyboardView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
	var onPick: ((String) -> Void)?
	var onDelete: (() -> Void)?
	var onABC: (() -> Void)?
	var onNextKeyboard: (() -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private let collection: UICollectionView
	private let bottomBar = UIView()
	private let barHeight: CGFloat = 44

	/// Recents come from UserDefaults; the catalog comes from the mmap'd EmojiStore
	/// (per-cell decode, no heap catalog) or, if `emoji.bin` is missing, the legacy
	/// in-code categories.
	private enum Section {
		case recents([String])
		case bundled(EmojiStore, Int)
		case legacy(EmojiCategory)
	}
	private var sections: [Section] = []
	private let store = EmojiStore.bundled

	// Search mode.
	private var isSearching = false
	private var query = ""
	private var results: [String] = []
	private let searchBar = UIView()
	private let searchLabel = UILabel()
	private let searchKeyboard = UIView()
	private let searchBarHeight: CGFloat = 40
	private let kbRowHeight: CGFloat = 42
	private var searchKeyboardHeight: CGFloat { kbRowHeight * 3 + 10 }

	private func name(of s: Int) -> String {
		switch sections[s] {
		case .recents:                return "Recently Used"
		case .bundled(let st, let c): return st.name(c)
		case .legacy(let cat):        return cat.name
		}
	}
	private func icon(of s: Int) -> String {
		switch sections[s] {
		case .recents:                return "clock"
		case .bundled(let st, let c): return st.icon(c)
		case .legacy(let cat):        return cat.icon
		}
	}
	private func emojiCount(in s: Int) -> Int {
		switch sections[s] {
		case .recents(let list):      return list.count
		case .bundled(let st, let c): return st.emojiCount(c)
		case .legacy(let cat):        return cat.emojis.count
		}
	}
	private func emoji(at ip: IndexPath) -> String {
		switch sections[ip.section] {
		case .recents(let list):      return list[ip.item]
		case .bundled(let st, let c): return st.emoji(c, ip.item)
		case .legacy(let cat):        return cat.emojis[ip.item]
		}
	}

	init(theme: KeyboardTheme, showsGlobe: Bool) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		let layout = UICollectionViewFlowLayout()
		layout.scrollDirection = .horizontal            // swipe left/right through categories
		layout.minimumInteritemSpacing = 0              // between rows within a column
		layout.minimumLineSpacing = 4                   // between columns
		layout.sectionInset = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
		collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
		super.init(frame: .zero)

		let recents = KBEmojiRecents.all()
		if !recents.isEmpty { sections.append(.recents(recents)) }
		if let store {
			sections.append(contentsOf: (0..<store.categoryCount).map { .bundled(store, $0) })
		} else {
			sections.append(contentsOf: EmojiData.categories.map(Section.legacy))
		}

		collection.backgroundColor = .clear
		collection.dataSource = self
		collection.delegate = self
		collection.register(EmojiCell.self, forCellWithReuseIdentifier: "e")
		// Horizontal-only scroll: kill the vertical bounce (the source of the zig-zag
		// diagonal drift) and lock a drag to one axis so a sideways swipe stays sideways.
		collection.alwaysBounceVertical = false
		collection.alwaysBounceHorizontal = true
		collection.isDirectionalLockEnabled = true
		collection.showsVerticalScrollIndicator = false
		collection.showsHorizontalScrollIndicator = false
		addSubview(collection)

		buildBottomBar()
		addSubview(bottomBar)
		buildSearch()
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		if isSearching {
			searchBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: searchBarHeight)
			searchKeyboard.frame = CGRect(x: 0, y: bounds.height - searchKeyboardHeight,
										  width: bounds.width, height: searchKeyboardHeight)
			collection.frame = CGRect(x: 0, y: searchBarHeight, width: bounds.width,
									  height: max(0, bounds.height - searchBarHeight - searchKeyboardHeight))
		} else {
			bottomBar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
			collection.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
		}
	}

	// MARK: Collection data (browse sections, or a single results section while searching)

	func numberOfSections(in cv: UICollectionView) -> Int { isSearching ? 1 : sections.count }
	func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int {
		isSearching ? results.count : emojiCount(in: s)
	}
	func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
		let cell = cv.dequeueReusableCell(withReuseIdentifier: "e", for: ip) as! EmojiCell
		cell.label.text = isSearching ? results[ip.item] : emoji(at: ip)
		return cell
	}
	func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
		// Horizontal scroll: fix the row count to the available height; cells are square,
		// so emoji fill top-to-bottom in each column and the grid scrolls sideways.
		let avail = isSearching ? (bounds.height - searchBarHeight - searchKeyboardHeight - 4)
							     : (bounds.height - barHeight - 4)
		let usable = max(44, avail)
		let rows = max(isSearching ? 1 : 3, Int(usable / 44))
		let side = floor(usable / CGFloat(rows))
		return CGSize(width: side, height: side)
	}
	func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
		let e = isSearching ? results[ip.item] : emoji(at: ip)
		onPick?(e)
		KBEmojiRecents.add(e)
	}

	// MARK: Bottom bar

	private func buildBottomBar() {
		bottomBar.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.04)
		var leading: [UIButton] = [barButton(title: "ABC") { [weak self] in self?.onABC?() }]
		if showsGlobe { leading.append(barButton(symbol: "globe") { [weak self] in self?.onNextKeyboard?() }) }
		if store != nil { leading.append(barButton(symbol: "magnifyingglass") { [weak self] in self?.enterSearch() }) }

		let nav = UIStackView()
		nav.axis = .horizontal
		nav.distribution = .fillEqually
		for i in sections.indices {
			nav.addArrangedSubview(barButton(symbol: icon(of: i)) { [weak self] in
				self?.collection.scrollToItem(at: IndexPath(item: 0, section: i), at: .left, animated: false)
			})
		}
		let del = barButton(symbol: "delete.left") { [weak self] in self?.onDelete?() }

		let stack = UIStackView(arrangedSubviews: leading + [nav, del])
		stack.axis = .horizontal
		stack.spacing = 2
		stack.alignment = .fill
		nav.setContentHuggingPriority(.defaultLow, for: .horizontal)      // nav takes the slack
		for b in leading + [del] {
			b.setContentHuggingPriority(.required, for: .horizontal)
			b.widthAnchor.constraint(equalToConstant: 38).isActive = true
		}
		stack.translatesAutoresizingMaskIntoConstraints = false
		bottomBar.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 4),
			stack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -4),
			stack.topAnchor.constraint(equalTo: bottomBar.topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor)
		])
	}

	private func barButton(title: String? = nil, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
		let b = UIButton(type: .system)
		if let title {
			b.setTitle(title, for: .normal)
			b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
		}
		if let symbol {
			b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
		}
		b.tintColor = theme.specialKeyText
		b.setTitleColor(theme.specialKeyText, for: .normal)
		b.addAction(UIAction { _ in action() }, for: .touchUpInside)
		return b
	}

	// MARK: Search (field + compact keypad + live results)

	private func buildSearch() {
		searchBar.isHidden = true
		searchKeyboard.isHidden = true
		searchBar.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.04)

		let pill = UIView()
		pill.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 1, alpha: 0.7)
		pill.layer.cornerRadius = 15
		pill.translatesAutoresizingMaskIntoConstraints = false
		searchBar.addSubview(pill)

		let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
		glass.tintColor = theme.specialKeyText.withAlphaComponent(0.6)
		glass.translatesAutoresizingMaskIntoConstraints = false
		pill.addSubview(glass)

		searchLabel.font = .systemFont(ofSize: 16)
		searchLabel.textColor = theme.keyText
		searchLabel.translatesAutoresizingMaskIntoConstraints = false
		pill.addSubview(searchLabel)

		let cancel = UIButton(type: .system)
		cancel.setTitle("Cancel", for: .normal)
		cancel.titleLabel?.font = .systemFont(ofSize: 15)
		cancel.tintColor = theme.specialKeyText
		cancel.setTitleColor(theme.specialKeyText, for: .normal)
		cancel.translatesAutoresizingMaskIntoConstraints = false
		cancel.addAction(UIAction { [weak self] _ in self?.exitSearch() }, for: .touchUpInside)
		searchBar.addSubview(cancel)

		NSLayoutConstraint.activate([
			pill.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
			pill.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
			pill.heightAnchor.constraint(equalToConstant: 30),
			pill.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -6),
			cancel.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),
			cancel.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
			glass.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
			glass.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
			glass.widthAnchor.constraint(equalToConstant: 16),
			glass.heightAnchor.constraint(equalToConstant: 16),
			searchLabel.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 8),
			searchLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
			searchLabel.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
		])
		addSubview(searchBar)

		buildSearchKeyboard()
		addSubview(searchKeyboard)
	}

	private func buildSearchKeyboard() {
		let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
		let column = UIStackView()
		column.axis = .vertical
		column.distribution = .fillEqually
		column.spacing = 5
		column.translatesAutoresizingMaskIntoConstraints = false
		for (i, row) in rows.enumerated() {
			let rowStack = UIStackView()
			rowStack.axis = .horizontal
			rowStack.distribution = .fillEqually
			rowStack.spacing = 4
			for ch in row { rowStack.addArrangedSubview(letterKey(String(ch))) }
			if i == 2 { rowStack.addArrangedSubview(letterKey("⌫", isBackspace: true)) }
			column.addArrangedSubview(rowStack)
		}
		searchKeyboard.addSubview(column)
		NSLayoutConstraint.activate([
			column.leadingAnchor.constraint(equalTo: searchKeyboard.leadingAnchor, constant: 4),
			column.trailingAnchor.constraint(equalTo: searchKeyboard.trailingAnchor, constant: -4),
			column.topAnchor.constraint(equalTo: searchKeyboard.topAnchor, constant: 5),
			column.bottomAnchor.constraint(equalTo: searchKeyboard.bottomAnchor, constant: -5)
		])
	}

	private func letterKey(_ label: String, isBackspace: Bool = false) -> UIButton {
		let b = UIButton(type: .system)
		b.setTitle(label, for: .normal)
		b.titleLabel?.font = .systemFont(ofSize: isBackspace ? 18 : 18, weight: .regular)
		b.setTitleColor(theme.keyText, for: .normal)
		b.backgroundColor = theme.key
		b.layer.cornerRadius = 5
		b.addAction(UIAction { [weak self] _ in
			if isBackspace { self?.backspaceQuery() } else { self?.appendQuery(label) }
		}, for: .touchUpInside)
		return b
	}

	private func enterSearch() {
		isSearching = true
		query = ""
		results = []
		searchLabel.text = "Search emoji"
		searchLabel.textColor = theme.keyText.withAlphaComponent(0.4)
		searchBar.isHidden = false
		searchKeyboard.isHidden = false
		bottomBar.isHidden = true
		collection.reloadData()
		setNeedsLayout()
	}
	private func exitSearch() {
		isSearching = false
		searchBar.isHidden = true
		searchKeyboard.isHidden = true
		bottomBar.isHidden = false
		collection.reloadData()
		setNeedsLayout()
	}
	private func appendQuery(_ ch: String) {
		query += ch
		refreshSearch()
	}
	private func backspaceQuery() {
		guard !query.isEmpty else { return }
		query.removeLast()
		refreshSearch()
	}
	private func refreshSearch() {
		if query.isEmpty {
			searchLabel.text = "Search emoji"
			searchLabel.textColor = theme.keyText.withAlphaComponent(0.4)
			results = []
		} else {
			searchLabel.text = query
			searchLabel.textColor = theme.keyText
			results = store?.search(query) ?? []
		}
		collection.reloadData()
		collection.setContentOffset(.zero, animated: false)
	}
}
