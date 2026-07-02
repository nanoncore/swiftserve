import Foundation
@testable import SwiftServeScan

enum FixtureError: Error { case missing(String) }

func scanFixtureData(_ name: String, ext: String = "json") throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: name, withExtension: ext)
    guard let url else { throw FixtureError.missing(name) }
    return try Data(contentsOf: url)
}

/// A small denylist used by the matcher tests (kept in code so they're self-contained).
let testDenylist = Denylist(version: 1, entries: [
    DenylistEntry(id: "mg", pattern: "MGCopyAnswer", match: .exact, appliesTo: [.importedSymbol],
                  framework: "libMobileGestalt (private)", severity: .high, why: "Private device info.",
                  rejectionCode: "ITMS-90338", alternative: "Use UIDevice."),
    DenylistEntry(id: "ls", pattern: "LSApplicationWorkspace", match: .prefix, appliesTo: [.objcClass],
                  framework: "CoreServices (private)", severity: .high, why: "Private app listing."),
    DenylistEntry(id: "orient", pattern: "setOrientation:", match: .exact, appliesTo: [.objcSelector],
                  framework: "UIDevice (private)", severity: .medium, why: "Force orientation."),
])
