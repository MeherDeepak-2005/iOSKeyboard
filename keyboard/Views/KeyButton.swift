import UIKit

// KeyButton: a dumb key view (KeyboardView owns touches) — extracted from Keyboard.swift.

final class KeyButton: UIView {
	let widthKind: KeyWidth
	let action: () -> Void
	let repeats: Bool
	let letterBase: String?          // lowercase base letter (for in-place shift relabelling)
	let committedText: String?
	let isShift: Bool                // shift key → its glyph is swapped on shift changes
	let isInputModeSwitch: Bool
	let isSpace: Bool
	private(set) var alternatives: [String]
	let role: KeyRole
	private let canPopup: Bool       // show the character balloon on press
	private let dark: Bool
	private let gradient: CAGradientLayer?        // non-nil for the accent (action) key
	private let dim = UIView()                    // press-feedback overlay (works on any fill)
	private let dimColor: UIColor
	private let isPill: Bool                       // capsule rounding
	private let baseRadius: CGFloat
	private var label: UILabel?                    // set for text keys — updated in place on shift
	private var iconView: UIImageView?            // set for symbol keys (e.g. the shift glyph)
	private var contentView: UIView?               // the glyph (label or icon) — hidden while covered
	private let recessColor: UIColor               // cap fill while the balloon is floating
	private let spokenLabelWasExplicit: Bool
	private let foregroundColor: UIColor
	private let glyphScale: CGFloat            // legend point-size multiplier (Telugu < 1)
	private(set) var acceptsInput = true

	/// Character to show in the press balloon (nil = no balloon). Reads the live label
	/// so it always reflects the current shift/case.
	var popupText: String? { canPopup ? label?.text : nil }

	init(spec: KeySpec, theme: KeyboardTheme) {
		self.widthKind = spec.width
		self.action = spec.action
		self.repeats = spec.repeats
		self.letterBase = spec.letterBase
		self.committedText = spec.committedText
		self.isShift = spec.isShift
		self.isInputModeSwitch = spec.isInputModeSwitch
		self.isSpace = spec.isSpace
		self.alternatives = spec.alternatives
		self.role = spec.role
		self.canPopup = spec.popup
		self.dark = theme.isDark
		self.gradient = spec.role == .accent ? CAGradientLayer() : nil
		self.dimColor = theme.pressedOverlay
		// Recessed "empty slot" look while the balloon floats: darken in both themes so the
		// cap reads as a blackish transparent well and only the raised balloon shows the glyph.
		self.recessColor = theme.isDark ? UIColor(white: 0, alpha: 0.34) : UIColor(white: 0, alpha: 0.16)
		self.isPill = spec.pill
		self.glyphScale = spec.glyphScale
		self.baseRadius = theme.cornerRadius
		self.spokenLabelWasExplicit = spec.accessibilityLabel != nil
		self.foregroundColor = {
			switch spec.role {
			case .normal: return theme.keyText
			case .special: return theme.specialKeyText
			case .accent: return theme.accentKeyText
			case .accentSoft: return theme.accentSoftText
			}
		}()
		super.init(frame: .zero)
		isUserInteractionEnabled = false        // touches handled by KeyboardView
		isAccessibilityElement = true
		accessibilityLabel = spec.accessibilityLabel ?? spec.label ?? Self.spokenName(for: spec.symbol)
		accessibilityTraits = .keyboardKey
		if spec.isSpace { accessibilityHint = "Hold and drag to move the cursor" }

		let fg = foregroundColor

		// Background: a gradient for the action key, a flat fill otherwise.
		if let gradient {
			gradient.colors = [theme.accentStart.cgColor, theme.accentEnd.cgColor]
			gradient.startPoint = CGPoint(x: 0, y: 0)
			gradient.endPoint   = CGPoint(x: 1, y: 1)
			gradient.cornerRadius = theme.cornerRadius
			gradient.cornerCurve = .continuous
			layer.addSublayer(gradient)
		} else {
			switch spec.role {
			case .special:    backgroundColor = theme.specialKey
			case .accentSoft: backgroundColor = theme.accentSoft
			default:          backgroundColor = theme.key
			}
		}

		dim.isUserInteractionEnabled = false
		dim.backgroundColor = .clear
		dim.layer.cornerRadius = theme.cornerRadius
		dim.layer.cornerCurve = .continuous
		addSubview(dim)

		let content: UIView
		if let symbol = spec.symbol {
			let iv = UIImageView(image: UIImage(systemName: symbol, withConfiguration: Self.symbolConfig))
			iv.tintColor = fg
			content = iv
			iconView = iv
		} else {
			let lbl = UILabel()
			lbl.text = spec.label
			lbl.textColor = fg
			let multi = (spec.label?.count ?? 0) > 1
			let bold = UIAccessibility.isBoldTextEnabled
			// Key legends use Apple's system face for consistent metrics and alignment.
			lbl.font = multi ? .systemFont(ofSize: 16 * glyphScale, weight: bold ? .semibold : .medium)
							 : .systemFont(ofSize: 23 * glyphScale, weight: bold ? .medium : .regular)
			content = lbl
			label = lbl
		}
		content.translatesAutoresizingMaskIntoConstraints = false
		contentView = content
		addSubview(content)
		NSLayoutConstraint.activate([
			content.centerXAnchor.constraint(equalTo: centerXAnchor),
			content.centerYAnchor.constraint(equalTo: centerYAnchor)
		])

		layer.cornerRadius = theme.cornerRadius
		layer.cornerCurve = .continuous
		if UIAccessibility.shouldDifferentiateWithoutColor,
		   spec.role == .accent || spec.role == .accentSoft {
			layer.borderWidth = 1.25
			layer.borderColor = foregroundColor.withAlphaComponent(0.48).cgColor
		}
		// Soft modern drop shadow. shadowPath is set in layoutSubviews so Core Animation
		// never rasterizes an offscreen blur on the hot path.
		layer.shadowColor = theme.shadowColor.cgColor
		layer.shadowOpacity = theme.shadowOpacity
		layer.shadowRadius = 2.5
		layer.shadowOffset = CGSize(width: 0, height: 1)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func accessibilityActivate() -> Bool {
		guard acceptsInput else { return false }
		action()
		return true
	}

	func trigger() {
		guard acceptsInput else { return }
		action()
	}

	func setInputEnabled(_ enabled: Bool) {
		guard acceptsInput != enabled else { return }
		acceptsInput = enabled
		alpha = enabled ? 1 : 0.42
		isAccessibilityElement = true
		if enabled { accessibilityTraits.remove(.notEnabled) }
		else { accessibilityTraits.insert(.notEnabled) }
	}

	func setAlternatives(_ values: [String], activation: @escaping (String) -> Void) {
		alternatives = values
		accessibilityCustomActions = values.map { value in
			UIAccessibilityCustomAction(name: value) { _ in
				activation(value)
				return true
			}
		}
	}

	override func layoutSubviews() {
		super.layoutSubviews()
		let r = isPill ? bounds.height / 2 : baseRadius     // capsule for functional keys
		CATransaction.begin(); CATransaction.setDisableActions(true)
		layer.cornerRadius = r
		gradient?.cornerRadius = r
		gradient?.frame = bounds
		dim.layer.cornerRadius = r
		dim.frame = bounds
		CATransaction.commit()
		layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: r).cgPath
	}

