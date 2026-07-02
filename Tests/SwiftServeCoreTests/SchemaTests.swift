import Foundation
import Testing
@testable import SwiftServeCore

@Suite("Report JSON Schema")
struct SchemaTests {

    @Test("Schema is valid JSON")
    func validJSON() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(ReportSchema.json.utf8))
        #expect(obj is [String: Any])
    }

    @Test("Schema declares every top-level report key")
    func topLevelKeys() {
        for key in ["reportVersion", "generatedAt", "overall", "packages", "graph", "enrichment"] {
            #expect(ReportSchema.json.contains("\"\(key)\""))
        }
    }

    @Test("Schema lists every scored mood (kept in sync with the enum)")
    func moodsInSync() {
        for mood in Mood.allCases where mood != .idle {
            #expect(ReportSchema.json.contains("\"\(mood.rawValue)\""), "schema missing mood \(mood.rawValue)")
        }
    }

    @Test("Schema lists every dependency flag (kept in sync with the enum)")
    func flagsInSync() {
        for flag in Flag.allCases {
            #expect(ReportSchema.json.contains("\"\(flag.rawValue)\""), "schema missing flag \(flag.rawValue)")
        }
    }
}
