import Foundation

/// Stable string flags raised on a dependency. Kept as raw strings so they ride
/// cleanly in JSON and stay stable for the future CLI / AI consumers.
/// Internal: the public surface is the `[String]` in `PackageReport.flags`.
enum Flag: String, Sendable, CaseIterable {
    case branchPin
    case revisionPin
    case preRelease
    case nonCanonicalLocation
    case localPath
    case registry
    case archived
    case noLicense
    case copyleftLicense
}

/// Turns parsed pins (+ optional enrichment) into a scored ``Report``.
///
/// The scorer is pure and synchronous — all network lives behind ``Enrichment``.
/// Given empty enrichment it still scores every dependency using what the file
/// reveals (hygiene, version shape) and neutral baselines elsewhere.
public struct Scorer: Sendable {
    public let config: ScoringConfig

    public init(config: ScoringConfig = .default) {
        self.config = config
    }

    public func buildReport(
        pins: [Pin],
        enrichment: [String: EnrichmentData],
        source: String,
        networkUsed: Bool,
        generatedAt: String,
        now: Date = Date()
    ) -> Report {
        let packages = pins.map { score(pin: $0, data: enrichment[$0.identity], now: now) }

        let overallScore: Int
        if packages.isEmpty {
            overallScore = 100 // nothing to scan is, from a supply-chain view, immaculate
        } else {
            overallScore = Int((Double(packages.map(\.score).reduce(0, +)) / Double(packages.count)).rounded())
        }
        let mood = Mood.from(score: overallScore, thresholds: config.thresholds)

        let overall = Overall(
            score: overallScore,
            mood: mood,
            voiceLine: mood.voiceLine,
            headline: headline(total: packages.count, mood: mood)
        )

        return Report(
            generatedAt: generatedAt,
            overall: overall,
            packages: packages,
            graph: graphMetrics(for: pins),
            enrichment: EnrichmentInfo(source: source, networkUsed: networkUsed)
        )
    }

    // MARK: - Per-dependency scoring

    public func score(pin: Pin, data: EnrichmentData?, now: Date = Date()) -> PackageReport {
        var flags: Set<Flag> = []

        let maintenance = maintenanceScore(data, now: now, flags: &flags)
        let staleness = stalenessScore(pin, data, flags: &flags)
        let busFactor = busFactorScore(data)
        let swift6 = swift6Score(data)
        let hygiene = hygieneScore(pin, flags: &flags)
        let license = licenseScore(data, flags: &flags)

        let sub = SubScores(
            maintenance: maintenance,
            staleness: staleness,
            busFactor: busFactor,
            swift6: swift6,
            hygiene: hygiene,
            license: license
        )

        let w = config.weights
        let composite = clamp(Int((
            w.maintenance * Double(maintenance) +
            w.staleness * Double(staleness) +
            w.busFactor * Double(busFactor) +
            w.swift6 * Double(swift6) +
            w.hygiene * Double(hygiene) +
            w.license * Double(license)
        ).rounded()))

        return PackageReport(
            identity: pin.identity,
            name: pin.identity,
            kind: pin.kind,
            location: pin.location,
            resolvedVersion: pin.resolvedVersion,
            latestVersion: data?.latestVersion,
            branch: pin.branch,
            pinType: pin.pinType,
            score: composite,
            subScores: sub,
            reason: reason(pin: pin, data: data, now: now, flags: flags),
            flags: flags.map(\.rawValue).sorted()
        )
    }

    // MARK: - Sub-scores

    private func maintenanceScore(_ data: EnrichmentData?, now: Date, flags: inout Set<Flag>) -> Int {
        if data?.archived == true {
            flags.insert(.archived)
            return 0 // archived → hard zero, per the rubric
        }
        guard let last = data?.lastReleaseDate else {
            return config.neutralBaseline // no network signal
        }
        let days = now.timeIntervalSince(last) / 86_400
        if days <= 90 { return 100 }
        if days >= 730 { return 0 }
        // Linear falloff from 90 days (100) to ~2 years (0).
        return clamp(Int((100 * (1 - (days - 90) / (730 - 90))).rounded()))
    }

