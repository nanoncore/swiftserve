import Foundation

public struct RepositoryCoordinates: Sendable, Equatable {
    public let id: Int64
    public let owner: String
    public let name: String

    public init(id: Int64, owner: String, name: String) {
        self.id = id
        self.owner = owner
        self.name = name
    }
}

public struct PullRequestEvent: Sendable, Equatable {
    public let action: String
    public let installationID: Int64
    public let repository: RepositoryCoordinates
    public let number: Int
    public let baseRef: String
    public let baseSHA: String
    public let headSHA: String

    public init(action: String, installationID: Int64, repository: RepositoryCoordinates,
                number: Int, baseRef: String, baseSHA: String, headSHA: String) {
        self.action = action
        self.installationID = installationID
        self.repository = repository
        self.number = number
        self.baseRef = baseRef
        self.baseSHA = baseSHA
        self.headSHA = headSHA
    }

    public var externalID: String {
        "swiftserve:\(repository.id):\(number):\(headSHA)"
    }
}

struct PullRequestWebhook: Decodable {
    let action: String
    let number: Int
    let installation: Installation
    let repository: Repository
    let pullRequest: PullRequest
    let changes: Changes?

    struct Installation: Decodable { let id: Int64 }
    struct Repository: Decodable {
        let id: Int64
        let name: String
        let owner: Owner
        struct Owner: Decodable { let login: String }
    }
    struct PullRequest: Decodable {
        let base: GitReference
        let head: GitReference
        struct GitReference: Decodable { let ref: String; let sha: String }
    }
    struct Changes: Decodable {
        let base: BaseChange?
        struct BaseChange: Decodable {}
    }

    enum CodingKeys: String, CodingKey {
        case action, number, installation, repository, changes
        case pullRequest = "pull_request"
    }

    var event: PullRequestEvent {
        PullRequestEvent(
            action: action,
            installationID: installation.id,
            repository: .init(id: repository.id, owner: repository.owner.login, name: repository.name),
            number: number,
            baseRef: pullRequest.base.ref,
            baseSHA: pullRequest.base.sha,
            headSHA: pullRequest.head.sha)
    }

    var editedBase: Bool { changes?.base != nil }
}

struct PushWebhook: Decodable {
    let ref: String
    let after: String
    let installation: PullRequestWebhook.Installation
    let repository: PullRequestWebhook.Repository

    var event: RepositoryPushEvent? {
        let prefix = "refs/heads/"
        guard ref.hasPrefix(prefix), after.contains(where: { $0 != "0" }) else { return nil }
        return RepositoryPushEvent(
            installationID: installation.id,
            repository: .init(id: repository.id, owner: repository.owner.login, name: repository.name),
            branch: String(ref.dropFirst(prefix.count)), afterSHA: after)
    }
}

public struct RepositoryPushEvent: Sendable, Equatable {
    public let installationID: Int64
    public let repository: RepositoryCoordinates
    public let branch: String
    public let afterSHA: String

    public init(installationID: Int64, repository: RepositoryCoordinates,
                branch: String, afterSHA: String) {
        self.installationID = installationID
        self.repository = repository
        self.branch = branch
        self.afterSHA = afterSHA
    }
}

public enum WebhookJob: Sendable, Equatable {
    case pullRequest(PullRequestEvent)
    case basePush(RepositoryPushEvent)

    public var stableID: String {
        switch self {
        case .pullRequest(let event):
            "swiftserve:pr-job:\(event.repository.id):\(event.number):\(event.baseRef):\(event.baseSHA):\(event.headSHA)"
        case .basePush(let event):
            "swiftserve:base-push:\(event.repository.id):\(event.branch):\(event.afterSHA)"
        }
    }
}

public struct PullRequestState: Sendable, Equatable {
    public let baseRef: String
    public let baseSHA: String
    public let headSHA: String

    public init(baseRef: String, baseSHA: String, headSHA: String) {
        self.baseRef = baseRef
        self.baseSHA = baseSHA
        self.headSHA = headSHA
    }
}

public enum CheckConclusion: String, Codable, Sendable, Equatable {
    case success
    case neutral
    case failure
    case skipped
    case actionRequired = "action_required"
}

public struct CheckPublication: Sendable, Equatable {
    public static let name = "SwiftServe / Upgrade Receipt"

    public let name: String
    public let headSHA: String
    public let externalID: String
    public let conclusion: CheckConclusion
    public let title: String
    public let summary: String

    public init(name: String = Self.name, headSHA: String, externalID: String,
                conclusion: CheckConclusion, title: String, summary: String) {
        self.name = name
        self.headSHA = headSHA
        self.externalID = externalID
        self.conclusion = conclusion
        self.title = title
        self.summary = summary
    }
}

public struct ChangedFile: Sendable, Equatable {
    public let filename: String
    public let status: String
    public let previousFilename: String?

    public init(filename: String, status: String = "modified", previousFilename: String? = nil) {
        self.filename = filename
        self.status = status
        self.previousFilename = previousFilename
    }
}

public struct Page<Element: Sendable>: Sendable {
    public let values: [Element]
    public let hasNext: Bool
    public init(values: [Element], hasNext: Bool) {
        self.values = values
        self.hasNext = hasNext
    }
}

public enum GitHubAPIError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound
    case unauthorized
    case rejected(status: Int)
    case malformedResponse
    case transport

    public var description: String {
        switch self {
        case .notFound: "GitHub resource was not found"
        case .unauthorized: "GitHub authentication was rejected"
        case .rejected(let status): "GitHub API request failed with status \(status)"
        case .malformedResponse: "GitHub returned an invalid response"
        case .transport: "GitHub API transport failed"
        }
    }
}

public protocol GitHubAPI: Sendable {
    func changedFiles(for event: PullRequestEvent, page: Int, perPage: Int) async throws -> Page<ChangedFile>
    func content(repository: RepositoryCoordinates, path: String, ref: String,
                 installationID: Int64) async throws -> Data
    func currentPullRequest(for event: PullRequestEvent) async throws -> PullRequestState
    func pullRequests(repository: RepositoryCoordinates, baseRef: String, installationID: Int64,
                      page: Int, perPage: Int) async throws -> Page<PullRequestEvent>
    func checkRunID(repository: RepositoryCoordinates, headSHA: String, externalID: String,
                    installationID: Int64) async throws -> Int64?
    func createCheck(repository: RepositoryCoordinates, publication: CheckPublication,
                     installationID: Int64) async throws
    func updateCheck(repository: RepositoryCoordinates, id: Int64, publication: CheckPublication,
                     installationID: Int64) async throws
}

public struct SafeDiagnostic: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code): \(message)" }
}
