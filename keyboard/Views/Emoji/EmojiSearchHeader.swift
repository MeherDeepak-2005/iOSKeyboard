import UIKit
import Darwin

// MARK: - EmojiSearchHeader (Gboard-style: search rides the REAL keyboard)
//
// Shown by KeyboardView above the normal letter deck while emoji search is active:
// a back button, the live query in a pill (with blinking caret + inline clear), and
// a horizontal strip of results. Typing goes through the real keys — KeyboardView
// routes inserts/deletes into the query instead of the host document — so there is
// no cramped mini keyboard, and every typing nicety (popups, multitouch) just works.
final class EmojiSearchHeader: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
	static let height: CGFloat = 92     // 44 search row + 48 results row

	var onCancel: (() -> Void)?
	var onClear: (() -> Void)?
	var onPick: ((String) -> Void)?

	var placeholder = "Search emoji"
	var emptyStatus = "Type to search emoji"
	var noResultsStatus = "No emoji found"

	private let theme: KeyboardTheme
	private let store: EmojiStore?
	private let explicitAtlas: EmojiAtlas?
	private lazy var atlas: EmojiAtlas? = explicitAtlas
		?? EmojiAtlas.loadShared(store: store, scale: traitCollection.displayScale)
	private let pill = UIView()
	private let queryLabel = UILabel()
	private let caret = UIView()
	// The caret rides the text: at the pill's start while the placeholder shows
	// (nothing typed yet), after the query once there is one. Toggled in update().
	private var caretAtStart: NSLayoutConstraint!
	private var caretAfterText: NSLayoutConstraint!
	private let clearButton = UIButton(type: .system)
	private let resultsCollection: UICollectionView
	private var results: [String] = []
	private let statusLabel = UILabel()
	private let resultCap = 60          // plenty to swipe through; keeps the strip cheap

	init(theme: KeyboardTheme, store: EmojiStore? = EmojiStore.bundled,
		 atlas: EmojiAtlas? = nil) {
		self.theme = theme
		self.store = store
		self.explicitAtlas = atlas
		let layout = UICollectionViewFlowLayout()
		layout.scrollDirection = .horizontal
		layout.itemSize = CGSize(width: 44, height: 48)
		layout.minimumLineSpacing = 0
		layout.minimumInteritemSpacing = 0
		self.resultsCollection = UICollectionView(frame: .zero, collectionViewLayout: layout)
		super.init(frame: .zero)

		// Row 1: back chevron + query pill.
		let back = UIButton(type: .system)
		back.setImage(UIImage(systemName: "arrow.left",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
		back.tintColor = theme.specialKeyText
		back.accessibilityLabel = "Back"
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
		clearButton.accessibilityLabel = "Clear search"
		clearButton.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
		clearButton.translatesAutoresizingMaskIntoConstraints = false
		pill.addSubview(clearButton)

		// Row 2: horizontal results strip (or a status line when there's nothing to show).
		resultsCollection.backgroundColor = .clear
		resultsCollection.showsHorizontalScrollIndicator = false
		resultsCollection.dataSource = self
		resultsCollection.delegate = self
		resultsCollection.register(EmojiSearchResultCell.self,
			forCellWithReuseIdentifier: "emoji-search-result")
		resultsCollection.translatesAutoresizingMaskIntoConstraints = false
		addSubview(resultsCollection)

		statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
		statusLabel.textColor = theme.specialKeyText.withAlphaComponent(0.5)
		statusLabel.translatesAutoresizingMaskIntoConstraints = false
		addSubview(statusLabel)

		NSLayoutConstraint.activate([
			back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
			back.centerYAnchor.constraint(equalTo: topAnchor, constant: 22),
			back.widthAnchor.constraint(equalToConstant: 44),
			back.heightAnchor.constraint(equalToConstant: 44),

			pill.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
			pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
			pill.centerYAnchor.constraint(equalTo: topAnchor, constant: 22),
			pill.heightAnchor.constraint(equalToConstant: 36),

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
			clearButton.widthAnchor.constraint(equalToConstant: 36),
			clearButton.heightAnchor.constraint(equalToConstant: 36),

			resultsCollection.topAnchor.constraint(equalTo: topAnchor, constant: 44),
			resultsCollection.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
			resultsCollection.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
			resultsCollection.heightAnchor.constraint(equalToConstant: 48),

			statusLabel.centerYAnchor.constraint(equalTo: resultsCollection.centerYAnchor),
			statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
		])
		caretAtStart = caret.trailingAnchor.constraint(equalTo: queryLabel.leadingAnchor, constant: -1)
		caretAfterText = caret.leadingAnchor.constraint(equalTo: queryLabel.trailingAnchor, constant: 1)
		caretAtStart.isActive = true                 // the query starts empty
	}
	required init?(coder: NSCoder) { fatalError() }

	override func didMoveToWindow() {
		super.didMoveToWindow()
		guard window != nil else { caret.layer.removeAllAnimations(); return }
		caret.alpha = 1
		guard !UIAccessibility.isReduceMotionEnabled else { return }
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

		self.results = Array(results.prefix(resultCap))
		resultsCollection.reloadData()
		resultsCollection.setContentOffset(.zero, animated: false)

		if results.isEmpty {
			statusLabel.text = showingRecents ? emptyStatus : noResultsStatus
			statusLabel.isHidden = false
		} else {
			statusLabel.isHidden = true
		}
	}

	func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
		results.count
	}

	func collectionView(_ collectionView: UICollectionView,
						cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
		let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "emoji-search-result",
			for: indexPath) as! EmojiSearchResultCell
		let emoji = results[indexPath.item]
		cell.configure(emoji, image: atlas?.image(for: emoji))
		return cell
	}

	func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
		onPick?(results[indexPath.item])
	}

	func collectionView(_ collectionView: UICollectionView,
						contextMenuConfigurationForItemAt indexPath: IndexPath,
						point: CGPoint) -> UIContextMenuConfiguration? {
		let variants = KBEmojiVariants.skinToneVariants(of: results[indexPath.item])
		guard !variants.isEmpty else { return nil }
		return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
			UIMenu(title: "Skin Tone", children: variants.map { variant in
				UIAction(title: variant) { [weak self] _ in self?.onPick?(variant) }
			})
		}
	}
}
