import SwiftServeEvidence
import Testing

@Suite("Bundled capability evidence")
struct CapabilityEvidenceLoaderTests {
    @Test("The reusable target ships the validated evidence snapshot")
    func bundledDataset() throws {
        let dataset = try CapabilityEvidenceLoader.load()
        #expect(!dataset.records.isEmpty)
        #expect(!dataset.taxonomy.capabilities.isEmpty)
    }

    @Test("Missing overrides report the path without falling back")
    func missingOverride() {
        let path = "/definitely-missing/swiftserve-capability-dataset.json"
        #expect(throws: CapabilityEvidenceError.unreadableOverride(path)) {
            try CapabilityEvidenceLoader.load(overridePath: path)
        }
    }
}
