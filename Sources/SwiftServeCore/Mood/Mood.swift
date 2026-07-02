import Foundation

/// Swiftee's facial expression — a state machine, not decoration.
///
/// The score maps to exactly one mood; the card shows the matching sprite and
/// voice line. `idle` is the landing state and is never the result of a scan.
/// This enum is the single source of truth: sprite filenames and voice lines
/// live here so the frontend reads them straight out of the JSON.
public enum Mood: String, Codable, Sendable, CaseIterable {
    case idle
    case partyMode
    case freshSwirl
    case softSqueeze
    case meltdown
    case dayOld

    /// Sprite basename served from `/swiftee/{spriteName}.png`.
    public var spriteName: String {
        switch self {
        case .idle: "swiftee-idle"
        case .partyMode: "swiftee-party"
        case .freshSwirl: "swiftee-fresh"
        case .softSqueeze: "swiftee-squeeze"
        case .meltdown: "swiftee-melt"
        case .dayOld: "swiftee-dayold"
        }
    }

    /// What Swiftee says for this mood. Warm, encouraging, never scolding.
    public var voiceLine: String {
        switch self {
        case .idle: "Drop your Package.resolved — let's take a look."
        case .partyMode: "Immaculate. Sprinkles earned."
        case .freshSwirl: "Looking sharp — couple of easy wins."
        case .softSqueeze: "Some melt setting in. Let's tidy up."
        case .meltdown: "Starting to drip. This needs attention."
        case .dayOld: "Rough night. We'll get you cleaned up."
        }
    }

    /// Map a 0–100 score to a scored mood (never `idle`).
    public static func from(score: Int, thresholds: MoodThresholds = .default) -> Mood {
        thresholds.mood(for: score)
    }
}

/// Inclusive lower bounds for each scored band. Deliberately skewed so most real
/// projects land in `softSqueeze` on a first scan (honest, not flattering) and
/// `partyMode` is rare/earned. Configurable; these are the shipping defaults.
public struct MoodThresholds: Sendable, Equatable {
    public var partyMin: Int   // 95–100  partyMode
    public var freshMin: Int   // 80–94   freshSwirl
    public var softMin: Int    // 55–79   softSqueeze
    public var meltMin: Int    // 30–54   meltdown
    // below meltMin              0–29    dayOld

    public init(partyMin: Int, freshMin: Int, softMin: Int, meltMin: Int) {
        self.partyMin = partyMin
        self.freshMin = freshMin
        self.softMin = softMin
        self.meltMin = meltMin
    }

    public static let `default` = MoodThresholds(partyMin: 95, freshMin: 80, softMin: 55, meltMin: 30)

    public func mood(for score: Int) -> Mood {
        let s = max(0, min(100, score))
        if s >= partyMin { return .partyMode }
        if s >= freshMin { return .freshSwirl }
        if s >= softMin { return .softSqueeze }
        if s >= meltMin { return .meltdown }
        return .dayOld
    }
}
