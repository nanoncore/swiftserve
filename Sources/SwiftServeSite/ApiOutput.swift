import Foundation
import SwiftServeCapability

/// The agent-facing surface: the records ARE the API, served as static JSON
/// with a stable schema. Same canonical-JSON philosophy as the CLI.
public enum ApiOutput {

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// `/api/index.json` — the root map agents start from.
    public static func rootIndex(site: Site) throws -> Data {
        struct Root: Encodable {
            let schemaVersion: Int
            let description: String
            let endpoints: [String: String]
        }
        let base = site.basePath
        return try encoder.encode(Root(
            schemaVersion: 1,
            description: "SwiftServe capability index — what Swift packages actually serve, per platform, with source-line evidence. All endpoints are static JSON.",
            endpoints: [
                "taxonomy": "\(base)/api/taxonomy.json",
                "packages": "\(base)/api/packages/index.json",
                "package": "\(base)/api/packages/{slug}.json",
                "capability": "\(base)/api/capabilities/{id}.json",
                "search": "\(base)/api/search-index.json",
                "recordSchema": "\(base)/api/schemas/capability-record-v1.json",
            ]))
    }

    /// `/api/packages/index.json` — slug → name/url/version map.
    public static func packagesIndex(site: Site) throws -> Data {
        struct Entry: Encodable {
            let slug, name, canonicalURL, version: String
            let capabilities: [String]
        }
        let entries = site.model.packages.map { package in
            Entry(slug: package.slug, name: package.name, canonicalURL: package.canonicalURL,
                  version: package.version, capabilities: package.records.map(\.capability.id))
        }
        return try encoder.encode(entries)
    }

    /// `/api/packages/{slug}.json` — the package's full records, verbatim.
    public static func packageJSON(_ package: PackageView) throws -> Data {
        try encoder.encode(package.records)
    }

    /// `/api/capabilities/{id}.json` — the capability-first pivot agents ask.
    public static func capabilityJSON(_ view: CapabilityView, site: Site) throws -> Data {
        struct PlatformEntry: Encodable {
            let status: String
            let confidence: Double
            let evidence: [Evidence]
        }
        struct Evidence: Encodable {
            let kind: String
            let symbol, file: String?
            let line: Int?
            let condition, note, permalink: String?
        }
        struct Row: Encodable {
            let package, packageName, slug, version, commit: String
            let platforms: [String: PlatformEntry]
            let requiresCompanion: [String]
            let notes: String?
        }
        struct Payload: Encodable {
            let id, label: String
            let aliases: [String]
            let packages: [Row]
        }

        let rows = view.rows.map { row -> Row in
            let record = row.record
            var platforms: [String: PlatformEntry] = [:]
            for (platform, claim) in record.platforms {
                platforms[platform] = PlatformEntry(
                    status: claim.status.rawValue, confidence: claim.confidence,
                    evidence: claim.evidence.map { anchor in
                        let target = anchor.package ?? record.package.canonicalURL
                        let permalink: String?
                        if let file = anchor.file, let line = anchor.line {
                            permalink = "\(target)/blob/\(record.package.version)/\(file)#L\(line)"
                        } else {
                            permalink = nil
                        }
                        return Evidence(kind: anchor.kind.rawValue, symbol: anchor.symbol,
                                        file: anchor.file, line: anchor.line,
                                        condition: anchor.condition, note: anchor.note,
                                        permalink: permalink)
                    })
            }
            return Row(package: record.package.canonicalURL, packageName: record.package.name,
                       slug: row.slug, version: record.package.version, commit: record.package.commit,
                       platforms: platforms, requiresCompanion: record.requiresCompanion,
                       notes: record.notes)
        }
        return try encoder.encode(Payload(id: view.capability.id, label: view.capability.label,
                                          aliases: view.capability.aliases ?? [], packages: rows))
    }

    /// `/api/search-index.json` — the compact client-side search index.
    public static func searchIndex(site: Site) throws -> Data {
        struct CapabilityEntry: Encodable {
            let id, label, domain: String
            let aliases: [String]
            let n: Int
            let p: [String: Int]
        }
        struct PackageEntry: Encodable {
            let slug, name: String
            let aliases: [String]
            let caps: Int
            let fp: Bool   // Apple first-party — search results mark these
        }
        struct Index: Encodable {
            let v: Int
            let capabilities: [CapabilityEntry]
            let packages: [PackageEntry]
        }

        let model = site.model
        let capabilities = model.capabilities.map { view -> CapabilityEntry in
            var perPlatform: [String: Int] = [:]
            for platform in Platform.allCases {
                perPlatform[platform.rawValue] = view.supportedCount(on: platform)
            }
            return CapabilityEntry(id: view.capability.id, label: view.capability.label,
                                   domain: view.capability.id.split(separator: ".").first.map(String.init) ?? "other",
                                   aliases: view.capability.aliases ?? [],
                                   n: view.rows.count, p: perPlatform)
        }
        let packages = model.packages.map { package in
            PackageEntry(slug: package.slug, name: package.name,
                         aliases: package.records.first?.package.aliases ?? [],
                         caps: package.records.count, fp: package.firstParty)
        }
        return try encoder.encode(Index(v: 1, capabilities: capabilities, packages: packages))
    }
}
