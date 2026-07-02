import Foundation

/// Pure parsers for `nm` / `otool` text output. The CLI spawns the tools; these
/// turn their text into `[ExtractedSymbol]` and are unit-tested with captured
/// sample output (no I/O here).
public enum OutputParsers {

    /// Parse `nm -arch <a> -u <bin>` (undefined/imported symbols). Each non-empty
    /// line's last whitespace-separated token is the symbol name; `_OBJC_CLASS_$_`/
    /// `_OBJC_METACLASS_$_` are classified as ObjC classes, everything else as
    /// imported symbols. Tolerates the fuller `<spaces>U _name` format too.
    public static func parseNmSymbols(_ text: String, origin: Origin) -> [ExtractedSymbol] {
        var out: [ExtractedSymbol] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasSuffix(":") { continue } // skip file/arch headers
            guard let name = line.split(separator: " ").last.map(String.init), !name.isEmpty else { continue }

            let kind: SymbolKind =
                (name.hasPrefix("_OBJC_CLASS_$_") || name.hasPrefix("_OBJC_METACLASS_$_"))
                ? .objcClass : .importedSymbol
            out.append(ExtractedSymbol(name: name, kind: kind, origin: origin))
        }
        return out
    }

    /// Parse the ObjC method-name pool. We feed it the **hex** dump from
    /// `otool -arch <a> -s __TEXT __objc_methname <bin>` (the `-v` form prints
    /// nothing useful on current toolchains), decode the C-strings, and emit each
    /// as an `.objcSelector`.
    public static func parseObjCMethnames(_ otoolHexDump: String, origin: Origin) -> [ExtractedSymbol] {
        decodeCStringHexSection(otoolHexDump)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ExtractedSymbol(name: $0, kind: .objcSelector, origin: origin) }
    }

    /// Decode an `otool -s` hex dump of a C-string section into its strings.
    /// Lines look like `<addr>\t<w0> <w1> <w2> <w3>` where each `w` is a 32-bit
    /// word printed little-endian (so each 4-byte word is byte-reversed), and the
    /// strings are NUL-separated.
    static func decodeCStringHexSection(_ text: String) -> [String] {
        var bytes: [UInt8] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let tab = rawLine.firstIndex(of: "\t") else { continue } // data lines only
            for word in rawLine[rawLine.index(after: tab)...].split(separator: " ") {
                let w = String(word)
                guard w.count == 8, w.allSatisfy(\.isHexDigit) else { continue }
                var wordBytes: [UInt8] = []
                var i = w.startIndex
                while i < w.endIndex {
                    let j = w.index(i, offsetBy: 2)
                    wordBytes.append(UInt8(w[i..<j], radix: 16) ?? 0)
                    i = j
                }
                bytes.append(contentsOf: wordBytes.reversed()) // little-endian word
            }
        }

        var strings: [String] = []
        var current: [UInt8] = []
        for b in bytes {
            if b == 0 {
                if !current.isEmpty { strings.append(String(decoding: current, as: UTF8.self)); current.removeAll(keepingCapacity: true) }
            } else {
                current.append(b)
            }
        }
        if !current.isEmpty { strings.append(String(decoding: current, as: UTF8.self)) }
        return strings
    }
}
