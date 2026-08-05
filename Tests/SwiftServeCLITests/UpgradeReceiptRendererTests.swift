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
}
