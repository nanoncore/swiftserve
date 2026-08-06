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
    private var inFlight: [Int64: Task<InstallationToken, Error>] = [:]

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
        let task: Task<InstallationToken, Error>
        let ownsExchange: Bool
        if let existing = inFlight[installationID] {
            task = existing
            ownsExchange = false
        } else {
            let jwt = try signer.token(now: current)
            task = Task {
                try await exchanger.exchange(appJWT: jwt, installationID: installationID)
            }
            inFlight[installationID] = task
            ownsExchange = true
        }
        do {
            let token = try await task.value
            guard token.expiresAt > current else { throw GitHubAPIError.malformedResponse }
            cache[installationID] = token
            if ownsExchange { inFlight[installationID] = nil }
            return token.value
        } catch {
            if ownsExchange { inFlight[installationID] = nil }
            throw error
        }
    }
}
