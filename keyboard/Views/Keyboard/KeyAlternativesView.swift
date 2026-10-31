import UIKit

final class KeyAlternativesView: UIView {
	private let options: [String]
	private var labels: [UILabel] = []
	private let selection = UIView()
	private(set) var selectedIndex = 0

	init(options: [String], theme: KeyboardTheme) {
		self.options = options
		super.init(frame: .zero)
		backgroundColor = theme.popupFill
		layer.cornerRadius = 12
		layer.cornerCurve = .continuous
		layer.shadowColor = UIColor.black.cgColor
		layer.shadowOpacity = theme.isDark ? 0.42 : 0.20
		layer.shadowRadius = 6
		layer.shadowOffset = CGSize(width: 0, height: 2)
		selection.backgroundColor = theme.accentSoft
		selection.layer.cornerRadius = 9
		selection.layer.cornerCurve = .continuous
		addSubview(selection)
		for option in options {
			let label = UILabel()
			label.text = option
			label.textAlignment = .center
			label.textColor = theme.popupText
			label.font = .systemFont(ofSize: 24,
				weight: UIAccessibility.isBoldTextEnabled ? .medium : .regular)
			labels.append(label)
			addSubview(label)
		}
		isAccessibilityElement = false
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		guard !labels.isEmpty else { return }
		let width = bounds.width / CGFloat(labels.count)
		selection.frame = CGRect(x: CGFloat(selectedIndex) * width + 3, y: 3,
			width: max(0, width - 6), height: max(0, bounds.height - 6))
		for (index, label) in labels.enumerated() {
			label.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
		}
	}

	func select(atX x: CGFloat) {
		guard !labels.isEmpty, bounds.width > 0 else { return }
		let index = min(labels.count - 1, max(0,
			Int(floor(x / (bounds.width / CGFloat(labels.count))))))
		guard index != selectedIndex else { return }
		selectedIndex = index
		setNeedsLayout()
	}

	var selectedValue: String { options[selectedIndex] }
	var baseValue: String { options[0] }
}
