import UIKit
import Darwin

// MARK: - Cells

final class EmojiCell: UICollectionViewCell {
	let label = UILabel()
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
			imageView.heightAnchor.constraint(equalToConstant: EmojiAtlas.pointSize),
		])
	}
	required init?(coder: NSCoder) { fatalError() }

	override func prepareForReuse() {
		super.prepareForReuse()
		label.text = nil
		imageView.image = nil
	}

	func configure(emoji: String, image: UIImage?, theme: KeyboardTheme) {
		if let image {
			imageView.image = image
			imageView.isHidden = false
			label.text = nil
			label.isHidden = true
		} else {
			imageView.image = nil
			imageView.isHidden = true
			label.text = emoji
			label.isHidden = false
		}
		isAccessibilityElement = true
		accessibilityLabel = emoji
		accessibilityTraits = .button
		highlightColor = theme.isDark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08)
		contentView.backgroundColor = isHighlighted ? highlightColor : .clear
	}
}

final class EmojiSearchResultCell: UICollectionViewCell {
	private let label = UILabel()
	private let imageView = UIImageView()
	override init(frame: CGRect) {
		super.init(frame: frame)
		label.textAlignment = .center
		label.font = .systemFont(ofSize: 28)
		label.translatesAutoresizingMaskIntoConstraints = false
		imageView.contentMode = .scaleAspectFit
		imageView.translatesAutoresizingMaskIntoConstraints = false
		contentView.addSubview(label)
		contentView.addSubview(imageView)
		NSLayoutConstraint.activate([
			label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
			imageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
			imageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
			imageView.widthAnchor.constraint(equalToConstant: EmojiAtlas.pointSize),
			imageView.heightAnchor.constraint(equalToConstant: EmojiAtlas.pointSize),
		])
		isAccessibilityElement = true
		accessibilityTraits = .button
	}
	required init?(coder: NSCoder) { fatalError() }
	override func prepareForReuse() {
		super.prepareForReuse()
		label.text = nil
		imageView.image = nil
	}
	func configure(_ emoji: String, image: UIImage?) {
		if let image {
			imageView.image = image
			imageView.isHidden = false
			label.text = nil
			label.isHidden = true
		} else {
			imageView.image = nil
			imageView.isHidden = true
			label.text = emoji
			label.isHidden = false
		}
		accessibilityLabel = emoji
	}
}

final class EmojiHeader: UICollectionReusableView {
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
