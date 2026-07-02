import Testing
@testable import SwiftServeBuild

@Suite("Type-check-timing warning parsing")
struct TimingParserTests {

    @Test("expression + function-body warnings parse into the right records")
    func parsesBothKinds() {
        let text = """
        Building for debugging...
        /Users/me/App/Sources/A.swift:12:34: warning: expression took 423ms to type-check (limit: 100ms)
        /Users/me/App/Sources/B.swift:88:5: warning: getter for 'body' took 910ms to type-check (limit: 200ms)
        /Users/me/App/Sources/C.swift:3:1: warning: instance method 'compute(_:)' took 250ms to type-check (limit: 200ms)
        Build complete!
        """
        let records = TimingParser.records(from: text)
        #expect(records.count == 3)

        let a = try! #require(records.first { $0.location.file.hasSuffix("A.swift") })
        #expect(a.category == .slowExpression)
        #expect(a.location.line == 12)
        #expect(a.location.column == 34)
        #expect(a.costMs == 423)
        #expect(a.limitMs == 100)
        #expect(a.subject == nil)   // a bare expression keeps no decl

        let b = try! #require(records.first { $0.location.file.hasSuffix("B.swift") })
        #expect(b.category == .slowFunctionBody)
        #expect(b.costMs == 910)
        #expect(b.subject == "getter for 'body'")

        let c = try! #require(records.first { $0.location.file.hasSuffix("C.swift") })
        #expect(c.category == .slowFunctionBody)
        #expect(c.subject == "instance method 'compute(_:)'")
    }

    @Test("malformed and unrelated lines are skipped, valid ones survive")
    func skipsGarbageDefensively() {
        let text = """

        this is not a warning line at all
        /Users/me/App/Sources/D.swift:1:1: warning: unused variable 'x'
        /Users/me/App/Sources/E.swift:9:9: error: cannot find 'Foo' in scope
        [3/9] Compiling MyTarget File.swift
        /Users/me/App/Sources/F.swift:5:5: warning: expression took 120ms to type-check
        /Users/me/App/Sources/G.swift:7:2: warning: expression took notanumber ms to type-check (limit: 100ms)
        """
        let records = TimingParser.records(from: text)

        // Only the well-formed timing warning (F) survives. The unused-variable warning has
        // no "to type-check", the error isn't a warning, and G's duration isn't a number.
        #expect(records.count == 1)
        let f = try! #require(records.first)
        #expect(f.location.file.hasSuffix("F.swift"))
        #expect(f.costMs == 120)
        #expect(f.limitMs == 0)        // the optional "(limit: …)" clause was absent — tolerated
        #expect(f.category == .slowExpression)
    }

    @Test("a path with spaces still resolves its line/column")
    func toleratesSpacedPaths() {
        let line = "/Users/me/My App/Sources/H.swift:42:7: warning: expression took 333ms to type-check (limit: 100ms)"
        let record = try! #require(TimingParser.parse(line: line))
        #expect(record.location.file == "/Users/me/My App/Sources/H.swift")
        #expect(record.location.line == 42)
        #expect(record.location.column == 7)
        #expect(record.costMs == 333)
    }
}
