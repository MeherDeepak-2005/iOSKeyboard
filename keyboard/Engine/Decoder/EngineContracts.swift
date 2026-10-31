// Public decode contracts: the request, snapshot and prior protocols the
// controller and the engine exchange.
import Foundation

nonisolated struct GlidePrediction {
	let word: String
	let alternatives: [String]
	let shapeCostByWord: [String: Double]
	let margin: Double
}

nonisolated struct GlideSessionID: Hashable, Sendable {
	let rawValue: UInt64
}

nonisolated struct GlideUpdate {
	let sessionID: GlideSessionID
	let revision: UInt64
	let prediction: GlidePrediction
}

/// Immutable correction gates. Calibration replays these exact gates against
/// captured production decisions; it never regenerates candidates from labels.
nonisolated struct CorrectionPolicy: Codable, Equatable {
    /// Native `CorrectionPolicy`: -0.5 since the channel weight became 4 (28 Oct 2026).
    var oovMargin = -0.5
    var realWordMargin = 5.0
    var closeRescueMargin = 3.0
    var closeRescueGap = 0.0
    var minimumCloseGap = 0.0
    var closeRescueMaxCost = 1.6
    static let baseline = CorrectionPolicy()
    // Frozen on development families; see correction-calibration-2026-10-19 artifacts.
    static let calibrated = CorrectionPolicy(oovMargin: 3, realWordMargin: 5,
        closeRescueMargin: 0, closeRescueGap: 0.5, minimumCloseGap: 0.25,
        closeRescueMaxCost: 1.2)
    static let severeMargin = log(10.0)
    static let looseGap = 1.0

    var nativeValues: [NSNumber] {
        [oovMargin, realWordMargin, closeRescueMargin, closeRescueGap, minimumCloseGap, closeRescueMaxCost]
            .map { NSNumber(value: $0) }
    }

    func accepts(_ evidence: CorrectionGateEvidence) -> Bool {
        KBRanking.acceptsKind(evidence.kind.rawValue, margin: evidence.typedMargin,
            gap: evidence.candidateGap.map(NSNumber.init(value:)), cost: evidence.spatialCost,
            allowsCloseRescue: evidence.allowsCloseRescue, policy: nativeValues)
    }
}

nonisolated struct CorrectionGateEvidence: Codable, Equatable {
    enum Kind: String, Codable { case realWord, close, loose, severe }
    let typed: String
    let candidate: String
    let kind: Kind
    let typedMargin: Double
    /// nil means there is no eligible runner-up. Finite values use raw commit scores.
    let candidateGap: Double?
    let spatialCost: Double
    let allowsCloseRescue: Bool
}
