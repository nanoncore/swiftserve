import Testing
@testable import SwiftServeCore

@Suite("Score → mood mapping")
struct MoodMappingTests {

    @Test("Maps scores to moods exactly at the band boundaries", arguments: [
        (100, Mood.partyMode),
        (95, .partyMode),
        (94, .freshSwirl),
        (80, .freshSwirl),
        (79, .softSqueeze),
        (55, .softSqueeze),
        (54, .meltdown),
        (30, .meltdown),
        (29, .dayOld),
        (0, .dayOld),
    ])
    func boundaries(score: Int, expected: Mood) {
        #expect(Mood.from(score: score) == expected)
    }

    @Test("Clamps out-of-range scores")
    func clamps() {
        #expect(Mood.from(score: -5) == .dayOld)
        #expect(Mood.from(score: 150) == .partyMode)
    }

    @Test("from(score:) never returns the landing-only idle mood")
    func neverIdle() {
        for score in 0...100 {
            #expect(Mood.from(score: score) != .idle)
        }
    }

    @Test("Every mood has a sprite and a voice line")
    func everyMoodHasAssets() {
        for mood in Mood.allCases {
            #expect(mood.spriteName.hasPrefix("swiftee-"))
            #expect(!mood.voiceLine.isEmpty)
        }
    }

    @Test("Custom thresholds shift the bands")
    func customThresholds() {
        let lenient = MoodThresholds(partyMin: 50, freshMin: 40, softMin: 30, meltMin: 20)
        #expect(Mood.from(score: 60, thresholds: lenient) == .partyMode)
        #expect(Mood.from(score: 60) == .softSqueeze) // same score, default thresholds
    }
}
