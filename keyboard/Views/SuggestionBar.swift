import UIKit

// Suggestion bar (its own taps) — extracted from Keyboard.swift.

final class SuggestionBar: UIView {
	var onPick: ((String) -> Void)?
	/// Tap on the leading clipboard icon — opens the history panel. The panel is the ONLY
	/// clipboard surface: copies are captured when it opens, never surfaced here (a strip
	/// chip meant reading UIPasteboard on the type path, which stalls layout and fires
	/// iOS's paste banner on every copy).
	var onOpenClipboard: (() -> Void)?

	private var buttons: [UIButton] = []
	private let clipButton = UIButton(type: .system)
	private static let clipWidth: CGFloat = 34
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
	private let visualOffsetY: CGFloat = -3
	private let bottomPassThroughHeight: CGFloat = 6

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
		clipButton.setImage(UIImage(systemName: "doc.on.clipboard",
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
		clipButton.tintColor = theme.specialKeyText.withAlphaComponent(0.55)
		clipButton.accessibilityLabel = "Clipboard"
		clipButton.accessibilityIdentifier = "suggestion.clipboard"
		clipButton.addAction(UIAction { [weak self] _ in self?.onOpenClipboard?() }, for: .touchUpInside)
		addSubview(clipButton)
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
		// The clipboard icon takes a fixed leading slot; the three suggestion columns
		// (and the highlight + separators) split the remaining width and start after it.
		let clipW = Self.clipWidth
		// Centered in the bar's own bounds (NOT shifted by visualOffsetY, which is a text
		// baseline nudge): an icon reads centered, and staying inside bounds keeps the
		// whole 44pt target hittable above the strip's bottom pass-through band.
		clipButton.frame = CGRect(x: 0, y: 0, width: clipW, height: bounds.height)
		let w = max(0, (bounds.width - clipW) / 3)
		for (index, button) in buttons.enumerated() {
			button.frame = CGRect(x: clipW + CGFloat(index) * w, y: visualOffsetY,
							  width: w, height: bounds.height)
		}
		let highlightInset: CGFloat = 4
		primaryBackground.frame = CGRect(
			x: clipW + w + highlightInset,
			y: highlightInset + visualOffsetY,
			width: max(0, w - highlightInset * 2),
			height: max(0, bounds.height - highlightInset * 2)
		)
		primaryBackground.layer.cornerRadius = max(0, min(15, primaryBackground.bounds.height / 2))
		let inset: CGFloat = 12
		let separatorHeight = max(0, bounds.height - inset * 2)
		sep1.frame = CGRect(x: clipW + w, y: inset, width: 0.5, height: separatorHeight)
		sep2.frame = CGRect(x: clipW + w * 2, y: inset, width: 0.5, height: separatorHeight)
	}

	/// The strip visually sits close to QWERTY, but the last six points belong to the
	/// nearest top-row key. VoiceOver keeps the complete 44-point semantic target.
	override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
		if !UIAccessibility.isVoiceOverRunning,
			point.y >= bounds.maxY - bottomPassThroughHeight { return false }
		return super.point(inside: point, with: event)
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
	func setGlidePreview(_ preview: String?, alternatives: [String] = [],
		confident: Bool = true) {
		guard let preview, !preview.isEmpty else {
			renderStablePresentation()
			return
		}
		let left = alternatives.indices.contains(0) ? alternatives[0] : ""
		let right = alternatives.indices.contains(1) ? alternatives[1] : ""
		let displayed = [left, preview, right]
		for (i, b) in buttons.enumerated() {
			b.setAttributedTitle(nil, for: .normal)
			b.setTitle(displayed[i], for: .normal)
			b.isEnabled = false
			b.backgroundColor = .clear
		}
		primaryBackground.alpha = confident ? 1 : 0.72
		setPrimaryHighlighted(true)
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
		if !on { primaryBackground.alpha = 1 }
		buttons.indices.forEach { index in
			buttons[index].accessibilityTraits = index == 1 && on ? [.button, .selected] : .button
		}
	}

	@objc private func tap(_ sender: UIButton) {
		// Attributed titles don't populate title(for:), so read the label text.
		if let t = sender.titleLabel?.text, !t.isEmpty { onPick?(t) }
	}
}
