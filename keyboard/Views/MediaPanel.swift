import UIKit
import UniformTypeIdentifiers

// GIF / Sticker panel (KLIPY-backed) — overlays the key deck at the SAME height
// (the emoji-page pattern; the keyboard never grows). Search reuses the REAL letter
// deck via KeyboardView's media-search mode, exactly like emoji search.
//
// Insert = copy-to-pasteboard + "Paste to send" toast: textDocumentProxy is text-only,
// so the pasteboard IS the mechanism every GIF keyboard uses (Gboard included).
//
// MEMORY LEDGER (the panel's whole budget, against ~60–70 MB jetsam):
//   · items metadata: 24/page × ~300 B ≈ 7 KB/page.
//   · visible cells: ~8 × one ≤256 px decoded frame ≈ 8 × 260 KB ≈ 2 MB dirty, the
//     dominant resident cost; scrolled-away cells free their frame on reuse.
//   · animation: one frame decode in flight at a time per tick; ImageIO sources are
//     file-mapped (clean). No frame is ever cached beyond the one on screen.
//   · send: hd gif streams to disk, one mapped read hands it to the pasteboard
//     (~1–4 MB transient, released immediately after setData).
//   · teardown (ABC / tap-into-field) releases everything — steady-state cost of
//     having browsed GIFs afterwards is ZERO resident, ≤50 MB disk LRU.
final class MediaPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
	var onABC: (() -> Void)?
	var onNextKeyboard: (() -> Void)?
	/// Tap on the search pill: KeyboardView swaps in the letter deck (media-search
	/// mode); on return it reopens the panel with the submitted query.
	var onSearch: ((KlipyKind) -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private let hasFullAccess: Bool
	private(set) var kind: KlipyKind
	private let query: String?
	/// Injectable for tests — skips all networking.
	private let injectedItems: [KlipyMediaItem]?

	private var items: [KlipyMediaItem] = []
	private var page = 1
	private var hasNext = false
	private var loading = false

	private var collection: UICollectionView!
	private let searchPill = UIButton(type: .system)
	private let statusLabel = UILabel()
	private let toast = UILabel()
	private let bottomBar = UIView()
	private var tabButtons: [KlipyKind: UIButton] = [:]
	private var link: CADisplayLink?
	private let searchRowHeight: CGFloat = 42
	private let barHeight: CGFloat = 42
	/// Longer-side pixel cap for cell frames — the panel's memory knob (see ledger).
	static let cellMaxPixel = 256

	init(theme: KeyboardTheme, showsGlobe: Bool, hasFullAccess: Bool,
		 kind: KlipyKind, query: String? = nil, items: [KlipyMediaItem]? = nil) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.hasFullAccess = hasFullAccess
		self.kind = kind
		self.query = query
		self.injectedItems = items
		super.init(frame: .zero)

		collection = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
		collection.backgroundColor = .clear
		collection.dataSource = self
		collection.delegate = self
		collection.register(MediaCell.self, forCellWithReuseIdentifier: "m")
		collection.showsVerticalScrollIndicator = false
		addSubview(collection)

		statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
		statusLabel.textColor = theme.specialKeyText.withAlphaComponent(0.55)
		statusLabel.textAlignment = .center
		statusLabel.numberOfLines = 3
		collection.backgroundView = statusLabel

		buildSearchPill()
		buildBottomBar()
		buildToast()
		addSubview(searchPill)
		addSubview(bottomBar)
		addSubview(toast)

		if let injected = items {
			self.items = injected
			statusLabel.isHidden = !injected.isEmpty
			statusLabel.text = injected.isEmpty ? "No results" : nil
		} else {
			loadFirstPage()
		}
		KBDiagnostics.recorder.sample()      // media panel footprint shows in health telemetry
	}
	required init?(coder: NSCoder) { fatalError() }

	/// 2-column grid of fixed-height tiles — cheap to lay out, no waterfall math.
	private static func makeLayout() -> UICollectionViewLayout {
		let item = NSCollectionLayoutItem(layoutSize: .init(
			widthDimension: .fractionalWidth(0.5), heightDimension: .fractionalHeight(1)))
		item.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
		let row = NSCollectionLayoutGroup.horizontal(layoutSize: .init(
			widthDimension: .fractionalWidth(1), heightDimension: .absolute(92)),
			subitems: [item, item])
		let sec = NSCollectionLayoutSection(group: row)
		sec.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 5, bottom: 6, trailing: 5)
		return UICollectionViewCompositionalLayout(section: sec)
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		searchPill.frame = CGRect(x: 8, y: 5, width: bounds.width - 16, height: searchRowHeight - 10)
		bottomBar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
		collection.frame = CGRect(x: 0, y: searchRowHeight, width: bounds.width,
								  height: max(0, bounds.height - searchRowHeight - barHeight))
		toast.frame = CGRect(x: bounds.midX - 110, y: bounds.midY - 18, width: 220, height: 36)
	}

	// MARK: Animation clock — one display link drives every visible cell

	override func didMoveToWindow() {
		super.didMoveToWindow()
		link?.invalidate(); link = nil
		guard window != nil else { return }
		let l = CADisplayLink(target: self, selector: #selector(tick))
		l.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 10)
		l.add(to: .main, forMode: .common)
		link = l
	}
	@objc private func tick(_ l: CADisplayLink) {
		for cell in collection.visibleCells { (cell as? MediaCell)?.tick(l.timestamp) }
	}

	// MARK: Data

	private func loadFirstPage() {
		guard hasFullAccess else { setStatus("Allow Full Access in Settings\nto browse \(kind.displayName)."); return }
		guard KlipyClient.shared.hasKey else {
			setStatus("Add your KLIPY API key\n(klipy.com/developers) to enable\nGIFs and stickers.")
			return
		}
		items = []
		page = 1
		hasNext = false
		collection.reloadData()
		setStatus("Loading…")
		load(page: 1)
	}

	private func load(page p: Int) {
		guard !loading else { return }
		loading = true
		KlipyClient.shared.fetch(kind, query: query, page: p) { [weak self] new, more in
			guard let self else { return }
			loading = false
			page = p
			hasNext = more
			items += new
			collection.reloadData()
			setStatus(items.isEmpty ? (query == nil ? "Nothing to show" : "No results for “\(query ?? "")”") : nil)
		}
	}

	private func setStatus(_ s: String?) {
		statusLabel.text = s
		statusLabel.isHidden = s == nil
	}

	func numberOfSections(in cv: UICollectionView) -> Int { 1 }
	func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { items.count }
	func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
		let cell = cv.dequeueReusableCell(withReuseIdentifier: "m", for: ip) as! MediaCell
		cell.configure(items[ip.item], theme: theme, live: injectedItems == nil)
		return cell
	}
	func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt ip: IndexPath) {
		if hasNext, ip.item >= items.count - 6 { load(page: page + 1) }
	}
	func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
		send(items[ip.item])
	}

	// MARK: Send — copy the full gif to the pasteboard (the universal insert path)

	private func send(_ item: KlipyMediaItem) {
		guard injectedItems == nil else { return }
		showToast("Loading…", autoHide: false)
		KBMediaCache.fetch(item.sendURL) { [weak self] file in
			guard let self else { return }
			// Mapped read: the file's pages back the Data; setData makes the one
			// unavoidable copy into the pasteboard daemon, then ours is released.
			guard let file, let data = try? Data(contentsOf: file, options: .alwaysMapped) else {
				showToast("Couldn't load — try again")
				return
			}
			UIPasteboard.general.setData(data, forPasteboardType: UTType.gif.identifier)
			showToast("Copied! Paste to send")
		}
	}

	// MARK: Chrome

	private func buildSearchPill() {
		updateSearchPill()
		searchPill.contentHorizontalAlignment = .leading
		searchPill.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 1, alpha: 0.55)
		searchPill.layer.cornerRadius = (searchRowHeight - 10) / 2
		searchPill.layer.cornerCurve = .continuous
		// Added ONCE — updateSearchPill (re-run on tab switch) must not stack actions.
		searchPill.addAction(UIAction { [weak self] _ in
			guard let self else { return }
			onSearch?(kind)
		}, for: .touchUpInside)
	}

	/// Re-applied whenever the kind or query wording changes.
	private func updateSearchPill() {
		var cfg = UIButton.Configuration.plain()
		cfg.image = UIImage(systemName: "magnifyingglass",
							withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
		cfg.imagePadding = 6
		let title = query ?? "Search \(kind.displayName)"
		cfg.attributedTitle = AttributedString(title, attributes: AttributeContainer([
			.font: UIFont.systemFont(ofSize: 15),
			.foregroundColor: theme.keyText.withAlphaComponent(query == nil ? 0.45 : 0.9)
		]))
		cfg.baseForegroundColor = theme.keyText.withAlphaComponent(0.45)
		cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
		searchPill.configuration = cfg
	}

	private func buildBottomBar() {
		bottomBar.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.04)
		var views: [UIView] = [barButton(title: "ABC") { [weak self] in self?.onABC?() }]
		if showsGlobe { views.append(barButton(symbol: "globe") { [weak self] in self?.onNextKeyboard?() }) }
		for k in [KlipyKind.gifs, .stickers] {
			let b = barButton(title: k.displayName) { [weak self] in self?.switchKind(k) }
			tabButtons[k] = b
			views.append(b)
		}
		// Attribution required by KLIPY's usage guidelines.
		let credit = UILabel()
		credit.text = "Powered by KLIPY"
		credit.font = .systemFont(ofSize: 10, weight: .medium)
		credit.textColor = theme.specialKeyText.withAlphaComponent(0.4)
		credit.textAlignment = .right
		views.append(credit)

		let stack = UIStackView(arrangedSubviews: views)
		stack.axis = .horizontal
		stack.spacing = 6
		stack.alignment = .fill
		credit.setContentHuggingPriority(.defaultLow, for: .horizontal)   // credit takes the slack
		for case let b as UIButton in views {
			b.setContentHuggingPriority(.required, for: .horizontal)
			b.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
		}
		stack.translatesAutoresizingMaskIntoConstraints = false
		bottomBar.addSubview(stack)
		// Sub-required trailing: bottomBar is frame-laid, so its width is 0 on the first
		// Auto Layout pass — see ClipboardPanel.
		let trailing = stack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -10)
		trailing.priority = .required - 1
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 6),
			trailing,
			stack.topAnchor.constraint(equalTo: bottomBar.topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor)
		])
		highlightTabs()
	}

	private func switchKind(_ k: KlipyKind) {
		guard k != kind else { return }
		kind = k
		highlightTabs()
		updateSearchPill()                     // pill placeholder tracks the kind
		if injectedItems == nil { loadFirstPage() }
	}

	private func highlightTabs() {
		for (k, b) in tabButtons {
			let active = k == kind
			b.tintColor = active ? theme.keyText : theme.specialKeyText.withAlphaComponent(0.5)
			b.setTitleColor(active ? theme.keyText : theme.specialKeyText.withAlphaComponent(0.6), for: .normal)
			b.backgroundColor = active
				? (theme.isDark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.08))
				: .clear
			b.layer.cornerRadius = 8
			b.layer.cornerCurve = .continuous
		}
	}

	private func buildToast() {
		toast.font = .systemFont(ofSize: 14, weight: .semibold)
		toast.textAlignment = .center
		toast.textColor = theme.isDark ? UIColor(hex: 0x1B1B1D) : .white
		toast.backgroundColor = (theme.isDark ? UIColor(hex: 0xECECF0) : UIColor(hex: 0x1B1B1D)).withAlphaComponent(0.92)
		toast.layer.cornerRadius = 18
		toast.layer.cornerCurve = .continuous
		toast.clipsToBounds = true
		toast.alpha = 0
	}

	private func showToast(_ text: String, autoHide: Bool = true) {
		toast.text = text
		bringSubviewToFront(toast)
		UIView.animate(withDuration: 0.15) { self.toast.alpha = 1 }
		guard autoHide else { return }
		UIView.animate(withDuration: 0.3, delay: 1.4, options: []) { self.toast.alpha = 0 }
	}

	private func barButton(title: String? = nil, symbol: String? = nil,
						   action: @escaping () -> Void) -> UIButton {
		let b = UIButton(type: .system)
		if let title {
			b.setTitle(title, for: .normal)
			b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
		}
		if let symbol {
			b.setImage(UIImage(systemName: symbol,
				withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
		}
		b.tintColor = theme.specialKeyText.withAlphaComponent(0.5)
		b.setTitleColor(theme.specialKeyText, for: .normal)
		b.addAction(UIAction { _ in action() }, for: .touchUpInside)
		return b
	}
}

// MARK: - Cell: one downsampled frame at a time, advanced by the panel's clock

private final class MediaCell: UICollectionViewCell {
	private let imageView = UIImageView()
	private var source: KBAnimatedSource?
	private var frameIndex = 0
	private var nextFrameAt: CFTimeInterval = 0
	private var generation = 0

	override init(frame: CGRect) {
		super.init(frame: frame)
		imageView.contentMode = .scaleAspectFill
		imageView.clipsToBounds = true
		imageView.layer.cornerRadius = 8
		imageView.layer.cornerCurve = .continuous
		imageView.frame = contentView.bounds
		imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		contentView.addSubview(imageView)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func prepareForReuse() {
		super.prepareForReuse()
		generation += 1               // orphan any in-flight fetch
		source = nil                  // the frame + mapped source free with the cell's reuse
		imageView.image = nil
	}

	func configure(_ item: KlipyMediaItem, theme: KeyboardTheme, live: Bool) {
		generation += 1
		let gen = generation
		source = nil
		imageView.image = nil
		imageView.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.06)
		guard live else { return }    // tests: chrome only, no network
		KBMediaCache.fetch(item.previewURL) { [weak self] file in
			guard let self, gen == generation, let file,
				  let src = KBAnimatedSource(fileURL: file) else { return }
			source = src
			frameIndex = 0
			imageView.image = src.frame(at: 0, maxPixel: MediaPanelView.cellMaxPixel)
			nextFrameAt = CACurrentMediaTime() + src.delay(at: 0)
		}
	}

	/// Advance to the next frame when its delay has elapsed. One ≤256 px decode per
	/// call; the previous frame's bitmap is released by the image swap.
	func tick(_ now: CFTimeInterval) {
		guard let src = source, src.frameCount > 1, now >= nextFrameAt else { return }
		frameIndex = (frameIndex + 1) % src.frameCount
		if let img = src.frame(at: frameIndex, maxPixel: MediaPanelView.cellMaxPixel) {
			imageView.image = img
		}
		nextFrameAt = now + src.delay(at: frameIndex)
	}
}
