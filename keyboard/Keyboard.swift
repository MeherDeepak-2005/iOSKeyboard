import UIKit

// Add this file to BOTH targets (app + keyboard extension). Pure UIKit.

// MARK: - Color

extension UIColor {
	convenience init(hex: UInt32) {
		self.init(red: CGFloat((hex >> 16) & 0xFF)/255,
				  green: CGFloat((hex >> 8) & 0xFF)/255,
				  blue: CGFloat(hex & 0xFF)/255, alpha: 1)
	}
}

// MARK: - Theme

struct KeyboardTheme {
	let name: String
	let background, key, keyText, specialKey, specialKeyText, accentKey, accentKeyText: UIColor
	let shadowOpacity: Float
	let cornerRadius: CGFloat
	let isDark: Bool

	static let doistLight = KeyboardTheme(name: "Light",
		background: UIColor(hex: 0xF4F4F8), key: UIColor(hex: 0xFFFFFF), keyText: UIColor(hex: 0x1B1B1D),
		specialKey: UIColor(hex: 0xCDD5E6), specialKeyText: UIColor(hex: 0x1B1B1D),
		accentKey: UIColor(hex: 0xA6C8FE), accentKeyText: UIColor(hex: 0x1B1B1D),
		shadowOpacity: 0.10, cornerRadius: 12, isDark: false)

	static let doistDark = KeyboardTheme(name: "Dark",
		background: UIColor(hex: 0x1D1F21), key: UIColor(hex: 0x222529), keyText: UIColor(hex: 0xF6F6F8),
		specialKey: UIColor(hex: 0x2E3238), specialKeyText: UIColor(hex: 0xF6F6F8),
		accentKey: UIColor(hex: 0x5483B0), accentKeyText: UIColor(hex: 0xFFFFFF),
		shadowOpacity: 0.40, cornerRadius: 12, isDark: true)
}

// MARK: - Model

enum KeyboardPage { case letters, numbers, symbols }
enum ShiftState   { case off, on, locked }
enum KeyRole      { case normal, special, accent }
enum KeyWidth     { case unit, wide, ret, flex }

private struct KeySpec {
	var label: String? = nil
	var symbol: String? = nil
	var role: KeyRole = .normal
	var width: KeyWidth = .unit
	var action: () -> Void
}

// MARK: - Key (now a dumb view — KeyboardView owns the touches)

final class KeyButton: UIView {
	let widthKind: KeyWidth
	let action: () -> Void
	private let base: UIColor
	private let dark: Bool

	fileprivate init(spec: KeySpec, theme: KeyboardTheme) {
		self.widthKind = spec.width
		self.action = spec.action
		self.dark = theme.isDark
		switch spec.role {
		case .normal:  base = theme.key
		case .special: base = theme.specialKey
		case .accent:  base = theme.accentKey
		}
		super.init(frame: .zero)
		isUserInteractionEnabled = false        // touches handled by KeyboardView

		let fg: UIColor
		switch spec.role {
		case .normal:  fg = theme.keyText
		case .special: fg = theme.specialKeyText
		case .accent:  fg = theme.accentKeyText
		}

		let content: UIView
		if let symbol = spec.symbol {
			let iv = UIImageView(image: UIImage(systemName: symbol,
				withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)))
			iv.tintColor = fg
			content = iv
		} else {
			let lbl = UILabel()
			lbl.text = spec.label
			lbl.textColor = fg
			lbl.font = .systemFont(ofSize: (spec.label?.count ?? 0) > 1 ? 16 : 22)
			content = lbl
		}
		content.translatesAutoresizingMaskIntoConstraints = false
		addSubview(content)
		NSLayoutConstraint.activate([
			content.centerXAnchor.constraint(equalTo: centerXAnchor),
			content.centerYAnchor.constraint(equalTo: centerYAnchor)
		])

		backgroundColor = base
		layer.cornerRadius = theme.cornerRadius
		layer.cornerCurve = .continuous
		layer.shadowColor = UIColor.black.cgColor
		layer.shadowOpacity = theme.shadowOpacity
		layer.shadowRadius = 1.5
		layer.shadowOffset = CGSize(width: 0, height: 1)
	}
	required init?(coder: NSCoder) { fatalError() }

	func setHighlighted(_ on: Bool) { backgroundColor = on ? pressed : base }

	private var pressed: UIColor {
		var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
		base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
		return UIColor(hue: h, saturation: s,
					   brightness: dark ? min(1, b + 0.08) : max(0, b - 0.06), alpha: a)
	}
}

