import Foundation
import Testing
@testable import SwiftServeCapability

/// The resolver is a truth-table machine — so it's tested as one. Every atom
/// on every interesting platform, plus the Kleene composition rules that make
/// three-valued logic sound.
@Suite struct PlatformResolverTests {

    private let modules = ModulePlatformTable(version: 1, modules: [
        "UIKit": ["iOS", "tvOS", "visionOS", "macCatalyst"],
        "AppKit": ["macOS"],
        "Glibc": ["linux"],
    ])

    private func presence(_ condition: PlatformCondition?, on platform: Platform,
                          availability: [AvailabilityConstraint] = []) -> PlatformPresence {
        PlatformResolver.resolve(condition: condition, availability: availability, modules: modules)[platform.rawValue]!
    }

    // MARK: - Atoms

    @Test func osMatchesItsPlatformOnly() {
        #expect(presence(.os("iOS"), on: .iOS) == .present)
        #expect(presence(.os("iOS"), on: .macOS) == .absent)
        #expect(presence(.os("iOS"), on: .watchOS) == .absent)
        #expect(presence(.os("Linux"), on: .linux) == .present)
        #expect(presence(.os("Linux"), on: .iOS) == .absent)
        #expect(presence(.os("Windows"), on: .macOS) == .absent)
    }

    @Test func osiOSIsTrueUnderCatalyst_osMacOSIsNot() {
        // Catalyst compiles as iOS — the subtlety that decides real verdicts.
        #expect(presence(.os("iOS"), on: .macCatalyst) == .present)
        #expect(presence(.os("macOS"), on: .macCatalyst) == .absent)
    }

    @Test func xrOSNormalizesToVisionOS() {
        #expect(presence(.os("xrOS"), on: .visionOS) == .present)
    }

    @Test func canImportDecidesFromTheTableBothWays() {
        #expect(presence(.canImport("UIKit"), on: .iOS) == .present)
        #expect(presence(.canImport("UIKit"), on: .macOS) == .absent)
        #expect(presence(.canImport("AppKit"), on: .macOS) == .present)
        #expect(presence(.canImport("AppKit"), on: .linux) == .absent)
    }