	private var covered = false
	func setHighlighted(_ on: Bool) {
		guard !covered else { return }            // covered wins — don't undo the recess with a highlight
		dim.backgroundColor = on ? dimColor : .clear
	}

	/// While its press balloon floats, the key hides its own glyph and sinks to a recessed
	/// slot, so only the raised balloon shows the character (Gboard / Apple behavior).
	func setCovered(_ on: Bool) {
		covered = on
		contentView?.isHidden = on
		dim.backgroundColor = on ? recessColor : .clear
	}

	static let symbolConfig = UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)

	/// Relabel a text key in place (used to switch letters between lower/upper case on a
	/// shift change, without rebuilding the view).
	func setTitle(_ text: String) {
		if label == nil {
			let newLabel = UILabel()
			newLabel.textColor = foregroundColor
			installContent(newLabel)
			label = newLabel
		}
		let bold = UIAccessibility.isBoldTextEnabled
		label?.font = text.count > 1
			? .systemFont(ofSize: 16 * glyphScale, weight: bold ? .semibold : .medium)
			: .systemFont(ofSize: 23 * glyphScale, weight: bold ? .medium : .regular)
		label?.text = text
		label?.isHidden = false
		iconView?.isHidden = true
		contentView = label
		if !spokenLabelWasExplicit { accessibilityLabel = text }
	}
	/// Swap a symbol key's glyph in place (used for shift → shift.fill → capslock.fill).
	func setSymbol(_ name: String) {
		if iconView == nil {
			let newIcon = UIImageView()
			newIcon.tintColor = foregroundColor
			installContent(newIcon)
			iconView = newIcon
		}
		iconView?.image = UIImage(systemName: name, withConfiguration: Self.symbolConfig)
		iconView?.isHidden = false
		label?.isHidden = true
		contentView = iconView
		if isShift {
			accessibilityLabel = name == "capslock.fill" ? "Caps Lock" : "Shift"
			accessibilityValue = name == "shift" ? "Off" : "On"
		}
	}

	private func installContent(_ view: UIView) {
		view.translatesAutoresizingMaskIntoConstraints = false
		addSubview(view)
		NSLayoutConstraint.activate([
			view.centerXAnchor.constraint(equalTo: centerXAnchor),
			view.centerYAnchor.constraint(equalTo: centerYAnchor)
		])
	}

	private static func spokenName(for symbol: String?) -> String? {
		switch symbol {
		case "delete.left": return "Delete"
		case "return": return "Return"
		case "shift", "shift.fill": return "Shift"
		case "capslock.fill": return "Caps Lock"
		case "face.smiling": return "Emoji"
		case "globe", "keyboard": return "Next Keyboard"
		default: return nil
		}
	}
}