// MARK: - Suggestion bar (its own touches — taps a candidate)

final class SuggestionBar: UIView {
	var onPick: ((String) -> Void)?
	private var buttons: [UIButton] = []
	private let sep1 = UIView(), sep2 = UIView()

	init(theme: KeyboardTheme) {
		super.init(frame: .zero)
		backgroundColor = theme.background
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
			b.titleLabel?.font = .systemFont(ofSize: 16)
			b.setTitleColor(theme.keyText, for: .normal)
			b.tag = i
			b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
			buttons.append(b)
			stack.addArrangedSubview(b)
		}
		for s in [sep1, sep2] {
			s.backgroundColor = theme.keyText.withAlphaComponent(0.15)
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

	func setSuggestions(_ s: [String]) {
		for (i, b) in buttons.enumerated() {
			let t = i < s.count ? s[i] : ""
			b.setTitle(t, for: .normal)
			b.isEnabled = !t.isEmpty
		}
	}

	@objc private func tap(_ sender: UIButton) {
		if let t = sender.title(for: .normal), !t.isEmpty { onPick?(t) }
	}
}

// MARK: - Keyboard

final class KeyboardView: UIView {

	var onInsert:         ((String) -> Void)?
	var onDelete:         (() -> Void)?
	var onReturn:         (() -> Void)?
	var onNextKeyboard:   (() -> Void)?
	var onPickSuggestion: ((String) -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private var page: KeyboardPage = .letters
	private var shift: ShiftState = .on
	private var rows: [[KeyButton]] = []
	private let suggestionBar: SuggestionBar

	private let keySpacing: CGFloat = 6
	private let rowSpacing: CGFloat = 11
	private let rowHeight:  CGFloat = 46
	private let stripHeight: CGFloat = 44
	private let sidePad: CGFloat = 3
	private let topPad: CGFloat = 6
	private let botPad: CGFloat = 6

	var keyboardHeight: CGFloat { stripHeight + topPad + rowHeight*4 + rowSpacing*3 + botPad }

	init(theme: KeyboardTheme, showsGlobe: Bool = true) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.suggestionBar = SuggestionBar(theme: theme)
		super.init(frame: .zero)
		backgroundColor = theme.background
		isMultipleTouchEnabled = true            // <-- fast typists / overlapping fingers
		addSubview(suggestionBar)
		suggestionBar.onPick = { [weak self] in self?.onPickSuggestion?($0) }
		reload()
	}
	required init?(coder: NSCoder) { fatalError() }

	func setSuggestions(_ s: [String]) { suggestionBar.setSuggestions(s) }

	// MARK: Layout

	override func layoutSubviews() {
		super.layoutSubviews()
		suggestionBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripHeight)

		let W = bounds.width - sidePad*2
		guard W > 0 else { return }
		let unit = max(1, (W - keySpacing*9)/10)
		let wide = unit*1.5 + keySpacing/2
		let retW = unit*2 + keySpacing
		func fixed(_ k: KeyWidth) -> CGFloat {
			switch k { case .unit: return unit; case .wide: return wide; case .ret: return retW; case .flex: return 0 }
		}

		var y = stripHeight + topPad
		for row in rows {
			let flexCount = row.filter { $0.widthKind == .flex }.count
			let fixedSum = row.reduce(0) { $0 + fixed($1.widthKind) }
			let gaps = keySpacing * CGFloat(max(0, row.count - 1))
			let flexW = flexCount > 0 ? max(1, (W - fixedSum - gaps)/CGFloat(flexCount)) : 0
			let content = fixedSum + flexW*CGFloat(flexCount) + gaps
			var x = sidePad + (flexCount == 0 ? (W - content)/2 : 0)
			for b in row {
				let w = b.widthKind == .flex ? flexW : fixed(b.widthKind)
				b.frame = CGRect(x: x, y: y, width: w, height: rowHeight)
				x += w + keySpacing
			}
			y += rowHeight + rowSpacing
		}
	}

	// MARK: Multi-touch — fire on contact, track every finger

