import Foundation
import SwiftServeCore
import SwiftServeEvidence
import SwiftServeGitHub
import SwiftServeReceipt
import Testing

@Suite("GitHub Check orchestration")
struct OrchestratorTests {
    let time = "2026-08-06T12:00:00Z"

    func makeOrchestrator(_ api: FakeGitHubAPI,
                          gate: ReceiptGateThreshold = .block) throws -> GitHubCheckOrchestrator {
        let dataset = try CapabilityEvidenceLoader.load()
        return GitHubCheckOrchestrator(api: api, gate: gate, capabilityDataset: dataset,
                                       generatedAt: { "2026-08-06T12:00:00Z" })
    }

    func configureOne(_ api: FakeGitHubAPI, path: String = "Package.resolved",
                      base: Data = resolved("1.0.0"), head: Data = resolved("1.0.1")) async {
        await api.setPage(1, files: [path])
        await api.setContent(path: path, ref: fixtureEvent.baseSHA, result: .success(base))
        await api.setContent(path: path, ref: fixtureEvent.headSHA, result: .success(head))
        await api.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA, result: .failure(.notFound))
    }

    @Test("Changed-file pagination finds a nested lockfile")
    func pagination() async throws {
        let api = FakeGitHubAPI()
        await api.setPage(1, files: ["README.md"], hasNext: true)
        await api.setPage(2, files: ["App/Package.resolved"])
        await api.setContent(path: "App/Package.resolved", ref: fixtureEvent.baseSHA,
                             result: .success(resolved("1.0.0")))
        await api.setContent(path: "App/Package.resolved", ref: fixtureEvent.headSHA,
                             result: .success(resolved("1.0.1")))
        await api.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA, result: .failure(.notFound))
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let snapshot = await api.snapshot()
        #expect(snapshot.pages == [1, 2])
        #expect(snapshot.created.first?.conclusion == .success)
    }

    @Test("Zero and multiple lockfiles map to explicit conclusions")
    func lockfileCardinality() async throws {
        let zero = FakeGitHubAPI()
        await zero.setPage(1, files: ["README.md"])
        await (try makeOrchestrator(zero)).process(fixtureEvent)
        #expect(await zero.snapshot().created.first?.conclusion == .skipped)

        let multiple = FakeGitHubAPI()
        await multiple.setPage(1, files: ["A/Package.resolved", "B/Package.resolved"])
        await (try makeOrchestrator(multiple)).process(fixtureEvent)
        let publication = await multiple.snapshot().created.first
        #expect(publication?.conclusion == .actionRequired)
        #expect(publication?.summary.contains("A/Package.resolved") == true)
        #expect(publication?.summary.contains("B/Package.resolved") == true)
    }

    @Test("Lockfiles use exact base/head SHAs and policy uses base only")
    func immutableInputs() async throws {
        let api = FakeGitHubAPI()
        await configureOne(api, path: "Workspace/Package.resolved")
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let calls = await api.snapshot().calls
        #expect(calls.contains { $0 == ("Workspace/Package.resolved", fixtureEvent.baseSHA) })
        #expect(calls.contains { $0 == ("Workspace/Package.resolved", fixtureEvent.headSHA) })
        #expect(calls.contains { $0 == (".swiftserve.json", fixtureEvent.baseSHA) })
        #expect(!calls.contains { $0 == (".swiftserve.json", fixtureEvent.headSHA) })
    }

    @Test("Canonical renderer output is passed unchanged")
    func canonicalMarkdown() async throws {
        let api = FakeGitHubAPI()
        await configureOne(api)
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let actual = await api.snapshot().created.first?.summary
        let parser = PackageResolvedParser()
        let receipt = ReceiptEngine.build(
            base: try parser.parse(resolved("1.0.0")), head: try parser.parse(resolved("1.0.1")),
            generatedAt: time,
            context: .init(policy: .default, policySource: "default",
                           capabilityDataset: try CapabilityEvidenceLoader.load()))
        #expect(actual == UpgradeReceiptMarkdownRenderer.render(receipt))
    }

    @Test(arguments: [
        (ReceiptVerdict.pass, ReceiptGateThreshold.block, CheckConclusion.success),
        (.pass, .review, .success),
        (.review, .block, .neutral),
        (.review, .review, .failure),
        (.block, .block, .failure),
        (.block, .review, .failure),
    ])
    func conclusionMapping(verdict: ReceiptVerdict, gate: ReceiptGateThreshold,
                           expected: CheckConclusion) {
        #expect(GitHubCheckOrchestrator.conclusion(for: verdict, gate: gate) == expected)
    }

    @Test("Malformed lockfile and policy fail closed")
    func malformedInputs() async throws {
        let malformedLock = FakeGitHubAPI()
        await configureOne(malformedLock, head: Data("secret-lockfile".utf8))
        await (try makeOrchestrator(malformedLock)).process(fixtureEvent)
        let lockFailure = await malformedLock.snapshot().created.first
        #expect(lockFailure?.conclusion == .failure)
        #expect(lockFailure?.summary.contains("secret-lockfile") == false)

        let malformedPolicy = FakeGitHubAPI()
        await configureOne(malformedPolicy)
        await malformedPolicy.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA,
                                         result: .success(Data("secret-policy".utf8)))
        await (try makeOrchestrator(malformedPolicy)).process(fixtureEvent)
        let policyFailure = await malformedPolicy.snapshot().created.first
        #expect(policyFailure?.conclusion == .failure)
        #expect(policyFailure?.summary.contains("secret-policy") == false)
    }

    @Test("Missing required lockfile content fails closed")
    func missingInput() async throws {
        let api = FakeGitHubAPI()
        await api.setPage(1, files: ["Package.resolved"])
        await api.setContent(path: "Package.resolved", ref: fixtureEvent.baseSHA,
                             result: .success(resolved("1.0.0")))
        await api.setContent(path: "Package.resolved", ref: fixtureEvent.headSHA,
                             result: .failure(.notFound))
        await api.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA,
                             result: .failure(.notFound))
        await (try makeOrchestrator(api)).process(fixtureEvent)
        #expect(await api.snapshot().created.first?.conclusion == .failure)
    }

    @Test("Redelivery updates the stable logical Check")
    func idempotentRedelivery() async throws {
        let api = FakeGitHubAPI()
        await configureOne(api)
        let orchestrator = try makeOrchestrator(api)
        await orchestrator.process(fixtureEvent)
        await orchestrator.process(fixtureEvent)
        let snapshot = await api.snapshot()
        #expect(snapshot.created.count == 1)
        #expect(snapshot.updated.count == 1)
        #expect(snapshot.created[0].externalID == fixtureEvent.externalID)
        #expect(snapshot.updated[0].externalID == fixtureEvent.externalID)
    }

    @Test("A stale worker cannot publish over a newer head")
    func staleHead() async throws {
        let api = FakeGitHubAPI()
        await configureOne(api)
        await api.setHead("newer-head")
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let snapshot = await api.snapshot()
        #expect(snapshot.created.isEmpty)
        #expect(snapshot.updated.isEmpty)
    }

    @Test("Oversize Markdown truncates on complete lines within the byte cap")
    func markdownLimit() {
        let markdown = (0..<100).map { "| row \($0) | `value` |" }.joined(separator: "\n")
        let bounded = GitHubCheckOrchestrator.boundedMarkdown(markdown, limit: 180)
        #expect(bounded.utf8.count <= 180)
        #expect(bounded.hasSuffix("_Receipt truncated to fit GitHub Check output limits._"))
        #expect(!bounded.contains("row 99"))
    }
}
