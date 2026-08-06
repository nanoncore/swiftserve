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
        let transport = GitHubHTTPTransport(
            baseURL: configuration.apiBaseURL,
            connectionTimeout: configuration.connectTimeout,
            requestTimeout: configuration.requestTimeout,
            responseLimit: configuration.responseLimit)
        let tokens = InstallationTokenProvider(signer: signer, exchanger: transport)
        let github = GitHubHTTPClient(transport: transport, tokens: tokens)
        let orchestrator = GitHubCheckOrchestrator(
            api: github, gate: configuration.gate, capabilityDataset: dataset,
            lockfileLimit: configuration.lockfileLimit,
            policyLimit: configuration.policyLimit)
        let store = try SQLiteJobStore(path: configuration.jobStorePath)
        let metrics = OperationalMetrics()
        let queue = DurableJobQueue(
            store: store, retention: configuration.retention, metrics: metrics)
        let workers = DurableWorkerPool(
            store: store, orchestrator: orchestrator, metrics: metrics,
            capacity: configuration.workerCapacity,
            perInstallationCapacity: configuration.perInstallationCapacity,
            leaseDuration: configuration.leaseDuration,
            retention: configuration.retention,
            retryPolicy: .init(maxAttempts: configuration.retryMaxAttempts,
                               maxElapsed: configuration.retryMaxElapsed))
        await workers.start()
        let webhook = WebhookHandler(
            secret: configuration.webhookSecret,
            previousSecret: configuration.previousWebhookSecret,
            payloadLimit: configuration.payloadLimit, queue: queue, metrics: metrics)

        let signatureName = HTTPField.Name("X-Hub-Signature-256")!
        let eventName = HTTPField.Name("X-GitHub-Event")!
        let deliveryName = HTTPField.Name("X-GitHub-Delivery")!
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
                deliveryID: request.headers[deliveryName],
                signature: request.headers[signatureName],
                body: Data(bytes.readableBytesView))
            return jsonResponse(status: result.status, code: result.code)
        }
        router.get("/livez") { _, _ -> Response in
            jsonResponse(status: 200, code: "alive")
        }
        router.get("/readyz") { _, _ -> Response in
            let workersReady = await workers.isReady()
            let accepting = await queue.isAccepting()
            let storeReady = await store.isReady()
            let ready = workersReady && accepting && storeReady
            return jsonResponse(status: ready ? 200 : 503, code: ready ? "ready" : "not_ready")
        }
        router.get("/metrics") { _, _ -> Response in
            let depth = (try? await store.queueDepth()) ?? -1
            let snapshot = await metrics.snapshot(queueDepth: depth)
            let data = (try? JSONEncoder().encode(snapshot)) ?? Data("{}".utf8)
            return dataResponse(status: 200, data: data)
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(configuration.host, port: configuration.port),
                serverName: "SwiftServeGitHubApp"))
        print("SwiftServe GitHub App listening on \(configuration.host):\(configuration.port)")
        do {
            try await app.runService()
            await queue.stopAccepting()
            await workers.shutdown()
        } catch {
            await queue.stopAccepting()
            await workers.shutdown()
            throw error
        }
    }

    private static func jsonResponse(status: Int, code: String) -> Response {
        var buffer = ByteBuffer()
        buffer.writeString("{\"status\":\"\(code)\"}")
        return Response(status: .init(code: status),
                        headers: [.contentType: "application/json; charset=utf-8"],
                        body: .init(byteBuffer: buffer))
    }

    private static func dataResponse(status: Int, data: Data) -> Response {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
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
