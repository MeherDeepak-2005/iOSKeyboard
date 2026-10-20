// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import UIKit
import ImageIO
import UniformTypeIdentifiers

final class MediaPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
	var onABC: (() -> Void)?
	var onNextKeyboard: (() -> Void)?
	var onSearch: ((KlipyKind) -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private let hasFullAccess: Bool
	private(set) var kind: KlipyKind
	private let query: String?
	private var items: [KlipyMediaItem] = []
	private var page = 1
	private var hasNext = false
	private var request: URLSessionDataTask?
	private var loadGeneration = 0
	private var collection: UICollectionView!
	private let topBar = UIView()
	private let footer = UIView()
	private let statusLabel = UILabel()
	private let searchButton = UIButton(type: .system)
	private let toast = UILabel()
	private let credit = UILabel()
	private let abcButton = UIButton(type: .system)
	private let globeButton = UIButton(type: .system)
	private var kindButtons: [KlipyKind: UIButton] = [:]
	private var displayLink: CADisplayLink?
	private var released = false
	private let topHeight: CGFloat = 44
	private let footerHeight: CGFloat = 22

	init(theme: KeyboardTheme, showsGlobe: Bool, hasFullAccess: Bool,
		kind: KlipyKind, query: String? = nil) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.hasFullAccess = hasFullAccess
		self.kind = kind
		self.query = query
		super.init(frame: .zero)
		collection = UICollectionView(frame: .zero,
			collectionViewLayout: Self.layout(for: kind))
		collection.backgroundColor = .clear
		collection.dataSource = self
		collection.delegate = self
		collection.showsVerticalScrollIndicator = false
		collection.register(MediaCell.self, forCellWithReuseIdentifier: "media")
		statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
		statusLabel.textColor = theme.specialKeyText.withAlphaComponent(0.62)
		statusLabel.textAlignment = .center
		statusLabel.numberOfLines = 3
		collection.backgroundView = statusLabel
		addSubview(collection)
		buildChrome()
		loadFirstPage()
		KBDiagnostics.recorder.sample()
	}

	required init?(coder: NSCoder) { fatalError() }
	deinit {
		request?.cancel()
		displayLink?.invalidate()
	}

	/// Called before the panel leaves the hierarchy. This deterministically drops
	/// decoded frames, mapped ImageIO sources, network work, and metadata rather than
	/// waiting for a memory warning or collection-view deallocation.
	func prepareForDismissal() {
		guard !released else { return }
		released = true
		loadGeneration &+= 1
		request?.cancel()
		request = nil
		displayLink?.invalidate()
		displayLink = nil
		for case let cell as MediaCell in collection.visibleCells { cell.releaseMedia() }
		items.removeAll(keepingCapacity: false)
		collection.dataSource = nil
		collection.delegate = nil
	}

	private static func layout(for kind: KlipyKind) -> UICollectionViewLayout {
		let columns = kind == .stickers ? 3 : 2
		let item = NSCollectionLayoutItem(layoutSize: .init(
			widthDimension: .fractionalWidth(1 / CGFloat(columns)),
			heightDimension: .fractionalHeight(1)))
		item.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
		let row = NSCollectionLayoutGroup.horizontal(layoutSize: .init(
			widthDimension: .fractionalWidth(1),
			heightDimension: .absolute(kind == .stickers ? 94 : 112)),
			repeatingSubitem: item, count: columns)
		let section = NSCollectionLayoutSection(group: row)
		section.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 5, bottom: 6, trailing: 5)
		return UICollectionViewCompositionalLayout(section: section)
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		topBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topHeight)
		footer.frame = CGRect(x: 0, y: bounds.height - footerHeight,
			width: bounds.width, height: footerHeight)
		collection.frame = CGRect(x: 0, y: topHeight, width: bounds.width,
			height: max(0, bounds.height - topHeight - footerHeight))
		let y: CGFloat = 5, height = topHeight - 10
		abcButton.frame = CGRect(x: 6, y: y, width: 42, height: height)
		kindButtons[.gifs]?.frame = CGRect(x: 52, y: y, width: 46, height: height)
		kindButtons[.stickers]?.frame = CGRect(x: 102, y: y, width: 62, height: height)
		searchButton.frame = CGRect(x: 169, y: y, width: max(0, bounds.width - 175), height: height)
		globeButton.frame = showsGlobe ? CGRect(x: 6, y: 0, width: 34, height: footerHeight) : .zero
		credit.frame = CGRect(x: showsGlobe ? 44 : 6, y: 0,
			width: bounds.width - (showsGlobe ? 50 : 12), height: footerHeight)
		toast.frame = CGRect(x: bounds.midX - 108, y: bounds.midY - 18, width: 216, height: 36)
	}

	override func didMoveToWindow() {
		super.didMoveToWindow()
		displayLink?.invalidate()
		guard window != nil, !released else { displayLink = nil; return }
		let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
		link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 10)
		link.add(to: .main, forMode: .common)
		displayLink = link
	}

	@objc private func tick(_ link: CADisplayLink) {
		guard !UIAccessibility.isReduceMotionEnabled else { return }
		for cell in collection.visibleCells { (cell as? MediaCell)?.tick(link.timestamp) }
	}

	private func loadFirstPage() {
		guard !released else { return }
		request?.cancel()
		request = nil
		loadGeneration &+= 1
		items.removeAll(keepingCapacity: true)
		collection.reloadData()
		// No query loads the trending feed (browse on open); a query searches. Both
		// still require Full Access and a configured, content-filter-approved key.
		guard hasFullAccess else {
			setStatus("Full Access is required only for GIFs and stickers.")
			return
		}
		guard KlipyClient.shared.hasKey else {
			setStatus("GIFs and stickers are unavailable in this build.")
			return
		}
		page = 1
		hasNext = false
		setStatus("Loading…")
		load(page: 1)
	}

	private func load(page: Int) {
		guard !released, request == nil else { return }
		let generation = loadGeneration
		request = KlipyClient.shared.fetch(kind, query: query, page: page) { [weak self] new, more in
			guard let self, !self.released, generation == self.loadGeneration else { return }
			self.request = nil
			self.page = page
			self.hasNext = more
			self.items.append(contentsOf: new.filter { candidate in
				!self.items.contains(where: { $0.id == candidate.id })
			})
			self.collection.reloadData()
			self.setStatus(self.items.isEmpty ? "No results" : nil)
		}
	}

	private func setStatus(_ value: String?) {
		statusLabel.text = value
		statusLabel.isHidden = value == nil
	}

	func collectionView(_ collectionView: UICollectionView,
		numberOfItemsInSection section: Int) -> Int { items.count }

	func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
		-> UICollectionViewCell {
		let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "media",
			for: indexPath) as! MediaCell
		cell.configure(items[indexPath.item], theme: theme)
		return cell
	}

	func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
		forItemAt indexPath: IndexPath) {
		if hasNext, request == nil, indexPath.item >= items.count - 5 { load(page: page + 1) }
	}

	func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		copy(items[indexPath.item])
	}

	private func copy(_ item: KlipyMediaItem) {
		showToast("Loading…", persistent: true)
		KBMediaCache.fetch(item.sendURL) { [weak self] file in
			guard let self, let file,
				let data = try? Data(contentsOf: file, options: .alwaysMapped),
				data.count <= KBMediaCache.individualFileCap,
				let source = CGImageSourceCreateWithData(data as CFData, nil),
				CGImageSourceGetType(source) as String? == UTType.gif.identifier else {
				self?.showToast("Couldn’t copy")
				return
			}
			UIPasteboard.general.setData(data, forPasteboardType: UTType.gif.identifier)
			self.showToast("Copied · Paste to send")
		}
	}

	private func buildChrome() {
		topBar.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.035)
			: UIColor(white: 0, alpha: 0.025)
		footer.backgroundColor = .clear
		abcButton.setTitle("ABC", for: .normal)
		abcButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
		abcButton.setTitleColor(theme.specialKeyText, for: .normal)
		abcButton.addAction(UIAction { [weak self] _ in self?.onABC?() }, for: .touchUpInside)
		topBar.addSubview(abcButton)
		for option in KlipyKind.allCases {
			let button = UIButton(type: .system)
			button.setTitle(option.displayName, for: .normal)
			button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
			button.addAction(UIAction { [weak self] _ in self?.select(option) }, for: .touchUpInside)
			kindButtons[option] = button
			topBar.addSubview(button)
		}
		updateKinds()
		var configuration = UIButton.Configuration.plain()
		configuration.image = UIImage(systemName: "magnifyingglass")
		configuration.imagePadding = 5
		configuration.title = query ?? "Search KLIPY"
		configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 8)
		searchButton.configuration = configuration
		searchButton.contentHorizontalAlignment = .leading
		searchButton.tintColor = theme.keyText.withAlphaComponent(0.55)
		searchButton.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.10)
			: UIColor(white: 1, alpha: 0.58)
		searchButton.layer.cornerRadius = 10
		searchButton.addAction(UIAction { [weak self] _ in
			guard let self else { return }; self.onSearch?(self.kind)
		}, for: .touchUpInside)
		topBar.addSubview(searchButton)
		credit.text = "Powered by KLIPY"
		credit.font = .systemFont(ofSize: 9, weight: .medium)
		credit.textColor = theme.specialKeyText.withAlphaComponent(0.45)
		credit.textAlignment = .right
		footer.addSubview(credit)
		if showsGlobe {
			globeButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
			globeButton.tintColor = theme.specialKeyText.withAlphaComponent(0.62)
			globeButton.addAction(UIAction { [weak self] _ in self?.onNextKeyboard?() }, for: .touchUpInside)
			footer.addSubview(globeButton)
		}
		toast.font = .systemFont(ofSize: 14, weight: .semibold)
		toast.textAlignment = .center
		toast.textColor = theme.isDark ? UIColor(hex: 0x1B1B1D) : .white
		toast.backgroundColor = (theme.isDark ? UIColor(hex: 0xECECF0)
			: UIColor(hex: 0x1B1B1D)).withAlphaComponent(0.94)
		toast.layer.cornerRadius = 18
		toast.clipsToBounds = true
		toast.alpha = 0
		addSubview(topBar); addSubview(footer); addSubview(toast)
	}

	private func select(_ next: KlipyKind) {
		guard next != kind else { return }
		kind = next
		updateKinds()
		collection.setCollectionViewLayout(Self.layout(for: next), animated: false)
		loadFirstPage()
	}

	private func updateKinds() {
		for (option, button) in kindButtons {
			let selected = option == kind
			button.setTitleColor(selected ? theme.keyText : theme.specialKeyText.withAlphaComponent(0.58),
				for: .normal)
			button.backgroundColor = selected
				? (theme.isDark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.08))
				: .clear
			button.layer.cornerRadius = 8
		}
	}

	private func showToast(_ text: String, persistent: Bool = false) {
		toast.layer.removeAllAnimations()
		toast.text = text
		bringSubviewToFront(toast)
		UIView.animate(withDuration: 0.15) { self.toast.alpha = 1 }
		guard !persistent else { return }
		UIView.animate(withDuration: 0.25, delay: 1.35) { self.toast.alpha = 0 }
	}
}

