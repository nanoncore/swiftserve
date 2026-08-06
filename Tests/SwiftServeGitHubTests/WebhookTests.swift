import Foundation
import SwiftServeGitHub
import Testing

@Suite("GitHub webhook boundary")
struct WebhookTests {
    let secret = "test-webhook-secret"

    @Test("Valid signatures enqueue accepted pull request actions")
    func validSignature() async {
        let queue = RecordingQueue()
        let body = webhookBody(action: "synchronize")
        let response = await WebhookHandler(secret: secret, queue: queue).handle(
            eventName: "pull_request",
            signature: WebhookSignatureVerifier.signature(secret: secret, body: body), body: body)
        #expect(response == .init(status: 202, code: "accepted"))
        #expect(await queue.count() == 1)
    }

    @Test(arguments: [
        (nil, "signature_missing"),
        ("sha256=nope", "signature_malformed"),
        ("sha256=0000000000000000000000000000000000000000000000000000000000000000", "signature_invalid"),
    ] as [(String?, String)])
    func rejectedSignatures(signature: String?, code: String) async {
        let queue = RecordingQueue()
        let response = await WebhookHandler(secret: secret, queue: queue).handle(
            eventName: "pull_request", signature: signature, body: webhookBody())
        #expect(response.status == 401)
        #expect(response.code == code)
        #expect(await queue.count() == 0)
    }

    @Test("Payload size is enforced")
    func payloadLimit() async {
        let queue = RecordingQueue()
        let response = await WebhookHandler(secret: secret, payloadLimit: 3, queue: queue).handle(
            eventName: "pull_request", signature: nil, body: Data("large".utf8))
        #expect(response == .init(status: 413, code: "payload_too_large"))
    }

    @Test(arguments: ["opened", "synchronize", "reopened"])
    func acceptedActions(action: String) async {
        let queue = RecordingQueue()
        let body = webhookBody(action: action)
        let response = await WebhookHandler(secret: secret, queue: queue).handle(
            eventName: "pull_request",
            signature: WebhookSignatureVerifier.signature(secret: secret, body: body), body: body)
        #expect(response.code == "accepted")
    }

    @Test("Edited events are accepted only when the base changed")
    func editedBase() async {
        let queue = RecordingQueue()
        let changed = webhookBody(action: "edited", baseEdited: true)
        let unchanged = webhookBody(action: "edited")
        let handler = WebhookHandler(secret: secret, queue: queue)
        #expect(await handler.handle(
            eventName: "pull_request",
            signature: WebhookSignatureVerifier.signature(secret: secret, body: changed),
            body: changed).code == "accepted")
        #expect(await handler.handle(
            eventName: "pull_request",
            signature: WebhookSignatureVerifier.signature(secret: secret, body: unchanged),
            body: unchanged).code == "action_ignored")
        #expect(await queue.count() == 1)
    }

    @Test("Branch pushes enqueue base invalidation work")
    func basePush() async {
        let queue = RecordingQueue()
        let body = pushBody()
        let response = await WebhookHandler(secret: secret, queue: queue).handle(
            eventName: "push",
            signature: WebhookSignatureVerifier.signature(secret: secret, body: body), body: body)
        #expect(response.code == "accepted")
        #expect(await queue.recorded() == [
            .basePush(.init(
                installationID: 99, repository: fixtureEvent.repository,
                branch: "main", afterSHA: "new-base-sha")),
        ])
    }

    @Test("Tag and deleted-branch pushes are ignored")
    func ignoredPushes() async {
        let queue = RecordingQueue()
        for body in [pushBody(ref: "refs/tags/1.0.0"), pushBody(after: String(repeating: "0", count: 40))] {
            let response = await WebhookHandler(secret: secret, queue: queue).handle(
                eventName: "push",
                signature: WebhookSignatureVerifier.signature(secret: secret, body: body), body: body)
            #expect(response.code == "event_ignored")
        }
        #expect(await queue.count() == 0)
    }

    @Test("Unrelated actions and events are ignored after verification")
    func ignoredEvents() async {
        let queue = RecordingQueue()
        let body = webhookBody(action: "closed")
        let signature = WebhookSignatureVerifier.signature(secret: secret, body: body)
        #expect(await WebhookHandler(secret: secret, queue: queue).handle(
            eventName: "pull_request", signature: signature, body: body).code == "action_ignored")
        #expect(await WebhookHandler(secret: secret, queue: queue).handle(
            eventName: "issues", signature: signature, body: body).code == "event_ignored")
    }

    @Test(arguments: ["dependabot[bot]", "renovate[bot]", "octocat"])
    func noIdentityFiltering(sender: String) async {
        let queue = RecordingQueue()
        let body = webhookBody(sender: sender)
        let response = await WebhookHandler(secret: secret, queue: queue).handle(
            eventName: "pull_request",
            signature: WebhookSignatureVerifier.signature(secret: secret, body: body), body: body)
        #expect(response.code == "accepted")
    }

    @Test("Malformed signed JSON is rejected without enqueueing")
    func malformedPayload() async {
        let queue = RecordingQueue()
        let body = Data("not-json".utf8)
        let response = await WebhookHandler(secret: secret, queue: queue).handle(
            eventName: "pull_request",
            signature: WebhookSignatureVerifier.signature(secret: secret, body: body), body: body)
        #expect(response == .init(status: 400, code: "payload_malformed"))
    }
}
