import Foundation
import Testing

enum FixtureError: Error { case missing(String) }

/// Load a JSON fixture from the test bundle's `Fixtures` directory.
func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: name, withExtension: "json")
    guard let url else { throw FixtureError.missing(name) }
    return try Data(contentsOf: url)
}
