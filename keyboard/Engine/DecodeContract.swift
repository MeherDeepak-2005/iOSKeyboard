import Foundation

/// Immutable identity for one decoder request. A result may be presented or committed
/// only while every revision still matches the controller's current document state.
struct DecodeRequest: Equatable {
	let fieldRevision: UInt64
	let documentRevision: UInt64
	let wordSessionID: UInt64
	let generation: UInt64
	let layoutRevision: UInt64
	let currentWord: String
	let context: [String]
	let taps: [KeyTap?]?
}

enum DecodeModelTier: String, Equatable {
	case ngram
}

struct DecodeCandidateEvidence: Equatable {
	let word: String
	let score: Double
	let spatialCost: Double
	let logFrequency: Double
	let logLanguageProbability: Double
}

/// One authoritative answer for a request. `suggestions.first` is always the center
/// suggestion. If `correction` is non-nil it is also `suggestions.first`, so a boundary
/// can never commit a word different from the primary word the user just saw.
struct DecodeSnapshot: Equatable {
	let request: DecodeRequest
	let suggestions: [String]
	let candidates: [DecodeCandidateEvidence]
	let correction: String?
	let confidence: Double
	let nextCharacterPriors: [Character: Double]
	let modelTier: DecodeModelTier
	let completedAtUptime: TimeInterval

	func isValid(for current: DecodeRequest) -> Bool {
		request == current
	}
}
