import Foundation

/// The header the Emoji, GIF and Sticker panels share.
nonisolated enum PanelHeaderStyle: String, CaseIterable, Sendable {
	/// C · Unified capsule: one 38 pt capsule, search on the left and the
	/// Emoji · GIF · Stickers switch inside its right end. 44 pt tall. The design.
	case unified
	/// A · Stacked: a full-width search capsule over an equal-thirds switch. 86 pt tall.
	/// Kept as the other arm of the A/B test.
	case stacked

	/// The arm's name in the design review and in Keyboard health.
	var arm: String { self == .unified ? "C" : "A" }
	var displayName: String { self == .unified ? "C · Unified capsule" : "A · Stacked" }
}

/// On-device A/B assignment. The first time an install asks, it is placed in one arm at
/// random and keeps it; the app can pin an arm for a moderated session. The arm and the
/// per-arm counts (Keyboard health) stay on the device and identify no one.
enum KBExperiments {
	/// Share of installs placed in the stacked arm (A); the rest get the unified capsule (C).
	static let stackedShare = 0.5

	private static let assignedKey = "kb.exp.panelHeader.assigned"
	private static let overrideKey = "kb.exp.panelHeader.override"
	/// Tests run inside the app: they use the design (C) and never assign this device an arm.
	private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
		|| NSClassFromString("XCTestCase") != nil
	private static var store: UserDefaults { KBSettings.sharedDefaults }

	/// The header this keyboard shows: the pinned arm, else the assigned one.
	static var panelHeader: PanelHeaderStyle {
		if isTestHost { return .unified }
		return panelHeaderOverride ?? assignedPanelHeader
	}

	/// An arm pinned from the app; nil follows the random assignment.
	static var panelHeaderOverride: PanelHeaderStyle? {
		get { store.string(forKey: overrideKey).flatMap(PanelHeaderStyle.init(rawValue:)) }
		set { store.set(newValue?.rawValue, forKey: overrideKey) }
	}

	/// This install's random arm, drawn once and kept.
	static var assignedPanelHeader: PanelHeaderStyle {
		if let raw = store.string(forKey: assignedKey), let style = PanelHeaderStyle(rawValue: raw) {
			return style
		}
		let style = arm(forDraw: Double.random(in: 0..<1))
		store.set(style.rawValue, forKey: assignedKey)
		return style
	}

	static func arm(forDraw draw: Double) -> PanelHeaderStyle {
		draw < stackedShare ? .stacked : .unified
	}
}
