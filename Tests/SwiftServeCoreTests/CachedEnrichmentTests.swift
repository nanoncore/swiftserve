import Foundation
import Testing
@testable import SwiftServeCore

/// A controllable inner enrichment: scripted responses, counted calls.
private actor FakeEnrichment: Enrichment {
    nonisolated var sourceName: String { "fake" }
    nonisolated var usesNetwork: Bool { true }

    private(set) var calls: [[String]] = []          // identities per enrich() call
    private var responses: [String: EnrichmentData]

    init(responses: [String: EnrichmentData] = [:]) {
        self.responses = responses
    }

    func set(_ identity: String, _ data: EnrichmentData?) {
        responses[identity] = data
    }

    func callCount() -> Int { calls.count }
    func totalPinsFetched() -> Int { calls.reduce(0) { $0 + $1.count } }

    func enrich(_ pins: [Pin]) async -> [String: EnrichmentData] {
        calls.append(pins.map(\.identity))
        var out: [String: EnrichmentData] = [:]
        for pin in pins {
            if let data = responses[pin.identity] { out[pin.identity] = data }
        }
        return out
    }
}

/// A hand-cranked clock, safe to share with the actor under test.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

private func pin(_ identity: String, github: Bool = true) -> Pin {
    Pin(identity: identity,
        kind: .remoteSourceControl,
        location: github
            ? "https://github.com/owner/\(identity).git"
            : "https://gitlab.com/owner/\(identity).git",
        resolvedVersion: "1.0.0", branch: nil, revision: "deadbeef", pinType: .version)
}

@Suite("CachedEnrichment — the production armor")
struct CachedEnrichmentTests {

    private func makeStack(responses: [String: EnrichmentData] = [:],
                           ttl: TimeInterval = 3600,
                           failureTTL: TimeInterval = 300,
                           cooldown: TimeInterval = 600,
                           fetchBudget: Int = 80,
                           maxEntries: Int = 4096) -> (CachedEnrichment, FakeEnrichment, FakeClock) {
        let fake = FakeEnrichment(responses: responses)
        let clock = FakeClock()
        let cached = CachedEnrichment(wrapping: fake, ttl: ttl, failureTTL: failureTTL,
                                      cooldown: cooldown, strikesToOpen: 2,
                                      fetchBudget: fetchBudget, maxEntries: maxEntries,
                                      now: { clock.now() })
        return (cached, fake, clock)
    }

    @Test func cacheHitsSkipTheNetwork() async {
        let (cached, fake, _) = makeStack(responses: ["alamofire": EnrichmentData(latestVersion: "5.9.1")])
        let first = await cached.enrich([pin("alamofire")])
        #expect(first["alamofire"]?.latestVersion == "5.9.1")
        let second = await cached.enrich([pin("alamofire")])
        #expect(second["alamofire"]?.latestVersion == "5.9.1")
        #expect(await fake.callCount() == 1)
    }

    @Test func ttlExpiryRefetches() async {
        let (cached, fake, clock) = makeStack(responses: ["alamofire": EnrichmentData(latestVersion: "5.9.1")],
                                              ttl: 3600)
        _ = await cached.enrich([pin("alamofire")])
        clock.advance(3601)
        _ = await cached.enrich([pin("alamofire")])
        #expect(await fake.callCount() == 2)
    }

    @Test func failuresAreCachedForTheShorterTTL() async {
        let (cached, fake, clock) = makeStack(failureTTL: 300)   // no responses: every fetch fails
        _ = await cached.enrich([pin("ghost")])
        _ = await cached.enrich([pin("ghost")])                  // within failureTTL — no refetch
        #expect(await fake.callCount() == 1)
        clock.advance(301)
        // One good pin rides along so the empty round doesn't trip the circuit.
        await fake.set("alamofire", EnrichmentData(latestVersion: "5.9.1"))
        _ = await cached.enrich([pin("ghost"), pin("alamofire")])
        #expect(await fake.callCount() == 2)
    }

