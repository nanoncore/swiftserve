import Testing
@testable import SwiftServeSurface
import SwiftServeCapability

/// Extraction is proven on exact, minimal source strings — no disk. The
/// `#if` negation semantics and access rules are the product's foundation;
/// every subtlety gets its own test.
@Suite struct SurfaceExtractorTests {

    private func extract(_ source: String) -> [SurfaceDecl] {
        SurfaceExtractor.decls(in: source, file: "T.swift")
    }

    private func names(_ source: String) -> [String] {
        extract(source).map(\.name)
    }

    // MARK: - Access rules

    @Test func publicFunctionIsSurface_internalIsNot() {
        let decls = extract("""
        public func visible() {}
        func hidden() {}
        internal func alsoHidden() {}
        private func veryHidden() {}
        """)
        #expect(decls.map(\.name) == ["visible"])
        #expect(decls[0].kind == .function)
        #expect(decls[0].signature == "func visible()")
        #expect(decls[0].condition == nil)
        #expect(decls[0].rawCondition == nil)
    }

    @Test func openClassAndMembersQualifyNames() {
        let decls = extract("""
        open class Room {
            public func connect() {}
            public struct Options {
                public var timeout: Int = 0
            }
        }
        """)
        #expect(decls.map(\.name) == ["Room", "Room.connect", "Room.Options", "Room.Options.timeout"])
        #expect(decls[0].kind == .class)
        #expect(decls[3].kind == .property)
        #expect(decls[3].signature == "var timeout: Int")
    }

    @Test func publicMemberInsideInternalTypeIsSuppressed() {
        let decls = extract("""
        class Hidden {
            public func notReallyPublic() {}
            public struct AlsoHidden {
                public var nope: Int = 0
            }
        }
        """)
        #expect(decls.isEmpty)
    }

    @Test func publicExtensionGrantsDefaultAccessToMembers() {
        let decls = extract("""
        public extension Room {
            func joins() {}                 // default public via the extension
            private func stillPrivate() {}
        }
        extension Room {
            func internalByDefault() {}
            public func explicitlyPublic() {}
        }
        """)
        #expect(decls.map(\.name) == ["Room.joins", "Room.explicitlyPublic"])
    }

    @Test func protocolMembersInheritProtocolAccess() {
        let decls = extract("""
        public protocol AudioProcessor {
            func process()
            var sampleRate: Double { get }
        }
        protocol InternalProcessor {
            func process()
        }
        """)
        #expect(decls.map(\.name) == ["AudioProcessor", "AudioProcessor.process", "AudioProcessor.sampleRate"])
        #expect(decls[0].kind == .protocol)
    }

