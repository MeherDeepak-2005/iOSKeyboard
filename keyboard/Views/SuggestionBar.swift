import UIKit

// Suggestion bar (its own taps) — extracted from Keyboard.swift.

final class SuggestionBar: UIView {
	var onPick: ((String) -> Void)?

	private var buttons: [UIButton] = []
	private let primaryBackground = UIView()
	private let sep1 = UIView(), sep2 = UIView()
	private let textColor: UIColor
	private let dimColor: UIColor
	private let primaryFill: UIColor
	private let primaryBorder: UIColor

	private var rankedSuggestions: [String] = []
	private var currentPrefix: String?
	private var highlightsPrimary = false
	private var stableGlideResult: (winner: String, alternatives: [String])?

	init(theme: KeyboardTheme) {
		self.textColor = theme.keyText
		self.dimColor = theme.keyText.withAlphaComponent(0.45)
		self.primaryFill = theme.suggestionHighlight
		self.primaryBorder = theme.suggestionHighlightBorder
		super.init(frame: .zero)
		backgroundColor = .clear
		isOpaque = false

		primaryBackground.isUserInteractionEnabled = false
		primaryBackground.backgroundColor = primaryFill
		primaryBackground.layer.cornerCurve = .continuous
		primaryBackground.layer.borderWidth = 0.75
		primaryBackground.layer.borderColor = primaryBorder.cgColor
		primaryBackground.isHidden = true
		addSubview(primaryBackground)
		for i in 0..<3 {
			let b = UIButton(type: .custom)
			let base = UIFont.systemFont(ofSize: 17,
				weight: i == 1 || UIAccessibility.isBoldTextEnabled ? .semibold : .regular)
			b.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base,
				maximumPointSize: 21)
			b.titleLabel?.adjustsFontSizeToFitWidth = true
			b.titleLabel?.minimumScaleFactor = 0.8
			b.setTitleColor(theme.keyText, for: .normal)
			b.tag = i
			b.accessibilityIdentifier = ["suggestion.left", "suggestion.primary", "suggestion.right"][i]
			b.accessibilityHint = i == 1 ? "Top suggestion" : "Alternative suggestion"
			b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
			buttons.append(b)
			addSubview(b)
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
		for (index, button) in buttons.enumerated() {
			button.frame = CGRect(x: CGFloat(index) * w, y: 0,
							  width: w, height: bounds.height)
		}
		let highlightInset: CGFloat = 4
		primaryBackground.frame = CGRect(
			x: w + highlightInset,
			y: highlightInset,
			width: max(0, w - highlightInset * 2),
			height: max(0, bounds.height - highlightInset * 2)
		)
		primaryBackground.layer.cornerRadius = max(0, min(15, primaryBackground.bounds.height / 2))
		let inset: CGFloat = 12
		let separatorHeight = max(0, bounds.height - inset * 2)
		sep1.frame = CGRect(x: w, y: inset, width: 0.5, height: separatorHeight)
		sep2.frame = CGRect(x: w * 2, y: inset, width: 0.5, height: separatorHeight)
	}

	/// `typedPrefix` (the word the user is mid-typing) turns completions into ghost
	/// text: the part the user already typed renders solid, the completion remainder
	/// dims — the closest an iOS keyboard extension can get to in-field grey preview
	/// (the host text field is off-limits to us).
	func setSuggestions(_ s: [String], typedPrefix: String? = nil, highlightPrimary: Bool = false) {
		stableGlideResult = nil
		rankedSuggestions = s
		currentPrefix = typedPrefix
		highlightsPrimary = highlightPrimary
		renderSuggestions()
	}

	/// Immediate, zero-decoder-cost feedback while a glide is in progress. The path's
	/// crossed letters occupy the primary (middle) slot until decoding replaces them.
	func setGlidePreview(_ preview: String?, confident: Bool = true) {
		guard let preview, !preview.isEmpty else {
			renderStablePresentation()
			return
		}
		for (i, b) in buttons.enumerated() {
			b.setAttributedTitle(nil, for: .normal)
			b.setTitle(i == 1 ? preview : "", for: .normal)
			b.isEnabled = false
			b.backgroundColor = .clear
		}
		setPrimaryHighlighted(confident)
	}

	/// Keep the word that was actually committed in the shaded middle slot. The two
	/// nearest alternatives remain available on either side for one-tap correction.
	func setGlideResult(_ winner: String, alternatives: [String]) {
		stableGlideResult = (winner, alternatives)
		renderGlideResult(winner, alternatives: alternatives)
	}

	private func renderGlideResult(_ winner: String, alternatives: [String]) {
		let left = alternatives.indices.contains(0) ? alternatives[0] : ""
		let right = alternatives.indices.contains(1) ? alternatives[1] : ""
		let displayed = [left, winner, right]
		for (index, button) in buttons.enumerated() {
			let title = displayed[index]
			button.setAttributedTitle(nil, for: .normal)
			button.setTitle(title, for: .normal)
			button.isEnabled = index != 1 && !title.isEmpty
			button.backgroundColor = .clear
		}
		setPrimaryHighlighted(true)
	}

	private func renderStablePresentation() {
		if let result = stableGlideResult {
			renderGlideResult(result.winner, alternatives: result.alternatives)
		} else {
			renderSuggestions()
		}
	}

	private func renderSuggestions() {
		let top = rankedSuggestions.indices.contains(0) ? rankedSuggestions[0] : ""
		let second = rankedSuggestions.indices.contains(1) ? rankedSuggestions[1] : ""
		let third = rankedSuggestions.indices.contains(2) ? rankedSuggestions[2] : ""
		// Visual order follows the familiar keyboard convention: #2, #1, #3.
		let displayed = [second, top, third]
		for (i, b) in buttons.enumerated() {
			let t = displayed[i]
			b.isEnabled = !t.isEmpty
			b.backgroundColor = .clear
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
		setPrimaryHighlighted(highlightsPrimary && !top.isEmpty)
	}

	private func setPrimaryHighlighted(_ on: Bool) {
		primaryBackground.isHidden = !on
		buttons.indices.forEach { index in
			buttons[index].accessibilityTraits = index == 1 && on ? [.button, .selected] : .button
		}
	}

	@objc private func tap(_ sender: UIButton) {
		// Attributed titles don't populate title(for:), so read the label text.
		if let t = sender.titleLabel?.text, !t.isEmpty { onPick?(t) }
	}
}
