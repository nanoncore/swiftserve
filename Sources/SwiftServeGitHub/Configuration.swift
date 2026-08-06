import Foundation
import SwiftServeReceipt

public struct GitHubAppConfiguration: Sendable, Equatable {
    public static let defaultPayloadLimit = 1 << 20
    public static let defaultLockfileLimit = 5 << 20
    public static let defaultPolicyLimit = 256 << 10
    public static let defaultResponseLimit = 8 << 20

    public let appID: String
    public let privateKeyPEM: String
    public let webhookSecret: String
    public let previousWebhookSecret: String?
    public let gate: ReceiptGateThreshold
    public let host: String
    public let port: Int
    public let payloadLimit: Int
    public let workerCapacity: Int
    public let perInstallationCapacity: Int
    public let leaseDuration: TimeInterval
    public let retention: TimeInterval
    public let jobStorePath: String
    public let lockfileLimit: Int
    public let policyLimit: Int
    public let responseLimit: Int
    public let connectTimeout: TimeInterval
    public let requestTimeout: TimeInterval
    public let retryMaxAttempts: Int
    public let retryMaxElapsed: TimeInterval
    public let apiBaseURL: URL
    public let isTestRuntime: Bool

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
        previousWebhookSecret = environment["SWIFTSERVE_GITHUB_WEBHOOK_SECRET_PREVIOUS"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
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
            environment["SWIFTSERVE_GITHUB_WORKER_CAPACITY"] ?? "4",
            name: "SWIFTSERVE_GITHUB_WORKER_CAPACITY")
        perInstallationCapacity = try Self.positiveInt(
            environment["SWIFTSERVE_GITHUB_INSTALLATION_CONCURRENCY"] ?? "2",
            name: "SWIFTSERVE_GITHUB_INSTALLATION_CONCURRENCY")
        guard perInstallationCapacity <= workerCapacity else {
            throw SafeDiagnostic(code: "configuration.invalid_concurrency",
                                 message: "Installation concurrency cannot exceed worker capacity")
        }
        leaseDuration = try Self.positiveDouble(
            environment["SWIFTSERVE_GITHUB_LEASE_SECONDS"] ?? "120",
            name: "SWIFTSERVE_GITHUB_LEASE_SECONDS")
        retention = try Self.positiveDouble(
            environment["SWIFTSERVE_GITHUB_RETENTION_SECONDS"] ?? "604800",
            name: "SWIFTSERVE_GITHUB_RETENTION_SECONDS")
        jobStorePath = environment["SWIFTSERVE_GITHUB_JOB_STORE"] ?? "./swiftserve-github.sqlite"
        guard !jobStorePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SafeDiagnostic(code: "configuration.invalid_job_store",
                                 message: "SWIFTSERVE_GITHUB_JOB_STORE must be a non-empty file path")
        }
        lockfileLimit = try Self.positiveInt(
            environment["SWIFTSERVE_GITHUB_MAX_LOCKFILE_BYTES"] ?? String(Self.defaultLockfileLimit),
            name: "SWIFTSERVE_GITHUB_MAX_LOCKFILE_BYTES")
        policyLimit = try Self.positiveInt(
            environment["SWIFTSERVE_GITHUB_MAX_POLICY_BYTES"] ?? String(Self.defaultPolicyLimit),
            name: "SWIFTSERVE_GITHUB_MAX_POLICY_BYTES")
        responseLimit = try Self.positiveInt(
            environment["SWIFTSERVE_GITHUB_MAX_RESPONSE_BYTES"] ?? String(Self.defaultResponseLimit),
            name: "SWIFTSERVE_GITHUB_MAX_RESPONSE_BYTES")
        connectTimeout = try Self.positiveDouble(
            environment["SWIFTSERVE_GITHUB_CONNECT_TIMEOUT_SECONDS"] ?? "10",
            name: "SWIFTSERVE_GITHUB_CONNECT_TIMEOUT_SECONDS")
        requestTimeout = try Self.positiveDouble(
            environment["SWIFTSERVE_GITHUB_REQUEST_TIMEOUT_SECONDS"] ?? "30",
            name: "SWIFTSERVE_GITHUB_REQUEST_TIMEOUT_SECONDS")
        retryMaxAttempts = try Self.positiveInt(
            environment["SWIFTSERVE_GITHUB_RETRY_MAX_ATTEMPTS"] ?? "6",
            name: "SWIFTSERVE_GITHUB_RETRY_MAX_ATTEMPTS")
        retryMaxElapsed = try Self.positiveDouble(
            environment["SWIFTSERVE_GITHUB_RETRY_MAX_ELAPSED_SECONDS"] ?? "900",
            name: "SWIFTSERVE_GITHUB_RETRY_MAX_ELAPSED_SECONDS")
        isTestRuntime = environment["SWIFTSERVE_RUNTIME_MODE"] == "test"
        guard let url = URL(string: environment["SWIFTSERVE_GITHUB_API_URL"] ?? "https://api.github.com") else {
            throw SafeDiagnostic(code: "configuration.invalid_api_url",
                                 message: "SWIFTSERVE_GITHUB_API_URL must be a valid configured origin")
        }
        let local = url.host == "127.0.0.1" || url.host == "localhost" || url.host == "::1"
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.host != nil, url.scheme == "https" || (isTestRuntime && url.scheme == "http" && local) else {
            throw SafeDiagnostic(code: "configuration.invalid_api_url",
                                 message: "SWIFTSERVE_GITHUB_API_URL must be an HTTPS origin (loopback HTTP is test-only)")
        }
        apiBaseURL = url
    }

    private static func positiveInt(_ raw: String, name: String) throws -> Int {
        guard let value = Int(raw), value > 0 else {
            throw SafeDiagnostic(code: "configuration.invalid_integer", message: "\(name) must be a positive integer")
        }
        return value
    }

    private static func positiveDouble(_ raw: String, name: String) throws -> Double {
        guard let value = Double(raw), value > 0, value.isFinite else {
            throw SafeDiagnostic(code: "configuration.invalid_number", message: "\(name) must be a positive number")
        }
        return value
    }
}
