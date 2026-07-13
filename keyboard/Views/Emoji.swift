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
final class EmojiStore {
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
			else { return string(u32(mapBase + 8 * mid + 4)) }
		}
		return nil
	}

	/// Emoji whose keyword matches `query`, ranked by exact, prefix, then contains.
	/// Scans the generated word->emoji map: the same binary data powers search and
	/// suggestion-bar emoji candidates.
	func search(_ query: String) -> [String] {
		guard mapCount > 0 else { return [] }
		let q = normalizedSearchTerm(query)
		guard !q.isEmpty else { return [] }
		var hits: [(rank: Int, order: Int, emoji: String)] = []
		var seen = Set<String>()
		for i in 0..<mapCount {
			let w = string(u32(mapBase + 8 * i))
			let term = normalizedSearchTerm(w)
			let rank: Int?
			if term == q {
				rank = 0
			} else if term.hasPrefix(q) {
				rank = 100 + term.count
			} else if let range = term.range(of: q) {
				rank = 200 + term.distance(from: term.startIndex, to: range.lowerBound)
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

// MARK: - Cells

private final class EmojiCell: UICollectionViewCell {
	let label = UILabel()
	private var highlightColor = UIColor.clear

	override var isHighlighted: Bool {
		didSet { contentView.backgroundColor = isHighlighted ? highlightColor : .clear }
	}

	override init(frame: CGRect) {
		super.init(frame: frame)
		label.textAlignment = .center
		label.font = .systemFont(ofSize: 28)
		label.translatesAutoresizingMaskIntoConstraints = false
		contentView.layer.cornerRadius = 8
		contentView.layer.cornerCurve = .continuous
		contentView.clipsToBounds = true
		contentView.addSubview(label)
		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
		])
	}
	required init?(coder: NSCoder) { fatalError() }

	func configure(emoji: String, theme: KeyboardTheme) {
		label.text = emoji
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

	/// `store` is injectable for tests (the app target doesn't bundle emoji.bin).
	init(theme: KeyboardTheme, showsGlobe: Bool, store: EmojiStore? = EmojiStore.bundled) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.store = store
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
		cell.configure(emoji: emoji(at: ip), theme: theme)
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
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 4),
			stack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -4),
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

	private let theme: KeyboardTheme
	private let pill = UIView()
	private let queryLabel = UILabel()
	private let caret = UIView()
	private let clearButton = UIButton(type: .system)
	private let resultsScroll = UIScrollView()
	private let resultsStack = UIStackView()
	private let statusLabel = UILabel()
	private let resultCap = 60          // plenty to swipe through; keeps the strip cheap

	init(theme: KeyboardTheme) {
		self.theme = theme
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

			caret.leadingAnchor.constraint(equalTo: queryLabel.trailingAnchor, constant: 1),
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
			queryLabel.text = "Search emoji"
			queryLabel.textColor = theme.keyText.withAlphaComponent(0.45)
			clearButton.isHidden = true
		} else {
			queryLabel.text = query
			queryLabel.textColor = theme.keyText
			clearButton.isHidden = false
		}

		resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
		for e in results.prefix(resultCap) {
			let b = UIButton(type: .system)
			b.setTitle(e, for: .normal)
			b.titleLabel?.font = .systemFont(ofSize: 28)
			b.widthAnchor.constraint(equalToConstant: 44).isActive = true
			b.addAction(UIAction { [weak self] _ in self?.onPick?(e) }, for: .touchUpInside)
			resultsStack.addArrangedSubview(b)
		}
		resultsScroll.setContentOffset(.zero, animated: false)

		if results.isEmpty {
			statusLabel.text = showingRecents ? "Type to search emoji" : "No emoji found"
			statusLabel.isHidden = false
		} else {
			statusLabel.isHidden = true
		}
	}
}
