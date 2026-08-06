import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import SwiftServeEvidence
import SwiftServeGitHub
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct SwiftServeGitHubApplication {
    static func main() async {
        do {
            try await run()
        } catch let diagnostic as SafeDiagnostic {
            writeStartupError(diagnostic)
            exit(2)
        } catch {
            writeStartupError(.init(code: "startup.failed", message: "GitHub App startup validation failed"))
            exit(2)
        }
    }

    private static func run() async throws {
        let configuration = try GitHubAppConfiguration(environment: ProcessInfo.processInfo.environment)
        let signer: AppJWTSigner
        do {
            signer = try AppJWTSigner(appID: configuration.appID, privateKeyPEM: configuration.privateKeyPEM)
        } catch {
            throw SafeDiagnostic(code: "configuration.invalid_private_key",
                                 message: "SWIFTSERVE_GITHUB_PRIVATE_KEY is not a valid RSA private key")
        }
        let dataset = try CapabilityEvidenceLoader.load()
        let transport = GitHubHTTPTransport(baseURL: configuration.apiBaseURL)
        let tokens = InstallationTokenProvider(signer: signer, exchanger: transport)
        let github = GitHubHTTPClient(transport: transport, tokens: tokens)
        let orchestrator = GitHubCheckOrchestrator(
            api: github, gate: configuration.gate, capabilityDataset: dataset)
        let queue = BoundedWebhookQueue(capacity: configuration.workerCapacity, orchestrator: orchestrator)
        let webhook = WebhookHandler(
            secret: configuration.webhookSecret, payloadLimit: configuration.payloadLimit, queue: queue)

        let signatureName = HTTPField.Name("X-Hub-Signature-256")!
        let eventName = HTTPField.Name("X-GitHub-Event")!
        let router = Router()
        router.post("/webhooks/github") { request, _ -> Response in
            let bytes: ByteBuffer
            do {
                bytes = try await request.body.collect(upTo: configuration.payloadLimit)
            } catch {
                return jsonResponse(status: 413, code: "payload_too_large")
            }
            let result = await webhook.handle(
                eventName: request.headers[eventName],
                signature: request.headers[signatureName],
                body: Data(bytes.readableBytesView))
            return jsonResponse(status: result.status, code: result.code)
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(configuration.host, port: configuration.port),
                serverName: "SwiftServeGitHubApp"))
        print("SwiftServe GitHub App listening on \(configuration.host):\(configuration.port)")
        try await app.runService()
    }

    private static func jsonResponse(status: Int, code: String) -> Response {
        var buffer = ByteBuffer()
        buffer.writeString("{\"status\":\"\(code)\"}")
        return Response(status: .init(code: status),
                        headers: [.contentType: "application/json; charset=utf-8"],
                        body: .init(byteBuffer: buffer))
    }

    private static func writeStartupError(_ error: SafeDiagnostic) {
        let payload = ["error": ["code": error.code, "message": error.message]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
