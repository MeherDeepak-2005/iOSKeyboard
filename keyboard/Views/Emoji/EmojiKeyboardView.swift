import UIKit
import Darwin

// MARK: - Emoji page (browse palette)
//
// A search pill on top, a HORIZONTALLY scrolling category-sectioned grid in the
// middle (columns that fill the height, as the stock emoji keyboard), and a bottom bar
// (ABC / input mode / category tabs / delete). Shown as an overlay by KeyboardView. The grid is a compositional layout whose columns hold an
// exact row count, so every column but a category's last is full.
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
	var onGIF: (() -> Void)?
	var onStickers: (() -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private var collection: UICollectionView!
	private let emptyLabel = UILabel()
	/// The name of the category at the grid's left edge, as the stock emoji keyboard shows it.
	private let categoryLabel = UILabel()
	private let header: PanelHeaderView
	private let bottomBar = UIView()
	private var tabButtons: [UIButton] = []
	private var selectedSection = 0
	private var searchRowHeight: CGFloat { header.height }
	private let barHeight: CGFloat = 44

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
	private lazy var atlas: EmojiAtlas? = explicitAtlas
		?? EmojiAtlas.loadShared(store: store, scale: traitCollection.displayScale)

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

	/// `store` and `atlas` are injectable for deterministic tests. `previous` is the
	/// panel tab the user came from, so the switch thumb slides from it.
	init(theme: KeyboardTheme, showsGlobe: Bool,
		 store: EmojiStore? = EmojiStore.bundled, atlas: EmojiAtlas? = nil,
		 from previous: PanelTab? = nil) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.store = store
		self.explicitAtlas = atlas
		self.header = PanelHeaderView(theme: theme, selected: .emoji, from: previous,
			searchEnabled: store != nil)            // no catalog → nothing to search
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
		collection.showsVerticalScrollIndicator = false
		collection.showsHorizontalScrollIndicator = false
		collection.alwaysBounceVertical = false
		collection.contentInsetAdjustmentBehavior = .never
		emptyLabel.font = KeyboardTypography.emptyState
		emptyLabel.textColor = theme.specialKeyText.withAlphaComponent(0.55)
		emptyLabel.textAlignment = .center
		emptyLabel.numberOfLines = 2
		emptyLabel.text = sections.isEmpty ? "Emoji data unavailable" : nil
		emptyLabel.isHidden = !sections.isEmpty
		collection.backgroundView = emptyLabel
		addSubview(collection)
		categoryLabel.font = KeyboardTypography.sectionHeader
		categoryLabel.textColor = theme.specialKeyText.withAlphaComponent(0.55)
		categoryLabel.accessibilityTraits = .header
		addSubview(categoryLabel)

		header.onSearch = { [weak self] in self?.onSearch?() }
		header.onSelect = { [weak self] tab in
			if tab == .gifs { self?.onGIF?() }
			if tab == .stickers { self?.onStickers?() }
		}
		buildBottomBar()
		addSubview(header)
		addSubview(bottomBar)
	}
	required init?(coder: NSCoder) { fatalError() }

	/// The space between neighbouring emoji, as a fraction of what a full-width six-column
	/// grid would leave.
	private static let gapScale: CGFloat = 0.85
	/// The strip above the grid that names the current category.
	private static let categoryLabelHeight: CGFloat = 22
	/// Space between the last column of one category and the first of the next.
	private static let sectionSpacing: CGFloat = 12

	/// Horizontal grid, as the stock emoji keyboard: each category is a run of columns that
	/// fills the grid's height, the categories follow each other left to right, and the
	/// grid never scrolls vertically. Cells are square, sized from the screen width so
	/// neighbouring emoji sit `gapScale` as far apart as a full-width six-column grid would
	/// put them, then adjusted so a whole number of rows fills the height. The first column
	/// starts at the left edge. The current category is named once, above the grid.
	private func makeLayout() -> UICollectionViewLayout {
		let config = UICollectionViewCompositionalLayoutConfiguration()
		config.scrollDirection = .horizontal
		config.interSectionSpacing = Self.sectionSpacing
		return UICollectionViewCompositionalLayout(sectionProvider: { _, env in
			let size = env.container.effectiveContentSize
			let width = max(1, size.width - 12)
			let cols = max(6, Int(width / EmojiAtlas.cellPitch))
			let glyph = EmojiAtlas.glyphFontSize
			let ideal = min(width / CGFloat(cols), glyph + (width / CGFloat(cols) - glyph) * Self.gapScale)
			let available = max(glyph, size.height)
			let rows = max(1, Int((available / ideal).rounded()))
			let side = available / CGFloat(rows)
			let item = NSCollectionLayoutItem(layoutSize: .init(
				widthDimension: .fractionalWidth(1), heightDimension: .absolute(side)))
			let column = NSCollectionLayoutGroup.vertical(layoutSize: .init(
				widthDimension: .absolute(side), heightDimension: .absolute(available)),
				repeatingSubitem: item, count: rows)
			return NSCollectionLayoutSection(group: column)
		}, configuration: config)
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: searchRowHeight)
		bottomBar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
		let labelHeight = Self.categoryLabelHeight
		categoryLabel.frame = CGRect(x: 12, y: searchRowHeight, width: bounds.width - 24, height: labelHeight)
		collection.frame = CGRect(x: 0, y: searchRowHeight + labelHeight, width: bounds.width,
								  height: max(0, bounds.height - searchRowHeight - labelHeight - barHeight))
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
	func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
		commit(emoji(at: ip))
	}

	func collectionView(_ collectionView: UICollectionView,
						contextMenuConfigurationForItemAt indexPath: IndexPath,
						point: CGPoint) -> UIContextMenuConfiguration? {
		let variants = KBEmojiVariants.skinToneVariants(of: emoji(at: indexPath))
		guard !variants.isEmpty else { return nil }
		return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
			UIMenu(title: "Skin Tone", children: variants.map { variant in
				UIAction(title: variant) { [weak self] _ in self?.commit(variant) }
			})
		}
	}

	private func commit(_ emoji: String) {
		KBDiagnostics.notePanelEvent(.pick)
		onPick?(emoji)
		KBEmojiRecents.add(emoji)
	}

	/// A tap owns selection immediately. Scrolling may change it only while the user is
	/// genuinely dragging/decelerating, never as a side effect of a programmatic jump.
	func scrollViewDidScroll(_ scrollView: UIScrollView) {
		guard scrollView.isDragging || scrollView.isDecelerating,
			  let section = sectionAtTop(), section != selectedSection else { return }
		setSelectedSection(section)
	}

	func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
		if !decelerate, let section = sectionAtTop() { setSelectedSection(section) }
	}

	func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
		if let section = sectionAtTop() { setSelectedSection(section) }
	}

	// MARK: Bottom bar — ABC | (input mode) | category tabs | delete

	private func buildBottomBar() {
		bottomBar.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.04)
		var leading: [UIButton] = [barButton(title: "ABC") { [weak self] in self?.onABC?() }]
		if showsGlobe { leading.append(barButton(symbol: "keyboard") { [weak self] in self?.onNextKeyboard?() }) }

		let nav = UIStackView()
		nav.axis = .horizontal
		nav.distribution = .fillEqually
		for i in sections.indices {
			let b = barButton(symbol: icon(of: i), pointSize: 15) { [weak self] in
				self?.scrollTo(section: i)
			}
			tabButtons.append(b)
			b.accessibilityLabel = name(of: i)
			b.accessibilityIdentifier = "emoji.category.\(i)"
			nav.addArrangedSubview(b)
		}
		setSelectedSection(0)
		let del = barButton(symbol: "delete.left") { [weak self] in self?.onDelete?() }

		let stack = UIStackView(arrangedSubviews: leading + [nav, del])
		stack.axis = .horizontal
		stack.spacing = 2
		stack.alignment = .fill
		nav.setContentHuggingPriority(.defaultLow, for: .horizontal)      // tabs take the slack
		for b in leading + [del] {
			b.setContentHuggingPriority(.required, for: .horizontal)
			b.widthAnchor.constraint(equalToConstant: 44).isActive = true
		}
		stack.translatesAutoresizingMaskIntoConstraints = false
		bottomBar.addSubview(stack)
		// Sub-required trailing: bottomBar is frame-laid, so its width is 0 on the first
		// Auto Layout pass and required children cannot fit at the initial zero width.
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
		setSelectedSection(i)
		collection.layoutIfNeeded()
		// Land the section's first column at the left edge.
		guard let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: i)) else { return }
		let maxX = max(0, collection.contentSize.width - collection.bounds.width)
		collection.setContentOffset(CGPoint(x: min(first.frame.minX, maxX), y: 0), animated: false)
	}

	private func setSelectedSection(_ i: Int) {
		guard tabButtons.indices.contains(i) else { return }
		selectedSection = i
		categoryLabel.text = name(of: i).uppercased()
		for (index, button) in tabButtons.enumerated() {
			let selected = index == i
			button.isSelected = selected
			button.tintColor = selected ? theme.keyText
				: theme.specialKeyText.withAlphaComponent(0.5)
			button.backgroundColor = selected
				? (theme.isDark ? UIColor(white: 1, alpha: 0.075)
					: UIColor(white: 0, alpha: 0.05))
				: .clear
			button.accessibilityTraits = selected ? [.button, .selected] : .button
			button.layer.cornerRadius = 8
			button.layer.cornerCurve = .continuous
		}
		// Once per category crossed, not per scroll tick: cheap footprint samples so
		// browsing the grid (glyph raster cache growth) is visible in health telemetry.
		KBDiagnostics.recorder.sample()
	}

	/// The category whose columns are at the left edge. At the end of the grid, the last
	/// category, even when it is too short to reach the left edge.
	private func sectionAtTop() -> Int? {
		guard !sections.isEmpty else { return nil }
		collection.layoutIfNeeded()
		let left = collection.contentOffset.x + 1
		if left + collection.bounds.width >= collection.contentSize.width { return sections.count - 1 }
		var result = 0
		for section in sections.indices where emojiCount(in: section) > 0 {
			guard let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: section))
			else { continue }
			if first.frame.minX <= left { result = section } else { break }
		}
		return result
	}

	private func barButton(title: String? = nil, symbol: String? = nil,
						   pointSize: CGFloat = 16, action: @escaping () -> Void) -> UIButton {
		// A custom button keeps iOS 26's automatic glass selection treatment from
		// replacing the deliberately subtle category background.
		let b = UIButton(type: .custom)
		if let title {
			b.setTitle(title, for: .normal)
			b.titleLabel?.font = KeyboardTypography.panelButton
		}
		if let symbol {
			b.setImage(UIImage(systemName: symbol,
				withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))?
				.withRenderingMode(.alwaysTemplate), for: .normal)
		}
		if title == "ABC" { b.accessibilityLabel = "Letters" }
		if symbol == "keyboard" { b.accessibilityLabel = "Next Keyboard" }
		if symbol == "delete.left" { b.accessibilityLabel = "Delete" }
		b.tintColor = theme.specialKeyText.withAlphaComponent(0.5)
		b.setTitleColor(theme.specialKeyText, for: .normal)
		b.addAction(UIAction { _ in action() }, for: .touchUpInside)
		return b
	}
}
