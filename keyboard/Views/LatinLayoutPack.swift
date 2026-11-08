import Foundation
import os

/// One key in a layout pack: a character key, or a control the keyboard builds itself
/// (shift, delete, page switches, globe, emoji, space, return, per-field keys).
nonisolated enum LayoutKey: Equatable, Sendable {
	enum Width: String, Decodable, Sendable { case unit, flex, modifier, utility, `return` }
	enum Control: String, Decodable, Sendable {
		case shift, delete, page, globe, emoji, space, `return`
		/// The keys the focused field asks for (email: @ and .), from `fieldExtras`.
		case fieldExtras
		/// The number pad's spare key: the decimal separator, or + on a phone pad.
		case padAuxiliary
		/// The layout locale's currency symbol ($ for en-US, ₹ for te-IN).
		case currency
	}
	enum PageTarget: String, Decodable, Sendable { case letters, numbers, symbols }

	case character(String, width: Width?, accessibilityLabel: String?)
	case control(Control, width: Width?, target: PageTarget?, label: String?)
}

nonisolated struct LayoutPage: Equatable, Sendable {
	let rows: [[LayoutKey]]
	/// nil for the number pad, whose last row is its own.
	let bottomRow: [LayoutKey]?
	/// Whether character keys offer the pack's long-press variants (the number pad's don't).
	let longPressVariants: Bool
}

