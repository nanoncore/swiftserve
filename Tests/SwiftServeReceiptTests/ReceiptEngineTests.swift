import Foundation
import SwiftServeCapability
import SwiftServeCore
import Testing
@testable import SwiftServeReceipt

@Suite("Upgrade Receipt diffing")
struct ReceiptEngineTests {
    let time = "2026-08-05T12:00:00Z"

    func pin(_ identity: String = "demo", _ version: String? = "1.0.0",
             location: String = "https://github.com/acme/demo.git",
             branch: String? = nil, revision: String? = "abc") -> Pin {
        let type: PinType = version != nil ? .version : (branch != nil ? .branch : .revision)
        return Pin(identity: identity, kind: .remoteSourceControl, location: location,
                   resolvedVersion: version, branch: branch, revision: revision, pinType: type)
    }

    func receipt(_ base: [Pin], _ head: [Pin], context: ReceiptBuildContext = .init()) -> UpgradeReceipt {
        ReceiptEngine.build(base: base, head: head, generatedAt: time, context: context)
    }

    @Test("Empty diff is a pass")
    func empty() {
        let result = receipt([pin()], [pin()])
        #expect(result.verdict == .pass)
        #expect(result.changes.isEmpty)
        #expect(result.base.packageCount == 1)
    }

    @Test("Added and removed packages")
    func addRemove() {
        let result = receipt([pin("old")], [pin("new")])
        #expect(result.changes.map(\.identity) == ["new", "old"])
        #expect(result.changes.first { $0.identity == "new" }?.changeType == .added)
        #expect(result.changes.first { $0.identity == "old" }?.changeType == .removed)
    }

    @Test(arguments: [
        ("1.0.0", "1.0.1", UpdateClassification.patch, ReceiptChangeType.upgraded),
        ("1.0.0", "1.2.0", .minor, .upgraded),
        ("1.0.0", "2.0.0", .major, .upgraded),
        ("2.0.0", "1.9.0", .major, .downgraded),
    ])
    func semanticChanges(old: String, new: String, classification: UpdateClassification,
                         type: ReceiptChangeType) {
        let change = receipt([pin("demo", old)], [pin("demo", new)]).changes[0]
        #expect(change.classification == classification)
        #expect(change.changeType == type)
        if type == .downgraded {
            #expect(!change.findings.contains { $0.code == .majorUpdate })
        }
    }

    @Test(arguments: [
        ("1.0.0", "2.0.0-rc.1", UpdateClassification.stableToPrerelease),
        ("2.0.0-rc.1", "2.0.0", .prereleaseToStable),
        ("2.0.0-alpha.2", "2.0.0-beta.1", .prereleaseToPrerelease),
    ])
    func prereleaseTransitions(old: String, new: String, classification: UpdateClassification) {
        #expect(receipt([pin("demo", old)], [pin("demo", new)]).changes[0].classification == classification)
    }

    @Test("Non-semantic versions are unknown, never guessed")
    func unknownVersion() {
        let change = receipt([pin("demo", "release-one")], [pin("demo", "release-two")]).changes[0]
        #expect(change.changeType == .unknown)
        #expect(change.classification == .unknown)
        #expect(change.findings.contains { $0.code == .unknownVersion })
    }

    @Test("Branch/revision pins and transitions are findings")
    func pinTypes() {
        let branch = pin("demo", nil, branch: "main", revision: "b")
        let revision = pin("demo", nil, revision: "c")
        let branchResult = receipt([], [branch]).changes[0]
        #expect(branchResult.findings.contains { $0.code == .branchPin && $0.severity == .block })
        let transition = receipt([branch], [revision]).changes[0]
        #expect(transition.findings.contains { $0.code == .pinTypeChange })
        #expect(transition.findings.contains { $0.code == .revisionPin })
    }

    @Test("Revision change beneath an unchanged version is visible")
    func revisionUnderVersion() {
        let change = receipt([pin("demo", "1.0.0", revision: "aaa")],
                             [pin("demo", "1.0.0", revision: "bbb")]).changes[0]
        #expect(change.classification == .revisionChanged)
        #expect(change.findings.contains { $0.code == .revisionChange })
    }

