import UIKit

// Suggestion bar (its own taps) — extracted from Keyboard.swift.

final class SuggestionBar: UIView {
	var onPick: ((String) -> Void)?
	private var buttons: [UIButton] = []
	private let sep1 = UIView(), sep2 = UIView()
	private let textColor: UIColor
	private let dimColor: UIColor

	init(theme: KeyboardTheme) {
		self.textColor = theme.keyText
		self.dimColor = theme.keyText.withAlphaComponent(0.45)
		super.init(frame: .zero)
		backgroundColor = .clear
		let stack = UIStackView()
		stack.axis = .horizontal
		stack.distribution = .fillEqually
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: trailingAnchor),
			stack.topAnchor.constraint(equalTo: topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomAnchor)
		])
		for i in 0..<3 {
			let b = UIButton(type: .custom)
			b.titleLabel?.font = .systemFont(ofSize: 17)
			b.titleLabel?.adjustsFontSizeToFitWidth = true
			b.titleLabel?.minimumScaleFactor = 0.8
			b.setTitleColor(theme.keyText, for: .normal)
			b.tag = i
			b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
			buttons.append(b)
			stack.addArrangedSubview(b)
		}
		for s in [sep1, sep2] {
			s.backgroundColor = theme.keyText.withAlphaComponent(0.12)
			addSubview(s)
		}
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		let w = bounds.width / 3
		let inset: CGFloat = 10
		sep1.frame = CGRect(x: w, y: inset, width: 0.5, height: bounds.height - inset*2)
		sep2.frame = CGRect(x: w*2, y: inset, width: 0.5, height: bounds.height - inset*2)
	}

	/// `typedPrefix` (the word the user is mid-typing) turns completions into ghost
	/// text: the part the user already typed renders solid, the completion remainder
	/// dims — the closest an iOS keyboard extension can get to in-field grey preview
	/// (the host text field is off-limits to us).
	func setSuggestions(_ s: [String], typedPrefix: String? = nil) {
		for (i, b) in buttons.enumerated() {
			let t = i < s.count ? s[i] : ""
			b.isEnabled = !t.isEmpty
			guard !t.isEmpty else { b.setTitle("", for: .normal); b.setAttributedTitle(nil, for: .normal); continue }
			if let p = typedPrefix, !p.isEmpty, t.count > p.count,
			   t.lowercased().hasPrefix(p.lowercased()) {
				let attr = NSMutableAttributedString(
					string: String(t.prefix(p.count)),
					attributes: [.foregroundColor: textColor, .font: b.titleLabel?.font as Any])
				attr.append(NSAttributedString(
					string: String(t.dropFirst(p.count)),
					attributes: [.foregroundColor: dimColor, .font: b.titleLabel?.font as Any]))
				b.setAttributedTitle(attr, for: .normal)
			} else {
				b.setAttributedTitle(nil, for: .normal)
				b.setTitle(t, for: .normal)
			}
		}
	}

	@objc private func tap(_ sender: UIButton) {
		// Attributed titles don't populate title(for:), so read the label text.
		if let t = sender.titleLabel?.text, !t.isEmpty { onPick?(t) }
	}
}