/// A compiled Latin layout (`*.kbpack`, built by tools/language_packs/build_latin_layout.py
/// from a reviewable JSON source). Key order, pages, long-press variants, per-field keys
/// and the decoders' letter grid live there, not in code.
nonisolated struct LatinLayoutPack: Equatable, Sendable {
	let identifier: String
	let version: Int
	let locale: String
	let letters, numbers, symbols, numberPad: LayoutPage
	/// Letter rows in order ("qwertyuiop", …) and the visual offset of each row's first key
	/// in key pitches: the coordinate space of tap scoring and Glide decoding.
	let gridRows: [String]
	let gridRowOffsets: [Double]
	let fieldExtras: [String: [String]]
	let alternatives: [String: [String]]

	static let english: LatinLayoutPack = load(resource: "english_layout")

	static func load(resource: String) -> LatinLayoutPack {
		do {
			guard let url = KBPackResources.url(resource: resource, extension: "kbpack") else {
				throw LatinLayoutError.missingResource(resource)
			}
			return try decode(Data(contentsOf: url, options: [.mappedIfSafe]))
		} catch {
			// The pack ships inside the extension and is checked by the layout tests, so this is
			// a damaged install. Keep the keyboard usable with plain QWERTY and record it.
			Logger(subsystem: Bundle.main.bundleIdentifier ?? "keyboard", category: "layout")
				.fault("Layout \(resource, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
			assertionFailure("layout pack \(resource) rejected: \(error)")
			return .emergencyQWERTY
		}
	}

	static func decode(_ data: Data) throws -> LatinLayoutPack {
		try PropertyListDecoder().decode(LatinLayoutDocument.self, from: data).materialize()
	}

	/// Letters, digits and the controls only, for a pack that failed to load.
	static let emergencyQWERTY: LatinLayoutPack = {
		let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
		func keys(_ s: String) -> [LayoutKey] { s.map { .character(String($0), width: nil, accessibilityLabel: nil) } }
		func control(_ c: LayoutKey.Control, _ target: LayoutKey.PageTarget? = nil, _ label: String? = nil) -> LayoutKey {
			.control(c, width: nil, target: target, label: label)
		}
		let bottom = [control(.page, .letters, "ABC"), control(.globe), control(.space), control(.return)]
		let digits = LayoutPage(rows: [keys("1234567890"), [control(.delete)]], bottomRow: bottom, longPressVariants: true)
		return LatinLayoutPack(identifier: "emergency.qwerty", version: 0, locale: "en-US",
			letters: LayoutPage(rows: [keys(rows[0]), keys(rows[1]), [control(.shift)] + keys(rows[2]) + [control(.delete)]],
				bottomRow: [control(.page, .numbers, "123"), control(.globe), control(.space), control(.return)], longPressVariants: true),
			numbers: digits, symbols: digits,
			numberPad: LayoutPage(rows: [keys("123"), keys("456"), keys("789"),
				[control(.page, .letters, "ABC")] + keys("0") + [control(.delete), control(.return)]],
				bottomRow: nil, longPressVariants: false),
			gridRows: rows, gridRowOffsets: [0, 0.5, 1.5], fieldExtras: [:], alternatives: [:])
	}()

	/// The currency key's symbol for `locale` ($ for en-US, ₹ for te-IN).
	static func currencySymbol(for locale: String) -> String {
		Locale(identifier: locale).currencySymbol ?? "$"
	}
}

nonisolated enum LatinLayoutError: Error, Equatable {
	case missingResource(String)
	case unsupportedSchema
	case missingPage(String)
	case invalidKey(String)
	case invalidGrid
}

private nonisolated struct LatinLayoutDocument: Decodable {
	let schemaVersion: Int
	let format: String
	let identifier: String
	let version: Int
	let locale: String
	let letterGrid: Grid
	let pages: [Page]
	let fieldExtras: [String: [String]]
	let alternatives: [String: [String]]

	struct Grid: Decodable { let rows: [String]; let rowOffsets: [Double] }
	struct Page: Decodable {
		let id: String
		let rows: [[Key]]
		let bottomRow: [Key]?
		let longPressVariants: Bool
	}
	struct Key: Decodable {
		let key: String?
		let control: LayoutKey.Control?
		let target: LayoutKey.PageTarget?
		let label: String?
		let width: LayoutKey.Width?
		let accessibilityLabel: String?
	}

	func materialize() throws -> LatinLayoutPack {
		guard schemaVersion == 1, format == "latin-layout", version > 0 else {
			throw LatinLayoutError.unsupportedSchema
		}
		func key(_ k: Key) throws -> LayoutKey {
			switch (k.key, k.control) {
			case let (text?, nil) where !text.isEmpty:
				return .character(text, width: k.width, accessibilityLabel: k.accessibilityLabel)
			case let (nil, control?):
				if control == .page, k.target == nil || (k.label ?? "").isEmpty {
					throw LatinLayoutError.invalidKey("page")
				}
				return .control(control, width: k.width, target: k.target, label: k.label)
			default:
				throw LatinLayoutError.invalidKey(k.key ?? k.control?.rawValue ?? "?")
			}
		}
		func page(_ id: String) throws -> LayoutPage {
			guard let p = pages.first(where: { $0.id == id }), !p.rows.isEmpty else {
				throw LatinLayoutError.missingPage(id)
			}
			return LayoutPage(rows: try p.rows.map { try $0.map(key) },
				bottomRow: try p.bottomRow.map { try $0.map(key) }, longPressVariants: p.longPressVariants)
		}
		let letters = try page("letters")
		// The grid must be exactly the letters page's character keys, row by row.
		let pageRows = letters.rows.map { row in
			row.compactMap { key -> String? in
				if case .character(let text, _, _) = key { return text }
				return nil
			}.joined()
		}
		let flat = letterGrid.rows.joined()
		guard letterGrid.rows == pageRows, letterGrid.rowOffsets.count == letterGrid.rows.count,
			  flat.count == 26, Set(flat).count == 26,
			  flat.allSatisfy({ $0.isASCII && $0.isLowercase }) else {
			throw LatinLayoutError.invalidGrid
		}
		return LatinLayoutPack(identifier: identifier, version: version, locale: locale,
			letters: letters, numbers: try page("numbers"), symbols: try page("symbols"),
			numberPad: try page("numberPad"), gridRows: letterGrid.rows,
			gridRowOffsets: letterGrid.rowOffsets, fieldExtras: fieldExtras,
			alternatives: alternatives)
	}
}

/// Locates signed resources in either the containing app or the keyboard extension.
/// The same helper is used by tests, where `Bundle.main` may be the XCTest bundle.
nonisolated enum KBPackResources {
	private final class BundleToken {}

	/// Same search order as before, but lazy: the app and the keyboard find every pack in
	/// Bundle.main, so the loaded frameworks are only listed when that fails. Listing them
	/// (Bundle.allFrameworks) creates an NSBundle for each framework in the process, and the
	/// keyboard asks for a pack about a dozen times as it starts.
	static func url(resource: String, extension fileExtension: String) -> URL? {
		var visited = Set<String>()
		func search(_ bundles: [Bundle]) -> URL? {
			for bundle in bundles where visited.insert(bundle.bundlePath).inserted {
				if let url = bundle.url(forResource: resource, withExtension: fileExtension) { return url }
			}
			return nil
		}
		return search([Bundle.main, Bundle(for: BundleToken.self)])
			?? search(Bundle.allFrameworks) ?? search(Bundle.allBundles)
	}
}
