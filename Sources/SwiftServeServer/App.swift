import Foundation
import Hummingbird
import HTTPTypes
import NIOCore
import SwiftServeCore

/// SwiftServe's web front door. Serves the hand-authored static frontend and
/// exposes `POST /analyze`, which turns a `Package.resolved` into a Scoop. We
/// dogfood Hummingbird on purpose.
@main
struct SwiftServeApp {
    /// Generous ceiling — a real Package.resolved is a few KB, never megabytes.
    static let maxBodySize = 1 << 20 // 1 MiB

    static func main() async throws {
        let port = ProcessInfo.processInfo.environment["PORT"].flatMap(Int.init) ?? 8080

        // Enrichment is additive: with a GITHUB_TOKEN we pull live GitHub data,
        // otherwise we fall back to the always-available file-only path.
        let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        let analyzer: Analyzer
        let mode: String
        if let token, !token.isEmpty {
            analyzer = Analyzer(enrichment: GitHubEnrichment(token: token))
            mode = "GitHub (token detected)"
        } else {
            analyzer = Analyzer()
            mode = "file-only (set GITHUB_TOKEN to enable live GitHub data)"
        }

        let router = Router()

        // POST /analyze — raw Package.resolved contents in, canonical JSON out.
        router.post("/analyze") { request, _ -> Response in
            let buffer: ByteBuffer
            do {
                buffer = try await request.body.collect(upTo: maxBodySize)
            } catch {
                return Self.errorResponse(.contentTooLarge,
                    "That file is bigger than a Package.resolved should ever be.")
            }

            do {
                let report = try await analyzer.analyze(resolved: Data(buffer.readableBytesView))
                return try Self.jsonResponse(report)
            } catch let error as PackageResolvedError {
                return Self.errorResponse(.badRequest, error.description)
            } catch {
                return Self.errorResponse(.internalServerError,
                    "Swiftee slipped while scanning. Mind trying that again?")
            }
        }

        // Everything else: the static frontend (index.html, css, js, sprites).
        router.addMiddleware {
            FileMiddleware("Public", searchForIndexHtml: true)
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "SwiftServe"
            )
        )

        print("🍦 SwiftServe is scooping at http://127.0.0.1:\(port)")
        print("   enrichment: \(mode)")
        try await app.runService()
    }

    // MARK: - Responses

    private static func jsonResponse(_ report: Report) throws -> Response {
        let encoder = JSONEncoder()
        // Deterministic, human-readable canonical output — the future CLI prints the same.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var buffer = ByteBuffer()
        buffer.writeBytes(try encoder.encode(report))
        return Response(
            status: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: buffer)
        )
    }

    private static func errorResponse(_ status: HTTPResponse.Status, _ message: String) -> Response {
        // Warm, plain JSON error — never scolding.
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        var buffer = ByteBuffer()
        buffer.writeString(#"{"error":"\#(escaped)"}"#)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: buffer)
        )
    }
}
