import Foundation

/// Maps a scanned artifact (by path) to who owns it. The CLI builds this from
/// disk (artifacts dir layout + Package.resolved); the attribution itself is pure
/// and unit-tested — it's the crux of "is this MY problem or a DEPENDENCY's?".
public struct ArtifactMapping: Sendable, Equatable {
    public let artifactPath: String
    public let origin: Origin
    public init(artifactPath: String, origin: Origin) {
        self.artifactPath = artifactPath
        self.origin = origin
    }
}

public struct ArtifactMap: Sendable, Equatable {
    public let mappings: [ArtifactMapping]
    public init(_ mappings: [ArtifactMapping]) { self.mappings = mappings }
}

public enum Attributor {
    /// The origin for a given artifact path. An artifact with no mapping is
    /// `unattributed` (a scanned binary we couldn't tie to a known package) —
    /// never dropped.
    public static func origin(forArtifact path: String, in map: ArtifactMap) -> Origin {
        if let hit = map.mappings.first(where: { $0.artifactPath == path }) {
            return hit.origin
        }
        return Origin(kind: .unattributed, artifact: (path as NSString).lastPathComponent)
    }
}
