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
