import Testing
import SwiftServeScan
@testable import SwiftServeSource

/// A small denylist for the source pipeline tests — kept in code so they're
/// self-contained (no disk), exactly as the slice requires.
private let denylist = Denylist(version: 1, entries: [
    DenylistEntry(id: "priv", pattern: "_privateThing", match: .exact, appliesTo: [.objcSelector],
                  framework: "UIView (private)", severity: .high, why: "Private selector.",
                  rejectionCode: "ITMS-90338", alternative: "Use the public API."),
    DenylistEntry(id: "ls", pattern: "LSApplicationWorkspace", match: .prefix, appliesTo: [.objcClass],
                  framework: "CoreServices (private)", severity: .high, why: "Private app listing."),
    DenylistEntry(id: "mg", pattern: "MGCopyAnswer", match: .exact, appliesTo: [.importedSymbol],
                  framework: "libMobileGestalt (private)", severity: .high, why: "Private device info."),
])

/// Run the real pipeline a user gets: parse Swift source → match → findings. Strings in,
/// no disk — which is the whole point of keeping parsing pure.
private func scan(_ source: String) -> [Finding] {
    SourceScanner.detect(SwiftSourceParser.candidates(in: source, file: "T.swift"), denylist: denylist)
}

@Suite struct SwiftSourceParserTests {

    // 1. A denylisted selector passed to perform → HIGH, at the right line.
    @Test func denylistedSelectorIsDefinite() throws {
        let findings = scan("""
        func go(o: NSObject) {
            o.perform(Selector("_privateThing"))
        }
        """)
        let hit = try #require(findings.first { $0.symbol == "_privateThing" })
        #expect(hit.confidence == .high)
        #expect(hit.surface == .source)
        #expect(hit.analyzer == .swiftSyntax)
        #expect(hit.severity == .high)
        #expect(hit.framework == "UIView (private)")
        #expect(hit.location?.line == 2)
    }

    // 2. A leading-underscore selector NOT on the denylist → NEEDS-REVIEW.
    @Test func underscoreSelectorIsPossible() throws {
        let findings = scan(#"let s = Selector("_secretMethod")"#)
        let hit = try #require(findings.first)
        #expect(hit.symbol == "_secretMethod")
        #expect(hit.confidence == .needsReview)
        #expect(hit.framework == nil)   // no denylist entry to attribute to
    }

    // 3. A benign value(forKey:) on a normal property → NOT reported.
    @Test func benignKvcIsSilent() {
        let findings = scan(#"let name = obj.value(forKey: "username")"#)
        #expect(findings.isEmpty)
    }

    // 4. A literal path under /System/Library/PrivateFrameworks/ → definite.
    @Test func dlopenPrivateFrameworksPathIsDefinite() throws {
        let findings = scan(#"let h = dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", 2)"#)
        let hit = try #require(findings.first)
        #expect(hit.confidence == .high)
        #expect(hit.severity == .high)
        #expect(hit.framework?.contains("Sharing") == true)
    }

    // 5. The AST proof: Selector("_x") in a comment OR an unrelated string is NOT a finding.
    @Test func selectorInCommentOrStringIsIgnored() {
        let findings = scan(#"""
        // o.perform(Selector("_commentedOut"))
        let note = "we sometimes call Selector(\"_insideAString\")"
        """#)
        #expect(findings.isEmpty)
    }

    // Boundary: a *constructed* PrivateFrameworks path can never be definite — we can't
    // prove what it resolves to.
    @Test func constructedPrivateFrameworksPathIsPossible() throws {
        let findings = scan("""
        func load(base: String, name: String) {
            _ = dlopen("\\(base)/PrivateFrameworks/\\(name)", 2)
        }
        """)
        let hit = try #require(findings.first)
        #expect(hit.confidence == .needsReview)
    }

    // NSClassFromString of a denylisted private class → definite, mapped to objcClass.
    @Test func classLookupDenylistedIsDefinite() throws {
        let findings = scan(#"let c = NSClassFromString("LSApplicationWorkspace")"#)
        let hit = try #require(findings.first)
        #expect(hit.confidence == .high)
        #expect(hit.symbolKind == .objcClass)
    }

    // ObjC is best-effort: even a denylisted selector via regex is capped at needs-review,
    // and tagged so it reads differently from a Swift-AST hit.
    @Test func objcHitIsCappedAndTagged() throws {
        let sites = ObjCHeuristicScanner.candidates(
            in: "[obj performSelector:@selector(_privateThing)];", file: "T.m")
        let hit = try #require(SourceScanner.detect(sites, denylist: denylist).first)
        #expect(hit.analyzer == .objcHeuristic)
        #expect(hit.confidence == .needsReview)
    }
}
