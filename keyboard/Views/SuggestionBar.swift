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
	private let stack = UIStackView()
	private let sep1 = UIView(), sep2 = UIView()
	private let textColor: UIColor
	private let dimColor: UIColor
	private let primaryFill: UIColor
	private static let clipWidth: CGFloat = 34

	private var rankedSuggestions: [String] = []
	private var currentPrefix: String?
	private var stableGlideResult: (winner: String, alternatives: [String])?

	init(theme: KeyboardTheme) {
		self.textColor = theme.keyText
		self.dimColor = theme.keyText.withAlphaComponent(0.45)
		self.primaryFill = UIColor.white.withAlphaComponent(theme.isDark ? 0.26 : 0.74)
		super.init(frame: .zero)
		backgroundColor = .clear

		clipButton.setImage(UIImage(systemName: "doc.on.clipboard",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
		clipButton.tintColor = theme.specialKeyText.withAlphaComponent(0.55)
		clipButton.addAction(UIAction { [weak self] _ in self?.onOpenClipboard?() }, for: .touchUpInside)
		addSubview(clipButton)

		stack.axis = .horizontal
		stack.distribution = .fillEqually
		addSubview(stack)
		for i in 0..<3 {
			let b = UIButton(type: .custom)
			b.titleLabel?.font = .systemFont(ofSize: 17, weight: i == 1 ? .medium : .regular)
			b.titleLabel?.adjustsFontSizeToFitWidth = true
			b.titleLabel?.minimumScaleFactor = 0.8
			b.setTitleColor(theme.keyText, for: .normal)
			b.layer.cornerRadius = 17
			b.layer.cornerCurve = .continuous
			b.tag = i
			b.accessibilityIdentifier = ["suggestion.left", "suggestion.primary", "suggestion.right"][i]
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
		let clipWidth = min(Self.clipWidth, bounds.width)
		let suggestionsWidth = max(0, bounds.width - clipWidth)
		clipButton.frame = CGRect(x: 0, y: 0, width: clipWidth, height: bounds.height)
		stack.frame = CGRect(x: clipWidth, y: 0, width: suggestionsWidth, height: bounds.height)
		let w = suggestionsWidth / 3
		let inset: CGFloat = 10
		let separatorHeight = max(0, bounds.height - inset * 2)
		sep1.frame = CGRect(x: clipWidth + w, y: inset, width: 0.5, height: separatorHeight)
		sep2.frame = CGRect(x: clipWidth + w * 2, y: inset, width: 0.5, height: separatorHeight)
	}

	/// `typedPrefix` (the word the user is mid-typing) turns completions into ghost
	/// text: the part the user already typed renders solid, the completion remainder
	/// dims — the closest an iOS keyboard extension can get to in-field grey preview
	/// (the host text field is off-limits to us).
	func setSuggestions(_ s: [String], typedPrefix: String? = nil) {
		stableGlideResult = nil
		rankedSuggestions = s
		currentPrefix = typedPrefix
		renderSuggestions()
	}

	/// Immediate, zero-decoder-cost feedback while a glide is in progress. The path's
	/// crossed letters occupy the primary (middle) slot until decoding replaces them.
	func setGlidePreview(_ preview: String?) {
		guard let preview, !preview.isEmpty else {
			renderStablePresentation()
			return
		}
		for (i, b) in buttons.enumerated() {
			b.setAttributedTitle(nil, for: .normal)
			b.setTitle(i == 1 ? preview : "", for: .normal)
			b.isEnabled = false
			b.backgroundColor = i == 1 ? primaryFill : .clear
		}
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
			button.backgroundColor = index == 1 ? primaryFill : .clear
		}
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
			b.backgroundColor = (i == 1 && shouldHighlightPrimary(top)) ? primaryFill : .clear
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

	private func shouldHighlightPrimary(_ candidate: String) -> Bool {
		guard let prefix = currentPrefix, prefix.count >= 2, !candidate.isEmpty else { return false }
		let p = prefix.lowercased()
		let c = candidate.lowercased()
		if p == c { return true }
		if c.hasPrefix(p) { return c.count - p.count <= 2 }
		return abs(c.count - p.count) <= 2
	}

	@objc private func tap(_ sender: UIButton) {
		// Attributed titles don't populate title(for:), so read the label text.
		if let t = sender.titleLabel?.text, !t.isEmpty { onPick?(t) }
	}
}
