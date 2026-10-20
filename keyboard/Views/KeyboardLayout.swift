// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import Foundation
import os

/// Semantic output from a visible key. Script data supplies the literal values;
/// Swift only decides whether that value can be appended to the current cluster.
nonisolated enum KeyOutput: Equatable, Sendable {
	case text(String)
	case teluguConsonant(String)
	case teluguVowel(independent: String, dependent: String?)
	case teluguDependentVowel(String)
	case teluguMark(String)
	case teluguVirama(String)

	var literal: String {
		switch self {
		case .text(let value), .teluguConsonant(let value),
			 .teluguDependentVowel(let value), .teluguMark(let value),
			 .teluguVirama(let value):
			return value
		case .teluguVowel(let independent, _):
			return independent
		}
	}
}

nonisolated struct KeyboardKeyDescriptor: Equatable, Sendable {
	let label: String
	let accessibilityLabel: String
	let output: KeyOutput
	let alternatives: [String]

	init(_ label: String, accessibilityLabel: String? = nil, output: KeyOutput? = nil,
		 alternatives: [String] = []) {
		self.label = label
		self.accessibilityLabel = accessibilityLabel ?? label
		self.output = output ?? .text(label)
		self.alternatives = alternatives
	}
}

nonisolated struct KeyboardPage: Equatable, Sendable {
	enum ID: String, Sendable { case alphabetic, shift, numbers }
	let id: ID
	let rows: [[KeyboardKeyDescriptor]]
}

nonisolated struct KeyboardLayoutDescriptor: Equatable, Sendable {
	let language: KBLanguageMode
	let primary: KeyboardPage
	let alternate: KeyboardPage?
	let numbers: KeyboardPage
	let bottomKeys: [KeyboardKeyDescriptor]

	static let english = KeyboardLayoutDescriptor(
		language: .english,
		primary: KeyboardPage(id: .alphabetic, rows: KB.rows.map {
			$0.map { KeyboardKeyDescriptor(String($0)) }
		}),
		alternate: nil,
		numbers: KeyboardPage(id: .numbers, rows: []),
		bottomKeys: []
	)

	/// An invalid or missing signed resource fails closed. The settings/controller
	/// resolves such a mode back to English before constructing a KeyboardView.
	private static let unavailableTelugu = KeyboardLayoutDescriptor(
		language: .telugu,
		primary: KeyboardPage(id: .alphabetic, rows: [[], [], [], [], []]),
		alternate: nil,
		numbers: KeyboardPage(id: .numbers, rows: []),
		bottomKeys: []
	)

	static var telugu: KeyboardLayoutDescriptor {
		TeluguLanguagePack.shared.layout ?? unavailableTelugu
	}

	static func forMode(_ mode: KBLanguageMode) -> KeyboardLayoutDescriptor {
		mode == .telugu ? .telugu : .english
	}
}

nonisolated struct TeluguPackMetadata: Equatable, Sendable {
	let identifier: String
	let version: Int
	let locale: String
	let normalization: String
	let releaseStatus: String
	let nativeSpeakerReviewed: Bool
	let sourceName: String
	let sourceURL: String
	let reviewNote: String
}

nonisolated struct TeluguCompositionRules: Sendable {
	let scriptRanges: [ClosedRange<UInt32>]
	let consonants: Set<UInt32>
	let dependentVowelSigns: Set<UInt32>
	let marks: Set<UInt32>
	let virama: UInt32
	let joiners: Set<UInt32>

	func isScriptScalar(_ scalar: UnicodeScalar) -> Bool {
		scriptRanges.contains { $0.contains(scalar.value) } || joiners.contains(scalar.value)
	}

	func isConsonant(_ scalar: UnicodeScalar) -> Bool {
		consonants.contains(scalar.value)
	}

	func isDependentVowel(_ scalar: UnicodeScalar) -> Bool {
		dependentVowelSigns.contains(scalar.value)
	}

	func isMark(_ scalar: UnicodeScalar) -> Bool {
		marks.contains(scalar.value)
	}

	func output(for value: String) -> KeyOutput {
		let normalized = value.precomposedStringWithCanonicalMapping
		let scalars = normalized.unicodeScalars
		if scalars.count == 1, let scalar = scalars.first {
			if isConsonant(scalar) { return .teluguConsonant(normalized) }
			if scalar.value == virama { return .teluguVirama(normalized) }
			if isDependentVowel(scalar) { return .teluguDependentVowel(normalized) }
			if isMark(scalar) { return .teluguMark(normalized) }
		}
		if scalars.first?.value == virama { return .teluguMark(normalized) }
		return .text(normalized)
	}
}

