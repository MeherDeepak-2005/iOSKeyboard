import UIKit
import Darwin

// MARK: - Recents (App Group-backed, shared across the frequent extension relaunches)

enum KBEmojiRecents {
	private static let key = "kb.emoji.recents"
	private static let cap = 30
	private static var store: UserDefaults { KBSettings.sharedDefaults }
	static func all() -> [String] { store.stringArray(forKey: key) ?? [] }
	static func add(_ e: String) {
		var list = all().filter { $0 != e }
		list.insert(e, at: 0)
		store.set(Array(list.prefix(cap)), forKey: key)
	}
}

enum KBEmojiVariants {
	private static let skinTones: [Unicode.Scalar] =
		(0x1F3FB...0x1F3FF).compactMap(Unicode.Scalar.init)

	static func skinToneVariants(of emoji: String) -> [String] {
		let scalars = Array(emoji.unicodeScalars)
		guard !scalars.contains(where: { (0x1F3FB...0x1F3FF).contains(Int($0.value)) }),
			  let baseIndex = scalars.firstIndex(where: { $0.properties.isEmojiModifierBase })
		else { return [] }
		return skinTones.map { tone in
			var variant = scalars
			variant.insert(tone, at: variant.index(after: baseIndex))
			return String(String.UnicodeScalarView(variant))
		}
	}
}
