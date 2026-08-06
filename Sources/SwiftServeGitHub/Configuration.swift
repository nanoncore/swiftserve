import Foundation
import SwiftServeReceipt

public struct GitHubAppConfiguration: Sendable, Equatable {
    public static let defaultPayloadLimit = 1 << 20

    public let appID: String
    public let privateKeyPEM: String
    public let webhookSecret: String
    public let gate: ReceiptGateThreshold
    public let host: String
    public let port: Int
    public let payloadLimit: Int
    public let workerCapacity: Int
    public let apiBaseURL: URL

    public init(environment: [String: String]) throws {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SafeDiagnostic(code: "configuration.missing", message: "Set \(name)")
            }
            return value
        }

        let rawAppID = try required("SWIFTSERVE_GITHUB_APP_ID")
        guard Int64(rawAppID).map({ $0 > 0 }) == true else {
            throw SafeDiagnostic(code: "configuration.invalid_app_id",
                                 message: "SWIFTSERVE_GITHUB_APP_ID must be a positive integer")
        }
        appID = rawAppID
        webhookSecret = try required("SWIFTSERVE_GITHUB_WEBHOOK_SECRET")
        let rawKey = try required("SWIFTSERVE_GITHUB_PRIVATE_KEY")
        privateKeyPEM = rawKey.replacingOccurrences(of: "\\n", with: "\n")
        guard let parsedGate = ReceiptGateThreshold(
            rawValue: environment["SWIFTSERVE_GITHUB_GATE"]?.lowercased() ?? "block") else {
            throw SafeDiagnostic(code: "configuration.invalid_gate",
                                 message: "SWIFTSERVE_GITHUB_GATE must be review or block")
        }
        gate = parsedGate
        host = environment["HOST"] ?? "127.0.0.1"
        port = try Self.positiveInt(environment["PORT"] ?? "8080", name: "PORT")
        payloadLimit = try Self.positiveInt(
            environment["SWIFTSERVE_GITHUB_MAX_PAYLOAD_BYTES"] ?? String(Self.defaultPayloadLimit),
            name: "SWIFTSERVE_GITHUB_MAX_PAYLOAD_BYTES")
        workerCapacity = try Self.positiveInt(
            environment["SWIFTSERVE_GITHUB_WORKER_CAPACITY"] ?? "16",
            name: "SWIFTSERVE_GITHUB_WORKER_CAPACITY")
        guard let url = URL(string: environment["SWIFTSERVE_GITHUB_API_URL"] ?? "https://api.github.com") else {
            throw SafeDiagnostic(code: "configuration.invalid_api_url",
                                 message: "SWIFTSERVE_GITHUB_API_URL must be HTTPS (or local HTTP for tests)")
        }
        let local = url.host == "127.0.0.1" || url.host == "localhost"
        guard url.scheme == "https" || (url.scheme == "http" && local) else {
            throw SafeDiagnostic(code: "configuration.invalid_api_url",
                                 message: "SWIFTSERVE_GITHUB_API_URL must be HTTPS (or local HTTP for tests)")
        }
        apiBaseURL = url
    }

    private static func positiveInt(_ raw: String, name: String) throws -> Int {
        guard let value = Int(raw), value > 0 else {
            throw SafeDiagnostic(code: "configuration.invalid_integer", message: "\(name) must be a positive integer")
        }
        return value
    }
}
