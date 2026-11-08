import Foundation

/// How a liked song feels, used to start a radio in that mood.
/// Raw values double as the Claude API's enum values, so they travel unchanged.
public enum Mood: String, CaseIterable, Codable, Sendable {
    case chill, feelGood, energetic, party, romantic, sad

    public var title: String {
        switch self {
        case .chill: "Chill"
        case .feelGood: "Feel good"
        case .energetic: "Energetic"
        case .party: "Party"
        case .romantic: "Romantic"
        case .sad: "Sad"
        }
    }

    /// YT radio filter names that fit the mood, tried in order and matched case-insensitively
    /// against a radio's chips. A mood whose chips aren't offered just plays the plain radio.
    public var ytFilters: [String] {
        switch self {
        case .chill: ["Chill", "Relax"]
        case .feelGood: ["Feel good", "Upbeat"]
        case .energetic: ["Workout", "Energy", "Pump-up"]
        case .party: ["Party"]
        case .romantic: ["Romance", "Romantic"]
        case .sad: ["Sad"]
        }
    }
}
