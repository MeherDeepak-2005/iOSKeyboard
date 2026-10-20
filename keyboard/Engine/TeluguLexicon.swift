// MIGRATION-FILE: planned SWIFT_IOS | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import Foundation
import os

/// Memory-mapped Telugu vocabulary, Unicode-scalar trie, and compact bi/trigram LM.
/// The pack is immutable and all lookup methods are read-only/thread-safe.
nonisolated final class TeluguLexicon {
	static let shared = TeluguLexicon()

	private static let magic = [UInt8(ascii: "K"), UInt8(ascii: "B"),
		UInt8(ascii: "T"), UInt8(ascii: "D")]
	private static let version: UInt32 = 1
	private static let noneWord = UInt16.max
	private static let headerSize = 76
	private static let wordRecordSize = 8
	private static let nodeRecordSize = 10
	private static let edgeRecordSize = 6
	private static let bigramContextSize = 10
	private static let trigramContextSize = 12
	private static let continuationSize = 6
	private static let log = Logger(subsystem: KBSettings.appGroup, category: "telugu-lexicon")

	private struct Header {
		let wordCount: Int
		let nodeCount: Int
		let edgeCount: Int
		let bigramContextCount: Int
		let bigramContinuationCount: Int
		let trigramContextCount: Int
		let trigramContinuationCount: Int
		let wordOffset: Int
		let nodeOffset: Int
		let edgeOffset: Int
		let bigramContextOffset: Int
		let bigramContinuationOffset: Int
		let trigramContextOffset: Int
		let trigramContinuationOffset: Int
		let blobOffset: Int
		let blobBytes: Int
	}

	private let data: Data?
	private let header: Header?
	let loadError: String?
	var isAvailable: Bool { data != nil && header != nil }
	var vocabularyCount: Int { header?.wordCount ?? 0 }

	init(url: URL? = KBPackResources.url(resource: "telugu_langdata", extension: "bin")) {
		guard let url else {
			data = nil
			header = nil
			loadError = "missing-language-data"
			Self.log.error("Telugu language data is missing")
			return
		}
		do {
			// Language packs are immutable for this process. Force a file mapping so a
			// larger corpus changes clean, evictable pages rather than Swift heap usage.
			let mapped = try Data(contentsOf: url, options: .alwaysMapped)
			let parsed = try Self.parseHeader(mapped)
			data = mapped
			header = parsed
			loadError = nil
		} catch {
			data = nil
			header = nil
			loadError = String(describing: error)
			Self.log.error("Telugu language data rejected: \(String(describing: error), privacy: .public)")
		}
	}

	func suggestions(prefix: String, context: [String], limit: Int = 3) -> [String] {
		guard limit > 0, let data, let header else { return [] }
		let normalized = prefix.precomposedStringWithCanonicalMapping
		if normalized.isEmpty {
			var result = contextSuggestions(context, data: data, header: header,
				limit: limit)
			if result.count < limit {
				for word in topWords(from: 0, data: data, header: header,
					limit: limit - result.count) where !result.contains(word) {
					result.append(word)
				}
			}
			return Array(result.prefix(limit))
		}
		guard let node = trieNode(for: normalized, data: data, header: header) else {
			return []
		}
		var result = topWords(from: node, data: data, header: header, limit: limit)
		if exactWordID(at: node, data: data, header: header) != nil {
			result.removeAll { $0 == normalized }
			result.insert(normalized, at: 0)
		}
		return Array(result.prefix(limit))
	}

	func contains(_ word: String) -> Bool {
		guard let data, let header,
			  let node = trieNode(for: word.precomposedStringWithCanonicalMapping,
				data: data, header: header) else { return false }
		return exactWordID(at: node, data: data, header: header) != nil
	}

	/// Small context prior used to rerank bounded transliteration candidates. It reads
	/// the same mmap continuation records as native prediction and allocates no model.
	func contextBonus(for word: String, context: [String]) -> Double {
		guard let data, let header, !context.isEmpty else { return 0 }
		let candidates = contextSuggestions(context, data: data, header: header, limit: 24)
		guard let index = candidates.firstIndex(of: word) else { return 0 }
		return max(0.25, 2.4 - log1p(Double(index)) * 0.8)
	}

	private func contextSuggestions(_ context: [String], data: Data, header: Header,
		limit: Int) -> [String] {
		let ids = context.suffix(2).map {
			wordID($0.precomposedStringWithCanonicalMapping, data: data, header: header)
		}
		if ids.count == 2, let first = ids[0], let second = ids[1] {
			let key = UInt32(first) << 16 | UInt32(second)
			if let range = trigramRange(key, data: data, header: header) {
				let words = continuationWords(range, offset: header.trigramContinuationOffset,
					data: data, header: header, limit: limit)
				if !words.isEmpty { return words }
			}
		}
		if let last = ids.last ?? nil,
		   let range = bigramRange(last, data: data, header: header) {
			return continuationWords(range, offset: header.bigramContinuationOffset,
				data: data, header: header, limit: limit)
		}
		return []
	}

	private func continuationWords(_ range: Range<Int>, offset: Int, data: Data,
		header: Header, limit: Int) -> [String] {
		var words: [String] = []
		for index in range.prefix(limit) {
			let record = offset + index * Self.continuationSize
			guard let id = data.u16(at: record),
				  let word = word(for: id, data: data, header: header) else { break }
			words.append(word)
		}
		return words
	}

	private func bigramRange(_ context: UInt16, data: Data,
		header: Header) -> Range<Int>? {
		var low = 0, high = header.bigramContextCount
		while low < high {
			let middle = (low + high) / 2
			let offset = header.bigramContextOffset + middle * Self.bigramContextSize
			guard let value = data.u16(at: offset) else { return nil }
			if value < context { low = middle + 1 } else { high = middle }
		}
		guard low < header.bigramContextCount else { return nil }
		let offset = header.bigramContextOffset + low * Self.bigramContextSize
		guard data.u16(at: offset) == context,
			  let first = data.u32(at: offset + 2), let count = data.u32(at: offset + 6) else {
			return nil
		}
		let start = Int(first), end = start + Int(count)
		guard end <= header.bigramContinuationCount else { return nil }
		return start..<end
	}

	private func trigramRange(_ context: UInt32, data: Data,
		header: Header) -> Range<Int>? {
		var low = 0, high = header.trigramContextCount
		while low < high {
			let middle = (low + high) / 2
			let offset = header.trigramContextOffset + middle * Self.trigramContextSize
			guard let value = data.u32(at: offset) else { return nil }
			if value < context { low = middle + 1 } else { high = middle }
		}
		guard low < header.trigramContextCount else { return nil }
		let offset = header.trigramContextOffset + low * Self.trigramContextSize
		guard data.u32(at: offset) == context,
			  let first = data.u32(at: offset + 4), let count = data.u32(at: offset + 8) else {
			return nil
		}
		let start = Int(first), end = start + Int(count)
		guard end <= header.trigramContinuationCount else { return nil }
		return start..<end
	}

	private func wordID(_ value: String, data: Data, header: Header) -> UInt16? {
		guard let node = trieNode(for: value, data: data, header: header) else { return nil }
		return exactWordID(at: node, data: data, header: header)
	}

	private func exactWordID(at node: Int, data: Data, header: Header) -> UInt16? {
		guard node >= 0, node < header.nodeCount,
			  let value = data.u16(at: header.nodeOffset + node * Self.nodeRecordSize + 6),
			  value != Self.noneWord, Int(value) < header.wordCount else { return nil }
		return value
	}

	private func trieNode(for value: String, data: Data, header: Header) -> Int? {
		var node = 0
		for scalar in value.unicodeScalars {
			guard scalar.value <= UInt16.max,
				  let next = child(of: node, scalar: UInt16(scalar.value),
					data: data, header: header) else { return nil }
			node = next
		}
		return node
	}

	private func child(of node: Int, scalar: UInt16, data: Data,
		header: Header) -> Int? {
		guard node >= 0, node < header.nodeCount else { return nil }
		let nodeOffset = header.nodeOffset + node * Self.nodeRecordSize
		guard let first = data.u32(at: nodeOffset),
			  let count = data.u16(at: nodeOffset + 4) else { return nil }
		var low = 0, high = Int(count)
		while low < high {
			let middle = (low + high) / 2
			let edge = header.edgeOffset + (Int(first) + middle) * Self.edgeRecordSize
			guard let value = data.u16(at: edge) else { return nil }
			if value < scalar { low = middle + 1 } else { high = middle }
		}
		guard low < Int(count) else { return nil }
		let edge = header.edgeOffset + (Int(first) + low) * Self.edgeRecordSize
		guard data.u16(at: edge) == scalar, let child = data.u32(at: edge + 2),
			  Int(child) < header.nodeCount else { return nil }
		return Int(child)
	}

	/// Best-first trie expansion. Each node stores its best descendant word ID, so
	/// obtaining three completions examines only promising branches instead of scanning
	/// an entire prefix range.
	private func topWords(from start: Int, data: Data, header: Header,
		limit: Int) -> [String] {
		guard limit > 0, start >= 0, start < header.nodeCount else { return [] }
		var frontier = [start]
		var seen = Set<UInt16>()
		var result: [String] = []
		var expanded = 0
		while result.count < limit, !frontier.isEmpty, expanded < 512 {
			frontier.sort { topWord(at: $0, data: data, header: header)
				< topWord(at: $1, data: data, header: header) }
			let node = frontier.removeFirst()
			expanded += 1
			if let terminal = exactWordID(at: node, data: data, header: header),
			   seen.insert(terminal).inserted,
			   let value = word(for: terminal, data: data, header: header) {
				result.append(value)
			}
			let nodeOffset = header.nodeOffset + node * Self.nodeRecordSize
			guard let first = data.u32(at: nodeOffset),
				  let count = data.u16(at: nodeOffset + 4) else { break }
			for index in 0..<Int(count) {
				let edge = header.edgeOffset + (Int(first) + index) * Self.edgeRecordSize
				if let child = data.u32(at: edge + 2), Int(child) < header.nodeCount,
				   topWord(at: Int(child), data: data, header: header) != Self.noneWord {
					frontier.append(Int(child))
				}
			}
		}
		return result
	}

	private func topWord(at node: Int, data: Data, header: Header) -> UInt16 {
		data.u16(at: header.nodeOffset + node * Self.nodeRecordSize + 8) ?? Self.noneWord
	}

	private func word(for id: UInt16, data: Data, header: Header) -> String? {
		guard Int(id) < header.wordCount else { return nil }
		let record = header.wordOffset + Int(id) * Self.wordRecordSize
		guard let relative = data.u32(at: record), let length = data.u16(at: record + 4) else {
			return nil
		}
		let start = header.blobOffset + Int(relative)
		let end = start + Int(length)
		guard start >= header.blobOffset,
			  end <= header.blobOffset + header.blobBytes,
			  end <= data.count else { return nil }
		return String(data: data[start..<end], encoding: .utf8)
	}

	private static func parseHeader(_ data: Data) throws -> Header {
		guard data.count >= headerSize,
			  Array(data.prefix(4)) == magic,
			  data.u32(at: 4) == version else { throw TeluguDataError.invalidHeader }
		let values = stride(from: 8, through: 72, by: 4).compactMap { data.u32(at: $0) }
		guard values.count == 17 else { throw TeluguDataError.invalidHeader }
		let header = Header(wordCount: Int(values[0]), nodeCount: Int(values[1]),
			edgeCount: Int(values[2]), bigramContextCount: Int(values[3]),
			bigramContinuationCount: Int(values[4]), trigramContextCount: Int(values[5]),
			trigramContinuationCount: Int(values[6]), wordOffset: Int(values[7]),
			nodeOffset: Int(values[8]), edgeOffset: Int(values[9]),
			bigramContextOffset: Int(values[10]), bigramContinuationOffset: Int(values[11]),
			trigramContextOffset: Int(values[12]), trigramContinuationOffset: Int(values[13]),
			blobOffset: Int(values[14]), blobBytes: Int(values[15]))
		guard header.wordCount > 0, header.wordCount <= Int(Self.noneWord),
			  header.nodeCount > 0,
			  header.wordOffset == Self.headerSize,
			  header.nodeOffset == header.wordOffset + header.wordCount * Self.wordRecordSize,
			  header.edgeOffset == header.nodeOffset + header.nodeCount * Self.nodeRecordSize,
			  header.bigramContextOffset == header.edgeOffset + header.edgeCount * Self.edgeRecordSize,
			  header.bigramContinuationOffset == header.bigramContextOffset
				+ header.bigramContextCount * Self.bigramContextSize,
			  header.trigramContextOffset == header.bigramContinuationOffset
				+ header.bigramContinuationCount * Self.continuationSize,
			  header.trigramContinuationOffset == header.trigramContextOffset
				+ header.trigramContextCount * Self.trigramContextSize,
			  header.blobOffset == header.trigramContinuationOffset
				+ header.trigramContinuationCount * Self.continuationSize,
			  header.blobOffset + header.blobBytes == data.count else {
			throw TeluguDataError.invalidOffsets
		}
		return header
	}
}

private nonisolated enum TeluguDataError: Error {
	case invalidHeader
	case invalidOffsets
}

private extension Data {
	nonisolated func u16(at offset: Int) -> UInt16? {
		guard offset >= 0, offset + 2 <= count else { return nil }
		return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
	}

	nonisolated func u32(at offset: Int) -> UInt32? {
		guard offset >= 0, offset + 4 <= count else { return nil }
		return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
			| UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
	}
}
