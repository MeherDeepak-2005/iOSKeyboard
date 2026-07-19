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
	private let topBar = UIView()
	private let bottomBar = UIView()
	private let abcButton = UIButton(type: .system)
	private let creditLabel = UILabel()
	private let globeButton = UIButton(type: .system)
	private var tabButtons: [KlipyKind: UIButton] = [:]
	private var link: CADisplayLink?
	private let topBarHeight: CGFloat = 42
	private let footerHeight: CGFloat = 20
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

		collection = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout(kind: kind))
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

		buildTopBar()
		buildBottomBar()
		buildToast()
		addSubview(topBar)
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

	/// GIFs favor larger two-column previews; transparent stickers fit a denser
	/// three-column grid. Both use fixed rows so scrolling stays cheap and stable.
	private static func makeLayout(kind: KlipyKind) -> UICollectionViewLayout {
		let columns = kind == .stickers ? 3 : 2
		let item = NSCollectionLayoutItem(layoutSize: .init(
			widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
			heightDimension: .fractionalHeight(1)))
		item.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
		let row = NSCollectionLayoutGroup.horizontal(layoutSize: .init(
			widthDimension: .fractionalWidth(1),
			heightDimension: .absolute(kind == .stickers ? 96 : 112)),
			repeatingSubitem: item,
			count: columns)
		let sec = NSCollectionLayoutSection(group: row)
		sec.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 5, bottom: 6, trailing: 5)
		return UICollectionViewCompositionalLayout(section: sec)
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		topBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topBarHeight)
		layoutTopBar()
		bottomBar.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
		layoutFooter()
		collection.frame = CGRect(x: 0, y: topBarHeight, width: bounds.width,
								  height: max(0, bounds.height - topBarHeight - footerHeight))
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

	private func buildTopBar() {
		topBar.backgroundColor = theme.isDark
			? UIColor(white: 1, alpha: 0.035)
			: UIColor(white: 0, alpha: 0.025)
		abcButton.setTitle("ABC", for: .normal)
		abcButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
		abcButton.setTitleColor(theme.specialKeyText, for: .normal)
		abcButton.addAction(UIAction { [weak self] _ in self?.onABC?() }, for: .touchUpInside)
		topBar.addSubview(abcButton)

		for k in [KlipyKind.gifs, .stickers] {
			let button = barButton(title: k.displayName) { [weak self] in self?.switchKind(k) }
			tabButtons[k] = button
			topBar.addSubview(button)
		}

		updateSearchPill()
		searchPill.contentHorizontalAlignment = .leading
		searchPill.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 1, alpha: 0.55)
		searchPill.layer.cornerRadius = 10
		searchPill.layer.cornerCurve = .continuous
		// Added ONCE — updateSearchPill (re-run on tab switch) must not stack actions.
		searchPill.addAction(UIAction { [weak self] _ in
			guard let self else { return }
			onSearch?(kind)
		}, for: .touchUpInside)
		topBar.addSubview(searchPill)
		highlightTabs()
	}

	private func layoutTopBar() {
		let y: CGFloat = 5
		let h = max(0, topBar.bounds.height - 10)
		let gap: CGFloat = 4
		var x: CGFloat = 6
		abcButton.frame = CGRect(x: x, y: y, width: 42, height: h)
		x = abcButton.frame.maxX + gap
		if let gifs = tabButtons[.gifs] {
			gifs.frame = CGRect(x: x, y: y, width: 48, height: h)
			x = gifs.frame.maxX + gap
		}
		if let stickers = tabButtons[.stickers] {
			stickers.frame = CGRect(x: x, y: y, width: 66, height: h)
			x = stickers.frame.maxX + gap
		}
		searchPill.frame = CGRect(x: x, y: y, width: max(0, topBar.bounds.width - x - 6), height: h)
	}

	/// Re-applied whenever the kind or query wording changes.
	private func updateSearchPill() {
		var cfg = UIButton.Configuration.plain()
		cfg.image = UIImage(systemName: "magnifyingglass",
							withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
		cfg.imagePadding = 6
		let title = query ?? "Search"
		cfg.attributedTitle = AttributedString(title, attributes: AttributeContainer([
			.font: UIFont.systemFont(ofSize: 15),
			.foregroundColor: theme.keyText.withAlphaComponent(query == nil ? 0.45 : 0.9)
		]))
		cfg.baseForegroundColor = theme.keyText.withAlphaComponent(0.45)
		cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 8)
		searchPill.configuration = cfg
	}

	private func buildBottomBar() {
		bottomBar.backgroundColor = .clear
		creditLabel.text = "Powered by KLIPY"
		creditLabel.font = .systemFont(ofSize: 9, weight: .medium)
		creditLabel.textColor = theme.specialKeyText.withAlphaComponent(0.38)
		creditLabel.textAlignment = .right
		bottomBar.addSubview(creditLabel)
		guard showsGlobe else { return }
		globeButton.setImage(UIImage(systemName: "globe",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)), for: .normal)
		globeButton.tintColor = theme.specialKeyText.withAlphaComponent(0.55)
		globeButton.addAction(UIAction { [weak self] _ in self?.onNextKeyboard?() }, for: .touchUpInside)
		bottomBar.addSubview(globeButton)
	}

	private func layoutFooter() {
		globeButton.frame = showsGlobe
			? CGRect(x: 6, y: 0, width: 32, height: bottomBar.bounds.height)
			: .zero
		creditLabel.frame = CGRect(
			x: showsGlobe ? 42 : 6,
			y: 0,
			width: max(0, bottomBar.bounds.width - (showsGlobe ? 48 : 12)),
			height: bottomBar.bounds.height
		)
	}

	private func switchKind(_ k: KlipyKind) {
		guard k != kind else { return }
		kind = k
		highlightTabs()
		updateSearchPill()                     // pill placeholder tracks the kind
		collection.setCollectionViewLayout(Self.makeLayout(kind: k), animated: false)
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
	private static let decodeQueue: OperationQueue = {
		let queue = OperationQueue()
		queue.name = "keyboard.media.preview-decode"
		queue.qualityOfService = .userInitiated
		queue.maxConcurrentOperationCount = 2
		return queue
	}()

	private let imageView = UIImageView()
	private var source: KBAnimatedSource?
	private var frameIndex = 0
	private var nextFrameAt: CFTimeInterval = 0
	private var generation = 0
	private var decoding = false

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
		decoding = false
		imageView.image = nil
	}

	func configure(_ item: KlipyMediaItem, theme: KeyboardTheme, live: Bool) {
		generation += 1
		let gen = generation
		source = nil
		decoding = false
		imageView.image = nil
		imageView.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.07) : UIColor(white: 0, alpha: 0.06)
		guard live else { return }    // tests: chrome only, no network
		KBMediaCache.fetch(item.previewURL) { [weak self] file in
			guard let self, gen == generation, let file else { return }
			decoding = true
			Self.decodeQueue.addOperation { [weak self] in
				guard let src = KBAnimatedSource(fileURL: file) else {
					OperationQueue.main.addOperation {
						guard let self, gen == self.generation else { return }
						self.decoding = false
					}
					return
				}
				let frame = src.frame(at: 0, maxPixel: MediaPanelView.cellMaxPixel)
				let delay = src.delay(at: 0)
				OperationQueue.main.addOperation {
					guard let self, gen == self.generation else { return }
					self.source = src
					self.frameIndex = 0
					self.imageView.image = frame
					self.nextFrameAt = CACurrentMediaTime() + delay
					self.decoding = false
				}
			}
		}
	}

	/// Advance to the next frame when its delay has elapsed. One ≤256 px decode per
	/// call; the previous frame's bitmap is released by the image swap.
	func tick(_ now: CFTimeInterval) {
		guard !decoding, let src = source, src.frameCount > 1, now >= nextFrameAt else { return }
		let next = (frameIndex + 1) % src.frameCount
		let gen = generation
		decoding = true
		Self.decodeQueue.addOperation { [weak self] in
			let image = src.frame(at: next, maxPixel: MediaPanelView.cellMaxPixel)
			let delay = src.delay(at: next)
			OperationQueue.main.addOperation {
				guard let self, gen == self.generation else { return }
				if let image { self.imageView.image = image }
				self.frameIndex = next
				self.nextFrameAt = CACurrentMediaTime() + delay
				self.decoding = false
			}
		}
	}
}