    private func stalenessScore(_ pin: Pin, _ data: EnrichmentData?, flags: inout Set<Flag>) -> Int {
        if let latest = data?.latestVersion, let resolved = pin.resolvedVersion {
            return stalenessFromVersions(resolved: resolved, latest: latest)
        }
        // File-only: infer from the pin's shape.
        switch pin.pinType {
        case .version:
            if isPreRelease(pin.resolvedVersion) {
                flags.insert(.preRelease)
                return config.preReleaseStaleness
            }
            return config.versionStaleness
        case .branch, .revision:
            return config.unknownStaleness
        case .unknown:
            return config.neutralBaseline
        }
    }

    /// Staleness from a known resolved→latest gap. Majors are heavy, minors light.
    private func stalenessFromVersions(resolved: String, latest: String) -> Int {
        guard let r = SemVer(resolved), let l = SemVer(latest) else {
            return config.versionStaleness
        }
        let majors = max(0, l.major - r.major)
        let minors = max(0, l.minor - r.minor)
        if majors > 0 { return clamp(100 - majors * 30) }   // a major behind is a real lag
        if minors > 0 { return clamp(100 - minors * 8) }    // minors are cheaper to chase
        return 100
    }

    private func busFactorScore(_ data: EnrichmentData?) -> Int {
        guard let count = data?.contributorCount, count > 0 else {
            return config.neutralBaseline
        }
        // Log-scaled: 1 contributor ≈ 30 (risky), ~100 contributors ≈ 100.
        return clamp(Int((30 + 35 * log10(Double(count))).rounded()))
    }

    private func swift6Score(_ data: EnrichmentData?) -> Int {
        guard let ready = data?.swift6Ready else { return config.neutralBaseline }
        return ready ? 100 : 40
    }

    private func hygieneScore(_ pin: Pin, flags: inout Set<Flag>) -> Int {
        var score: Int
        switch pin.pinType {
        case .version:
            score = config.versionPinScore
        case .branch:
            flags.insert(.branchPin)
            score = config.branchPinScore
        case .revision:
            flags.insert(.revisionPin)
            score = config.revisionPinScore
        case .unknown:
            score = config.neutralBaseline
        }

        switch pin.kind {
        case .registry:
            flags.insert(.registry)
        case .localSourceControl:
            flags.insert(.localPath)
        case .remoteSourceControl:
            if let host = host(of: pin.location), !ScoringConfig.canonicalHosts.contains(host) {
                flags.insert(.nonCanonicalLocation)
                score -= config.nonCanonicalPenalty
            }
        case .unknown:
            break
        }

        return clamp(score)
    }

    private func licenseScore(_ data: EnrichmentData?, flags: inout Set<Flag>) -> Int {
        guard let license = data?.license else { return config.neutralBaseline }
        switch license {
        case .permissive: return 100
        case .copyleft:
            flags.insert(.copyleftLicense)
            return 70
        case .none:
            flags.insert(.noLicense)
            return 30
        case .unknown:
            return config.neutralBaseline
        }
    }

    // MARK: - Reason (one plain-English line, by dominant signal)

    private func reason(pin: Pin, data: EnrichmentData?, now: Date, flags: Set<Flag>) -> String {
        if flags.contains(.archived) {
            return "Archived — no longer maintained."
        }
        if pin.pinType == .branch {
            let name = pin.branch.map { "'\($0)'" } ?? "a branch"
            return "Tracks \(name) — no released version pinned."
        }
        if pin.pinType == .revision {
            return "Pinned to a bare commit — no released version."
        }
        // Version gap — only when we actually know the latest tag.
        if let latest = data?.latestVersion, let resolved = pin.resolvedVersion,
           let gap = versionGapReason(resolved: resolved, latest: latest) {
            return gap
        }
        // Maintenance recency, when known.
        if let last = data?.lastReleaseDate {
            let months = Int((now.timeIntervalSince(last) / (86_400 * 30)).rounded())
            if months >= 18 { return "No activity in about \(months) months." }
        }
        if flags.contains(.noLicense) {
            return "No license detected — usage rights are unclear."
        }
        if isPreRelease(pin.resolvedVersion) {
            return "Pre-1.0 release (\(pin.resolvedVersion ?? "0.x")) — API may still shift."
        }
        if flags.contains(.nonCanonicalLocation) {
            return "Hosted outside the common Swift forges — worth a glance."
        }
        if flags.contains(.localPath) {
            return "Local path dependency — not a published package."
        }
        // Healthy. Distinguish a network-backed "all good" from a file-only scan.
        if data?.lastReleaseDate != nil || data?.latestVersion != nil {
            return "Up to date and actively maintained."
        }
        return "Pinned to a release; a network scan would fill in the rest."
    }