    @Test("Same identity changing repository is a source change")
    func sourceChange() {
        let result = receipt(
            [pin("demo", "1.0.0", location: "https://github.com/acme/demo.git")],
            [pin("DEMO", "1.1.0", location: "https://github.com/fork/demo.git")])
        #expect(result.changes.count == 1)
        #expect(result.changes[0].classification == .sourceChanged)
        #expect(result.changes[0].findings.contains { $0.code == .sourceChange })
        #expect(result.changes[0].findings.contains { $0.code == .minorUpdate })
    }

    @Test("SCP-style repository user-info is redacted from receipts and findings")
    func sourceCredentialsAreRedacted() {
        let result = receipt(
            [pin("demo", location: "secret-token@github.com:acme/private.git")],
            [pin("demo", location: "another-token@github.com:fork/private.git")])
        let change = result.changes[0]
        #expect(change.oldPin?.location == "<redacted>@github.com:acme/private.git")
        #expect(change.newPin?.location == "<redacted>@github.com:fork/private.git")
        #expect(!change.findings.contains { $0.message.contains("secret-token") || $0.message.contains("another-token") })
    }

    @Test("Duplicate and conflicting normalized identities fail closed")
    func duplicates() {
        let head = [pin("Demo"), pin(" demo ", "2.0.0")]
        let result = receipt([], head)
        #expect(result.head.duplicateIdentities == ["demo"])
        #expect(result.head.conflictingIdentities == ["demo"])
        #expect(result.changes[0].findings.contains { $0.code == .duplicateIdentity })
        #expect(result.changes[0].findings.contains { $0.code == .conflictingIdentity })

        let unchanged = receipt(head, head)
        #expect(unchanged.verdict == .block)
        #expect(unchanged.changes[0].findings.contains { $0.code == .duplicateIdentity })
    }

    @Test("Sorting is deterministic by normalized identity")
    func sorting() {
        let result = receipt([], [pin("Zulu"), pin("alpha"), pin("Middle")])
        #expect(result.changes.map(\.identity) == ["alpha", "middle", "zulu"])
    }

    @Test("One enrichment snapshot yields a base/head health delta")
    func healthDelta() {
        let context = ReceiptBuildContext(
            enrichment: ["demo": EnrichmentData(latestVersion: "2.0.0", archived: false,
                                                   contributorCount: 10, license: .permissive)],
            enrichmentSource: "synthetic", networkUsed: true)
        let change = receipt([pin("demo", "1.0.0")], [pin("demo", "2.0.0")], context: context).changes[0]
        #expect(change.healthDelta != nil)
        #expect(change.healthDelta?.latestVersion == "2.0.0")
    }

    @Test("Canonical JSON has exact top-level fields and explicit nullable keys")
    func canonicalJSON() throws {
        let result = receipt([], [pin()])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        #expect(Set(object.keys) == Set(["receiptVersion", "generatedAt", "verdict", "headline", "base", "head", "counts", "changes", "policy", "enrichment"]))
        let change = try #require((object["changes"] as? [[String: Any]])?.first)
        #expect(Set(change.keys) == Set(["identity", "changeType", "classification", "severity", "findings", "oldPin", "newPin", "healthDelta", "capabilityChecks"]))
        #expect(change["oldPin"] is NSNull)
        #expect(change["healthDelta"] is NSNull)
        let newPin = try #require(change["newPin"] as? [String: Any])
        #expect(newPin["branch"] is NSNull)
        #expect(Set(newPin.keys) == Set(["identity", "kind", "location", "pinType", "version", "branch", "revision"]))
    }

    @Test("Schema is valid JSON and contains every stable finding code")
    func schema() throws {
        _ = try JSONSerialization.jsonObject(with: Data(UpgradeReceiptSchema.json.utf8))
        for code in FindingCode.allCases { #expect(UpgradeReceiptSchema.json.contains(code.rawValue)) }
    }
}

@Suite("Upgrade Receipt presentation and gates")
struct ReceiptPresentationTests {
    func pin(_ version: String) -> Pin {
        Pin(identity: "demo", kind: .remoteSourceControl,
            location: "https://github.com/acme/demo.git",
            resolvedVersion: version, branch: nil, revision: version, pinType: .version)
    }

