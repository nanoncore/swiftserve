import Foundation
import SwiftServeCore
import SwiftServeCapability

// View models the pages render from — derived once from the dataset, with
// deterministic ordering everywhere so regeneration is diff-clean.

/// Display order and labels for the platform axis (differs from the enum's
/// resolution order: Linux before Catalyst, friendlier labels).
public enum PlatformDisplay {
    public static let order: [Platform] = [.iOS, .macOS, .watchOS, .tvOS, .visionOS, .linux, .macCatalyst]

    public static func label(_ platform: Platform) -> String {
        switch platform {
        case .linux: "Linux"
        case .macCatalyst: "Catalyst"
        default: platform.rawValue
        }
    }
}

public struct PackageView: Sendable, Equatable {
    public let slug: String
    public let name: String
    public let canonicalURL: String
    public let version: String
    public let commit: String
    public let records: [CapabilityRecord]   // sorted by capability id

    /// Apple framework, pinned to an Xcode build instead of a git commit.
    public var firstParty: Bool { records.first?.package.firstParty ?? false }
}

public struct CapabilityRow: Sendable, Equatable {
    public let record: CapabilityRecord
    public let slug: String                  // package slug
}

public struct CapabilityView: Sendable, Equatable {
    public let capability: Taxonomy.Capability
    public let rows: [CapabilityRow]         // sorted: supported count desc, then name

    /// Packages serving this per platform — the coverage dots.
    public func supportedCount(on platform: Platform) -> Int {
        rows.filter { $0.record.platforms[platform.rawValue]?.status == .supported }.count
    }
}

/// A capability category — the id prefix ("audio", "network"…), displayed as
/// pills for quick switching and as menu groups.
public struct CategoryView: Sendable, Equatable {
    public let prefix: String
    public let label: String
    public let capabilityCount: Int   // entries with at least one record

    static let labels: [String: String] = [
        "audio": "Audio", "image": "Images", "media": "Media", "midi": "MIDI",
        "network": "Networking", "speech": "Speech", "video": "Video", "voice": "Voice",
    ]

    public static func label(for prefix: String) -> String {
        labels[prefix] ?? prefix.prefix(1).uppercased() + prefix.dropFirst()
    }
}

public struct SiteModel: Sendable {
    public let dataset: CapabilityDataset
    public let packages: [PackageView]       // sorted by name
    public let capabilities: [CapabilityView] // every taxonomy entry, with or without rows

    /// Categories in fixed alphabetical order — the pill bar everywhere.
    public var categories: [CategoryView] {
        var byPrefix: [String: Int] = [:]
        var order: [String] = []
        for view in capabilities {
            let prefix = view.capability.id.split(separator: ".").first.map(String.init) ?? "other"
            if byPrefix[prefix] == nil { order.append(prefix) }
            byPrefix[prefix, default: 0] += view.rows.isEmpty ? 0 : 1
        }
        return order.sorted().map {
            CategoryView(prefix: $0, label: CategoryView.label(for: $0), capabilityCount: byPrefix[$0] ?? 0)
        }
    }

    public init(dataset: CapabilityDataset) {
        self.dataset = dataset

        // Slugs: repo name, lowercased; collisions become owner-repo.
        let urls = Set(dataset.records.map(\.package.canonicalURL)).sorted()
        var slugByURL: [String: String] = [:]
        var taken: Set<String> = []
        for url in urls {
            let pair = RepoIdentity.ownerRepo(from: url)
            var slug = (pair?.repo ?? url.split(separator: "/").last.map(String.init) ?? url).lowercased()
            if taken.contains(slug), let pair {
                slug = "\(pair.owner.lowercased())-\(pair.repo.lowercased())"
            }
            taken.insert(slug)
            slugByURL[url] = slug
        }

        packages = urls.compactMap { url -> PackageView? in
            let records = dataset.records
                .filter { $0.package.canonicalURL == url }
                .sorted { $0.capability.id < $1.capability.id }
            guard let first = records.first else { return nil }
            return PackageView(slug: slugByURL[url]!, name: first.package.name,
                               canonicalURL: url, version: first.package.version,
                               commit: first.package.commit, records: records)
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }

        capabilities = dataset.taxonomy.capabilities.map { capability in
            let rows = dataset.records
                .filter { $0.capability.id == capability.id }
                .map { CapabilityRow(record: $0, slug: slugByURL[$0.package.canonicalURL] ?? "") }
                .sorted { a, b in
                    let sa = a.record.platforms.values.filter { $0.status == .supported }.count
                    let sb = b.record.platforms.values.filter { $0.status == .supported }.count
                    return sa == sb ? a.record.package.name.lowercased() < b.record.package.name.lowercased() : sa > sb
                }
            return CapabilityView(capability: capability, rows: rows)
        }
        .sorted { $0.capability.id < $1.capability.id }
    }