    @Test func enumCasesInheritEnumAccess() {
        let decls = extract("""
        public enum ConnectionState {
            case connected
            case disconnected(reason: String)
        }
        enum InternalState { case hidden }
        """)
        #expect(decls.map(\.name) == [
            "ConnectionState", "ConnectionState.connected", "ConnectionState.disconnected",
        ])
        #expect(decls[1].kind == .enumCase)
        #expect(decls[2].signature == "case disconnected(reason: String)")
    }

    @Test func setterOnlyModifierDoesNotHideTheGetter() {
        let decls = extract("""
        public struct Counter {
            public private(set) var count: Int = 0
        }
        """)
        #expect(decls.map(\.name) == ["Counter", "Counter.count"])
    }

    @Test func initializerSubscriptAndTypealiasAreSurface() {
        let decls = extract("""
        public struct Buffer {
            public init?(capacity: Int) {}
            public subscript(index: Int) -> UInt8 { 0 }
            public typealias Element = UInt8
        }
        """)
        #expect(decls.map(\.name) == ["Buffer", "Buffer.init", "Buffer.subscript", "Buffer.Element"])
        #expect(decls[1].signature == "init?(capacity: Int)")
        #expect(decls[1].kind == .initializer)
        #expect(decls[2].kind == .subscript)
        #expect(decls[3].kind == .typealias)
    }

    @Test func localDeclarationsInsideBodiesAreNotSurface() {
        let decls = extract("""
        public func outer() {
            struct Local { var x: Int }
            func inner() {}
        }
        """)
        #expect(decls.map(\.name) == ["outer"])
    }

    // MARK: - #if conditions

    @Test func simpleOsGuard() {
        let decls = extract("""
        #if os(iOS)
        public func onlyOniOS() {}
        #endif
        public func everywhere() {}
        """)
        #expect(decls.count == 2)
        #expect(decls[0].condition == .os("iOS"))
        #expect(decls[0].rawCondition == "os(iOS)")
        #expect(decls[1].condition == nil)
    }

    @Test func nestedIfConfigsConjoin() {
        let decls = extract("""
        #if os(iOS)
        #if canImport(UIKit)
        public func needsBoth() {}
        #endif
        #endif
        """)
        #expect(decls.count == 1)
        #expect(decls[0].condition == .allOf([.os("iOS"), .canImport("UIKit")]))
        #expect(decls[0].rawCondition == "os(iOS) && canImport(UIKit)")
    }

    @Test func elseBranchNegatesTheCondition() {
        let decls = extract("""
        #if os(watchOS)
        public func watchOnly() {}
        #else
        public func everythingButWatch() {}
        #endif
        """)
        #expect(decls.count == 2)
        #expect(decls[0].condition == .os("watchOS"))
        #expect(decls[1].condition == .not(.os("watchOS")))
        #expect(decls[1].rawCondition == "!os(watchOS)")
    }

    @Test func elseifCarriesNegatedPriors() {
        let decls = extract("""
        #if os(iOS)
        public func a() {}
        #elseif os(macOS)
        public func b() {}
        #else
        public func c() {}
        #endif
        """)
        #expect(decls.count == 3)
        #expect(decls[0].condition == .os("iOS"))
        #expect(decls[1].condition == .allOf([.not(.os("iOS")), .os("macOS")]))
        #expect(decls[2].condition == .allOf([.not(.os("iOS")), .not(.os("macOS"))]))
    }

    @Test func notOperator() {
        let decls = extract("""
        #if !os(Linux)
        public func appleOnly() {}
        #endif
        """)
        #expect(decls[0].condition == .not(.os("Linux")))
    }

    @Test func andBindsTighterThanOr() {
        let decls = extract("""
        #if os(iOS) && canImport(UIKit) || os(macOS)
        public func f() {}
        #endif
        """)
        #expect(decls[0].condition == .anyOf([
            .allOf([.os("iOS"), .canImport("UIKit")]),
            .os("macOS"),
        ]))
        #expect(decls[0].rawCondition == "(os(iOS) && canImport(UIKit)) || os(macOS)")
    }

    @Test func parenthesesOverridePrecedence() {
        let decls = extract("""
        #if (os(iOS) || os(tvOS)) && canImport(UIKit)
        public func f() {}
        #endif
        """)
        #expect(decls[0].condition == .allOf([
            .anyOf([.os("iOS"), .os("tvOS")]),
            .canImport("UIKit"),
        ]))
    }

    @Test func compilationFlagAndTargetEnvironment() {
        let decls = extract("""
        #if DEBUG
        public func debugOnly() {}
        #endif
        #if targetEnvironment(macCatalyst)
        public func catalystOnly() {}
        #endif
        """)
        #expect(decls[0].condition == .flag("DEBUG"))
        #expect(decls[1].condition == .targetEnvironment("macCatalyst"))
    }

    @Test func languageVersionAndArchConditions() {
        let decls = extract("""
        #if swift(>=5.9)
        public func modern() {}
        #endif
        #if arch(arm64)
        public func armOnly() {}
        #endif
        """)
        #expect(decls[0].condition == .languageVersion("swift(>=5.9)"))
        #expect(decls[1].condition == .arch("arm64"))
    }

    @Test func unparseableConditionIsUnknownNeverGuessed() {
        let decls = extract("""
        #if MY_FLAGS > 1
        public func weird() {}
        #endif
        """)
        guard case .unknown(let raw)? = decls[0].condition else {
            Issue.record("expected .unknown, got \(String(describing: decls[0].condition))")
            return
        }
        #expect(raw.contains("MY_FLAGS"))
    }

    @Test func ifConfigInsideTypeAppliesToMembers() {
        let decls = extract("""
        public struct RoomOptions {
            #if os(iOS)
            public var noiseCancellationFilter: String?
            #endif
            public var url: String = ""
        }
        """)
        #expect(decls.map(\.name) == [
            "RoomOptions", "RoomOptions.noiseCancellationFilter", "RoomOptions.url",
        ])
        #expect(decls[0].condition == nil)
        #expect(decls[1].condition == .os("iOS"))
        #expect(decls[2].condition == nil)
    }

    @Test func ifConfigWrappingAWholeTypeAppliesToTypeAndMembers() {
        let decls = extract("""
        #if canImport(AppKit)
        public class MacRenderer {
            public func render() {}
        }
        #endif
        """)
        #expect(decls.count == 2)
        #expect(decls[0].condition == .canImport("AppKit"))
        #expect(decls[1].condition == .canImport("AppKit"))
    }

    // MARK: - @available

    @Test func shorthandAvailability() {
        let decls = extract("""
        @available(iOS 14.0, macOS 11.0, *)
        public func modern() {}
        """)
        #expect(decls[0].availability == [
            AvailabilityConstraint(platform: "iOS", introduced: "14.0"),
            AvailabilityConstraint(platform: "macOS", introduced: "11.0"),
        ])
    }

    @Test func unavailableOnOnePlatform() {
        let decls = extract("""
        @available(macOS, unavailable)
        public func notOnMac() {}
        """)
        #expect(decls[0].availability == [
            AvailabilityConstraint(platform: "macOS", unavailable: true),
        ])
    }

    @Test func longFormIntroducedDeprecatedMessage() {
        let decls = extract("""
        @available(iOS, introduced: 13.0, deprecated: 16.0, message: "Use NewThing")
        public func oldThing() {}
        @available(*, deprecated)
        public func softDeprecated() {}
        """)
        #expect(decls[0].availability == [
            AvailabilityConstraint(platform: "iOS", introduced: "13.0", deprecated: "16.0",
                                   message: "Use NewThing"),
        ])
        #expect(decls[1].availability == [
            AvailabilityConstraint(platform: "*", deprecated: "unversioned"),
        ])
    }

    @Test func typeAvailabilityIsInheritedByMembers() {
        let decls = extract("""
        @available(iOS 15.0, *)
        public struct Modern {
            public func f() {}
            @available(iOS 16.0, *)
            public func newer() {}
        }
        """)
        #expect(decls[1].availability == [AvailabilityConstraint(platform: "iOS", introduced: "15.0")])
        #expect(decls[2].availability == [
            AvailabilityConstraint(platform: "iOS", introduced: "15.0"),
            AvailabilityConstraint(platform: "iOS", introduced: "16.0"),
        ])
    }

    // MARK: - Doc comments + macro flag

    @Test func docCommentFirstLineIsCaptured() {
        let decls = extract("""
        /// Enables Krisp-powered noise cancellation for the local mic track.
        /// Second line is not the summary.
        public func setNoiseCancellation(enabled: Bool) {}

        /** Block-style summary. */
        public func blockDocumented() {}

        public func undocumented() {}
        """)
        #expect(decls[0].docSummary == "Enables Krisp-powered noise cancellation for the local mic track.")
        #expect(decls[1].docSummary == "Block-style summary.")
        #expect(decls[2].docSummary == nil)
    }

    @Test func macroLookingAttributeSetsTheFlag_propertyWrappersDoNot() {
        let decls = extract("""
        @SomeMacro
        public struct Generated {}

        public class Model {
            @Published public var value: Int = 0
        }

        @MainActor
        public func onMain() {}
        """)
        #expect(decls[0].hasMacroAttributes == true)
        #expect(decls[2].hasMacroAttributes == false)   // @Published — wrapper, not macro
        #expect(decls[3].hasMacroAttributes == false)   // @MainActor — global actor
    }

    // MARK: - Locations

    @Test func locationsAreOneIndexedAndAfterLeadingTrivia() {
        let decls = extract("""
        /// Docs.
        public func f() {}
        """)
        #expect(decls[0].location.file == "T.swift")
        #expect(decls[0].location.line == 2)
    }
}