    /// A plain-English version gap, or `nil` when up to date at major.minor.
    private func versionGapReason(resolved: String, latest: String) -> String? {
        guard let r = SemVer(resolved), let l = SemVer(latest) else {
            return resolved == latest ? nil : "Resolved at \(resolved); latest is \(latest)."
        }
        let majors = l.major - r.major
        if majors > 0 { return "\(majors) major\(majors == 1 ? "" : "s") behind (latest \(latest))." }
        let minors = l.minor - r.minor
        if minors > 0 { return "\(minors) minor\(minors == 1 ? "" : "s") behind (latest \(latest))." }
        return nil
    }

    // MARK: - Overall headline

    private func headline(total: Int, mood: Mood) -> String {
        if total == 0 { return "No dependencies to scan — nothing to melt." }
        let n = "\(total) " + (total == 1 ? "dependency" : "dependencies")
        switch mood {
        case .partyMode: return "\(n) scanned — all crisp and tidy."
        case .freshSwirl: return "\(n) scanned — a couple of easy wins."
        case .softSqueeze: return "\(n) scanned — a few things to tidy up."
        case .meltdown: return "\(n) scanned — several need attention."
        case .dayOld: return "\(n) scanned — let's clean this up together."
        case .idle: return "\(n) scanned."
        }
    }

    // MARK: - Graph metrics

    private func graphMetrics(for pins: [Pin]) -> GraphMetrics {
        // Same repo name resolved from different locations → fork-vs-upstream smell.
        var byName: [String: [String]] = [:]
        for pin in pins {
            byName[repoName(for: pin), default: []].append(pin.location)
        }
        let duplicates = byName
            .filter { Set($0.value).count > 1 }
            .map { DuplicateGroup(name: $0.key, locations: Array(Set($0.value)).sorted()) }
            .sorted { $0.name < $1.name }

        // Conflicting versions for one identity — by construction rare in a single
        // resolved file (SPM resolves one version per identity), reported honestly.
        var byIdentity: [String: Set<String>] = [:]
        for pin in pins {
            if let v = pin.resolvedVersion { byIdentity[pin.identity, default: []].insert(v) }
        }
        let conflicts = byIdentity.filter { $0.value.count > 1 }.keys.sorted()

        return GraphMetrics(
            total: pins.count,
            duplicates: duplicates,
            conflicts: conflicts
        )
    }

    // MARK: - Helpers

    private func clamp(_ value: Int) -> Int { max(0, min(100, value)) }

    private func isPreRelease(_ version: String?) -> Bool {
        guard let v = version else { return false }
        return SemVer(v)?.major == 0
    }

    private func repoName(for pin: Pin) -> String {
        guard pin.kind != .registry, !pin.location.isEmpty else { return pin.identity.lowercased() }
        let trimmed = pin.location.hasSuffix(".git") ? String(pin.location.dropLast(4)) : pin.location
        let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init)
        return (last ?? pin.identity).lowercased()
    }

    private func host(of location: String) -> String? {
        if let host = URLComponents(string: location)?.host { return host.lowercased() }
        // scp-like form: git@github.com:owner/repo.git
        if let at = location.firstIndex(of: "@") {
            let rest = location[location.index(after: at)...]
            if let colon = rest.firstIndex(of: ":") {
                return String(rest[..<colon]).lowercased()
            }
        }
        return nil
    }
}

// SemVer moved to Identity/RepoIdentity.swift (promoted public for the
// capability corpus pipeline; same tolerant parsing, now Comparable).