    public func package(slug: String) -> PackageView? {
        packages.first { $0.slug == slug }
    }

    public var recordCount: Int { dataset.records.count }
}

/// The /on/<platform> pivot: one page's worth of answers to "what is the
/// state of <platform> in the Swift ecosystem?" — derived from the records at
/// generation time, never hand-counted. Parameterized by platform so other
/// pivots can ship later; only visionOS is generated today.
public struct OnPlatformView: Sendable, Equatable {

    /// One first-party framework and what it already covers here.
    public struct BuiltIn: Sendable, Equatable {
        public struct Coverage: Sendable, Equatable {
            public let capability: CapabilityRef
            public let floor: String?     // availability floor, e.g. "visionOS 1.0+"
        }
        public let slug: String
        public let name: String
        public let version: String        // the SDK pin, e.g. "Xcode 26.6"
        public let coverage: [Coverage]   // sorted by capability id
    }

    /// Per-capability coverage — each one links to /can/<id>/?on=<platform>.
    public struct CapabilityCoverage: Sendable, Equatable {
        /// One package's verdict for this capability here — enough for a
        /// consumer (the WebXR detail panels) to render the roster without a
        /// second fetch.
        public struct PackageVerdict: Sendable, Equatable {
            public let name: String
            public let slug: String
            public let status: ClaimStatus
        }
        public let capability: Taxonomy.Capability
        public let supported: Int         // third-party packages serving it here
        public let packages: Int          // third-party packages with a verdict
        public let builtInCovers: Bool    // an OS framework serves it here
        public let builtInNames: [String] // which frameworks, when it does
        public let verdicts: [PackageVerdict]  // third-party, best verdict first
    }

    /// One proven fence: the record's receipt for "not on this platform".
    public struct Fence: Sendable, Equatable {
        public let capability: CapabilityRef
        public let receipt: String        // compiler one-liner, or the source guard
        public let compilerProven: Bool   // grounded in a build verdict
        public let worksOn: [Platform]    // where the same record IS supported
    }

    /// A package with at least one fence, grouped for display.
    public struct FencedPackage: Sendable, Equatable {
        public let slug: String
        public let name: String
        public let version: String
        public let fences: [Fence]        // in capability-id order
    }

    /// A verdict we refuse to guess: unknown, with the reason on record.
    public struct Unknown: Sendable, Equatable {
        public let slug: String
        public let name: String
        public let capability: CapabilityRef
        public let why: String?           // the evidence note
    }

    public let platform: Platform
    public let supported: Int             // records, first-party included
    public let conditional: Int
    public let unsupported: Int
    public let unknown: Int               // unknown claims + records with no claim
    public let recordCount: Int
    public let packageCount: Int
    public let builtIn: [BuiltIn]                  // sorted by name
    public let capabilities: [CapabilityCoverage]  // every capability with rows, by id
    public let fenced: [FencedPackage]             // sorted by name
    public let unknowns: [Unknown]                 // by name, then capability id

