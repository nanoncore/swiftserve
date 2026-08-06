import Foundation
import SwiftServeGitHub

let fixtureEvent = PullRequestEvent(
    action: "opened", installationID: 99,
    repository: .init(id: 42, owner: "acme", name: "demo"),
    number: 7, baseSHA: "base-sha", headSHA: "head-sha")

func resolved(_ version: String) -> Data {
    Data("""
    {"version":3,"pins":[{"identity":"demo","kind":"remoteSourceControl","location":"https://github.com/acme/demo.git","state":{"revision":"abc","version":"\(version)"}}]}
    """.utf8)
}

func webhookBody(action: String = "opened", sender: String = "human") -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "action": action,
        "number": 7,
        "installation": ["id": 99],
        "repository": ["id": 42, "name": "demo", "owner": ["login": "acme"]],
        "pull_request": ["base": ["sha": "base-sha"], "head": ["sha": "head-sha"]],
        "sender": ["login": sender],
    ], options: [.sortedKeys])
}

actor RecordingQueue: WebhookJobEnqueuing {
    private(set) var events: [PullRequestEvent] = []
    var accepts = true

    func enqueue(_ event: PullRequestEvent) -> Bool {
        guard accepts else { return false }
        events.append(event)
        return true
    }

    func count() -> Int { events.count }
}

actor FakeGitHubAPI: GitHubAPI {
    var pages: [Int: Page<ChangedFile>] = [:]
    var contentResults: [String: Result<Data, GitHubAPIError>] = [:]
    var headSHA = fixtureEvent.headSHA
    var existingCheckID: Int64?
    var contentCalls: [(String, String)] = []
    var changedFilePages: [Int] = []
    var created: [CheckPublication] = []
    var updated: [CheckPublication] = []

    func setPage(_ number: Int, files: [String], hasNext: Bool = false) {
        pages[number] = Page(values: files.map(ChangedFile.init), hasNext: hasNext)
    }

    func setContent(path: String, ref: String, result: Result<Data, GitHubAPIError>) {
        contentResults["\(path)@\(ref)"] = result
    }

    func setHead(_ sha: String) { headSHA = sha }
    func setExistingCheck(_ id: Int64?) { existingCheckID = id }

    func changedFiles(for event: PullRequestEvent, page: Int, perPage: Int) async throws -> Page<ChangedFile> {
        changedFilePages.append(page)
        return pages[page] ?? Page(values: [], hasNext: false)
    }

    func content(repository: RepositoryCoordinates, path: String, ref: String,
                 installationID: Int64) async throws -> Data {
        contentCalls.append((path, ref))
        return try contentResults["\(path)@\(ref)"]?.get() ?? { throw GitHubAPIError.notFound }()
    }

    func currentHeadSHA(for event: PullRequestEvent) async throws -> String { headSHA }

    func checkRunID(repository: RepositoryCoordinates, headSHA: String, externalID: String,
                    installationID: Int64) async throws -> Int64? { existingCheckID }

    func createCheck(repository: RepositoryCoordinates, publication: CheckPublication,
                     installationID: Int64) async throws {
        created.append(publication)
        existingCheckID = 123
    }

    func updateCheck(repository: RepositoryCoordinates, id: Int64, publication: CheckPublication,
                     installationID: Int64) async throws {
        updated.append(publication)
    }

    func snapshot() -> (created: [CheckPublication], updated: [CheckPublication],
                        calls: [(String, String)], pages: [Int]) {
        (created, updated, contentCalls, changedFilePages)
    }
}

struct ImmediateQueue: WebhookJobEnqueuing {
    let orchestrator: GitHubCheckOrchestrator
    func enqueue(_ event: PullRequestEvent) async -> Bool {
        await orchestrator.process(event)
        return true
    }
}