private final class MediaDecodeToken {
	private let lock = NSLock()
	private var cancelled = false
	func cancel() { lock.lock(); cancelled = true; lock.unlock() }
	var isCancelled: Bool {
		lock.lock(); defer { lock.unlock() }
		return cancelled
	}
}

private final class MediaCell: UICollectionViewCell {
	private static let decodeQueue: OperationQueue = {
		let queue = OperationQueue()
		queue.name = "keyboard.media.decode"
		queue.qualityOfService = .userInitiated
		queue.maxConcurrentOperationCount = 2
		return queue
	}()
	private let imageView = UIImageView()
	private var download: URLSessionDownloadTask?
	private var source: KBAnimatedSource?
	private var frameIndex = 0
	private var nextFrameAt: CFTimeInterval = 0
	private var generation = 0
	private var decoding = false
	private var decodeToken: MediaDecodeToken?

	override init(frame: CGRect) {
		super.init(frame: frame)
		imageView.contentMode = .scaleAspectFill
		imageView.clipsToBounds = true
		imageView.layer.cornerRadius = 8
		imageView.frame = contentView.bounds
		imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		contentView.addSubview(imageView)
	}
	required init?(coder: NSCoder) { fatalError() }
	deinit { download?.cancel(); decodeToken?.cancel() }

