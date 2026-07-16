import Foundation

// LanguageScorer seam (the context-prior protocol) — extracted from Keyboardengine.swift.

protocol LanguageScorer {
	/// One log-probability per candidate, same order as the input.
	func logProbs(_ candidates: [String], context: [String]) -> [Double]
	/// False while a heavyweight scorer (Core ML model) is still loading; the
	/// engine falls back to the n-gram scorer until then.
	var isReady: Bool { get }
	/// True when the prior can assign a MEANINGFUL probability to any string,
	/// including words outside the lexicon. The neural LM can (subword tokenizer:
	/// OOV is just less probable, never impossible); n-grams can't — their OOV
	/// answer is a flat unigram floor that swings with the user-model size.
	/// Precondition for the autocorrect margin gate and prediction reranking.
	var scoresArbitraryWords: Bool { get }
	/// Debug only: the per-candidate (neural, ngram) split from the most recent
	/// logProbs call, in the same order. nil when there is no neural term — lets the
	/// ranking log show both columns without a second forward pass.
	var lastSplit: (neural: [Double], ngram: [Double])? { get }
	/// One log-probability of the SAME word under several alternative contexts —
	/// the n-1 rescue's forward-evidence term logP(current | left + [C]). Declared
	/// on the seam so a neural scorer can ride all contexts in ONE batched Core ML
	/// dispatch; the default implementation just loops logProbs (fine for n-grams).
	func logProbs(of word: String, underContexts contexts: [[String]]) -> [Double]
}

extension LanguageScorer {
	var lastSplit: (neural: [Double], ngram: [Double])? { nil }
	func logProbs(of word: String, underContexts contexts: [[String]]) -> [Double] {
		contexts.map { logProbs([word], context: $0).first ?? -.infinity }
	}
}

