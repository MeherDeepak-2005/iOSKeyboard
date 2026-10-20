// MIGRATION-FILE: planned CPP_CORE | See CPP_IOS_MIGRATION_PLAN.md.
// MIGRATION-NOTE: Keep current runtime behavior; destination ownership is planned only.
import Foundation

/// Bounded segmentation beam for internal neural decoding. Each hypothesis keeps
/// its consumed touch position, uncommitted words and true channel cost. The caller
/// scores the full hypothesized phrase from committed context before pruning, so
/// the recurrent LM conditions later words on earlier uncommitted words.
// MIGRATION: planned CPP_CORE | stage=policy-glide | target=MultiwordBeam
// MIGRATION-NOTE: Preserve current segmentation limits and true channel costs.
nonisolated final class MultiwordSearch {
    private var nativeSearch: KBNativeMultiword?
	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=MultiwordBeam
	// MIGRATION-NOTE: Preserve current segmentation limits and true channel costs.
	struct Hypothesis {
		let offset: Int
		let words: [String]
		let cost: Double
		let logFrequency: Double
        var native: KBMultiwordHypothesis { KBMultiwordHypothesis.make(offset: UInt(offset), words: words, cost: cost, frequency: logFrequency) }
        init(offset: Int, words: [String], cost: Double, logFrequency: Double) {
            self.offset = offset; self.words = words; self.cost = cost; self.logFrequency = logFrequency
        }
        init(native: KBMultiwordHypothesis) { offset = Int(native.offset); words = native.words; cost = native.cost; logFrequency = native.logFrequency }
		var candidate: Candidate {
			Candidate(word: words.joined(separator: " "), cost: cost, logFreq: logFrequency)
		}
	}
	private let bytes: [UInt8]
	private let taps: [KeyTap?]?
#if DEBUG || KB_REFERENCE_DECODER_YES
	private let candidates: (String, [KeyTap?]?) -> [Candidate]
	private var cache: [Range<Int>: [Candidate]] = [:]
	private static let boundaryNeighbors = Set("cvbnm".utf8)
#endif
	static let maximumWords = 3
	static let maximumTypedBytes = 24
	static let beamPerPosition = 2
	let root = Hypothesis(offset: 0, words: [], cost: 0, logFrequency: .infinity)
	var inputCount: Int { bytes.count }

    init(typed: String, taps: [KeyTap?]?, lexicon: KBGenerationLexicon) {
        bytes = Array(typed.utf8); self.taps = taps
#if DEBUG || KB_REFERENCE_DECODER_YES
        candidates = { _, _ in [] }
#endif
        let buffers = NativeTapBuffers(taps: taps, expectedCount: typed.utf8.count)
        nativeSearch = KBNativeMultiword(lexicon: lexicon, word: typed, tapOffsets: buffers?.offsets, tapValidity: buffers?.validity)
    }
    func prune(_ rows: [Hypothesis], neural: [Double], language: [Double]) -> (frontier: [Hypothesis], finished: [Candidate])? {
        guard let nativeSearch else { return nil }
        let value = nativeSearch.prune(rows.map(\.native), neural: neural.withUnsafeBytes { Data($0) }, language: language.withUnsafeBytes { Data($0) })
        return (value.frontier.map(Hypothesis.init(native:)), value.finished.map(Candidate.init(native:)))
    }

	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=MultiwordBeam
	// MIGRATION-NOTE: Preserve current segmentation limits and true channel costs.
#if DEBUG || KB_REFERENCE_DECODER_YES
	init(typed: String, taps: [KeyTap?]?, candidates: @escaping (String, [KeyTap?]?) -> [Candidate]) {
		bytes = Array(typed.utf8)
		self.taps = taps?.count == bytes.count ? taps : nil
		self.candidates = candidates
	}
#endif

	// MIGRATION: planned CPP_CORE | stage=policy-glide | target=MultiwordBeam
	// MIGRATION-NOTE: Preserve current segmentation limits and true channel costs.
	func expand(_ frontier: [Hypothesis], shouldCancel: @escaping () -> Bool) -> [Hypothesis] {
        if let nativeSearch { return nativeSearch.expand(frontier.map(\.native), shouldCancel: shouldCancel).map(Hypothesis.init(native:)) }
#if DEBUG || KB_REFERENCE_DECODER_YES
		guard bytes.count >= 4, bytes.count <= Self.maximumTypedBytes,
			bytes.allSatisfy({ ($0 >= 97 && $0 <= 122) || $0 == KB.apostrophe }) else { return [] }
		var result: [Hypothesis] = []
		for state in frontier where state.words.count < Self.maximumWords && state.offset < bytes.count {
			for end in (state.offset + 1)...min(bytes.count, state.offset + 16) {
				guard !shouldCancel() else { return [] }
				if state.words.isEmpty && end == bytes.count { continue } // single-word path already exists
				let range = state.offset..<end
				let options: [Candidate]
				if let cached = cache[range] { options = cached }
				else {
					let text = String(decoding: bytes[range], as: UTF8.self)
					let aligned = taps.map { Array($0[range]) }
					options = Array(candidates(text, aligned).filter {
						($0.word.count >= 2 || $0.word == "a" || $0.word == "i") && $0.cost <= 1.8
					}.sorted {
						let lhs = -$0.cost + 0.12 * $0.logFreq, rhs = -$1.cost + 0.12 * $1.logFreq
						return lhs == rhs ? $0.word < $1.word : lhs > rhs
					}.prefix(8))
					cache[range] = options
				}
				for word in options {
					func append(offset: Int, boundaryCost: Double) {
						let cost = state.cost + word.cost + boundaryCost
						guard cost <= 4.8 else { return }
						let words = state.words + [word.word]
						guard offset == bytes.count || words.count < Self.maximumWords else { return }
						result.append(Hypothesis(offset: offset, words: words, cost: cost,
							logFrequency: min(state.logFrequency, word.logFreq)))
					}
					append(offset: end, boundaryCost: end == bytes.count ? 0 : 1.1)
					if end + 1 < bytes.count, Self.boundaryNeighbors.contains(bytes[end]) {
						append(offset: end + 1, boundaryCost: 0.72)
					}
				}
			}
		}
		// Distinct paths to the same spelling/position differ only by channel cost.
		var unique: [String: Hypothesis] = [:]
		for state in result {
			let key = "\(state.offset):\(state.candidate.word)"
			if unique[key] == nil || state.cost < unique[key]!.cost { unique[key] = state }
		}
		return unique.values.sorted { $0.candidate.word == $1.candidate.word
			? $0.offset < $1.offset : $0.candidate.word < $1.candidate.word }
#else
        return []
#endif
	}
}