    public init(model: SiteModel, platform: Platform) {
        self.platform = platform
        let key = platform.rawValue

        var supported = 0, conditional = 0, unsupported = 0, unknown = 0
        for record in model.dataset.records {
            switch record.platforms[key]?.status {
            case .supported: supported += 1
            case .conditional: conditional += 1
            case .unsupported: unsupported += 1
            case .unknown, nil: unknown += 1
            }
        }
        self.supported = supported
        self.conditional = conditional
        self.unsupported = unsupported
        self.unknown = unknown
        recordCount = model.recordCount
        packageCount = model.packages.count

        builtIn = model.packages.filter(\.firstParty).compactMap { package -> BuiltIn? in
            let coverage = package.records.compactMap { record -> BuiltIn.Coverage? in
                guard let claim = record.platforms[key], claim.status == .supported else { return nil }
                return BuiltIn.Coverage(capability: record.capability,
                                        floor: claim.evidence.compactMap(\.note).first)
            }
            guard !coverage.isEmpty else { return nil }
            return BuiltIn(slug: package.slug, name: package.name,
                           version: package.version, coverage: coverage)
        }

        capabilities = model.capabilities.filter { !$0.rows.isEmpty }.map { view in
            let thirdParty = view.rows.filter { !$0.record.package.firstParty }
            let rank: [ClaimStatus: Int] = [.supported: 0, .conditional: 1, .unsupported: 2, .unknown: 3]
            let verdicts = thirdParty.map { row in
                CapabilityCoverage.PackageVerdict(
                    name: row.record.package.name, slug: row.slug,
                    status: row.record.platforms[key]?.status ?? .unknown)
            }.sorted { a, b in
                rank[a.status]! == rank[b.status]!
                    ? a.name.lowercased() < b.name.lowercased()
                    : rank[a.status]! < rank[b.status]!
            }
            let builtInNames = view.rows.filter {
                $0.record.package.firstParty && $0.record.platforms[key]?.status == .supported
            }.map { $0.record.package.name }
            return CapabilityCoverage(
                capability: view.capability,
                supported: verdicts.filter { $0.status == .supported }.count,
                packages: verdicts.count,
                builtInCovers: !builtInNames.isEmpty,
                builtInNames: builtInNames,
                verdicts: verdicts)
        }

        // Fences and unknowns walk the packages so the lists mirror the
        // headline counts exactly — same records, same totals, no drift.
        var fenced: [FencedPackage] = []
        var unknowns: [Unknown] = []
        for package in model.packages {
            var fences: [Fence] = []
            for record in package.records {
                let claim = record.platforms[key]
                switch claim?.status {
                case .unsupported:
                    fences.append(Fence(
                        capability: record.capability,
                        receipt: Self.receipt(for: claim!),
                        compilerProven: claim!.evidence.contains { $0.kind == .buildVerdict },
                        worksOn: PlatformDisplay.order.filter {
                            record.platforms[$0.rawValue]?.status == .supported
                        }))
                case .unknown, nil:
                    unknowns.append(Unknown(slug: package.slug, name: package.name,
                                            capability: record.capability,
                                            why: claim?.evidence.compactMap(\.note).first))
                default:
                    break
                }
            }
            if !fences.isEmpty {
                fenced.append(FencedPackage(slug: package.slug, name: package.name,
                                            version: package.version, fences: fences))
            }
        }
        self.fenced = fenced
        self.unknowns = unknowns
    }

    /// The one-liner that proves a fence: the compiler's own words when a
    /// build verdict grounds the claim, otherwise the source guard or
    /// availability fence that decides it.
    static func receipt(for claim: PlatformClaim) -> String {
        if let note = claim.evidence.first(where: { $0.kind == .buildVerdict })?.note {
            return note
        }
        if let anchor = claim.evidence.first(where: { $0.kind == .guard }) {
            return [anchor.condition.map { "#if \($0)" }, anchor.note]
                .compactMap { $0 }.joined(separator: " — ")
        }
        if let anchor = claim.evidence.first(where: { $0.kind == .availability }) {
            return [anchor.availability, anchor.note].compactMap { $0 }.joined(separator: " — ")
        }
        return claim.evidence.compactMap(\.note).first ?? ""
    }
}
