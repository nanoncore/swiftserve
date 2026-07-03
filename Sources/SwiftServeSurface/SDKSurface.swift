import Foundation
import SwiftServeCapability

/// Merges per-platform SDK interface parses into one surface. Apple ships a
/// `.swiftinterface` per platform SDK; a symbol's platform truth is SDK
/// MEMBERSHIP first (in the visionOS SDK's interface = exists on visionOS),
/// then `@available` overlays (macCatalyst inherits iOS, `unavailable`
/// fences win). Linux is always absent — no Apple SDK ships there.
public enum SDKSurfaceMerger {

    /// The SDKs we parse. macCatalyst rides the iOS interface + availability;
    /// linux is decided by enumeration.
    public static let probedPlatforms: [Platform] = [.iOS, .macOS, .tvOS, .watchOS, .visionOS]

    /// Which platform's interface anchors the merged decl (file + line +
    /// signature): the visionOS interface first — this corpus exists to make
    /// visionOS truth citable — then the broadest desktop/mobile ones.
    public static let primaryOrder: [Platform] = [.visionOS, .macOS, .iOS, .tvOS, .watchOS]

    public static func merge(perPlatform: [Platform: [SurfaceDecl]]) -> [SurfaceDecl] {
        // Identity: qualified name + signature (overloads stay distinct).
        func key(_ decl: SurfaceDecl) -> String { decl.name + "|" + (decl.signature ?? "") }

        var byKey: [String: [Platform: SurfaceDecl]] = [:]
        for (platform, decls) in perPlatform {
            for decl in decls {
                byKey[key(decl), default: [:]][platform] = decl
            }
        }

        var merged: [SurfaceDecl] = []
        for versions in byKey.values {
            guard let primary = primaryOrder.compactMap({ versions[$0] }).first else { continue }
            let membership = Set(versions.keys)

            // Availability annotations in an interface enumerate every
            // platform, so the primary's array + membership decide the rest.
            var resolved = PlatformResolver.resolve(
                condition: primary.condition, availability: primary.availability, modules: .empty)
            for platform in probedPlatforms where !membership.contains(platform) {
                resolved[platform.rawValue] = .absent
            }
            if !membership.contains(.iOS) {
                resolved[Platform.macCatalyst.rawValue] = .absent
            }
            resolved[Platform.linux.rawValue] = .absent

            merged.append(primary.resolving(resolved))
        }
        return merged.sorted {
            ($0.location.file, $0.location.line, $0.name) < ($1.location.file, $1.location.line, $1.name)
        }
    }

    /// SDK interfaces qualify extension members with the module name
    /// (`AVFAudio.AVAudioSession.sharedInstance`); package surfaces don't.
    /// Strip the module prefix so records read like the rest of the corpus.
    public static func stripModulePrefix(_ decls: [SurfaceDecl], module: String) -> [SurfaceDecl] {
        decls.map { decl in
            guard decl.name.hasPrefix(module + ".") else { return decl }
            return SurfaceDecl(
                name: String(decl.name.dropFirst(module.count + 1)),
                kind: decl.kind, signature: decl.signature, location: decl.location,
                condition: decl.condition, rawCondition: decl.rawCondition,
                availability: decl.availability, resolvedPlatforms: decl.resolvedPlatforms,
                docSummary: decl.docSummary, hasMacroAttributes: decl.hasMacroAttributes)
        }
    }
}
