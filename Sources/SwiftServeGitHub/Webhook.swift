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
    /// Returns only after the job and its idempotency key are durably committed.
    func enqueue(deliveryID: String, job: WebhookJob) async -> Bool
}

public struct WebhookHandler: Sendable {
    public static let acceptedActions: Set<String> = ["opened", "synchronize", "reopened", "edited"]

    private let verifier: WebhookSignatureVerifier
    private let payloadLimit: Int
    private let queue: any WebhookJobEnqueuing
    private let metrics: OperationalMetrics?

    public init(secret: String, previousSecret: String? = nil,
                payloadLimit: Int = 1 << 20, queue: any WebhookJobEnqueuing,
                metrics: OperationalMetrics? = nil) {
        verifier = WebhookSignatureVerifier(secret: secret, previousSecret: previousSecret)
        self.payloadLimit = payloadLimit
        self.queue = queue
        self.metrics = metrics
    }

    public func handle(eventName: String?, deliveryID: String? = nil,
                       signature: String?, body: Data) async -> WebhookResponse {
        guard body.count <= payloadLimit else {
            return await finish(.init(status: 413, code: "payload_too_large"))
        }
        switch verifier.verify(header: signature, body: body) {
        case .valid: break
        case .missing: return await finish(.init(status: 401, code: "signature_missing"))
        case .malformed: return await finish(.init(status: 401, code: "signature_malformed"))
        case .invalid: return await finish(.init(status: 401, code: "signature_invalid"))
        }
        let job: WebhookJob
        switch eventName {
        case "pull_request":
            guard let webhook = try? JSONDecoder().decode(PullRequestWebhook.self, from: body) else {
                return await finish(.init(status: 400, code: "payload_malformed"))
            }
            guard Self.acceptedActions.contains(webhook.action) else {
                return await finish(.init(status: 202, code: "action_ignored"))
            }
            guard webhook.action != "edited" || webhook.editedBase else {
                return await finish(.init(status: 202, code: "action_ignored"))
            }
            job = .pullRequest(webhook.event)
        case "push":
            guard let webhook = try? JSONDecoder().decode(PushWebhook.self, from: body) else {
                return await finish(.init(status: 400, code: "payload_malformed"))
            }
            guard let event = webhook.event else {
                return await finish(.init(status: 202, code: "event_ignored"))
            }
            job = .basePush(event)
        default:
            return await finish(.init(status: 202, code: "event_ignored"))
        }
        guard let deliveryID, Self.validDeliveryID(deliveryID) else {
            return await finish(.init(status: 400, code: "delivery_id_invalid"))
        }
        guard await queue.enqueue(deliveryID: deliveryID, job: job) else {
            return await finish(.init(status: 503, code: "enqueue_failed"))
        }
        return await finish(.init(status: 202, code: "accepted"))
    }

    private func finish(_ response: WebhookResponse) async -> WebhookResponse {
        if response.status >= 200, response.status < 300 {
            await metrics?.webhookAccepted()
        } else {
            await metrics?.webhookRejected()
        }
        return response
    }

    private static func validDeliveryID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
        }
    }
}
