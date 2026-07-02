import Foundation
import Testing
@testable import SwiftServeCore

@Suite("Package.resolved parsing")
struct ParserTests {
    let parser = PackageResolvedParser()

    @Test("Parses format version 2, including a registry-kind pin")
    func parsesV2() throws {
        let pins = try parser.parse(fixtureData("resolved-v2"))
        #expect(pins.count == 3)

        let nio = try #require(pins.first { $0.identity == "swift-nio" })
        #expect(nio.kind == .remoteSourceControl)
        #expect(nio.pinType == .version)
        #expect(nio.resolvedVersion == "2.65.0")
        #expect(nio.location == "https://github.com/apple/swift-nio.git")

        let collections = try #require(pins.first { $0.identity == "swift-collections" })
        #expect(collections.kind == .registry)
        #expect(collections.pinType == .version)
        #expect(collections.resolvedVersion == "1.1.0")

        // Every pin in this fixture tracks a released version.
        #expect(pins.allSatisfy { $0.pinType == .version })
    }

    @Test("Parses format version 3, including branch and revision-only pins")
    func parsesV3() throws {
        let pins = try parser.parse(fixtureData("resolved-v3"))
        #expect(pins.count == 3)

        let log = try #require(pins.first { $0.identity == "swift-log" })
        #expect(log.pinType == .version)
        #expect(log.resolvedVersion == "1.5.4")

        let branchPin = try #require(pins.first { $0.identity == "experimental-lib" })
        #expect(branchPin.pinType == .branch)
        #expect(branchPin.branch == "main")
        #expect(branchPin.resolvedVersion == nil)

        let revisionPin = try #require(pins.first { $0.identity == "pinned-fork" })
        #expect(revisionPin.pinType == .revision)
        #expect(revisionPin.resolvedVersion == nil)
        #expect(revisionPin.branch == nil)
        #expect(revisionPin.revision == "0123456789abcdef0123456789abcdef01234567")
    }

    @Test("Rejects unsupported format version 1")
    func rejectsV1() throws {
        #expect(throws: PackageResolvedError.unsupportedVersion(1)) {
            try parser.parse(fixtureData("resolved-v1"))
        }
    }

    @Test("Rejects non-JSON input")
    func rejectsGarbage() {
        #expect(throws: PackageResolvedError.notJSON) {
            try parser.parse("this is not json")
        }
    }

    @Test("Rejects JSON that isn't a resolved file")
    func rejectsNonResolved() {
        #expect(throws: PackageResolvedError.notAResolvedFile) {
            try parser.parse(#"{"hello":"world"}"#)
        }
    }

    @Test("Accepts an empty but valid resolved file")
    func acceptsEmpty() throws {
        let pins = try parser.parse(#"{"pins":[],"version":2}"#)
        #expect(pins.isEmpty)
    }
}
