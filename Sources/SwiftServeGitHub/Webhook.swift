import Foundation

public struct WebhookResponse: Sendable, Equatable {
    public let status: Int
    public let code: String

    public init(status: Int, code: String) {
        self.status = status
        self.code = code
    }
}

public protocol WebhookJobEnqueuing: Sendable {
    func enqueue(_ job: WebhookJob) async -> Bool
}

public struct WebhookHandler: Sendable {
    public static let acceptedActions: Set<String> = ["opened", "synchronize", "reopened", "edited"]

    private let verifier: WebhookSignatureVerifier
    private let payloadLimit: Int
    private let queue: any WebhookJobEnqueuing

    public init(secret: String, payloadLimit: Int = 1 << 20, queue: any WebhookJobEnqueuing) {
        verifier = WebhookSignatureVerifier(secret: secret)
        self.payloadLimit = payloadLimit
        self.queue = queue
    }

    public func handle(eventName: String?, signature: String?, body: Data) async -> WebhookResponse {
        guard body.count <= payloadLimit else {
            return .init(status: 413, code: "payload_too_large")
        }
        switch verifier.verify(header: signature, body: body) {
        case .valid: break
        case .missing: return .init(status: 401, code: "signature_missing")
        case .malformed: return .init(status: 401, code: "signature_malformed")
        case .invalid: return .init(status: 401, code: "signature_invalid")
        }
        let job: WebhookJob
        switch eventName {
        case "pull_request":
            guard let webhook = try? JSONDecoder().decode(PullRequestWebhook.self, from: body) else {
                return .init(status: 400, code: "payload_malformed")
            }
            guard Self.acceptedActions.contains(webhook.action) else {
                return .init(status: 202, code: "action_ignored")
            }
            guard webhook.action != "edited" || webhook.editedBase else {
                return .init(status: 202, code: "action_ignored")
            }
            job = .pullRequest(webhook.event)
        case "push":
            guard let webhook = try? JSONDecoder().decode(PushWebhook.self, from: body) else {
                return .init(status: 400, code: "payload_malformed")
            }
            guard let event = webhook.event else {
                return .init(status: 202, code: "event_ignored")
            }
            job = .basePush(event)
        default:
            return .init(status: 202, code: "event_ignored")
        }
        guard await queue.enqueue(job) else {
            return .init(status: 503, code: "queue_full")
        }
        return .init(status: 202, code: "accepted")
    }
}

public actor BoundedWebhookQueue: WebhookJobEnqueuing {
    private let capacity: Int
    private let orchestrator: GitHubCheckOrchestrator
    private var active: Set<String> = []

    public init(capacity: Int, orchestrator: GitHubCheckOrchestrator) {
        self.capacity = capacity
        self.orchestrator = orchestrator
    }

    public func enqueue(_ job: WebhookJob) -> Bool {
        if active.contains(job.stableID) { return true }
        guard active.count < capacity else { return false }
        active.insert(job.stableID)
        Task {
            await orchestrator.process(job)
            self.finished(job.stableID)
        }
        return true
    }

    private func finished(_ externalID: String) {
        active.remove(externalID)
    }
}
