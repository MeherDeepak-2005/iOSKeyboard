// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import Foundation
import CryptoKit

nonisolated enum LanguagePackHealthState: String, Codable, Equatable, Sendable {
	case ready
	case missingResource
	case invalidSchemaOrHeader
	case hashMismatch
	case appExtensionBuildMismatch
}

nonisolated struct LanguagePackHealth: Codable, Equatable, Sendable {
	let languageMode: KBLanguageMode
	let state: LanguagePackHealthState
	let detail: String
	let marketingVersion: String
	let buildVersion: String
	let packIdentifier: String?
	let packVersion: Int?
	let resourceHashes: [String: String]

	var isReady: Bool { state == .ready }

	var conciseDetail: String {
		switch state {
		case .ready: return languageMode.detail
		case .missingResource: return "Missing keyboard resource"
		case .invalidSchemaOrHeader: return "Invalid language pack"
		case .hashMismatch: return "Language pack integrity failed"
		case .appExtensionBuildMismatch: return "Keyboard extension needs refresh"
		}
	}

	var packSignature: String {
		let hashes = resourceHashes.sorted { $0.key < $1.key }
			.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
		return "\(packIdentifier ?? "none")|\(packVersion ?? 0)|\(hashes)"
	}

	func replacingState(_ state: LanguagePackHealthState, detail: String) -> LanguagePackHealth {
		LanguagePackHealth(languageMode: languageMode, state: state, detail: detail,
			marketingVersion: marketingVersion, buildVersion: buildVersion,
			packIdentifier: packIdentifier, packVersion: packVersion,
			resourceHashes: resourceHashes)
	}
}

nonisolated struct KeyboardExtensionLanguageReport: Codable, Equatable, Sendable {
	let observedAt: Date
	let marketingVersion: String
	let buildVersion: String
	let healthByLanguage: [String: LanguagePackHealth]
}

nonisolated struct LanguagePackResourceSet: Sendable {
	let manifestURL: URL?
	let layoutURL: URL?
	let teluguLanguageDataURL: URL?
	let tenglishLexiconURL: URL?

	static var bundled: LanguagePackResourceSet {
		LanguagePackResourceSet(
			manifestURL: KBPackResources.url(resource: "telugu_pack_manifest", extension: "json"),
			layoutURL: KBPackResources.url(resource: "telugu_layout", extension: "kbpack"),
			teluguLanguageDataURL: KBPackResources.url(resource: "telugu_langdata", extension: "bin"),
			tenglishLexiconURL: KBPackResources.url(resource: "tenglish_lexicon", extension: "bin")
		)
	}
}

