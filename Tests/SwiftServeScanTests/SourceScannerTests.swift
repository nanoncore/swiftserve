import Testing
@testable import SwiftServeScan

/// Matcher-only tests: feed `CandidateSite`s straight in (no SwiftSyntax, no disk) and
/// pin down the confidence rules in isolation. Reuses `testDenylist` from ScanTestSupport
/// (selector `setOrientation:` medium, class `LSApplicationWorkspace` high, symbol
/// `MGCopyAnswer` high).
@Suite struct SourceScannerTests {

    private func site(_ kind: SourceCallKind, _ form: ArgumentForm,
                      analyzer: SourceAnalyzer = .swiftSyntax) -> CandidateSite {
        CandidateSite(kind: kind, api: "x", argument: form,
                      location: SourceLocation(file: "T.swift", line: 1, column: 1), analyzer: analyzer)
    }

    @Test func denylistedLiteralSelectorIsHigh() {
        let f = SourceScanner.detect([site(.selector, .literal("setOrientation:"))], denylist: testDenylist)
        #expect(f.first?.confidence == .high)
        #expect(f.first?.severity == .medium)        // inherited from the denylist entry
        #expect(f.first?.matchedPattern == "setOrientation:")
    }

    @Test func underscoreSelectorIsNeedsReview() {
        let f = SourceScanner.detect([site(.selector, .literal("_whatever"))], denylist: testDenylist)
        #expect(f.first?.confidence == .needsReview)
        #expect(f.first?.severity == .low)            // gentle — won't trip a severity gate
        #expect(f.first?.framework == nil)
    }

    @Test func benignKvcKeyIsSilent() {
        let f = SourceScanner.detect([site(.kvcKey, .literal("username"))], denylist: testDenylist)
        #expect(f.isEmpty)
    }

    @Test func literalPrivateFrameworksPathIsHigh() {
        let f = SourceScanner.detect(
            [site(.dynamicLoadPath, .literal("/System/Library/PrivateFrameworks/Foo.framework/Foo"))],
            denylist: testDenylist)
        #expect(f.first?.confidence == .high)
        #expect(f.first?.framework?.contains("Foo") == true)
    }

    @Test func constructedPathIsCappedAtNeedsReview() {
        let f = SourceScanner.detect([site(.dynamicLoadPath, .constructed(["/PrivateFrameworks/"]))],
                                     denylist: testDenylist)
        #expect(f.first?.confidence == .needsReview)
    }

    @Test func objcAnalyzerNeverHigh() {
        let f = SourceScanner.detect([site(.selector, .literal("setOrientation:"), analyzer: .objcHeuristic)],
                                     denylist: testDenylist)
        #expect(f.first?.confidence == .needsReview)  // denylist hit, but ObjC can't prove context
        #expect(f.first?.analyzer == .objcHeuristic)
    }

    @Test func fullyDynamicIsSilent() {
        let f = SourceScanner.detect([site(.selector, .constructed([]))], denylist: testDenylist)
        #expect(f.isEmpty)
    }

    @Test func definiteSortsBeforePossible() {
        let f = SourceScanner.detect([
            site(.selector, .literal("_possible")),         // needs-review
            site(.selector, .literal("setOrientation:")),   // definite
        ], denylist: testDenylist)
        #expect(f.count == 2)
        #expect(f.first?.confidence == .high)               // definite first
    }
}