    @Test("Markdown renders from the canonical receipt")
    func markdown() {
        let receipt = ReceiptEngine.build(base: [pin("1.0.0")], head: [pin("2.0.0")],
                                          generatedAt: "2026-08-05T00:00:00Z")
        let markdown = UpgradeReceiptMarkdownRenderer.render(receipt)
        #expect(markdown == """
        ## 🍦 Upgrade Receipt — REVIEW

        1 dependency change; review requested by policy.

        | Package | Before | After | Classification | Severity |
        |---|---:|---:|---|---|
        | `demo` | `1.0.0` | `2.0.0` | major | **review** |

        ### Findings

        - **review** `major-update` — Major version changed from 1.0.0 to 2.0.0.

        ### Policy violations

        - `major-update`

        Policy: `default` · needs attention

        > A `pass` means no configured policy was violated. It is not a universal safety guarantee and does not replace compiling or tests.
        """)
    }

    @Test("Gate evaluation is independent from presentation")
    func gates() {
        #expect(!ReceiptGateThreshold.review.fails(.pass))
        #expect(ReceiptGateThreshold.review.fails(.review))
        #expect(ReceiptGateThreshold.review.fails(.block))
        #expect(!ReceiptGateThreshold.block.fails(.pass))
        #expect(!ReceiptGateThreshold.block.fails(.review))
        #expect(ReceiptGateThreshold.block.fails(.block))
    }

    @Test("Markdown neutralizes repository-controlled content by context")
    func adversarialMarkdown() {
        let hostileIdentity = "demo\\|```\n## injected [link](https://evil.example) <img> @maintainers"
        let hostileVersion = "release`\r\n![image](https://evil.example/x)"
        let base = Pin(identity: hostileIdentity, kind: .remoteSourceControl,
                       location: "https://github.com/acme/demo.git",
                       resolvedVersion: "old", branch: nil, revision: "old", pinType: .version)
        let head = Pin(identity: hostileIdentity, kind: .remoteSourceControl,
                       location: "https://github.com/acme/demo.git",
                       resolvedVersion: hostileVersion, branch: nil, revision: "new", pinType: .version)
        let receipt = ReceiptEngine.build(
            base: [base], head: [head], generatedAt: "t",
            context: .init(policySource: "`.swiftserve.json`\n# forged @owners"))

        let markdown = UpgradeReceiptMarkdownRenderer.render(receipt)
        let findingText = markdown.split(separator: "\n")
            .filter { $0.hasPrefix("- **") }
            .joined(separator: "\n")
        #expect(!markdown.contains("\n## injected"))
        #expect(!markdown.contains("\n# forged"))
        #expect(markdown.contains(#"demo\\\|"#))
        #expect(markdown.contains("````"))
        #expect(findingText.contains("!\\[image\\]("))
        #expect(!findingText.contains("![image]("))
        #expect(markdown.contains("`` `.swiftserve.json` # forged @owners ``"))
    }
}

@Suite("Upgrade Receipt policy")
struct ReceiptPolicyTests {
    @Test("Default and custom severity override")
    func overrides() throws {
        let data = Data(#"{"version":1,"rules":{"major-update":"block"}}"#.utf8)
        let policy = try ReceiptPolicy.decode(from: data)
        #expect(ReceiptPolicy.default.severity(for: .majorUpdate) == .review)
        #expect(policy.severity(for: .majorUpdate) == .block)
    }

    @Test("Malformed, unsupported, invalid, duplicate, unknown rule and platform fail closed")
    func malformed() {
        #expect(throws: ReceiptPolicyError.self) { try ReceiptPolicy.decode(from: Data("{".utf8)) }
        #expect(throws: ReceiptPolicyError.unsupportedVersion(2)) {
            try ReceiptPolicy.decode(from: Data(#"{"version":2}"#.utf8))
        }
        #expect(throws: ReceiptPolicyError.duplicateKey("branch-pin")) {
            try ReceiptPolicy.decode(from: Data(#"{"version":1,"rules":{"branch-pin":"block","branch-pin":"review"}}"#.utf8))
        }
        #expect(throws: ReceiptPolicyError.duplicateKey("rules")) {
            try ReceiptPolicy.decode(from: Data(#"{"version":1,"rules":{},"\u0072ules":{}}"#.utf8))
        }
        #expect(throws: ReceiptPolicyError.invalidSeverity("fatal")) {
            try ReceiptPolicy.decode(from: Data(#"{"version":1,"rules":{"branch-pin":"fatal"}}"#.utf8))
        }
        #expect(throws: ReceiptPolicyError.unknownRule("magic")) {
            try ReceiptPolicy.decode(from: Data(#"{"version":1,"rules":{"magic":"block"}}"#.utf8))
        }
        #expect(throws: ReceiptPolicyError.unknownPlatform("beos")) {
            try ReceiptPolicy.decode(from: Data(#"{"version":1,"requiredCapabilities":[{"package":"demo","capability":"audio.demo","platform":"beos","expect":"supported"}]}"#.utf8))
        }
    }
}

@Suite("Upgrade Receipt capability evidence")
struct ReceiptCapabilityTests {
    let url = "https://github.com/acme/demo"

    func pin(_ version: String) -> Pin {
        Pin(identity: "demo", kind: .remoteSourceControl, location: url,
            resolvedVersion: version, branch: nil, revision: "abc", pinType: .version)
    }

    func dataset(version: String = "1.0.0", firstParty: Bool = false) -> CapabilityDataset {
        let record = CapabilityRecord(
            package: RecordPackage(canonicalURL: url, name: "demo", aliases: [], version: version,
                                   commit: "abc", surfaceDigest: "fnv1a64:1", firstParty: firstParty),
            capability: CapabilityRef(id: "audio.demo", label: "Demo"),
            platforms: ["macOS": PlatformClaim(status: .supported, confidence: 0.9,
                                                 evidence: [.init(kind: .symbol, symbol: "Demo", file: "Demo.swift", line: 1)])],
            labeledBy: "test", labeledAt: "2026-08-05T00:00:00Z")
        return CapabilityDataset(taxonomy: Taxonomy(domain: "audio", capabilities: [
            .init(id: "audio.demo", label: "Demo"),
        ]), records: [record])
    }

    @Test("Exact version evidence is used; mismatched evidence is unverified")
    func exactAndMismatch() {
        let exact = ReceiptEngine.build(base: [pin("0.9.0")], head: [pin("1.0.0")], generatedAt: "t",
            context: .init(capabilityDataset: dataset()))
        #expect(exact.changes[0].capabilityChecks[0].outcome == .exactEvidence)
        #expect(exact.changes[0].capabilityChecks[0].headStatus == .supported)

        let vPrefix = ReceiptEngine.build(base: [pin("0.9.0")], head: [pin("1.0.0")], generatedAt: "t",
            context: .init(capabilityDataset: dataset(version: "v1.0.0")))
        #expect(vPrefix.changes[0].capabilityChecks[0].outcome == .exactEvidence)

        let mismatch = ReceiptEngine.build(base: [pin("1.0.0")], head: [pin("1.1.0")], generatedAt: "t",
            context: .init(capabilityDataset: dataset()))
        #expect(mismatch.changes[0].capabilityChecks[0].outcome == .unverified)
        #expect(mismatch.changes[0].capabilityChecks[0].headStatus == nil)

        let retagged = Pin(identity: "demo", kind: .remoteSourceControl, location: url,
                           resolvedVersion: "1.0.0", branch: nil, revision: "different",
                           pinType: .version)
        let revisionMismatch = ReceiptEngine.build(base: [pin("1.0.0")], head: [retagged], generatedAt: "t",
            context: .init(capabilityDataset: dataset()))
        #expect(revisionMismatch.changes[0].capabilityChecks[0].outcome == .unverified)
    }

    @Test("Unindexed and first-party records stay honest")
    func specialCases() {
        let unindexed = ReceiptEngine.build(base: [], head: [pin("1.0.0")], generatedAt: "t",
                                             context: .init(capabilityDataset: .init(
                                                taxonomy: .init(domain: "empty", capabilities: []), records: [])))
        #expect(unindexed.changes[0].capabilityChecks[0].outcome == .notIndexed)
        let firstParty = ReceiptEngine.build(base: [], head: [pin("1.0.0")], generatedAt: "t",
                                             context: .init(capabilityDataset: dataset(firstParty: true)))
        #expect(firstParty.changes[0].capabilityChecks[0].outcome == .firstPartySkipped)
    }

    @Test("Recheck network failure remains unavailable and requests review")
    func unavailable() {
        let impact = CapabilityImpact(capability: "audio.demo", platform: "macOS", outcome: .unavailable,
                                      baseStatus: .supported, headStatus: nil, evidenceVersion: "1.0.0",
                                      detail: "synthetic network failure")
        let result = ReceiptEngine.build(base: [pin("1.0.0")], head: [pin("1.1.0")], generatedAt: "t",
            context: .init(capabilityDataset: dataset(), recheckedCapabilities: ["demo": [impact]],
                           capabilityRecheckRequested: true, capabilityRecheckExecuted: false,
                           unavailablePackages: ["demo"]))
        #expect(result.verdict == .review)
        #expect(result.changes[0].findings.contains { $0.code == .capabilityUnavailable })
        #expect(result.enrichment.unavailablePackages == ["demo"])
    }

    @Test("Required capabilities match exact evidence and fail closed when unverified")
    func requiredCapability() {
        let requirement = CapabilityRequirement(package: "demo", capability: "audio.demo",
                                                platform: "macOS", expect: .supported)
        let policy = ReceiptPolicy(requiredCapabilities: [requirement])
        let pass = ReceiptEngine.build(base: [], head: [pin("1.0.0")], generatedAt: "t",
                                       context: .init(policy: policy, capabilityDataset: dataset()))
        #expect(!pass.policy.violations.contains { $0.contains("required-capability") })
        let review = ReceiptEngine.build(base: [], head: [pin("1.1.0")], generatedAt: "t",
                                         context: .init(policy: policy, capabilityDataset: dataset()))
        #expect(review.policy.violations.contains { $0.hasPrefix("required-capability-unverified") })
        #expect(review.verdict == .review)
    }

    @Test("Required capability findings honor severity overrides in both directions")
    func requiredCapabilitySeverityOverrides() {
        let requirement = CapabilityRequirement(package: "demo", capability: "audio.demo",
                                                platform: "macOS", expect: .supported)
        let blockedPolicy = ReceiptPolicy(
            rules: [FindingCode.requiredCapabilityUnverified.rawValue: .block],
            requiredCapabilities: [requirement])
        let blocked = ReceiptEngine.build(base: [pin("1.1.0")], head: [pin("1.1.0")], generatedAt: "t",
            context: .init(policy: blockedPolicy, capabilityDataset: dataset()))
        #expect(blocked.changes.isEmpty)
        #expect(blocked.verdict == .block)
        #expect(blocked.policy.violations.contains { $0.hasPrefix("required-capability-unverified") })
        #expect(blocked.headline == "No dependency changes detected; blocked by policy.")

        let mismatch = CapabilityRequirement(package: "demo", capability: "audio.demo",
                                             platform: "macOS", expect: .unsupported)
        let demotedPolicy = ReceiptPolicy(
            rules: [FindingCode.requiredCapabilityMismatch.rawValue: .info],
            requiredCapabilities: [mismatch])
        let demoted = ReceiptEngine.build(base: [pin("1.0.0")], head: [pin("1.0.0")], generatedAt: "t",
            context: .init(policy: demotedPolicy, capabilityDataset: dataset()))
        #expect(demoted.verdict == .pass)
        #expect(demoted.policy.violations.isEmpty)
    }
}
