import Foundation
import SwiftServeCapability

/// Parses `swift-symbolgraph-extract` output — Apple's own docs-pipeline
/// format — into surface decls. This is how first-party frameworks become
/// parseable truth: the graph covers the ObjC-imported API that the
/// swiftinterface overlay misses (AVAudioEngine, all of AVFoundation), and
/// every symbol carries availability per platform.
public enum SymbolGraphParser {

    /// The graph has no source locations, so a decl's `line` is its ordinal
    /// in the (name, signature)-sorted symbol list — a stable disambiguator
    /// for same-named overloads, pinned like everything else to the Xcode
    /// build the surface was extracted at.
    public static func decls(from data: Data, file: String) throws -> [SurfaceDecl] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let symbols = root["symbols"] as? [[String: Any]] else { return [] }

        var parsed: [(name: String, kind: DeclKind, signature: String?,
                      availability: [AvailabilityConstraint], doc: String?)] = []
        for symbol in symbols {
            guard let kindID = (symbol["kind"] as? [String: Any])?["identifier"] as? String,
                  let kind = declKind(kindID),
                  let path = symbol["pathComponents"] as? [String], !path.isEmpty else { continue }
            let signature = ((symbol["names"] as? [String: Any])?["subHeading"] as? [[String: Any]])
                .map { $0.compactMap { $0["spelling"] as? String }.joined() }
            let availability = (symbol["availability"] as? [[String: Any]])?
                .compactMap(constraint) ?? []
            parsed.append((path.joined(separator: "."), kind, signature, availability, docSummary(symbol)))
        }

        parsed.sort { ($0.name, $0.signature ?? "") < ($1.name, $1.signature ?? "") }
        return parsed.enumerated().map { index, p in
            SurfaceDecl(name: p.name, kind: p.kind, signature: p.signature,
                        location: SurfaceLocation(file: file, line: index + 1),
                        condition: nil, rawCondition: nil,
                        availability: p.availability, resolvedPlatforms: nil,
                        docSummary: p.doc, hasMacroAttributes: false)
        }
    }

    private static func declKind(_ identifier: String) -> DeclKind? {
        switch identifier {
        case "swift.class": .class
        case "swift.struct": .struct
        case "swift.enum": .enum
        case "swift.enum.case": .enumCase
        case "swift.protocol": .protocol
        case "swift.actor": .actor
        case "swift.typealias": .typealias
        case "swift.init": .initializer
        case "swift.subscript", "swift.type.subscript": .subscript
        case "swift.method", "swift.type.method", "swift.func", "swift.func.op": .function
        case "swift.property", "swift.type.property", "swift.var": .property
        default: nil   // associatedtypes, macros — not anchor material (v1)
        }
    }

    private static func constraint(_ entry: [String: Any]) -> AvailabilityConstraint? {
        guard let domain = entry["domain"] as? String else { return nil }
        func version(_ key: String) -> String? {
            guard let v = entry[key] as? [String: Any], let major = v["major"] else { return nil }
            let minor = v["minor"].map { ".\($0)" } ?? ""
            let patch = v["patch"].map { ".\($0)" } ?? ""
            return "\(major)\(minor)\(patch)"
        }
        return AvailabilityConstraint(
            platform: domain,
            introduced: version("introduced"),
            deprecated: (entry["isUnconditionallyDeprecated"] as? Bool == true) ? "unversioned" : version("deprecated"),
            obsoleted: version("obsoleted"),
            unavailable: entry["isUnconditionallyUnavailable"] as? Bool ?? false)
    }

    private static func docSummary(_ symbol: [String: Any]) -> String? {
        guard let lines = (symbol["docComment"] as? [String: Any])?["lines"] as? [[String: Any]] else { return nil }
        for line in lines {
            if let text = (line["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
