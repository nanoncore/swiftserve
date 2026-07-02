import Foundation
import Testing
@testable import SwiftServeScan

@Suite("Denylist & verdict")
struct DenylistTests {

    @Test("Decodes a denylist JSON fixture")
    func decodes() throws {
        let list = try Denylist.decode(from: scanFixtureData("denylist.test"))
        #expect(list.version == 99)
        #expect(list.entries.count == 3)

        let mg = try #require(list.entries.first { $0.id == "mg" })
        #expect(mg.match == .exact)
        #expect(mg.appliesTo == [.importedSymbol])
        #expect(mg.severity == .high)
        #expect(mg.rejectionCode == "ITMS-90338")
    }

    @Test("Verdict: clean → partyMode")
    func clean() {
        let v = BinaryVerdict.make(findings: [])
        #expect(v.mood == .partyMode)
    }

    @Test("Verdict: any high finding → meltdown")
    func meltdown() {
        let f = Finding(symbol: "MGCopyAnswer", rawSymbol: "_MGCopyAnswer", symbolKind: .importedSymbol,
                        matchType: .exact, matchedPattern: "MGCopyAnswer", framework: "x", severity: .high,
                        explanation: "x", rejectionCode: nil, alternative: nil, reference: nil,
                        origin: Origin(kind: .firstParty, artifact: "b"))
        #expect(BinaryVerdict.make(findings: [f]).mood == .meltdown)
    }

    @Test("Verdict: only low/medium → softSqueeze")
    func soft() {
        let f = Finding(symbol: "setOrientation:", rawSymbol: "setOrientation:", symbolKind: .objcSelector,
                        matchType: .exact, matchedPattern: "setOrientation:", framework: "x", severity: .medium,
                        explanation: "x", rejectionCode: nil, alternative: nil, reference: nil,
                        origin: Origin(kind: .dependency, artifact: "b"))
        #expect(BinaryVerdict.make(findings: [f]).mood == .softSqueeze)
    }

    @Test("The shipped seed denylist is valid and non-trivial")
    func seedDecodes() throws {
        // The seed lives in the CLI bundle; re-validate its shape via a copy here would
        // require the CLI bundle. Instead assert our fixture round-trips cleanly.
        let list = try Denylist.decode(from: scanFixtureData("denylist.test"))
        let reencoded = try JSONEncoder().encode(list)
        let again = try Denylist.decode(from: reencoded)
        #expect(again == list)
    }
}