	override func prepareForReuse() {
		super.prepareForReuse()
		releaseMedia()
	}

	func releaseMedia() {
		generation &+= 1
		decodeToken?.cancel(); decodeToken = nil
		download?.cancel(); download = nil
		source = nil; imageView.image = nil; decoding = false
	}

	func configure(_ item: KlipyMediaItem, theme: KeyboardTheme) {
		releaseMedia()
		let current = generation
		let token = MediaDecodeToken()
		decodeToken = token
		imageView.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.07)
			: UIColor(white: 0, alpha: 0.06)
		download = KBMediaCache.fetch(item.previewURL) { [weak self] file in
			guard let self, !token.isCancelled, current == self.generation, let file else { return }
			self.decoding = true
			Self.decodeQueue.addOperation { [weak self] in
				guard !token.isCancelled else { return }
				guard let source = KBAnimatedSource(fileURL: file) else {
					OperationQueue.main.addOperation {
						guard let self, !token.isCancelled, current == self.generation else { return }
						self.decoding = false
					}
					return
				}
				guard !token.isCancelled else { return }
				let image = source.frame(at: 0, maxPixel: 256)
				let delay = source.delay(at: 0)
				OperationQueue.main.addOperation {
					guard let self, !token.isCancelled, current == self.generation else { return }
					self.source = source; self.imageView.image = image
					self.frameIndex = 0; self.nextFrameAt = CACurrentMediaTime() + delay
					self.decoding = false
				}
			}
		}
	}

	func tick(_ now: CFTimeInterval) {
		guard !decoding, let source, let token = decodeToken, !token.isCancelled,
			source.frameCount > 1, now >= nextFrameAt else { return }
		let next = (frameIndex + 1) % source.frameCount
		let current = generation
		decoding = true
		Self.decodeQueue.addOperation { [weak self] in
			guard !token.isCancelled else { return }
			let image = source.frame(at: next, maxPixel: 256)
			let delay = source.delay(at: next)
			OperationQueue.main.addOperation {
				guard let self, !token.isCancelled, current == self.generation else { return }
				if let image { self.imageView.image = image }
				self.frameIndex = next; self.nextFrameAt = CACurrentMediaTime() + delay
				self.decoding = false
			}
		}
	}
}
