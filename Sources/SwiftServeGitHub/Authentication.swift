import Foundation

public struct InstallationToken: Sendable, Equatable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

public protocol InstallationTokenExchanging: Sendable {
    func exchange(appJWT: String, installationID: Int64) async throws -> InstallationToken
}

public actor InstallationTokenProvider {
    private let signer: any AppJWTSigning
    private let exchanger: any InstallationTokenExchanging
    private let now: @Sendable () -> Date
    private var cache: [Int64: InstallationToken] = [:]

    public init(signer: any AppJWTSigning, exchanger: any InstallationTokenExchanging,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.signer = signer
        self.exchanger = exchanger
        self.now = now
    }

    public func token(for installationID: Int64) async throws -> String {
        let current = now()
        if let cached = cache[installationID], cached.expiresAt.timeIntervalSince(current) > 60 {
            return cached.value
        }
        let jwt = try signer.token(now: current)
        let token = try await exchanger.exchange(appJWT: jwt, installationID: installationID)
        guard token.expiresAt > current else { throw GitHubAPIError.malformedResponse }
        cache[installationID] = token
        return token.value
    }
}