nonisolated enum LanguagePackHealthInspector {
	private final class Cache {
		private let lock = NSLock()
		private var values: [KBLanguageMode: LanguagePackHealth] = [:]

		func value(for mode: KBLanguageMode) -> LanguagePackHealth? {
			lock.lock(); defer { lock.unlock() }
			return values[mode]
		}

		func set(_ value: LanguagePackHealth, for mode: KBLanguageMode) {
			lock.lock(); values[mode] = value; lock.unlock()
		}
	}

	private static let cache = Cache()

	static var marketingVersion: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
	}

	static var buildVersion: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
	}

	static var isExtensionProcess: Bool {
		Bundle.main.bundleURL.pathExtension == "appex"
	}

	static func bundledHealth(for mode: KBLanguageMode) -> LanguagePackHealth {
		if let cached = cache.value(for: mode) { return cached }
		let inspected = inspect(mode: mode, resources: .bundled,
			marketingVersion: marketingVersion, buildVersion: buildVersion)
		cache.set(inspected, for: mode)
		return inspected
	}

	static func inspect(mode: KBLanguageMode, resources: LanguagePackResourceSet,
		marketingVersion: String = "test", buildVersion: String = "test") -> LanguagePackHealth {
		if mode == .english {
			return health(mode, .ready, "English resources are built in.", marketingVersion,
				buildVersion, nil, nil, [:])
		}
		guard let manifestURL = resources.manifestURL,
			  let manifestData = try? Data(contentsOf: manifestURL),
			  let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
		else {
			return health(mode, .missingResource, "telugu_pack_manifest.json is missing or unreadable.",
				marketingVersion, buildVersion, nil, nil, [:])
		}
		guard let schemaVersion = manifest["schema_version"] as? Int,
			  [1, 2].contains(schemaVersion),
			  let identifier = manifest["identifier"] as? String,
			  let version = manifest["version"] as? Int,
			  let artifacts = manifest["artifacts"] as? [String: Any]
		else {
			return health(mode, .invalidSchemaOrHeader,
				"The language-pack manifest has an unsupported schema or missing identity.",
				marketingVersion, buildVersion, nil, nil, [:])
		}

		let required: [(manifestKey: String, name: String, url: URL?)]
		switch mode {
		case .tenglishToTelugu:
			required = [
				("transliteration_lexicon", "tenglish_lexicon.bin",
					resources.tenglishLexiconURL),
				("language_model", "telugu_langdata.bin",
					resources.teluguLanguageDataURL),
			]
		case .romanTelugu:
			required = [("transliteration_lexicon", "tenglish_lexicon.bin",
				resources.tenglishLexiconURL)]
		case .telugu:
			required = [
				("layout", "telugu_layout.kbpack", resources.layoutURL),
				("language_model", "telugu_langdata.bin", resources.teluguLanguageDataURL),
			]
		case .english:
			required = []
		}

		var hashes: [String: String] = [:]
		for resource in required {
			guard let url = resource.url else {
				return health(mode, .missingResource, "\(resource.name) is missing from this target.",
					marketingVersion, buildVersion, identifier, version, hashes)
			}
			guard let record = artifacts[resource.manifestKey] as? [String: Any],
				  let expectedHash = record["sha256"] as? String,
				  let expectedBytes = record["bytes"] as? Int,
				  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
				  let byteCount = (attributes[.size] as? NSNumber)?.intValue,
				  let actualHash = sha256(url)
			else {
				return health(mode, .invalidSchemaOrHeader,
					"The manifest record for \(resource.name) is invalid.", marketingVersion,
					buildVersion, identifier, version, hashes)
			}
			hashes[resource.name] = actualHash
			guard byteCount == expectedBytes, actualHash == expectedHash.lowercased() else {
				return health(mode, .hashMismatch,
					"\(resource.name) does not match the reviewed language-pack manifest.",
					marketingVersion, buildVersion, identifier, version, hashes)
			}
		}

		switch mode {
		case .english:
			break
		case .tenglishToTelugu:
			let transliterator = TenglishTransliterator(url: resources.tenglishLexiconURL)
			guard transliterator.isAvailable else {
				return health(mode, .invalidSchemaOrHeader,
					"Tenglish lexicon rejected: \(transliterator.loadError ?? "unknown header error")",
					marketingVersion, buildVersion, identifier, version, hashes)
			}
			let lexicon = TeluguLexicon(url: resources.teluguLanguageDataURL)
			guard lexicon.isAvailable else {
				return health(mode, .invalidSchemaOrHeader,
					"Telugu context model rejected: \(lexicon.loadError ?? "unknown header error")",
					marketingVersion, buildVersion, identifier, version, hashes)
			}
		case .romanTelugu:
			let transliterator = TenglishTransliterator(url: resources.tenglishLexiconURL)
			guard transliterator.isAvailable else {
				return health(mode, .invalidSchemaOrHeader,
					"Tenglish lexicon rejected: \(transliterator.loadError ?? "unknown header error")",
					marketingVersion, buildVersion, identifier, version, hashes)
			}
		case .telugu:
			let layout = TeluguLanguagePack(url: resources.layoutURL)
			guard layout.isAvailable else {
				return health(mode, .invalidSchemaOrHeader,
					"Telugu layout rejected: \(layout.loadError ?? "unknown schema error")",
					marketingVersion, buildVersion, identifier, version, hashes)
			}
			let lexicon = TeluguLexicon(url: resources.teluguLanguageDataURL)
			guard lexicon.isAvailable else {
				return health(mode, .invalidSchemaOrHeader,
					"Telugu lexicon rejected: \(lexicon.loadError ?? "unknown header error")",
					marketingVersion, buildVersion, identifier, version, hashes)
			}
		}
		return health(mode, .ready, "\(mode.displayName) pack \(version) is ready.",
			marketingVersion, buildVersion, identifier, version, hashes)
	}

	private static func health(_ mode: KBLanguageMode, _ state: LanguagePackHealthState,
		_ detail: String, _ marketingVersion: String, _ buildVersion: String,
		_ identifier: String?, _ version: Int?, _ hashes: [String: String]) -> LanguagePackHealth {
		LanguagePackHealth(languageMode: mode, state: state, detail: detail,
			marketingVersion: marketingVersion, buildVersion: buildVersion,
			packIdentifier: identifier, packVersion: version, resourceHashes: hashes)
	}

	private static func sha256(_ url: URL) -> String? {
		guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
		return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}
