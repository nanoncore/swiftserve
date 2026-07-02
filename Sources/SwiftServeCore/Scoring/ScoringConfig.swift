import Foundation

/// Tunable knobs for the scorer. Everything here is configurable; the static
/// `.default` ships the v1 rubric weights and the deliberately-skewed baselines.
public struct ScoringConfig: Sendable, Equatable {

    /// Composite weights across the six rubric dimensions. Should sum to 1.0.
    public struct Weights: Sendable, Equatable {
        public var maintenance: Double
        public var staleness: Double
        public var busFactor: Double
        public var swift6: Double
        public var hygiene: Double
        public var license: Double

        public init(maintenance: Double, staleness: Double, busFactor: Double, swift6: Double, hygiene: Double, license: Double) {
            self.maintenance = maintenance
            self.staleness = staleness
            self.busFactor = busFactor
            self.swift6 = swift6
            self.hygiene = hygiene
            self.license = license
        }

        public static let `default` = Weights(
            maintenance: 0.30,
            staleness: 0.20,
            busFactor: 0.15,
            swift6: 0.15,
            hygiene: 0.10,
            license: 0.10
        )
    }

    public var weights: Weights
    public var thresholds: MoodThresholds

    /// Used for any dimension where there's no signal at all (e.g. a file-only
    /// scan can't know maintenance/bus-factor/swift6/license). Chosen so a clean,
    /// fully version-pinned project lands mid-`softSqueeze` — honest, not flattering.
    public var neutralBaseline: Int

    // Supply-chain hygiene (computed from pin shape + location).
    public var versionPinScore: Int     // clean release pin
    public var branchPinScore: Int      // tracks a moving branch — smell
    public var revisionPinScore: Int    // bare commit — smell
    public var nonCanonicalPenalty: Int // hosted off the common forges

    // Version staleness (file-only heuristic from the pin's shape).
    public var versionStaleness: Int    // a release pin (latest unknown without network)
    public var preReleaseStaleness: Int // a 0.x release — API may still shift
    public var unknownStaleness: Int    // branch/revision — no released version to compare

    public init(
        weights: Weights = .default,
        thresholds: MoodThresholds = .default,
        neutralBaseline: Int = 62,
        versionPinScore: Int = 90,
        branchPinScore: Int = 25,
        revisionPinScore: Int = 20,
        nonCanonicalPenalty: Int = 15,
        versionStaleness: Int = 75,
        preReleaseStaleness: Int = 55,
        unknownStaleness: Int = 40
    ) {
        self.weights = weights
        self.thresholds = thresholds
        self.neutralBaseline = neutralBaseline
        self.versionPinScore = versionPinScore
        self.branchPinScore = branchPinScore
        self.revisionPinScore = revisionPinScore
        self.nonCanonicalPenalty = nonCanonicalPenalty
        self.versionStaleness = versionStaleness
        self.preReleaseStaleness = preReleaseStaleness
        self.unknownStaleness = unknownStaleness
    }

    public static let `default` = ScoringConfig()

    /// Hosts we treat as canonical for Swift packages. Anything else gets a small
    /// hygiene nudge (a fork on a personal host is worth a second glance).
    public static let canonicalHosts: Set<String> = [
        "github.com", "www.github.com",
        "gitlab.com", "bitbucket.org",
        "git.sr.ht", "codeberg.org",
        "swift.org", "apple.com",
    ]
}
