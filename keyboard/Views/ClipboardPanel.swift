import UIKit

// Clipboard panel — the full history/pins overlay. Shown by KeyboardView OVER the key
// deck at the SAME height (the emoji-page pattern), so the keyboard never grows. Rows
// insert on tap and the panel stays up (multi-paste, Gboard-style); swipe left to pin,
// per-row ✕ to delete. Text only. Add this file to BOTH targets.

final class ClipboardPanelView: UIView, UITableViewDataSource, UITableViewDelegate {
	var onPick: ((String) -> Void)?
	var onABC: (() -> Void)?
	var onNextKeyboard: (() -> Void)?

	private let theme: KeyboardTheme
	private let showsGlobe: Bool
	private let hasFullAccess: Bool
	/// Injectable for tests; nil → live KBClipboard store (mutations enabled).
	private let injectedItems: [KBClipboardItem]?
	private var pinnedItems: [KBClipboardItem] = []
	private var recentItems: [KBClipboardItem] = []

	private let table = UITableView(frame: .zero, style: .insetGrouped)
	private let bottomBar = UIView()
	private let emptyLabel = UILabel()
	private let barHeight: CGFloat = 42

	init(theme: KeyboardTheme, showsGlobe: Bool, hasFullAccess: Bool,
		 items: [KBClipboardItem]? = nil) {
		self.theme = theme
		self.showsGlobe = showsGlobe
		self.hasFullAccess = hasFullAccess
		self.injectedItems = items
		super.init(frame: .zero)
		accessibilityIdentifier = "clipboard.panel"

		table.backgroundColor = .clear
		table.dataSource = self
		table.delegate = self
		table.register(UITableViewCell.self, forCellReuseIdentifier: "c")
		table.showsVerticalScrollIndicator = false
		table.sectionHeaderTopPadding = 4
		addSubview(table)

		emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
		emptyLabel.textColor = theme.specialKeyText.withAlphaComponent(0.55)
		emptyLabel.textAlignment = .center
		emptyLabel.numberOfLines = 3
		table.backgroundView = emptyLabel

		buildBottomBar()
		addSubview(bottomBar)
		reload()
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layoutSubviews() {
		super.layoutSubviews()
		table.frame = CGRect(x: 0, y: 0, width: bounds.width,
							 height: max(0, bounds.height - barHeight))
		bottomBar.frame = CGRect(x: 0, y: bounds.height - barHeight,
								 width: bounds.width, height: barHeight)
	}

	private func reload() {
		let items = injectedItems ?? KBClipboard.all()
		pinnedItems = items.filter(\.pinned)
		recentItems = items.filter { !$0.pinned }
		if items.isEmpty {
			emptyLabel.text = hasFullAccess
				? "Nothing saved yet.\nCopy text anywhere, then tap the\nclipboard icon in the suggestion bar."
				: "Allow Full Access in Settings\nto use the clipboard."
			emptyLabel.isHidden = false
		} else {
			emptyLabel.isHidden = true
		}
		table.reloadData()
	}

	// MARK: Table

	private func items(in section: Int) -> [KBClipboardItem] {
		section == 0 ? pinnedItems : recentItems
	}

	func numberOfSections(in tv: UITableView) -> Int { 2 }
	func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { items(in: s).count }
	func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? {
		items(in: s).isEmpty ? nil : (s == 0 ? "Pinned" : "Recent")
	}

	func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
		let cell = tv.dequeueReusableCell(withIdentifier: "c", for: ip)
		let item = items(in: ip.section)[ip.row]
		var cfg = cell.defaultContentConfiguration()
		cfg.text = item.text
		cfg.textProperties.font = .systemFont(ofSize: 15)
		cfg.textProperties.color = theme.keyText
		cfg.textProperties.numberOfLines = 2
		cell.contentConfiguration = cfg
		cell.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 1, alpha: 0.65)
		cell.selectionStyle = .none
		cell.isAccessibilityElement = true
		cell.accessibilityLabel = (item.pinned ? "Pinned clipboard item. " : "Clipboard item. ") + item.text
		cell.accessibilityHint = "Inserts this text"
		// Per-row delete: a VISIBLE affordance on every clip. Swipe-to-delete alone was
		// undiscoverable, and one global "clear" is the wrong granularity — each item
		// gets its own ✕. Pin stays on swipe (a secondary, rarer action).
		cell.accessoryView = rowButton(symbol: "xmark.circle.fill",
			tint: theme.keyText.withAlphaComponent(0.35), accessibilityLabel: "Delete clipboard item") {
			[weak self] in
			guard let self else { return }
			if injectedItems == nil { KBClipboard.remove(item.text) }
			reload()
		}
		return cell
	}

	/// A 28pt tap target for a row accessory. Frame-based on purpose: `accessoryView`
	/// is sized by its frame, not Auto Layout.
	private func rowButton(symbol: String, tint: UIColor, accessibilityLabel: String,
						   action: @escaping () -> Void) -> UIButton {
		let b = UIButton(type: .system)
		b.setImage(UIImage(systemName: symbol,
			withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)), for: .normal)
		b.tintColor = tint
		b.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
		b.accessibilityLabel = accessibilityLabel
		b.addAction(UIAction { _ in action() }, for: .touchUpInside)
		return b
	}

	func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
		onPick?(items(in: ip.section)[ip.row].text)
	}

	func tableView(_ tv: UITableView, trailingSwipeActionsConfigurationForRowAt ip: IndexPath)
		-> UISwipeActionsConfiguration? {
		let item = items(in: ip.section)[ip.row]
		let pin = UIContextualAction(style: .normal, title: item.pinned ? "Unpin" : "Pin") { [weak self] _, _, done in
			if self?.injectedItems == nil { KBClipboard.togglePin(item.text) }
			self?.reload()
			done(true)
		}
		pin.backgroundColor = .systemOrange
		return UISwipeActionsConfiguration(actions: [pin])
	}

	// MARK: Bottom bar — ABC | (globe) | title

	private func buildBottomBar() {
		bottomBar.backgroundColor = theme.isDark ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.04)
		var leading: [UIButton] = [barButton(title: "ABC") { [weak self] in self?.onABC?() }]
		if showsGlobe { leading.append(barButton(symbol: "globe", accessibilityLabel: "Next Keyboard") { [weak self] in self?.onNextKeyboard?() }) }

		let title = UILabel()
		title.text = "Clipboard"
		title.font = .systemFont(ofSize: 14, weight: .semibold)
		title.textColor = theme.specialKeyText.withAlphaComponent(0.7)
		title.textAlignment = .center

		let stack = UIStackView(arrangedSubviews: leading + [title])
		stack.axis = .horizontal
		stack.spacing = 2
		stack.alignment = .fill
		title.setContentHuggingPriority(.defaultLow, for: .horizontal)   // title takes the slack
		for b in leading {
			b.setContentHuggingPriority(.required, for: .horizontal)
			b.widthAnchor.constraint(equalToConstant: 40).isActive = true
		}
		stack.translatesAutoresizingMaskIntoConstraints = false
		bottomBar.addSubview(stack)
		// bottomBar is frame-laid (layoutSubviews), so its autoresizing width is 0 on the
		// FIRST Auto Layout pass — pinning the stack to both edges while its children
		// carry required 40pt widths is unsatisfiable at width 0 and logs "Unable to
		// simultaneously satisfy constraints". Sub-required trailing lets that one pass
		// resolve silently; at real width it binds exactly as before.
		let trailing = stack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -4)
		trailing.priority = .required - 1
		NSLayoutConstraint.activate([
			stack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 4),
			trailing,
			stack.topAnchor.constraint(equalTo: bottomBar.topAnchor),
			stack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor)
		])
	}

	private func barButton(title: String? = nil, symbol: String? = nil,
						   accessibilityLabel: String? = nil,
						   action: @escaping () -> Void) -> UIButton {
		let b = UIButton(type: .system)
		if let title {
			b.setTitle(title, for: .normal)
			b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
		}
		if let symbol {
			b.setImage(UIImage(systemName: symbol,
				withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
		}
		if title == "ABC" { b.accessibilityLabel = "Letters" }
		if let accessibilityLabel { b.accessibilityLabel = accessibilityLabel }
		b.tintColor = theme.specialKeyText.withAlphaComponent(0.5)
		b.setTitleColor(theme.specialKeyText, for: .normal)
		b.addAction(UIAction { _ in action() }, for: .touchUpInside)
		return b
	}
}
