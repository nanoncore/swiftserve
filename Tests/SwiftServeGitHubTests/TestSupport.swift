import Foundation
import SwiftServeGitHub

let fixtureEvent = PullRequestEvent(
    action: "opened", installationID: 99,
    repository: .init(id: 42, owner: "acme", name: "demo"),
    number: 7, baseRef: "main", baseSHA: "base-sha", headSHA: "head-sha")

func resolved(_ version: String) -> Data {
    Data("""
    {"version":3,"pins":[{"identity":"demo","kind":"remoteSourceControl","location":"https://github.com/acme/demo.git","state":{"revision":"abc","version":"\(version)"}}]}
    """.utf8)
}

func webhookBody(action: String = "opened", sender: String = "human",
                 baseEdited: Bool = false) -> Data {
    var payload: [String: Any] = [
        "action": action,
        "number": 7,
        "installation": ["id": 99],
        "repository": ["id": 42, "name": "demo", "owner": ["login": "acme"]],
        "pull_request": [
            "base": ["ref": "main", "sha": "base-sha"],
            "head": ["ref": "feature", "sha": "head-sha"],
        ],
        "sender": ["login": sender],
    ]
    if baseEdited { payload["changes"] = ["base": ["ref": ["from": "develop"]]] }
    return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
}

func pushBody(ref: String = "refs/heads/main", after: String = "new-base-sha") -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "ref": ref,
        "after": after,
        "installation": ["id": 99],
        "repository": ["id": 42, "name": "demo", "owner": ["login": "acme"]],
    ], options: [.sortedKeys])
}

actor RecordingQueue: WebhookJobEnqueuing {
    private(set) var jobs: [WebhookJob] = []
    private(set) var deliveries: [String] = []
    var accepts = true

    func enqueue(deliveryID: String, job: WebhookJob) -> Bool {
        guard accepts else { return false }
        deliveries.append(deliveryID)
        jobs.append(job)
        return true
    }

    func count() -> Int { jobs.count }
    func recorded() -> [WebhookJob] { jobs }
}

actor FakeGitHubAPI: GitHubAPI {
    var pages: [Int: Page<ChangedFile>] = [:]
    var changedFileFailures: [GitHubAPIError] = []
    var pullRequestPages: [Int: Page<PullRequestEvent>] = [:]
    var contentResults: [String: Result<Data, GitHubAPIError>] = [:]
    var currentState = PullRequestState(
        baseRef: fixtureEvent.baseRef, baseSHA: fixtureEvent.baseSHA,
        headSHA: fixtureEvent.headSHA)
    var existingCheckID: Int64?
    var contentCalls: [(String, String)] = []
    var changedFilePages: [Int] = []
    var listedPullRequestPages: [Int] = []
    var checkRunLookups = 0
    var holdCheckRunLookups = false
    var checkRunLookupWaiters: [CheckedContinuation<Void, Never>] = []
    var created: [CheckPublication] = []
    var updated: [CheckPublication] = []

    func setPage(_ number: Int, files: [String], hasNext: Bool = false) {
        pages[number] = Page(values: files.map { ChangedFile(filename: $0) }, hasNext: hasNext)
    }

    func setPage(_ number: Int, files: [ChangedFile], hasNext: Bool = false) {
        pages[number] = Page(values: files, hasNext: hasNext)
    }

    func failNextChangedFiles(with error: GitHubAPIError) {
        changedFileFailures.append(error)
    }

    func setPullRequestPage(_ number: Int, events: [PullRequestEvent], hasNext: Bool = false) {
        pullRequestPages[number] = Page(values: events, hasNext: hasNext)
    }

    func setContent(path: String, ref: String, result: Result<Data, GitHubAPIError>) {
        contentResults["\(path)@\(ref)"] = result
    }

    func setHead(_ sha: String) {
        currentState = .init(baseRef: currentState.baseRef, baseSHA: currentState.baseSHA, headSHA: sha)
    }
    func setBase(ref: String? = nil, sha: String) {
        currentState = .init(baseRef: ref ?? currentState.baseRef, baseSHA: sha,
                             headSHA: currentState.headSHA)
    }
    func setExistingCheck(_ id: Int64?) { existingCheckID = id }
    func holdCheckRunLookup() { holdCheckRunLookups = true }

    func releaseCheckRunLookups() {
        holdCheckRunLookups = false
        let waiters = checkRunLookupWaiters
        checkRunLookupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func changedFiles(for event: PullRequestEvent, page: Int, perPage: Int) async throws -> Page<ChangedFile> {
        changedFilePages.append(page)
        if !changedFileFailures.isEmpty { throw changedFileFailures.removeFirst() }
        return pages[page] ?? Page(values: [], hasNext: false)
    }

    func content(repository: RepositoryCoordinates, path: String, ref: String,
                 installationID: Int64) async throws -> Data {
        contentCalls.append((path, ref))
        return try contentResults["\(path)@\(ref)"]?.get() ?? { throw GitHubAPIError.notFound }()
    }

    func currentPullRequest(for event: PullRequestEvent) async throws -> PullRequestState {
        currentState
    }

    func pullRequests(repository: RepositoryCoordinates, baseRef: String, installationID: Int64,
                      page: Int, perPage: Int) async throws -> Page<PullRequestEvent> {
        listedPullRequestPages.append(page)
        return pullRequestPages[page] ?? Page(values: [], hasNext: false)
    }

    func checkRunID(repository: RepositoryCoordinates, headSHA: String, externalID: String,
                    installationID: Int64) async throws -> Int64? {
        checkRunLookups += 1
        if holdCheckRunLookups {
            await withCheckedContinuation { continuation in
                checkRunLookupWaiters.append(continuation)
            }
        }
        return existingCheckID
    }

    func createCheck(repository: RepositoryCoordinates, publication: CheckPublication,
                     installationID: Int64) async throws -> Int64 {
        created.append(publication)
        existingCheckID = 123
        return 123
    }

    func updateCheck(repository: RepositoryCoordinates, id: Int64, publication: CheckPublication,
                     installationID: Int64) async throws {
        updated.append(publication)
    }

    func snapshot() -> (created: [CheckPublication], updated: [CheckPublication],
                        calls: [(String, String)], pages: [Int]) {
        (created, updated, contentCalls, changedFilePages)
    }

    func pullRequestPageCalls() -> [Int] { listedPullRequestPages }
    func checkRunLookupCount() -> Int { checkRunLookups }
}

struct ImmediateQueue: WebhookJobEnqueuing {
    let orchestrator: GitHubCheckOrchestrator
    func enqueue(deliveryID: String, job: WebhookJob) async -> Bool {
        await orchestrator.process(job)
        return true
    }
}

final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(by interval: TimeInterval) { lock.withLock { value = value.addingTimeInterval(interval) } }
}