    @Test func canImportUnknownModuleIsHonestlyConditional() {
        #expect(presence(.canImport("SomePrivateSDK"), on: .iOS)
                == .conditional("canImport(SomePrivateSDK)"))
    }

    @Test func canImportSubmoduleKeysOnTopModule() {
        #expect(presence(.canImport("UIKit.UIGestureRecognizerSubclass"), on: .iOS) == .present)
        #expect(presence(.canImport("UIKit.UIGestureRecognizerSubclass"), on: .macOS) == .absent)
    }

    @Test func targetEnvironmentCatalystIsDecided_simulatorIsNot() {
        #expect(presence(.targetEnvironment("macCatalyst"), on: .macCatalyst) == .present)
        #expect(presence(.targetEnvironment("macCatalyst"), on: .iOS) == .absent)
        #expect(presence(.targetEnvironment("simulator"), on: .iOS)
                == .conditional("targetEnvironment(simulator)"))
    }

    @Test func languageVersionIsAssumedTrue() {
        #expect(presence(.languageVersion("swift(>=5.9)"), on: .macOS) == .present)
    }

    @Test func archFlagsAndUnknownsStayConditional() {
        #expect(presence(.arch("arm64"), on: .iOS) == .conditional("arch(arm64)"))
        #expect(presence(.flag("DEBUG"), on: .iOS) == .conditional("DEBUG"))
        #expect(presence(.unknown("MY_FLAGS > 1"), on: .iOS) == .conditional("MY_FLAGS > 1"))
    }

    @Test func booleanLiteralFlagsAreDecided() {
        #expect(presence(.flag("true"), on: .iOS) == .present)
        #expect(presence(.flag("false"), on: .iOS) == .absent)
    }

    // MARK: - Composition (Kleene)

    @Test func notInvertsAndPreservesIndeterminate() {
        #expect(presence(.not(.os("watchOS")), on: .iOS) == .present)
        #expect(presence(.not(.os("watchOS")), on: .watchOS) == .absent)
        #expect(presence(.not(.flag("DEBUG")), on: .iOS) == .conditional("!DEBUG"))
    }

    @Test func falseAndIndeterminateIsFalse() {
        // The decl provably isn't there — an undecidable flag can't resurrect it.
        let condition = PlatformCondition.allOf([.os("iOS"), .flag("DEBUG")])
        #expect(presence(condition, on: .macOS) == .absent)
        #expect(presence(condition, on: .iOS) == .conditional("os(iOS) && DEBUG"))
    }

    @Test func trueOrIndeterminateIsTrue() {
        let condition = PlatformCondition.anyOf([.os("macOS"), .flag("DEBUG")])
        #expect(presence(condition, on: .macOS) == .present)
        #expect(presence(condition, on: .iOS) == .conditional("os(macOS) || DEBUG"))
    }

    @Test func orOfExclusivePlatformGuards() {
        let condition = PlatformCondition.anyOf([.os("iOS"), .os("macOS"), .os("tvOS")])
        #expect(presence(condition, on: .iOS) == .present)
        #expect(presence(condition, on: .macOS) == .present)
        #expect(presence(condition, on: .watchOS) == .absent)
        #expect(presence(condition, on: .macCatalyst) == .present)   // via os(iOS)
    }

    // MARK: - @available overlay

    @Test func nilConditionIsPresentEverywhere() {
        for platform in Platform.allCases {
            #expect(presence(nil, on: platform) == .present)
        }
    }

    @Test func unavailableOverridesEvenAPassingGuard() {
        let unavailable = [AvailabilityConstraint(platform: "macOS", unavailable: true)]
        #expect(presence(nil, on: .macOS, availability: unavailable) == .absent)
        #expect(presence(.os("macOS"), on: .macOS, availability: unavailable) == .absent)
        #expect(presence(nil, on: .iOS, availability: unavailable) == .present)
    }

    @Test func starUnavailableIsAbsentEverywhere() {
        let unavailable = [AvailabilityConstraint(platform: "*", unavailable: true)]
        for platform in Platform.allCases {
            #expect(presence(nil, on: platform, availability: unavailable) == .absent)
        }
    }

    @Test func catalystInheritsiOSUnavailabilityConsistentWithOsRule() {
        let unavailable = [AvailabilityConstraint(platform: "iOS", unavailable: true)]
        #expect(presence(nil, on: .macCatalyst, availability: unavailable) == .absent)
        let catalystOnly = [AvailabilityConstraint(platform: "macCatalyst", unavailable: true)]
        #expect(presence(nil, on: .macCatalyst, availability: catalystOnly) == .absent)
        #expect(presence(nil, on: .iOS, availability: catalystOnly) == .present)
    }

    @Test func introducedVersionsAreMetadataNotFences() {
        let introduced = [AvailabilityConstraint(platform: "iOS", introduced: "14.0")]
        #expect(presence(nil, on: .iOS, availability: introduced) == .present)
    }

    // MARK: - Table behavior

    @Test func emptyTableMakesEveryCanImportConditional() {
        let result = PlatformResolver.resolve(
            condition: .canImport("UIKit"), availability: [], modules: .empty)
        for platform in Platform.allCases {
            #expect(result[platform.rawValue] == .conditional("canImport(UIKit)"))
        }
    }

    @Test func tableDecodesFromJSONIgnoringComments() throws {
        let json = """
        {"_comment": "x", "version": 1, "modules": {"UIKit": ["iOS", "macCatalyst"]}}
        """
        let table = try ModulePlatformTable.decode(from: Data(json.utf8))
        #expect(table.platforms(for: "UIKit") == Set<Platform>([.iOS, .macCatalyst]))
        #expect(table.platforms(for: "Nope") == nil)
    }
}