	private var touchKeys: [UITouch: KeyButton] = [:]

	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			guard let key = key(at: touch.location(in: self)) else { continue }
			key.setHighlighted(true)
			touchKeys[touch] = key
			key.action()                        // commit immediately
		}
	}
	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			guard let key = touchKeys[touch] else { continue }
			key.setHighlighted(key.frame.contains(touch.location(in: self)))
		}
	}
	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
		for touch in touches {
			touchKeys[touch]?.setHighlighted(false)
			touchKeys[touch] = nil
		}
	}
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		touchesEnded(touches, with: event)
	}

	private func key(at p: CGPoint) -> KeyButton? {
		var best: KeyButton?
		var bestDist = CGFloat.greatestFiniteMagnitude
		for row in rows {
			for key in row {
				if key.frame.contains(p) { return key }       // exact hit
				let dx = max(key.frame.minX - p.x, 0, p.x - key.frame.maxX)
				let dy = max(key.frame.minY - p.y, 0, p.y - key.frame.maxY)
				let d = dx*dx + dy*dy                          // squared distance to the key rect
				if d < bestDist { bestDist = d; best = key }
			}
		}
		return best                                           // nearest key — gaps aren't dead zones
	}

	// MARK: Build keys

	private func reload() {
		rows.forEach { $0.forEach { $0.removeFromSuperview() } }
		rows = specs().map { row in
			row.map { spec -> KeyButton in
				let b = KeyButton(spec: spec, theme: theme)
				addSubview(b)
				return b
			}
		}
		bringSubviewToFront(suggestionBar)
		setNeedsLayout()
	}

	private func shifted(_ c: String) -> String { shift == .off ? c : c.uppercased() }
	private var shiftSymbol: String {
		switch shift { case .off: return "shift"; case .on: return "shift.fill"; case .locked: return "capslock.fill" }
	}
	private func charSpec(_ c: String) -> KeySpec {
		if page == .letters {
			return KeySpec(label: shifted(c), width: .unit) { [weak self] in
				guard let self else { return }
				self.onInsert?(self.shifted(c))
				if self.shift == .on { self.shift = .off; self.reload() }
			}
		}
		return KeySpec(label: c, width: .unit) { [weak self] in self?.onInsert?(c) }
	}
	private func punct(_ c: String) -> KeySpec {
		KeySpec(label: c, width: .flex) { [weak self] in self?.onInsert?(c) }
	}

	private func specs() -> [[KeySpec]] {
		let del = KeySpec(symbol: "delete.left", role: .special, width: .wide) { [weak self] in self?.onDelete?() }
		let ret = KeySpec(symbol: "return", role: .accent, width: .ret) { [weak self] in self?.onReturn?() }
		let space = KeySpec(label: "space", width: .flex) { [weak self] in self?.onInsert?(" ") }
		func switchKey(_ l: String, to t: KeyboardPage) -> KeySpec {
			KeySpec(label: l, role: .special, width: .wide) { [weak self] in self?.page = t; self?.reload() }
		}
		func bottom(_ leading: KeySpec) -> [KeySpec] {
			var r = [leading]
			if showsGlobe { r.append(KeySpec(symbol: "globe", role: .special, width: .unit) { [weak self] in self?.onNextKeyboard?() }) }
			r.append(space); r.append(ret); return r
		}
		let shiftKey = KeySpec(symbol: shiftSymbol, role: .special, width: .wide) { [weak self] in
			guard let self else { return }
			switch self.shift { case .off: self.shift = .on; case .on: self.shift = .locked; case .locked: self.shift = .off }
			self.reload()
		}
		switch page {
		case .letters:
			return [
				["q","w","e","r","t","y","u","i","o","p"].map(charSpec),
				["a","s","d","f","g","h","j","k","l"].map(charSpec),
				[shiftKey] + ["z","x","c","v","b","n","m"].map(charSpec) + [del],
				bottom(switchKey("123", to: .numbers))
			]
		case .numbers:
			return [
				["1","2","3","4","5","6","7","8","9","0"].map(charSpec),
				["-","/",":",";","(",")","$","&","@","\""].map(charSpec),
				[switchKey("#+=", to: .symbols)] + [".",",","?","!","'"].map(punct) + [del],
				bottom(switchKey("ABC", to: .letters))
			]
		case .symbols:
			return [
				["[","]","{","}","#","%","^","*","+","="].map(charSpec),
				["_","\\","|","~","<",">","€","£","¥","•"].map(charSpec),
				[switchKey("123", to: .numbers)] + [".",",","?","!","'"].map(punct) + [del],
				bottom(switchKey("ABC", to: .letters))
			]
		}
	}
}
