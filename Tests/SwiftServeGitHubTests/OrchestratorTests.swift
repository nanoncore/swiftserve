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

    @Test("Added, removed, and renamed lockfiles use the sides that exist")
    func lockfileLifecycle() async throws {
        let added = FakeGitHubAPI()
        await added.setPage(1, files: [
            ChangedFile(filename: "New/Package.resolved", status: "added"),
        ])
        await added.setContent(path: "New/Package.resolved", ref: fixtureEvent.headSHA,
                               result: .success(resolved("1.0.0")))
        await added.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA,
                               result: .failure(.notFound))
        await (try makeOrchestrator(added)).process(fixtureEvent)
        let addedSnapshot = await added.snapshot()
        let addedPublication = try #require(addedSnapshot.created.first)
        #expect(addedPublication.conclusion != .failure)
        #expect(addedPublication.title.hasPrefix("Upgrade Receipt"))
        #expect(!addedSnapshot.calls.contains { $0 == ("New/Package.resolved", fixtureEvent.baseSHA) })

        let removed = FakeGitHubAPI()
        await removed.setPage(1, files: [
            ChangedFile(filename: "Old/Package.resolved", status: "removed"),
        ])
        await removed.setContent(path: "Old/Package.resolved", ref: fixtureEvent.baseSHA,
                                 result: .success(resolved("1.0.0")))
        await removed.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA,
                                 result: .failure(.notFound))
        await (try makeOrchestrator(removed)).process(fixtureEvent)
        let removedSnapshot = await removed.snapshot()
        let removedPublication = try #require(removedSnapshot.created.first)
        #expect(removedPublication.conclusion != .failure)
        #expect(removedPublication.title.hasPrefix("Upgrade Receipt"))
        #expect(!removedSnapshot.calls.contains { $0 == ("Old/Package.resolved", fixtureEvent.headSHA) })

        let renamed = FakeGitHubAPI()
        await renamed.setPage(1, files: [
            ChangedFile(filename: "New/Package.resolved", status: "renamed",
                        previousFilename: "Old/Package.resolved"),
        ])
        await renamed.setContent(path: "Old/Package.resolved", ref: fixtureEvent.baseSHA,
                                 result: .success(resolved("1.0.0")))
        await renamed.setContent(path: "New/Package.resolved", ref: fixtureEvent.headSHA,
                                 result: .success(resolved("1.0.1")))
        await renamed.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA,
                                 result: .failure(.notFound))
        await (try makeOrchestrator(renamed)).process(fixtureEvent)
        let renamedSnapshot = await renamed.snapshot()
        #expect(renamedSnapshot.created.first?.conclusion == .success)
        #expect(renamedSnapshot.calls.contains { $0 == ("Old/Package.resolved", fixtureEvent.baseSHA) })
        #expect(renamedSnapshot.calls.contains { $0 == ("New/Package.resolved", fixtureEvent.headSHA) })
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

    @Test("A stale worker cannot publish after the base changes")
    func staleBase() async throws {
        let api = FakeGitHubAPI()
        await configureOne(api)
        await api.setBase(sha: "newer-base")
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let snapshot = await api.snapshot()
        #expect(snapshot.created.isEmpty)
        #expect(snapshot.updated.isEmpty)

        let retargeted = FakeGitHubAPI()
        await configureOne(retargeted)
        await retargeted.setBase(ref: "release", sha: fixtureEvent.baseSHA)
        await (try makeOrchestrator(retargeted)).process(fixtureEvent)
        let retargetedSnapshot = await retargeted.snapshot()
        #expect(retargetedSnapshot.created.isEmpty)
        #expect(retargetedSnapshot.updated.isEmpty)
    }

    @Test("A base push reprocesses open pull requests targeting that branch")
    func basePush() async throws {
        let api = FakeGitHubAPI()
        let refreshed = PullRequestEvent(
            action: "base_push", installationID: fixtureEvent.installationID,
            repository: fixtureEvent.repository, number: fixtureEvent.number,
            baseRef: "main", baseSHA: "new-base-sha", headSHA: fixtureEvent.headSHA)
        await api.setPullRequestPage(1, events: [refreshed])
        await api.setBase(sha: refreshed.baseSHA)
        await api.setPage(1, files: ["Package.resolved"])
        await api.setContent(path: "Package.resolved", ref: refreshed.baseSHA,
                             result: .success(resolved("1.0.0")))
        await api.setContent(path: "Package.resolved", ref: refreshed.headSHA,
                             result: .success(resolved("1.0.1")))
        await api.setContent(path: ".swiftserve.json", ref: refreshed.baseSHA,
                             result: .failure(.notFound))
        await (try makeOrchestrator(api)).process(.basePush(.init(
            installationID: fixtureEvent.installationID, repository: fixtureEvent.repository,
            branch: "main", afterSHA: refreshed.baseSHA)))
        #expect(await api.pullRequestPageCalls() == [1])
        #expect(await api.snapshot().created.first?.conclusion == .success)
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