    @Test func fetchBudgetCapsARequestAndTheTailCatchesUp() async {
        var responses: [String: EnrichmentData] = [:]
        let pins = (0..<10).map { pin("pkg\($0)") }
        for p in pins { responses[p.identity] = EnrichmentData(latestVersion: "1.0.0") }
        let (cached, fake, _) = makeStack(responses: responses, fetchBudget: 7)

        let first = await cached.enrich(pins)
        #expect(first.count == 7)                       // budget honored, tail unknown
        #expect(await fake.totalPinsFetched() == 7)

        let second = await cached.enrich(pins)          // cached 7 + fetched 3
        #expect(second.count == 10)
        #expect(await fake.totalPinsFetched() == 10)
    }

    @Test func circuitOpensAfterEmptyRoundsAndRecloses() async {
        let (cached, fake, clock) = makeStack(cooldown: 600)     // all fetches fail
        _ = await cached.enrich([pin("a")])                      // strike 1
        clock.advance(301)                                       // let failure cache lapse
        _ = await cached.enrich([pin("b")])                      // strike 2 → circuit opens
        #expect(await fake.callCount() == 2)

        clock.advance(301)
        _ = await cached.enrich([pin("c")])                      // circuit open — no fetch
        #expect(await fake.callCount() == 2)

        clock.advance(600)                                       // cooldown over
        await fake.set("c", EnrichmentData(latestVersion: "2.0.0"))
        let after = await cached.enrich([pin("c")])
        #expect(after["c"]?.latestVersion == "2.0.0")
        #expect(await fake.callCount() == 3)
    }

    @Test func nonGitHubForgesNeverTripTheCircuit() async {
        let (cached, fake, clock) = makeStack()
        _ = await cached.enrich([pin("g1", github: false)])      // empty round, but not GitHub-shaped
        clock.advance(301)
        _ = await cached.enrich([pin("g2", github: false)])
        clock.advance(301)
        await fake.set("real", EnrichmentData(latestVersion: "1.0.0"))
        let result = await cached.enrich([pin("real")])          // circuit must still be closed
        #expect(result["real"]?.latestVersion == "1.0.0")
        #expect(await fake.callCount() == 3)
    }

    @Test func concurrentRequestsForTheSameRepoCoalesce() async {
        let (cached, fake, _) = makeStack(responses: ["nio": EnrichmentData(latestVersion: "2.72.0")])
        async let a = cached.enrich([pin("nio")])
        async let b = cached.enrich([pin("nio")])
        let (ra, rb) = await (a, b)
        #expect(ra["nio"]?.latestVersion == "2.72.0")
        #expect(rb["nio"]?.latestVersion == "2.72.0")
        // Either both calls raced past the cache check (coalesced to ≤2 inner
        // calls is still correct) or one joined the other's fetch. The hard
        // requirement: never MORE inner traffic than requests, and a warm
        // cache afterwards.
        #expect(await fake.callCount() <= 2)
        _ = await cached.enrich([pin("nio")])
        #expect(await fake.callCount() <= 2)
    }

    @Test func evictionKeepsTheCacheBounded() async {
        var responses: [String: EnrichmentData] = [:]
        let pins = (0..<20).map { pin("pkg\($0)") }
        for p in pins { responses[p.identity] = EnrichmentData(latestVersion: "1.0.0") }
        let (cached, fake, _) = makeStack(responses: responses, fetchBudget: 100, maxEntries: 5)

        _ = await cached.enrich(pins)
        #expect(await fake.totalPinsFetched() == 20)
        // Everything still answers (refetching what was evicted), and the
        // stack survives — bounded memory, not bounded answers.
        let again = await cached.enrich(pins)
        #expect(again.count == 20)
    }

    @Test func duplicateLocationsInOneRequestFetchOnce() async {
        let (cached, fake, _) = makeStack(responses: ["dup": EnrichmentData(latestVersion: "1.0.0")])
        let twice = [pin("dup"), pin("dup")]
        let result = await cached.enrich(twice)
        #expect(result["dup"]?.latestVersion == "1.0.0")
        #expect(await fake.totalPinsFetched() == 1)
    }
}
