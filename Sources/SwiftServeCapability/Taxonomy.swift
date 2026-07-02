import Foundation

/// The governed capability vocabulary, one file per domain
/// (`data/taxonomy/<domain>.json`). Records may only claim ids that exist
/// here (validator V01); labeling may PROPOSE new entries, the curator
/// approves them by committing the taxonomy change.
public struct Taxonomy: Codable, Sendable, Equatable {
    public struct Capability: Codable, Sendable, Equatable {
        public let id: String          // "audio.noise-cancellation"
        public let label: String       // "Noise cancellation"
        public let aliases: [String]?  // ["noise suppression", "denoise", "krisp"]
        /// Curator's note, shown when the capability has no records — for the
        /// cases where "nothing on the menu" IS the verified answer (e.g. no
        /// dedicated spatial-audio package exists; Apple's frameworks are it).
        public let note: String?

        public init(id: String, label: String, aliases: [String]? = nil, note: String? = nil) {
            self.id = id
            self.label = label
            self.aliases = aliases
            self.note = note
        }
    }

    public let taxonomyVersion: Int
    public let domain: String
    public let capabilities: [Capability]

    public init(taxonomyVersion: Int = 1, domain: String, capabilities: [Capability]) {
        self.taxonomyVersion = taxonomyVersion
        self.domain = domain
        self.capabilities = capabilities
    }

    public static func decode(from data: Data) throws -> Taxonomy {
        try JSONDecoder().decode(Taxonomy.self, from: data)
    }

    public func capability(withID id: String) -> Capability? {
        capabilities.first { $0.id == id }
    }

    public func contains(_ id: String) -> Bool {
        capability(withID: id) != nil
    }

    /// Merge per-domain taxonomy files into the one vocabulary the dataset
    /// ships. Capability ids are already namespaced (audio.*, network.*…);
    /// a duplicate id across domains is a curation error, thrown loudly.
    public static func merged(_ taxonomies: [Taxonomy]) throws -> Taxonomy {
        var seen: Set<String> = []
        var capabilities: [Capability] = []
        for taxonomy in taxonomies {
            for capability in taxonomy.capabilities {
                guard seen.insert(capability.id).inserted else {
                    throw MergeError.duplicateID(capability.id)
                }
                capabilities.append(capability)
            }
        }
        let domain = taxonomies.map(\.domain).sorted().joined(separator: "+")
        return Taxonomy(domain: domain.isEmpty ? "empty" : domain,
                        capabilities: capabilities.sorted { $0.id < $1.id })
    }

    public enum MergeError: Error, CustomStringConvertible {
        case duplicateID(String)
        public var description: String {
            switch self { case .duplicateID(let id): "capability id ‘\(id)’ appears in more than one taxonomy file" }
        }
    }
}
