import SwiftServeCore
import SwiftServeReceipt
import Testing
@testable import SwiftServeCLI

@Suite("Upgrade Receipt CLI surfaces")
struct UpgradeReceiptRendererTests {
    func pin(_ version: String, location: String = "https://github.com/acme/demo.git") -> Pin {
        Pin(identity: "demo", kind: .remoteSourceControl, location: location,
            resolvedVersion: version, branch: nil, revision: version, pinType: .version)
    }

    @Test("Markdown and card render from the canonical receipt")
    func renderers() {
        let receipt = ReceiptEngine.build(base: [pin("1.0.0")], head: [pin("2.0.0")],
                                          generatedAt: "2026-08-05T00:00:00Z")
        let markdown = UpgradeReceiptRenderer.markdown(receipt)
        let card = UpgradeReceiptRenderer.card(receipt)
        #expect(markdown.contains("Upgrade Receipt — REVIEW"))
        #expect(markdown.contains("| `demo` | `1.0.0` | `2.0.0` | major | **review** |"))
        #expect(markdown.contains("not a universal safety guarantee"))
        #expect(card.contains("Upgrade Receipt — REVIEW"))
        #expect(card.contains("major-update"))
    }

    @Test("Zero-change policy failures remain visible in both renderers")
    func zeroChangePolicyFailure() {
        let requirement = CapabilityRequirement(package: "missing", capability: "audio.demo",
                                                platform: "macOS", expect: .supported)
        let receipt = ReceiptEngine.build(base: [], head: [], generatedAt: "t",
            context: .init(policy: ReceiptPolicy(requiredCapabilities: [requirement])))
        #expect(receipt.changes.isEmpty)
        #expect(receipt.verdict == .block)
        #expect(!receipt.headline.contains("passed"))
        let markdown = UpgradeReceiptRenderer.markdown(receipt)
        let card = UpgradeReceiptRenderer.card(receipt)
        #expect(markdown.contains("required-capability-mismatch:missing:missing-package"))
        #expect(card.contains("required-capability-mismatch:missing:missing-package"))
    }

    @Test("Receipt health enrichment selects a changed repository once")
    func changedRepositoriesAreDeduplicated() {
        let base = [pin("1.0.0"), Pin(identity: "DEMO", kind: .remoteSourceControl,
                                      location: "https://github.com/acme/demo",
                                      resolvedVersion: "1.0.0", branch: nil,
                                      revision: "old", pinType: .version)]
        let head = [pin("2.0.0"), Pin(identity: "demo", kind: .remoteSourceControl,
                                      location: "https://github.com/acme/demo.git",
                                      resolvedVersion: "2.0.0", branch: nil,
                                      revision: "new", pinType: .version)]
        #expect(Diff.changedRepositoryPins(base: base, head: head).count == 1)
    }

    @Test("Network metadata reflects GitHub health and capability recheck activity")
    func networkMetadata() {
        let nonGitHub = pin("2.0.0", location: "https://gitlab.com/acme/demo.git")
        #expect(Diff.githubEnrichmentPins([nonGitHub]).isEmpty)
        #expect(Diff.enrichmentSource(healthNetworkUsed: false, capabilityNetworkUsed: false) == "fileOnly")
        #expect(Diff.enrichmentSource(healthNetworkUsed: true, capabilityNetworkUsed: false) == "github")
        #expect(Diff.enrichmentSource(healthNetworkUsed: false, capabilityNetworkUsed: true) == "capability-recheck")
        #expect(Diff.enrichmentSource(healthNetworkUsed: true, capabilityNetworkUsed: true)
                == "github+capability-recheck")
    }
}
