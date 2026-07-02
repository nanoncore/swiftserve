import Foundation

/// Reads an `.xcframework`'s `Info.plist` and resolves the Mach-O for the shipping
/// iOS device slice (the one that actually goes to the App Store). Small + impure.
enum XCFramework {
    /// Returns the binary path + slice identifier (e.g. "ios-arm64"), or nil.
    static func iOSDeviceBinary(at xcframeworkPath: String) -> (binary: String, slice: String)? {
        let infoPath = "\(xcframeworkPath)/Info.plist"
        guard let data = FileManager.default.contents(atPath: infoPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let libs = plist["AvailableLibraries"] as? [[String: Any]] else { return nil }

        func isIOS(_ l: [String: Any]) -> Bool { (l["SupportedPlatform"] as? String) == "ios" }
        func isDevice(_ l: [String: Any]) -> Bool { l["SupportedPlatformVariant"] == nil }

        // Prefer iOS device, then any iOS, then anything.
        let chosen = libs.first(where: { isIOS($0) && isDevice($0) })
            ?? libs.first(where: isIOS)
            ?? libs.first

        guard let lib = chosen,
              let slice = lib["LibraryIdentifier"] as? String,
              let libPath = lib["LibraryPath"] as? String else { return nil }

        let root = "\(xcframeworkPath)/\(slice)"
        let binary: String
        if libPath.hasSuffix(".framework") {
            let name = String((libPath as NSString).lastPathComponent.dropLast(".framework".count))
            binary = "\(root)/\(libPath)/\(name)"
        } else {
            binary = "\(root)/\(libPath)" // static lib*.a, etc.
        }
        return FileManager.default.fileExists(atPath: binary) ? (binary, slice) : nil
    }

    /// First `.xcframework` under a directory (skipping resource-fork junk).
    static func findXCFramework(under dir: String) -> String? {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return nil }
        for case let rel as String in e {
            if rel.contains("__MACOSX") || (rel as NSString).lastPathComponent.hasPrefix("._") { continue }
            if rel.hasSuffix(".xcframework") { return "\(dir)/\(rel)" }
        }
        return nil
    }
}
