import Testing
@testable import SwiftServeScan

@Suite("nm / otool output parsing")
struct ParserTests {

    @Test("nm undefined symbols → classified ExtractedSymbols")
    func nmSymbols() {
        let text = """
        myapp:
        _MGCopyAnswer
                         U _OBJC_CLASS_$_LSApplicationWorkspace
        _$s10Foundation3URLV

        """
        let syms = OutputParsers.parseNmSymbols(text, origin: Origin(kind: .firstParty, artifact: "myapp"))
        #expect(syms.count == 3)   // header and blank line skipped

        let mg = try! #require(syms.first { $0.name == "_MGCopyAnswer" })
        #expect(mg.kind == .importedSymbol)
        #expect(mg.normalizedName == "MGCopyAnswer")

        let ls = try! #require(syms.first { $0.name.contains("LSApplicationWorkspace") })
        #expect(ls.kind == .objcClass)
        #expect(ls.normalizedName == "LSApplicationWorkspace")  // sigil stripped, even from the "U _name" form
    }

    @Test("otool -s __objc_methname hex dump decodes to selector strings")
    func methnameDecode() {
        // Real bytes captured from `otool -s __TEXT __objc_methname` (little-endian words).
        let hex = """
        myapp:
        Contents of (__TEXT,__objc_methname) section
        000000010014e3c0\t00000000 00000000 00000000 00000000
        000000010014e3d0\t6f630000 676e6964 68746150 656c6500
        000000010014e3e0\t746e656d 00000000 00000000 00000000
        """
        let syms = OutputParsers.parseObjCMethnames(hex, origin: Origin(kind: .firstParty, artifact: "myapp"))
        let names = syms.map(\.name)
        #expect(names.contains("codingPath"))
        #expect(names.contains("element"))
        #expect(syms.allSatisfy { $0.kind == .objcSelector })
    }
}
