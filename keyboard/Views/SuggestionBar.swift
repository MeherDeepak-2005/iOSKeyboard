import UIKit

// Suggestion bar (its own taps) — extracted from Keyboard.swift.

final class SuggestionBar: UIView {
	var onPick: ((String) -> Void)?
	/// Tap on the leading clipboard icon — opens the history panel. The panel is the
	/// ONLY clipboard surface: copies are captured when it opens, never surfaced here
	/// (a strip chip meant reading UIPasteboard on the type path, which stalled layout
	/// and fired iOS's paste banner on every copy).
	var onOpenClipboard: (() -> Void)?

	private var buttons: [UIButton] = []
	private let clipButton = UIButton(type: .system)
	private let sep1 = UIView(), sep2 = UIView()
	private let textColor: UIColor
	private let dimColor: UIColor
	private static let clipWidth: CGFloat = 34

	private var current: [String] = []
	private var currentPrefix: String?

	init(theme: KeyboardTheme) {
		self.textColor = theme.keyText
		self.dimColor = theme.keyText.withAlphaComponent(0.45)
		super.init(frame: .zero)
		backgroundColor = .clear

		clipButton.setImage(UIImage(systemName: "doc.on.clipboard",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
		clipButton.tintColor = theme.specialKeyText.withAlphaComponent(0.55)
		clipButton.addAction(UIAction { [weak self] _ in self?.onOpenClipboard?() }, for: .touchUpInside)
		clipButton.translatesAutoresizingMaskIntoConstraints = false
		addSubview(clipButton)

		let stack = UIStackView()
		stack.axis = .horizontal
		stack.distribution = .fillEqually
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			clipButton.leadingAnchor.constraint(equalTo: leadingAnchor),
			clipButton.topAnchor.constraint(equalTo: topAnchor),
			clipButton.bottomAnchor.constraint(equalTo: bottomAnchor),
			clipButton.widthAnchor.constraint(equalToConstant: Self.clipWidth),
			stack.leadingAnchor.constraint(equalTo: clipButton.trailingAnchor),
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
		let w = (bounds.width - Self.clipWidth) / 3
		let inset: CGFloat = 10
		sep1.frame = CGRect(x: Self.clipWidth + w, y: inset, width: 0.5, height: bounds.height - inset*2)
		sep2.frame = CGRect(x: Self.clipWidth + w*2, y: inset, width: 0.5, height: bounds.height - inset*2)
	}

	/// `typedPrefix` (the word the user is mid-typing) turns completions into ghost
	/// text: the part the user already typed renders solid, the completion remainder
	/// dims — the closest an iOS keyboard extension can get to in-field grey preview
	/// (the host text field is off-limits to us).
	func setSuggestions(_ s: [String], typedPrefix: String? = nil) {
		current = s
		currentPrefix = typedPrefix
		for (i, b) in buttons.enumerated() {
			let t = i < current.count ? current[i] : ""
			b.isEnabled = !t.isEmpty
			guard !t.isEmpty else { b.setTitle("", for: .normal); b.setAttributedTitle(nil, for: .normal); continue }
			if let p = currentPrefix, !p.isEmpty, t.count > p.count,
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
