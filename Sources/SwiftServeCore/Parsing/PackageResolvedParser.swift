import Foundation

/// Errors surfaced while reading a `Package.resolved`. Messages are warm and
/// plain — they're shown to a human who may have dropped the wrong file.
public enum PackageResolvedError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case unsupportedVersion(Int)
    case notAResolvedFile

    public var description: String {
        switch self {
        case .notJSON:
            return "That doesn't look like a Package.resolved — it isn't valid JSON."
        case .unsupportedVersion(let v):
            return "This Package.resolved is format version \(v); SwiftServe reads versions 2 and 3."
        case .notAResolvedFile:
            return "That JSON isn't a Package.resolved — it has no \"version\" field."
        }
    }
}

/// Parses `Package.resolved` (format version 2 and 3) into clean ``Pin`` models.
///
/// Version 3 is structurally identical to version 2 for `pins`; it only adds a
/// top-level `originHash`, which we ignore. Version 1's `object.pins` shape is
/// intentionally unsupported (it predates the registry/identity model).
public struct PackageResolvedParser: Sendable {
    public init() {}

    public func parse(_ string: String) throws -> [Pin] {
        try parse(Data(string.utf8))
    }

    public func parse(_ data: Data) throws -> [Pin] {
        let raw: RawFile
        do {
            raw = try JSONDecoder().decode(RawFile.self, from: data)
        } catch let error as DecodingError {
            // A missing top-level `version` means it isn't a resolved file at all.
            if case .keyNotFound(let key, _) = error, key.stringValue == "version" {
                throw PackageResolvedError.notAResolvedFile
            }
            throw PackageResolvedError.notJSON
        } catch {
            throw PackageResolvedError.notJSON
        }

        guard raw.version == 2 || raw.version == 3 else {
            throw PackageResolvedError.unsupportedVersion(raw.version)
        }

        return (raw.pins ?? []).map(Self.makePin)
    }

    // MARK: - Raw on-disk shapes

    private struct RawFile: Decodable {
        let version: Int
        let pins: [RawPin]?
    }

    private struct RawPin: Decodable {
        let identity: String
        let kind: String?
        let location: String?
        let state: RawState?
    }

    private struct RawState: Decodable {
        let version: String?
        let branch: String?
        let revision: String?
    }

    private static func makePin(_ raw: RawPin) -> Pin {
        let kind = PinKind(rawValue: raw.kind ?? "") ?? .unknown
        let version = raw.state?.version
        let branch = raw.state?.branch
        let revision = raw.state?.revision

        let pinType: PinType
        if version != nil {
            pinType = .version
        } else if branch != nil {
            pinType = .branch
        } else if revision != nil {
            pinType = .revision
        } else {
            pinType = .unknown
        }

        return Pin(
            identity: raw.identity,
            kind: kind,
            location: raw.location ?? "",
            resolvedVersion: version,
            branch: branch,
            revision: revision,
            pinType: pinType
        )
    }
}
