import Foundation

// The Mac evaluator has no iOS App Group. Touch-profile persistence is unused by
// the Glide replay, but production SpatialModel.swift requires this default seam.
enum KBSettings {
    static let sharedDefaults = UserDefaults(suiteName: "kb.glide-evaluation") ?? .standard
}
