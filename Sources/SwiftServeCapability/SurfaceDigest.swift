import Foundation

/// The labeling view of a surface: prioritized, capped, honest about
/// truncation. The digest is what goes into a labeling bundle; validation
/// always runs against the FULL surface, so truncation can only ever cause a
/// missed capability, never a falsely-grounded one.
public enum SurfaceDigest {

    public struct Digest: Codable, Sendable, Equatable {
        public let package: String
        public let tag: String?
        public let commit: String?
        public let truncated: Bool
        public let declCount: Int          // decls included
        public let totalDecls: Int         // decls on the full surface
        public let decls: [Decl]
    }

    /// One decl, compacted for labeling: platform info only where it deviates
    /// from present-everywhere — the deviations ARE the capability signal.
    public struct Decl: Codable, Sendable, Equatable {
        public let name: String
        public let kind: String
        public let signature: String?
        public let doc: String?
        public let file: String
        public let line: Int
        public let condition: String?
        public let gaps: [String: String]?   // platform → "absent"/"conditional: …"
    }

    public static func build(from surface: PackageSurface, limit: Int = 800) -> Digest {
        // Priority: platform-fenced decls first (the whole point), then
        // documented types, then documented members, then the rest.
        func tier(_ decl: SurfaceDecl) -> Int {
            let fenced = decl.condition != nil || decl.availability.contains(where: \.unavailable)
                || (decl.resolvedPlatforms?.values.contains { $0 != .present } ?? false)
            if fenced { return 0 }
            let isType = [.class, .struct, .enum, .protocol, .actor].contains(decl.kind)
            if isType, decl.docSummary != nil { return 1 }
            if decl.docSummary != nil { return 2 }
            if isType { return 3 }
            return 4
        }

        // Drop synthesized-looking noise that spends budget without signal.
        let meaningful = surface.decls.filter { decl in
            let last = decl.name.split(separator: ".").last.map(String.init) ?? decl.name
            return !["hashValue", "==", "hash", "description", "debugDescription"].contains(last)
        }

        let prioritized = meaningful.enumerated()
            .sorted { a, b in
                let ta = tier(a.element), tb = tier(b.element)
                return ta == tb ? a.offset < b.offset : ta < tb   // stable within tiers
            }
            .map(\.element)

        let included = Array(prioritized.prefix(limit))
        let digestDecls = included.map { decl -> Decl in
            var gaps: [String: String] = [:]
            for (platform, presence) in decl.resolvedPlatforms ?? [:] {
                switch presence {
                case .present: continue
                case .absent: gaps[platform] = "absent"
                case .conditional(let condition): gaps[platform] = "conditional: \(condition)"
                }
            }
            return Decl(name: decl.name, kind: decl.kind.rawValue, signature: decl.signature,
                        doc: decl.docSummary, file: decl.location.file, line: decl.location.line,
                        condition: decl.rawCondition, gaps: gaps.isEmpty ? nil : gaps)
        }

        return Digest(package: surface.package.canonicalURL ?? surface.package.name,
                      tag: surface.package.tag, commit: surface.package.commit,
                      truncated: included.count < meaningful.count,
                      declCount: included.count, totalDecls: surface.decls.count,
                      decls: digestDecls)
    }
}
