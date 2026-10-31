import UIKit
import Darwin

// MARK: - Emoji page (browse palette)
//
// Gboard-style: a search pill on top, a VERTICALLY scrolling category-sectioned grid
// in the middle, and a bottom bar (ABC / input mode / category tabs / delete). Shown as an
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
	var onGIF: (() -> Void)?
	var onStickers: (() -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private var collection: UICollectionView!
	private let emptyLabel = UILabel()
	private let searchPill = UIButton(type: .system)
	private let mediaControl = UISegmentedControl(items: ["Emoji", "GIFs", "Stickers"])
	private let bottomBar = UIView()
	private var tabButtons: [UIButton] = []
	private var selectedSection = 0
	private let searchRowHeight: CGFloat = 44
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

	/// `store` and `atlas` are injectable for deterministic tests.
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
		buildMediaControl()
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
		mediaControl.frame = CGRect(x: 8, y: 5, width: 170, height: searchRowHeight - 10)
		searchPill.frame = CGRect(x: 184, y: 2, width: max(0, bounds.width - 192), height: searchRowHeight - 4)
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
		searchPill.layer.cornerRadius = (searchRowHeight - 4) / 2
		searchPill.layer.cornerCurve = .continuous
		searchPill.isEnabled = store != nil          // no catalog → nothing to search
		searchPill.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)
	}

	private func buildMediaControl() {
		mediaControl.selectedSegmentIndex = 0
		mediaControl.selectedSegmentTintColor = theme.isDark
			? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.045)
		mediaControl.setTitleTextAttributes([
			.foregroundColor: theme.specialKeyText,
			.font: UIFont.systemFont(ofSize: 12, weight: .semibold),
		], for: .normal)
		mediaControl.addAction(UIAction { [weak self] _ in
			guard let self else { return }
			if self.mediaControl.selectedSegmentIndex == 1 { self.onGIF?() }
			if self.mediaControl.selectedSegmentIndex == 2 { self.onStickers?() }
		}, for: .valueChanged)
		addSubview(mediaControl)
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
		// Land the section HEADER at the top, not the first cell under it.
		if let attr = collection.layoutAttributesForSupplementaryElement(
			ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: i)) {
			let maxY = max(0, collection.contentSize.height - collection.bounds.height)
			collection.setContentOffset(CGPoint(x: 0, y: min(attr.frame.minY, maxY)), animated: false)
		} else {
			collection.scrollToItem(at: IndexPath(item: 0, section: i), at: .top, animated: false)
		}
	}

	private func setSelectedSection(_ i: Int) {
		guard tabButtons.indices.contains(i) else { return }
		selectedSection = i
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

	private func sectionAtTop() -> Int? {
		guard !sections.isEmpty else { return nil }
		collection.layoutIfNeeded()
		let top = collection.contentOffset.y + collection.adjustedContentInset.top + 1
		var result = 0
		for section in sections.indices {
			guard let attributes = collection.layoutAttributesForSupplementaryElement(
				ofKind: UICollectionView.elementKindSectionHeader,
				at: IndexPath(item: 0, section: section)) else { continue }
			if attributes.frame.minY <= top { result = section } else { break }
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
			b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
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
