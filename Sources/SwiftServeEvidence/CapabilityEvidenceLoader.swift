import Foundation
import SwiftServeCapability

public enum CapabilityEvidenceError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadableOverride(String)
    case missingBundledDataset

    public var description: String {
        switch self {
        case .unreadableOverride(let path):
            "couldn't read dataset at \(path)"
        case .missingBundledDataset:
            "no bundled capability dataset — run `swiftserve index assemble` and rebuild, or pass --dataset"
        }
    }
}

/// Loads the immutable capability-evidence snapshot shared by the CLI and
/// hosted surfaces. Decoding and evidence semantics remain in
/// SwiftServeCapability; this target owns only resource I/O.
public enum CapabilityEvidenceLoader {
    public static func load(overridePath: String? = nil) throws -> CapabilityDataset {
        if let overridePath {
            guard let data = FileManager.default.contents(atPath: overridePath) else {
                throw CapabilityEvidenceError.unreadableOverride(overridePath)
            }
            return try CapabilityDataset.decode(from: data)
        }

        guard let url = Bundle.module.url(
            forResource: "capability-dataset", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "capability-dataset", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            throw CapabilityEvidenceError.missingBundledDataset
        }
        return try CapabilityDataset.decode(from: data)
    }
}