/// Locates signed resources in either the containing app or the keyboard extension.
/// The same helper is used by tests, where `Bundle.main` may be the XCTest bundle.
nonisolated enum KBPackResources {
	private final class BundleToken {}

	static func url(resource: String, extension fileExtension: String) -> URL? {
		var bundles = [Bundle.main, Bundle(for: BundleToken.self)]
		bundles.append(contentsOf: Bundle.allFrameworks)
		bundles.append(contentsOf: Bundle.allBundles)
		var visited = Set<String>()
		for bundle in bundles where visited.insert(bundle.bundlePath).inserted {
			if let url = bundle.url(forResource: resource, withExtension: fileExtension) {
				return url
			}
		}
		return nil
	}
}

/// Immutable binary layout/composition pack. It is decoded once (about 5 KB) and
/// contains every Telugu glyph, accessibility name, and Unicode composition class.
nonisolated final class TeluguLanguagePack {
	static let shared = TeluguLanguagePack()

	let layout: KeyboardLayoutDescriptor?
	let composition: TeluguCompositionRules?
	let metadata: TeluguPackMetadata?
	let loadError: String?
	var isAvailable: Bool { layout != nil && composition != nil }

	private static let log = Logger(subsystem: KBSettings.appGroup, category: "telugu-pack")

	init(url: URL? = KBPackResources.url(resource: "telugu_layout", extension: "kbpack")) {
		guard let url else {
			layout = nil
			composition = nil
			metadata = nil
			loadError = "missing-layout-resource"
			Self.log.error("Telugu layout resource is missing")
			return
		}
		do {
			let data = try Data(contentsOf: url, options: [.mappedIfSafe])
			let document = try PropertyListDecoder().decode(LayoutDocument.self, from: data)
			let loaded = try document.materialize()
			layout = loaded.layout
			composition = loaded.composition
			metadata = loaded.metadata
			loadError = nil
		} catch {
			layout = nil
			composition = nil
			metadata = nil
			loadError = String(describing: error)
			Self.log.error("Telugu layout rejected: \(String(describing: error), privacy: .public)")
		}
	}
}

private nonisolated enum LayoutPackError: Error {
	case unsupportedSchema(Int)
	case invalidMetadata
	case invalidComposition
	case missingPage(String)
	case invalidRows(String)
	case invalidKey(String)
}

