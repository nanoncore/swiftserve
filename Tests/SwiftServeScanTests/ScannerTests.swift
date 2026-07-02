import Testing
@testable import SwiftServeScan

@Suite("Private-symbol matcher")
struct ScannerTests {

    func sym(_ name: String, _ kind: SymbolKind, _ kindOrigin: OriginKind = .firstParty) -> ExtractedSymbol {
        ExtractedSymbol(name: name, kind: kind, origin: Origin(kind: kindOrigin, artifact: "TestBin"))
    }

    @Test("A clean binary produces no findings")
    func clean() {
        let symbols = [
            sym("_$s10Foundation3URLV", .importedSymbol),
            sym("_OBJC_CLASS_$_NSObject", .objcClass),
            sym("viewDidLoad", .objcSelector),
        ]
        #expect(BinaryScanner.detect(symbols, denylist: testDenylist).isEmpty)
    }

    @Test("Seeded private symbols are caught with the right metadata")
    func hits() {
        let symbols = [
            sym("_MGCopyAnswer", .importedSymbol),                              // exact, underscore stripped
            sym("_OBJC_CLASS_$_LSApplicationWorkspaceFoo", .objcClass),         // prefix, sigil stripped
            sym("setOrientation:", .objcSelector, .dependency),                 // selector verbatim
        ]
        let findings = BinaryScanner.detect(symbols, denylist: testDenylist)
        #expect(findings.count == 3)

        let mg = try! #require(findings.first { $0.matchedPattern == "MGCopyAnswer" })
        #expect(mg.symbol == "MGCopyAnswer")
        #expect(mg.symbolKind == .importedSymbol)
        #expect(mg.severity == .high)
        #expect(mg.rejectionCode == "ITMS-90338")

        let ls = try! #require(findings.first { $0.matchedPattern == "LSApplicationWorkspace" })
        #expect(ls.matchType == .prefix)
        #expect(ls.symbol == "LSApplicationWorkspaceFoo")

        let orient = try! #require(findings.first { $0.matchedPattern == "setOrientation:" })
        #expect(orient.severity == .medium)
        #expect(orient.origin.kind == .dependency)
    }

    @Test("Findings are sorted worst-first")
    func sorted() {
        let symbols = [sym("setOrientation:", .objcSelector), sym("_MGCopyAnswer", .importedSymbol)]
        let findings = BinaryScanner.detect(symbols, denylist: testDenylist)
        #expect(findings.first?.severity == .high)   // MGCopyAnswer (high) before setOrientation: (medium)
    }

    @Test("appliesTo scoping prevents cross-kind matches")
    func appliesTo() {
        // "MGCopyAnswer" as a selector must NOT match the importedSymbol-only entry.
        let findings = BinaryScanner.detect([sym("MGCopyAnswer", .objcSelector)], denylist: testDenylist)
        #expect(findings.isEmpty)
    }

    @Test("Duplicate symbols collapse to one finding")
    func dedup() {
        let symbols = [sym("_MGCopyAnswer", .importedSymbol), sym("_MGCopyAnswer", .importedSymbol)]
        #expect(BinaryScanner.detect(symbols, denylist: testDenylist).count == 1)
    }
}
