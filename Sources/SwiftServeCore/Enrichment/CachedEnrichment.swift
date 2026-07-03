import Foundation

/// The production armor around a network enrichment: a TTL cache, request
/// coalescing, a per-request fetch budget, and a circuit breaker — so a
/// public `/analyze` endpoint can run live GitHub enrichment without burning
/// the rate limit, hammering the same repos, or falling over when GitHub does.
///
/// The Enrichment contract stays intact: additive, never required. Anything
/// this layer declines to fetch (over budget, circuit open, cached failure)
/// simply comes back as "unknown" and the scorer keeps its neutral baseline.
///
/// Behavior, in order:
///   · fresh cache entries answer immediately — successes for `ttl`,
///     failures for the shorter `failureTTL` (a repo that errored is not
///     retried on every request)
///   · pins already being fetched by a concurrent request share that fetch
///     (coalescing), they never trigger a duplicate
///   · at most `fetchBudget` uncached pins go to the network per call; the
///     tail stays unknown and is picked up by later requests
///   · when `strikesToOpen` consecutive rounds of GitHub-shaped fetches come
///     back completely empty (the rate-limited/offline signature), the
///     circuit opens for `cooldown` and everything is served cache-only
public actor CachedEnrichment: Enrichment {

    private struct Entry {
        let data: EnrichmentData?   // nil = cached failure
        let expires: Date
    }

    private let inner: any Enrichment
    private let ttl: TimeInterval
    private let failureTTL: TimeInterval
    private let cooldown: TimeInterval
    private let strikesToOpen: Int
    private let fetchBudget: Int
    private let maxEntries: Int
    private let now: @Sendable () -> Date

    private var cache: [String: Entry] = [:]                          // key = pin.location
    private var inFlight: [String: Task<[String: EnrichmentData], Never>] = [:]
    private var strikes = 0
    private var circuitOpenUntil: Date?

    public init(wrapping inner: any Enrichment,
                ttl: TimeInterval = 3600,
                failureTTL: TimeInterval = 300,
                cooldown: TimeInterval = 600,
                strikesToOpen: Int = 2,
                fetchBudget: Int = 80,
                maxEntries: Int = 4096,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.inner = inner
        self.ttl = ttl
        self.failureTTL = failureTTL
        self.cooldown = cooldown
        self.strikesToOpen = strikesToOpen
        self.fetchBudget = fetchBudget
        self.maxEntries = maxEntries
        self.now = now
    }

    public nonisolated var sourceName: String { inner.sourceName }
    public nonisolated var usesNetwork: Bool { inner.usesNetwork }

    public func enrich(_ pins: [Pin]) async -> [String: EnrichmentData] {
        let moment = now()
        var result: [String: EnrichmentData] = [:]
        var joins: [(identity: String, location: String, task: Task<[String: EnrichmentData], Never>)] = []
        var toFetch: [Pin] = []
        var seenLocations = Set<String>()

        let circuitOpen = circuitOpenUntil.map { moment < $0 } ?? false

        for pin in pins where pin.kind == .remoteSourceControl {
            if let entry = cache[pin.location], moment < entry.expires {
                if let data = entry.data { result[pin.identity] = data }
                continue
            }
            if let running = inFlight[pin.location] {
                joins.append((pin.identity, pin.location, running))
                continue
            }
            guard !circuitOpen, toFetch.count < fetchBudget,
                  !seenLocations.contains(pin.location) else { continue }
            seenLocations.insert(pin.location)
            toFetch.append(pin)
        }

        if !toFetch.isEmpty {
            let batch = toFetch
            let inner = inner
            let task = Task { await inner.enrich(batch) }
            for pin in batch {
                inFlight[pin.location] = task
                joins.append((pin.identity, pin.location, task))
            }
            let fetched = await task.value
            settle(batch: batch, fetched: fetched, startedAt: moment)
        }

        // Coalesced joins. Actor reentrancy means a joiner can resume before
        // the batch owner settles the cache, so read the fetch result first
        // (same location → same SwiftPM identity) and fall back to the cache.
        for join in joins {
            let fetched = await join.task.value
            if let data = fetched[join.identity] ?? cache[join.location]?.data {
                result[join.identity] = data
            }
        }
        return result
    }

    // MARK: - internals

    /// Write a finished batch into the cache, advance the circuit state, and
    /// release the in-flight markers.
    private func settle(batch: [Pin], fetched: [String: EnrichmentData], startedAt: Date) {
        for pin in batch {
            let data = fetched[pin.identity]
            let life = data == nil ? failureTTL : ttl
            cache[pin.location] = Entry(data: data, expires: startedAt.addingTimeInterval(life))
            inFlight[pin.location] = nil
        }
        evictIfNeeded()

        // The circuit only counts rounds that SHOULD have produced data:
        // GitHub-shaped locations coming back completely empty is the
        // rate-limited/offline signature, not "this forge isn't GitHub".
        let expected = batch.filter { GitHubParsing.ownerRepo(from: $0.location) != nil }
        guard !expected.isEmpty else { return }
        if expected.allSatisfy({ fetched[$0.identity] == nil }) {
            strikes += 1
            if strikes >= strikesToOpen {
                circuitOpenUntil = startedAt.addingTimeInterval(cooldown)
                strikes = 0
            }
        } else {
            strikes = 0
            circuitOpenUntil = nil
        }
    }

    /// Bounded memory: beyond `maxEntries`, the entries closest to expiry go
    /// first — they were about to leave anyway.
    private func evictIfNeeded() {
        guard cache.count > maxEntries else { return }
        let overflow = cache.count - maxEntries
        for (key, _) in cache.sorted(by: { $0.value.expires < $1.value.expires }).prefix(overflow) {
            cache[key] = nil
        }
    }
}
