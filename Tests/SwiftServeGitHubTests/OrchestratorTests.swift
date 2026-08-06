import Foundation
import SwiftServeEvidence
import SwiftServeGitHub
import SwiftServeReceipt
import Testing

@Suite("GitHub Check orchestration")
struct OrchestratorTests {
    func makeOrchestrator(_ api: FakeGitHubAPI,
                          gate: ReceiptGateThreshold = .block) throws -> GitHubCheckOrchestrator {
        GitHubCheckOrchestrator(
            api: api, gate: gate, capabilityDataset: try CapabilityEvidenceLoader.load(),
            generatedAt: { "2026-08-06T12:00:00Z" })
    }

    func configure(_ api: FakeGitHubAPI, files: [ChangedFile],
                   base: Data = resolved("1.0.0"), head: Data = resolved("1.0.1"),
                   policy: Result<Data, GitHubAPIError> = .failure(.notFound)) async {
        await api.setPage(1, files: files)
        for file in files {
            let basePath = file.status == "added" ? nil : (file.previousFilename ?? file.filename)
            let headPath = file.status == "removed" ? nil : file.filename
            if let basePath { await api.setContent(path: basePath, ref: fixtureEvent.baseSHA, result: .success(base)) }
            if let headPath { await api.setContent(path: headPath, ref: fixtureEvent.headSHA, result: .success(head)) }
        }
        await api.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA, result: policy)
    }

    func final(_ api: FakeGitHubAPI) async -> CheckPublication? {
        await api.snapshot().updated.last
    }

    @Test("Two lockfiles produce one deterministic aggregate Check")
    func multiLockfile() async throws {
        let first = FakeGitHubAPI()
        await configure(first, files: [
            .init(filename: "Z/Package.resolved"),
            .init(filename: "A/Package.resolved"),
        ])
        await (try makeOrchestrator(first)).process(fixtureEvent)
        let snapshot = await first.snapshot()
        let publication = try #require(snapshot.updated.last)
        #expect(snapshot.created.count == 1)
        #expect(snapshot.created[0].status == .inProgress)
        #expect(snapshot.updated.filter { $0.status == .completed }.count == 1)
        #expect(publication.conclusion == .success)
        #expect(publication.title.contains("2 lockfiles"))
        let a = try #require(publication.summary.range(of: "A/Package.resolved"))
        let z = try #require(publication.summary.range(of: "Z/Package.resolved"))
        #expect(a.lowerBound < z.lowerBound)
        #expect(publication.summary.components(separatedBy: "## 🍦 Upgrade Receipt — PASS").count == 3)

        let reversed = FakeGitHubAPI()
        await configure(reversed, files: [
            .init(filename: "A/Package.resolved"),
            .init(filename: "Z/Package.resolved"),
        ])
        await (try makeOrchestrator(reversed)).process(fixtureEvent)
        #expect(await final(reversed)?.summary == publication.summary)
    }

    @Test("Changed-file pagination and immutable SHA fetches cover every input")
    func paginationAndImmutableInputs() async throws {
        let api = FakeGitHubAPI()
        await api.setPage(1, files: ["README.md"], hasNext: true)
        await api.setPage(2, files: ["App/Package.resolved"])
        await api.setContent(path: "App/Package.resolved", ref: fixtureEvent.baseSHA,
                             result: .success(resolved("1.0.0")))
        await api.setContent(path: "App/Package.resolved", ref: fixtureEvent.headSHA,
                             result: .success(resolved("1.0.1")))
        await api.setContent(path: ".swiftserve.json", ref: fixtureEvent.baseSHA,
                             result: .failure(.notFound))
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let snapshot = await api.snapshot()
        #expect(snapshot.pages == [1, 2])
        #expect(snapshot.calls.contains { $0 == ("App/Package.resolved", fixtureEvent.baseSHA) })
        #expect(snapshot.calls.contains { $0 == ("App/Package.resolved", fixtureEvent.headSHA) })
        #expect(snapshot.calls.contains { $0 == (".swiftserve.json", fixtureEvent.baseSHA) })
        #expect(!snapshot.calls.contains { $0 == (".swiftserve.json", fixtureEvent.headSHA) })
    }

    @Test("Incomplete changed-file enumeration fails closed")
    func incompleteChangedFileEnumeration() async throws {
        let api = FakeGitHubAPI()
        await api.setPage(1, files: ["README.md"])
        await api.setChangedFileCount(3_001)
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let publication = try #require(await final(api))
        #expect(publication.conclusion == .failure)
        #expect(publication.summary.contains("only 1 of 3001 changed files"))
        #expect(!publication.title.contains("No Package.resolved changed"))
    }

    @Test("Added, deleted, modified, and renamed lockfiles model empty sides in memory")
    func lifecycle() async throws {
        let files: [ChangedFile] = [
            .init(filename: "Added/Package.resolved", status: "added"),
            .init(filename: "Deleted/Package.resolved", status: "removed"),
            .init(filename: "Modified/Package.resolved", status: "modified"),
            .init(filename: "Renamed/Package.resolved", status: "renamed",
                  previousFilename: "Old/Package.resolved"),
        ]
        let api = FakeGitHubAPI()
        await configure(api, files: files)
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let snapshot = await api.snapshot()
        #expect(await final(api)?.status == .completed)
        #expect(!snapshot.calls.contains { $0 == ("Added/Package.resolved", fixtureEvent.baseSHA) })
        #expect(!snapshot.calls.contains { $0 == ("Deleted/Package.resolved", fixtureEvent.headSHA) })
        #expect(snapshot.calls.contains { $0 == ("Old/Package.resolved", fixtureEvent.baseSHA) })
        #expect(snapshot.calls.contains { $0 == ("Renamed/Package.resolved", fixtureEvent.headSHA) })
    }

    @Test("One malformed lockfile does not hide a valid lockfile and fails closed")
    func isolatedMalformedInput() async throws {
        let api = FakeGitHubAPI()
        await configure(api, files: [
            .init(filename: "Bad/Package.resolved"),
            .init(filename: "Good/Package.resolved"),
        ])
        await api.setContent(path: "Bad/Package.resolved", ref: fixtureEvent.headSHA,
                             result: .success(Data("raw-secret-lockfile".utf8)))
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let publication = try #require(await final(api))
        #expect(publication.conclusion == .failure)
        #expect(publication.title.contains("BLOCK"))
        #expect(publication.summary.contains("Bad/Package.resolved"))
        #expect(publication.summary.contains("lockfile_malformed"))
        #expect(publication.summary.contains("Good/Package.resolved"))
        #expect(publication.summary.contains("## 🍦 Upgrade Receipt — PASS"))
        #expect(!publication.summary.contains("raw-secret-lockfile"))
    }

    @Test("Worst verdict drives every aggregate gate mapping")
    func worstVerdictAndGate() async throws {
        let reviewAPI = FakeGitHubAPI()
        await configure(reviewAPI, files: [
            .init(filename: "Pass/Package.resolved"),
            .init(filename: "Review/Package.resolved"),
        ])
        await reviewAPI.setContent(path: "Review/Package.resolved", ref: fixtureEvent.headSHA,
                                   result: .success(resolved("2.0.0")))
        await (try makeOrchestrator(reviewAPI, gate: .block)).process(fixtureEvent)
        #expect(await final(reviewAPI)?.conclusion == .neutral)
        #expect(await final(reviewAPI)?.title.contains("REVIEW") == true)

        let strictReview = FakeGitHubAPI()
        await configure(strictReview, files: [.init(filename: "Package.resolved")],
                        head: resolved("2.0.0"))
        await (try makeOrchestrator(strictReview, gate: .review)).process(fixtureEvent)
        #expect(await final(strictReview)?.conclusion == .failure)

        let blockAPI = FakeGitHubAPI()
        let blockPolicy = Data("""
        {"version":1,"rules":{"major-update":"block"}}
        """.utf8)
        await configure(blockAPI, files: [.init(filename: "Package.resolved")],
                        head: resolved("2.0.0"), policy: .success(blockPolicy))
        await (try makeOrchestrator(blockAPI, gate: .block)).process(fixtureEvent)
        #expect(await final(blockAPI)?.conclusion == .failure)
        #expect(await final(blockAPI)?.title.contains("BLOCK") == true)

        #expect(GitHubCheckOrchestrator.conclusion(for: .pass, gate: .block) == .success)
        #expect(GitHubCheckOrchestrator.conclusion(for: .pass, gate: .review) == .success)
        #expect(GitHubCheckOrchestrator.conclusion(for: .block, gate: .review) == .failure)
    }

    @Test("Malicious lockfile paths are rendered as inert Markdown")
    func maliciousPath() async throws {
        let path = "evil|`x`\n# injected/Package.resolved"
        let api = FakeGitHubAPI()
        await configure(api, files: [.init(filename: path)])
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let summary = try #require(await final(api)?.summary)
        #expect(summary.contains("evil\\|"))
        #expect(summary.contains("\\n# injected"))
        #expect(!summary.contains("evil|`x`\n# injected"))
    }

    @Test("Aggregate output truncates only between lockfile sections")
    func aggregateLimit() async throws {
        let api = FakeGitHubAPI()
        let files = (0..<90).map { index in
            ChangedFile(filename: "\(String(repeating: "x", count: 450))/\(index)/Package.resolved")
        }
        await configure(api, files: files)
        await (try makeOrchestrator(api)).process(fixtureEvent)
        let summary = try #require(await final(api)?.summary)
        #expect(summary.utf8.count <= GitHubCheckOrchestrator.outputByteLimit)
        #expect(summary.contains("sections omitted to fit GitHub Check output limits"))
        #expect(!summary.hasSuffix("| Package | Before"))
    }

    @Test("Lockfile and policy content limits fail closed without content exposure")
    func contentLimits() async throws {
        let lockAPI = FakeGitHubAPI()
        await configure(lockAPI, files: [.init(filename: "Package.resolved")])
        let lockOrchestrator = GitHubCheckOrchestrator(
            api: lockAPI, capabilityDataset: try CapabilityEvidenceLoader.load(),
            lockfileLimit: 8, policyLimit: 1024)
        await lockOrchestrator.process(fixtureEvent)
        let lockSummary = try #require(await final(lockAPI)?.summary)
        #expect(lockSummary.contains("lockfile_too_large"))
        #expect(!lockSummary.contains("https://github.com/acme/demo.git"))

        let policyAPI = FakeGitHubAPI()
        let oversized = Data("POLICY-CONTENT-SENTINEL".utf8)
        await configure(policyAPI, files: [.init(filename: "Package.resolved")],
                        policy: .success(oversized))
        let policyOrchestrator = GitHubCheckOrchestrator(
            api: policyAPI, capabilityDataset: try CapabilityEvidenceLoader.load(),
            lockfileLimit: 1024, policyLimit: 8)
        await policyOrchestrator.process(fixtureEvent)
        let policySummary = try #require(await final(policyAPI)?.summary)
        #expect(policySummary.contains("policy_too_large"))
        #expect(!policySummary.contains("POLICY-CONTENT-SENTINEL"))
    }

    @Test("Zero lockfiles skip and stale immutable states never publish")
    func skippedAndStale() async throws {
        let zero = FakeGitHubAPI()
        await zero.setPage(1, files: ["README.md"])
        await (try makeOrchestrator(zero)).process(fixtureEvent)
        #expect(await final(zero)?.conclusion == .skipped)

        let stale = FakeGitHubAPI()
        await configure(stale, files: [.init(filename: "Package.resolved")])
        await stale.setHead("newer-head")
        await (try makeOrchestrator(stale)).process(fixtureEvent)
        #expect(await stale.snapshot().created.isEmpty)
        #expect(await stale.snapshot().updated.isEmpty)
    }

    @Test("Redelivery completes the same Check Run")
    func redelivery() async throws {
        let api = FakeGitHubAPI()
        await configure(api, files: [.init(filename: "Package.resolved")])
        let orchestrator = try makeOrchestrator(api)
        await orchestrator.process(fixtureEvent)
        await orchestrator.process(fixtureEvent)
        let snapshot = await api.snapshot()
        #expect(snapshot.created.count == 1)
        #expect(snapshot.updated.count == 3)
        #expect(Set(snapshot.created.map(\.externalID) + snapshot.updated.map(\.externalID)) ==
                Set([fixtureEvent.externalID]))
        #expect(snapshot.updated.last?.status == .completed)
    }

    @Test("Generic Markdown truncation stays on complete lines")
    func markdownLimit() {
        let markdown = (0..<100).map { "| row \($0) | `value` |" }.joined(separator: "\n")
        let bounded = GitHubCheckOrchestrator.boundedMarkdown(markdown, limit: 180)
        #expect(bounded.utf8.count <= 180)
        #expect(bounded.hasSuffix("_Output truncated at a safe line boundary for GitHub Check limits._"))
        #expect(!bounded.contains("row 99"))
    }
}