private nonisolated struct LayoutDocument: Decodable {
	let schemaVersion: Int
	let identifier: String
	let version: Int
	let locale: String
	let normalization: String
	let releaseStatus: String
	let nativeSpeakerReviewed: Bool
	let source: SourceDocument
	let composition: CompositionDocument
	let pages: [PageDocument]
	let bottomKeys: [KeyDocument]?

	struct SourceDocument: Decodable {
		let name: String
		let url: String
		let cldrURL: String
		let note: String
	}

	struct CompositionDocument: Decodable {
		let scriptRanges: [[UInt32]]
		let consonants: [UInt32]
		let dependentVowelSigns: [UInt32]
		let marks: [UInt32]
		let virama: UInt32
		let joiners: [UInt32]
	}

	struct PageDocument: Decodable {
		let id: String
		let rows: [[KeyDocument]]
	}

	struct KeyDocument: Decodable {
		let label: String
		let accessibilityLabel: String
		let kind: String
		let text: String
		let dependentText: String?
		let alternatives: [String]?
	}

	func materialize() throws -> (layout: KeyboardLayoutDescriptor,
		composition: TeluguCompositionRules, metadata: TeluguPackMetadata) {
		guard schemaVersion == 1 else { throw LayoutPackError.unsupportedSchema(schemaVersion) }
		guard !identifier.isEmpty, version > 0, !locale.isEmpty, normalization == "NFC",
			  !source.name.isEmpty, URL(string: source.url) != nil else {
			throw LayoutPackError.invalidMetadata
		}
		let ranges = composition.scriptRanges.compactMap { values -> ClosedRange<UInt32>? in
			guard values.count == 2, values[0] <= values[1] else { return nil }
			return values[0]...values[1]
		}
		guard ranges.count == composition.scriptRanges.count,
			  ranges.contains(where: { $0.contains(composition.virama) }),
			  !composition.consonants.isEmpty else {
			throw LayoutPackError.invalidComposition
		}
		let rules = TeluguCompositionRules(scriptRanges: ranges,
			consonants: Set(composition.consonants),
			dependentVowelSigns: Set(composition.dependentVowelSigns),
			marks: Set(composition.marks), virama: composition.virama,
			joiners: Set(composition.joiners))

		func materializeKey(_ key: KeyDocument) throws -> KeyboardKeyDescriptor {
			let text = key.text.precomposedStringWithCanonicalMapping
			guard !key.label.isEmpty, !key.accessibilityLabel.isEmpty, !text.isEmpty,
				  text.unicodeScalars.allSatisfy(rules.isScriptScalar)
					|| text.unicodeScalars.allSatisfy({ $0.isASCII }) else {
				throw LayoutPackError.invalidKey(key.label)
			}
			let output: KeyOutput
			switch key.kind {
			case "text": output = .text(text)
			case "vowel":
				let dependent = key.dependentText?.precomposedStringWithCanonicalMapping
				guard dependent?.unicodeScalars.allSatisfy(rules.isScriptScalar) ?? true else {
					throw LayoutPackError.invalidKey(key.label)
				}
				output = .teluguVowel(independent: text, dependent: dependent)
			case "consonant":
				guard text.unicodeScalars.count == 1,
					  text.unicodeScalars.first.map(rules.isConsonant) == true else {
					throw LayoutPackError.invalidKey(key.label)
				}
				output = .teluguConsonant(text)
			case "dependentVowel":
				guard text.unicodeScalars.count == 1,
					  text.unicodeScalars.first.map(rules.isDependentVowel) == true else {
					throw LayoutPackError.invalidKey(key.label)
				}
				output = .teluguDependentVowel(text)
			case "mark": output = .teluguMark(text)
			case "virama":
				guard text.unicodeScalars.first?.value == rules.virama else {
					throw LayoutPackError.invalidKey(key.label)
				}
				output = .teluguVirama(text)
			default: throw LayoutPackError.invalidKey(key.label)
			}
			let alternatives = (key.alternatives ?? []).map {
				$0.precomposedStringWithCanonicalMapping
			}
			return KeyboardKeyDescriptor(key.label,
				accessibilityLabel: key.accessibilityLabel, output: output,
				alternatives: alternatives)
		}

		func page(_ id: KeyboardPage.ID, expectedRows: ClosedRange<Int>? = nil,
			optional: Bool = false) throws -> KeyboardPage? {
			guard let document = pages.first(where: { $0.id == id.rawValue }) else {
				if optional { return nil }
				throw LayoutPackError.missingPage(id.rawValue)
			}
			if let expectedRows, !expectedRows.contains(document.rows.count) {
				throw LayoutPackError.invalidRows(id.rawValue)
			}
			let rows = try document.rows.map { row in
				try row.map(materializeKey)
			}
			return KeyboardPage(id: id, rows: rows)
		}

		guard let primary = try page(.alphabetic, expectedRows: 3...6),
			  let numbers = try page(.numbers) else {
			throw LayoutPackError.invalidRows("required")
		}
		let alternate = try page(.shift, expectedRows: 3...6, optional: true)
		if let alternate, alternate.rows.count != primary.rows.count {
			throw LayoutPackError.invalidRows("shift")
		}
		let controls = try (bottomKeys ?? []).map(materializeKey)
		let metadata = TeluguPackMetadata(identifier: identifier, version: version,
			locale: locale, normalization: normalization, releaseStatus: releaseStatus,
			nativeSpeakerReviewed: nativeSpeakerReviewed, sourceName: source.name,
			sourceURL: source.url, reviewNote: source.note)
		return (KeyboardLayoutDescriptor(language: .telugu, primary: primary,
			alternate: alternate, numbers: numbers, bottomKeys: controls), rules, metadata)
	}
}
