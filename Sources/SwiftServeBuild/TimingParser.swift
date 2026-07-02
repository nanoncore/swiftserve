import Foundation

/// Pure parser for Swift's type-check-timing warnings. The CLI drives `swift build` with
/// `-warn-long-expression-type-checking` / `-warn-long-function-bodies` and hands the
/// captured output here; this turns the warning TEXT into `[TimingRecord]`. Unit-tested
/// with literal warning strings — no build, no I/O.
///
/// The lines look like:
///
///     /path/File.swift:12:34: warning: expression took 423ms to type-check (limit: 100ms)
///     /path/View.swift:88:5: warning: getter for 'body' took 910ms to type-check (limit: 200ms)
///
/// We anchor on the stable `… took <N>ms to type-check …` sentence. A subject of exactly
/// `expression` is a slow expression; anything else is a function body and we keep its decl
/// description for the explanation. Parsing is deliberately defensive: the `(limit: …)`
/// clause is optional, and any line that doesn't match is skipped, never fatal — toolchain
/// versions phrase these slightly differently and we'd rather drop a line than crash.
public enum TimingParser {

    public static func records(from text: String) -> [TimingRecord] {
        var out: [TimingRecord] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            if let record = parse(line: String(rawLine)) { out.append(record) }
        }
        return out
    }

    /// One line → at most one record. `internal` so tests can hit it directly.
    static func parse(line: String) -> TimingRecord? {
        // Cheap pre-filter: skip anything that isn't a timing warning before the regex.
        guard line.contains("to type-check"), line.contains(" warning: ") else { return nil }

        guard let match = line.firstMatch(of: pattern) else { return nil }
        let o = match.output

        guard let lineNo = Int(o.line), let col = Int(o.col), let ms = Int(o.ms) else { return nil }
        let file = String(o.file)
        guard !file.isEmpty else { return nil }

        let subject = String(o.subject).trimmingCharacters(in: .whitespaces)
        let isExpression = subject == "expression"
        let limit = o.limit.flatMap { Int($0) } ?? 0

        return TimingRecord(
            category: isExpression ? .slowExpression : .slowFunctionBody,
            location: CodeLocation(file: file, line: lineNo, column: col),
            costMs: ms,
            limitMs: limit,
            subject: isExpression ? nil : subject)
    }

    /// `<file>:<line>:<col>: warning: <subject> took <N>ms to type-check[ (limit: <M>ms)]`.
    /// The file capture is non-greedy so the first `:<digits>:<digits>:` wins as the
    /// line/column, and the limit clause is optional for toolchain tolerance.
    ///
    /// `nonisolated(unsafe)`: `Regex` isn't `Sendable`, but this value is immutable and only
    /// ever read (matching allocates its own state), so sharing it is safe.
    nonisolated(unsafe) private static let pattern =
        #/^(?<file>.+?):(?<line>\d+):(?<col>\d+): warning: (?<subject>.+?) took (?<ms>\d+)ms to type-check(?: \(limit: (?<limit>\d+)ms\))?/#
}
