import UIKit
import CoreText

// Runtime font registration — extracted from Keyboard.swift.

enum FontInstaller {
	private static var done = false

	/// Register EVERY bundled font. Used by the APP (its Fonts page previews all of
	/// them). Do not call from the extension — see registerSelectedFont.
	static func registerBundledFonts() {
		guard !done else { return }
		done = true
		let bundle = Bundle(for: KeyboardView.self)   // the target that owns this code
		for ext in ["ttf", "otf"] {
			for url in bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
				CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
			}
		}
	}

	/// Register ONLY the font the user picked. The keyboard extension renders a single
	/// font at a time, so loading the others just burns its tight memory budget. (iOS
	/// On-Demand Resources aren't available to app extensions — NSBundleResourceRequest
	/// is app-only — so selective registration is the mechanism; the files still ship
	/// in the bundle, they're simply not mapped into the font system.) A system-design
	/// font has no file to load, so this registers nothing.
	static func registerSelectedFont() {
		guard !done else { return }
		done = true
		guard let token = KBSettings.font.fileToken else { return }
		let bundle = Bundle(for: KeyboardView.self)
		for ext in ["ttf", "otf"] {
			for url in bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
			where url.lastPathComponent.range(of: token, options: .caseInsensitive) != nil {
				CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
			}
		}
	}
}

