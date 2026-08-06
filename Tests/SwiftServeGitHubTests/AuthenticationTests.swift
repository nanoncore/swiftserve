import Foundation
import SwiftServeGitHub
import Testing

private struct FakeSigner: AppJWTSigning {
    func token(now: Date) throws -> String { "app-jwt" }
}

private actor FakeExchanger: InstallationTokenExchanging {
    let expiry: Date
    private(set) var calls = 0

    init(expiry: Date) { self.expiry = expiry }

    func exchange(appJWT: String, installationID: Int64) async throws -> InstallationToken {
        calls += 1
        return InstallationToken(value: "token-\(calls)", expiresAt: expiry)
    }

    func count() -> Int { calls }
}

private actor BlockingExchanger: InstallationTokenExchanging {
    let expiry: Date
    private var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expiry: Date) { self.expiry = expiry }

    func exchange(appJWT: String, installationID: Int64) async throws -> InstallationToken {
        calls += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        return InstallationToken(value: "shared-token", expiresAt: expiry)
    }

    func count() -> Int { calls }

    func release() {
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

@Suite("Installation authentication")
struct AuthenticationTests {
    @Test("Installation tokens are cached while safely before expiry")
    func caching() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exchanger = FakeExchanger(expiry: now.addingTimeInterval(120))
        let provider = InstallationTokenProvider(signer: FakeSigner(), exchanger: exchanger, now: { now })
        #expect(try await provider.token(for: 1) == "token-1")
        #expect(try await provider.token(for: 1) == "token-1")
        #expect(await exchanger.count() == 1)
    }

    @Test("Tokens refresh shortly before expiry")
    func refresh() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exchanger = FakeExchanger(expiry: now.addingTimeInterval(30))
        let provider = InstallationTokenProvider(signer: FakeSigner(), exchanger: exchanger, now: { now })
        #expect(try await provider.token(for: 1) == "token-1")
        #expect(try await provider.token(for: 1) == "token-2")
        #expect(await exchanger.count() == 2)
    }

    @Test("Concurrent cold requests coalesce one token exchange per installation")
    func coalescing() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exchanger = BlockingExchanger(expiry: now.addingTimeInterval(120))
        let provider = InstallationTokenProvider(signer: FakeSigner(), exchanger: exchanger, now: { now })
        let first = Task { try await provider.token(for: 1) }
        while await exchanger.count() == 0 { await Task.yield() }
        let second = Task { try await provider.token(for: 1) }
        let third = Task { try await provider.token(for: 1) }
        for _ in 0..<10 { await Task.yield() }
        #expect(await exchanger.count() == 1)
        await exchanger.release()
        #expect(try await first.value == "shared-token")
        #expect(try await second.value == "shared-token")
        #expect(try await third.value == "shared-token")
        #expect(await exchanger.count() == 1)
    }

    @Test("Configuration errors name variables without exposing their values")
    func safeConfigurationErrors() {
        let secret = "do-not-print-this"
        #expect(throws: (any Error).self) {
            _ = try GitHubAppConfiguration(environment: ["SWIFTSERVE_GITHUB_WEBHOOK_SECRET": secret])
        }
        do {
            _ = try GitHubAppConfiguration(environment: ["SWIFTSERVE_GITHUB_WEBHOOK_SECRET": secret])
        } catch {
            #expect(!String(describing: error).contains(secret))
        }
    }

    @Test("Loopback HTTP GitHub origins are unavailable in production configuration")
    func productionOriginBoundary() throws {
        var environment = [
            "SWIFTSERVE_GITHUB_APP_ID": "1",
            "SWIFTSERVE_GITHUB_PRIVATE_KEY": "placeholder",
            "SWIFTSERVE_GITHUB_WEBHOOK_SECRET": "secret",
            "SWIFTSERVE_GITHUB_API_URL": "http://127.0.0.1:9999",
        ]
        #expect(throws: SafeDiagnostic.self) {
            _ = try GitHubAppConfiguration(environment: environment)
        }
        environment["SWIFTSERVE_RUNTIME_MODE"] = "test"
        let configuration = try GitHubAppConfiguration(environment: environment)
        #expect(configuration.isTestRuntime)
        #expect(configuration.apiBaseURL.host == "127.0.0.1")
    }
}
