import Foundation
import os

nonisolated struct TransliterationCandidate: Equatable, Sendable {
	let text: String
	let score: Double
	let confidence: Double
	let fromLexicon: Bool
}

nonisolated struct RomanTeluguCandidate: Equatable, Sendable {
	let text: String
	let score: Double
	let confidence: Double
}

/// Memory-mapped Aksharantar Roman-to-Telugu lexicon (KBXL v1/v2). Unknown forms remain
/// literal; there is no hidden Swift conversion table or low-quality fallback composer.
/// Prefix rows are suggestion-only, while an exact reviewed lexicon row may be used at
/// a boundary by the existing confidence gate.
nonisolated final class TenglishTransliterator {
	static let shared = TenglishTransliterator()

	private static let headerSize = 32
	private static let headerWithLMSize = 64
	private static let bigramContextSize = 10
	private static let trigramContextSize = 12
	private static let continuationSize = 6
	private static let log = Logger(subsystem: KBSettings.appGroup, category: "tenglish-pack")

	private struct Header {
		let version: Int
		let keyCount: Int
		let variantCount: Int
		let keyOffset: Int
		let variantOffset: Int
		let blobOffset: Int
		let blobBytes: Int
		let keyRecordSize: Int
		let variantRecordSize: Int
		let bigramContextOffset: Int
		let bigramContextCount: Int
		let bigramContinuationOffset: Int
		let bigramContinuationCount: Int
		let trigramContextOffset: Int
		let trigramContextCount: Int
		let trigramContinuationOffset: Int
		let trigramContinuationCount: Int
	}

	private let data: Data?
	private let header: Header?
	private let starterCandidates: [RomanTeluguCandidate]
	let loadError: String?
	var isAvailable: Bool { data != nil && header != nil }
	var keyCount: Int { header?.keyCount ?? 0 }

	init(url: URL? = KBPackResources.url(resource: "tenglish_lexicon", extension: "bin")) {
		guard let url else {
			data = nil
			header = nil
			starterCandidates = []
			loadError = "missing-transliteration-data"
			Self.log.error("Tenglish transliteration data is missing")
			return
		}
		do {
			// Keep the transliteration FST/LM file-backed. Only decoded result strings
			// enter the heap, and those are bounded by the requested candidate limit.
			let mapped = try Data(contentsOf: url, options: .alwaysMapped)
			let parsed = try Self.parseHeader(mapped)
			data = mapped
			header = parsed
			starterCandidates = Self.makeRomanStarters(data: mapped,
				header: parsed, limit: 24)
			loadError = nil
		} catch {
			data = nil
			header = nil
			starterCandidates = []
			loadError = String(describing: error)
			Self.log.error("Tenglish data rejected: \(String(describing: error), privacy: .public)")
		}
	}

	func candidates(for roman: String, context: [String], limit: Int = 3)
		-> [TransliterationCandidate] {
		guard limit > 0, let data, let header,
			  let query = Self.normalizeRoman(roman) else { return [] }
		var best: [String: TransliterationCandidate] = [:]
		for (variant, penalty) in Self.searchVariants(for: query) {
			for candidate in nativeCandidates(matching: variant, scorePenalty: penalty,
				data: data, header: header) {
				if let previous = best[candidate.text], previous.score >= candidate.score { continue }
				best[candidate.text] = candidate
			}
		}
		return Array(best.values.sorted {
			if $0.score != $1.score { return $0.score > $1.score }
			return $0.text < $1.text
		}.prefix(limit))
	}

	/// Latin-output suggestions from the same attested Roman key inventory. This path
	/// deliberately exposes no Telugu output and never delegates to the English LM.
	func romanCandidates(for roman: String, limit: Int = 3) -> [RomanTeluguCandidate] {
		guard limit > 0, let data, let header,
			  let query = Self.normalizeRoman(roman) else { return [] }
		let first = lowerBound(query, data: data, header: header)
		var result: [RomanTeluguCandidate] = []
		var index = first
		var scanned = 0
		while index < header.keyCount, scanned < 128 {
			guard let key = romanKey(at: index, data: data, header: header),
				  key.hasPrefix(query) else { break }
			let exact = key == query
			let weight = bestVariantWeight(at: index, data: data, header: header)
			let suffixPenalty = Double(max(0, key.count - query.count)) * 0.18
			result.append(RomanTeluguCandidate(text: key,
				score: weight + (exact ? 1.5 : 0) - suffixPenalty,
				confidence: exact ? 0.98 : 0.66))
			index += 1
			scanned += 1
		}
		return Array(result.sorted {
			if $0.score != $1.score { return $0.score > $1.score }
			return $0.text < $1.text
		}.prefix(limit))
	}

	/// Dedicated Roman Telugu prior embedded after the weighted transliteration keys.
	/// Older KBXL v1/v2 packs simply return no bonus, preserving migration compatibility.
	func romanContextBonus(for word: String, context: [String]) -> Double {
		guard let data, let header, header.version >= 3,
			let normalized = Self.normalizeRoman(word),
			let target = exactRomanKeyID(normalized, data: data, header: header),
			let range = romanContextRange(context, data: data, header: header) else { return 0 }
		for (rank, index) in range.prefix(24).enumerated() {
			let record = range.offset + index * Self.continuationSize
			guard let candidate = data.readU16(record) else { break }
			if candidate == target {
				return max(0.25, 2.4 - log1p(Double(rank)) * 0.8)
			}
		}
		return 0
	}

	func romanPredictions(context: [String], limit: Int = 3) -> [RomanTeluguCandidate] {
		guard limit > 0, let data, let header, header.version >= 3 else { return [] }
		guard let range = romanContextRange(context, data: data, header: header)
			?? bigramRange(.max, data: data, header: header).map({
				ContinuationRange(offset: header.bigramContinuationOffset, range: $0)
			}) else {
			return Array(starterCandidates.prefix(limit))
		}
		var result: [RomanTeluguCandidate] = []
		for (rank, index) in range.prefix(limit).enumerated() {
			let record = range.offset + index * Self.continuationSize
			guard let id = data.readU16(record),
				let word = romanKey(at: Int(id), data: data, header: header),
				let count = data.readU32(record + 2) else { break }
			result.append(RomanTeluguCandidate(text: word,
				score: log1p(Double(count)) - Double(rank) * 0.05,
				confidence: rank == 0 ? 0.82 : 0.68))
		}
		return result
	}

	private func nativeCandidates(matching query: String, scorePenalty: Double,
		data: Data, header: Header) -> [TransliterationCandidate] {
		let first = lowerBound(query, data: data, header: header)
		var result: [TransliterationCandidate] = []
		var scanned = 0
		var index = first
		while index < header.keyCount, scanned < 96 {
			guard let key = romanKey(at: index, data: data, header: header),
				  key.hasPrefix(query) else { break }
			let exact = key == query
			for candidate in variants(at: index, exact: exact, queryLength: query.count,
				keyLength: key.count, data: data, header: header) {
				result.append(TransliterationCandidate(text: candidate.text,
					score: candidate.score - scorePenalty,
					confidence: max(0, candidate.confidence - scorePenalty * 0.08),
					fromLexicon: candidate.fromLexicon))
			}
			index += 1
			scanned += 1
		}
		return result
	}

	private func bestVariantWeight(at keyIndex: Int, data: Data, header: Header) -> Double {
		let record = header.keyOffset + keyIndex * header.keyRecordSize
		guard let count = data.readU16(record + 6), count > 0,
			  let first = data.readU32(record + 8) else { return 0 }
		var best = -Double.infinity
		for offset in 0..<Int(count) {
			let variant = header.variantOffset
				+ (Int(first) + offset) * header.variantRecordSize
			if let weight = data.readFloat32(variant + 8) {
				best = max(best, Double(weight))
			}
		}
		return best.isFinite ? best : 0
	}

	private func variants(at keyIndex: Int, exact: Bool, queryLength: Int,
		keyLength: Int, data: Data, header: Header) -> [TransliterationCandidate] {
		let record = header.keyOffset + keyIndex * header.keyRecordSize
		guard let count = data.readU16(record + 6),
			  let first = data.readU32(record + 8),
			  Int(first) + Int(count) <= header.variantCount else { return [] }
		var result: [TransliterationCandidate] = []
		for offset in 0..<Int(count) {
			let variant = header.variantOffset
				+ (Int(first) + offset) * header.variantRecordSize
			guard let relative = data.readU32(variant),
				  let length = data.readU16(variant + 4),
				  let weight = data.readFloat32(variant + 8) else { continue }
			let start = header.blobOffset + Int(relative)
			let end = start + Int(length)
			guard start >= header.blobOffset,
				  end <= header.blobOffset + header.blobBytes,
				  let output = String(data: data[start..<end], encoding: .utf8) else { continue }
			let completionPenalty = exact ? 0 : Double(max(0, keyLength - queryLength)) * 0.18
			result.append(TransliterationCandidate(
				text: output.precomposedStringWithCanonicalMapping,
				score: Double(weight) + (exact ? 1.5 : 0) - completionPenalty,
				confidence: exact ? min(0.99, 0.92 + Double(max(weight, 0)) * 0.01) : 0.64,
				fromLexicon: true
			))
		}
		return result
	}

	private func lowerBound(_ query: String, data: Data, header: Header) -> Int {
		var low = 0, high = header.keyCount
		while low < high {
			let middle = (low + high) / 2
			guard let value = romanKey(at: middle, data: data, header: header) else {
				return header.keyCount
			}
			if value < query { low = middle + 1 } else { high = middle }
		}
		return low
	}

	private func exactRomanKeyID(_ query: String, data: Data, header: Header) -> UInt16? {
		let index = lowerBound(query, data: data, header: header)
		guard index < header.keyCount,
			romanKey(at: index, data: data, header: header) == query else { return nil }
		return UInt16(index)
	}

	private struct ContinuationRange {
		let offset: Int
		let range: Range<Int>

		func prefix(_ limit: Int) -> Range<Int> {
			range.lowerBound..<min(range.upperBound, range.lowerBound + limit)
		}
	}

	private func romanContextRange(_ context: [String], data: Data,
		header: Header) -> ContinuationRange? {
		let suffix = context.suffix(2).map {
			Self.normalizeRoman($0).flatMap {
				exactRomanKeyID($0, data: data, header: header)
			}
		}
		if suffix.count == 2, let first = suffix[0], let second = suffix[1],
			let range = trigramRange(UInt32(first) << 16 | UInt32(second),
				data: data, header: header) {
			return ContinuationRange(offset: header.trigramContinuationOffset, range: range)
		}
		guard let last = suffix.last ?? nil,
			let range = bigramRange(last, data: data, header: header) else { return nil }
		return ContinuationRange(offset: header.bigramContinuationOffset, range: range)
	}

	private func bigramRange(_ context: UInt16, data: Data,
		header: Header) -> Range<Int>? {
		var low = 0, high = header.bigramContextCount
		while low < high {
			let middle = (low + high) / 2
			let record = header.bigramContextOffset + middle * Self.bigramContextSize
			guard let value = data.readU16(record) else { return nil }
			if value < context { low = middle + 1 } else { high = middle }
		}
		guard low < header.bigramContextCount else { return nil }
		let record = header.bigramContextOffset + low * Self.bigramContextSize
		guard data.readU16(record) == context,
			let first = data.readU32(record + 2), let count = data.readU32(record + 6),
			Int(first) + Int(count) <= header.bigramContinuationCount else { return nil }
		return Int(first)..<(Int(first) + Int(count))
	}

	private func trigramRange(_ context: UInt32, data: Data,
		header: Header) -> Range<Int>? {
		var low = 0, high = header.trigramContextCount
		while low < high {
			let middle = (low + high) / 2
			let record = header.trigramContextOffset + middle * Self.trigramContextSize
			guard let value = data.readU32(record) else { return nil }
			if value < context { low = middle + 1 } else { high = middle }
		}
		guard low < header.trigramContextCount else { return nil }
		let record = header.trigramContextOffset + low * Self.trigramContextSize
		guard data.readU32(record) == context,
			let first = data.readU32(record + 4), let count = data.readU32(record + 8),
			Int(first) + Int(count) <= header.trigramContinuationCount else { return nil }
		return Int(first)..<(Int(first) + Int(count))
	}

	private func romanKey(at index: Int, data: Data, header: Header) -> String? {
		guard index >= 0, index < header.keyCount else { return nil }
		let record = header.keyOffset + index * header.keyRecordSize
		guard let relative = data.readU32(record), let length = data.readU16(record + 4) else {
			return nil
		}
		let start = header.blobOffset + Int(relative)
		let end = start + Int(length)
		guard start >= header.blobOffset,
			  end <= header.blobOffset + header.blobBytes else { return nil }
		return String(data: data[start..<end], encoding: .utf8)
	}

	private static func normalizeRoman(_ value: String) -> String? {
		let normalized = value.lowercased()
			.replacingOccurrences(of: "’", with: "'")
			.replacingOccurrences(of: "‘", with: "'")
			.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
		guard (1...48).contains(normalized.count),
			  normalized.unicodeScalars.allSatisfy({
				$0.isASCII && (CharacterSet.letters.contains($0) || $0 == "'")
			  }) else { return nil }
		return normalized
	}

	/// The current bootstrap corpus has very sparse Roman context tables. Keep a tiny
	/// immutable starter list derived from the highest-confidence attested forms so an
	/// unknown context does not leave the strip empty. This scan runs once at pack load.
	private static func makeRomanStarters(data: Data, header: Header,
		limit: Int) -> [RomanTeluguCandidate] {
		var best: [RomanTeluguCandidate] = []
		best.reserveCapacity(limit + 1)
		for index in 0..<header.keyCount {
			let keyRecord = header.keyOffset + index * header.keyRecordSize
			guard let relative = data.readU32(keyRecord),
				let length = data.readU16(keyRecord + 4),
				let variantCount = data.readU16(keyRecord + 6), variantCount > 0,
				let firstVariant = data.readU32(keyRecord + 8) else { continue }
			let start = header.blobOffset + Int(relative)
			let end = start + Int(length)
			guard start >= header.blobOffset,
				end <= header.blobOffset + header.blobBytes,
				let key = String(data: data[start..<end], encoding: .utf8) else { continue }
			var weight = -Double.infinity
			for offset in 0..<Int(variantCount) {
				let variant = header.variantOffset
					+ (Int(firstVariant) + offset) * header.variantRecordSize
				if let value = data.readFloat32(variant + 8) {
					weight = max(weight, Double(value))
				}
			}
			guard weight.isFinite else { continue }
			best.append(RomanTeluguCandidate(text: key, score: weight,
				confidence: weight >= 8 ? 0.82 : 0.62))
			best.sort {
				if $0.score != $1.score { return $0.score > $1.score }
				return $0.text < $1.text
			}
			if best.count > limit { best.removeLast(best.count - limit) }
		}
		return best
	}

	/// Bounded weighted arcs for common conversational spelling equivalences. Exact
	/// attested forms always win; these alternatives only recover a missing alias and
	/// never run as fuzzy safety filtering.
	private static func searchVariants(for query: String) -> [(String, Double)] {
		var result: [(String, Double)] = [(query, 0)]
		var seen = Set([query])
		func add(_ value: String, penalty: Double) {
			guard value != query, seen.insert(value).inserted else { return }
			result.append((value, penalty))
		}
		for (source, target, penalty) in [
			("dh", "d", 0.32), ("th", "t", 0.38), ("bh", "b", 0.42),
			("ph", "p", 0.42), ("kh", "k", 0.42), ("gh", "g", 0.42),
			("aa", "a", 0.28), ("ee", "i", 0.34), ("oo", "u", 0.34),
		] where query.contains(source) {
			add(query.replacingOccurrences(of: source, with: target), penalty: penalty)
		}
		return Array(result.prefix(8))
	}

	private static func parseHeader(_ data: Data) throws -> Header {
		guard data.count >= headerSize,
			  Array(data.prefix(4)) == [UInt8(ascii: "K"), UInt8(ascii: "B"),
				UInt8(ascii: "X"), UInt8(ascii: "L")],
			  let version = data.readU32(4), (1...3).contains(version),
			  let keyCount = data.readU32(8), let variantCount = data.readU32(12),
			  let keyOffset = data.readU32(16), let variantOffset = data.readU32(20),
			  let blobOffset = data.readU32(24), let blobBytes = data.readU32(28) else {
			throw TenglishDataError.invalidHeader
		}
		let keyRecordSize = version == 1 ? 16 : 12
		let variantRecordSize = version == 1 ? 16 : 12
		let hasLM = version >= 3
		guard !hasLM || data.count >= headerWithLMSize else {
			throw TenglishDataError.invalidHeader
		}
		let header = Header(version: Int(version), keyCount: Int(keyCount),
			variantCount: Int(variantCount),
			keyOffset: Int(keyOffset), variantOffset: Int(variantOffset),
			blobOffset: Int(blobOffset), blobBytes: Int(blobBytes),
			keyRecordSize: keyRecordSize, variantRecordSize: variantRecordSize,
			bigramContextOffset: Int(data.readU32(32) ?? 0),
			bigramContextCount: Int(data.readU32(36) ?? 0),
			bigramContinuationOffset: Int(data.readU32(40) ?? 0),
			bigramContinuationCount: Int(data.readU32(44) ?? 0),
			trigramContextOffset: Int(data.readU32(48) ?? 0),
			trigramContextCount: Int(data.readU32(52) ?? 0),
			trigramContinuationOffset: Int(data.readU32(56) ?? 0),
			trigramContinuationCount: Int(data.readU32(60) ?? 0))
		guard header.keyCount > 0, header.variantCount > 0,
			  header.keyCount <= Int(UInt16.max) - 1,
			  header.keyOffset == (hasLM ? Self.headerWithLMSize : Self.headerSize),
			  header.variantOffset == header.keyOffset
				+ header.keyCount * header.keyRecordSize,
			  header.blobOffset == header.variantOffset
				+ header.variantCount * header.variantRecordSize else {
			throw TenglishDataError.invalidOffsets
		}
		if hasLM {
			guard header.bigramContextOffset == header.blobOffset + header.blobBytes,
				header.bigramContinuationOffset == header.bigramContextOffset
					+ header.bigramContextCount * Self.bigramContextSize,
				header.trigramContextOffset == header.bigramContinuationOffset
					+ header.bigramContinuationCount * Self.continuationSize,
				header.trigramContinuationOffset == header.trigramContextOffset
					+ header.trigramContextCount * Self.trigramContextSize,
				header.trigramContinuationOffset
					+ header.trigramContinuationCount * Self.continuationSize == data.count else {
				throw TenglishDataError.invalidOffsets
			}
		} else if header.blobOffset + header.blobBytes != data.count {
			throw TenglishDataError.invalidOffsets
		}
		return header
	}
}

private nonisolated enum TenglishDataError: Error {
	case invalidHeader
	case invalidOffsets
}

private extension Data {
	nonisolated func readU16(_ offset: Int) -> UInt16? {
		guard offset >= 0, offset + 2 <= count else { return nil }
		return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
	}

	nonisolated func readU32(_ offset: Int) -> UInt32? {
		guard offset >= 0, offset + 4 <= count else { return nil }
		return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
			| UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
	}

	nonisolated func readFloat32(_ offset: Int) -> Float? {
		readU32(offset).map { Float(bitPattern: $0) }
	}
}
