import Foundation
import SwiftServeScan

/// A single Mach-O to scan, with how we'll attribute its hits.
struct ScanTarget {
    let path: String
    let displayName: String
    let origin: Origin
}

struct Resolved {
    let kind: String            // machO | app | framework | dylib
    let targets: [ScanTarget]
    let warnings: [String]
}

/// Turns a user-supplied path (.app / .framework / .dylib / raw Mach-O) into the
/// concrete binary/binaries to scan. (CLI side of the pure/impure boundary.)
enum BinaryResolver {
    static func resolve(_ input: String) throws -> Resolved {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input, isDirectory: &isDir) else {
            throw ScanError("no such file: \(input)")
        }

        if isDir.boolValue {
            let name = (input as NSString).lastPathComponent
            if name.hasSuffix(".framework") {
                let base = String(name.dropLast(".framework".count))
                let candidates = ["\(input)/\(base)", "\(input)/Versions/Current/\(base)"]
                guard let bin = candidates.first(where: { isMachO($0) }) else {
                    throw ScanError("couldn't find the Mach-O inside \(name)")
                }
                return Resolved(kind: "framework",
                                targets: [ScanTarget(path: bin, displayName: name,
                                                     origin: Origin(kind: .dependency, artifact: name))],
                                warnings: [])
            }
            if name.hasSuffix(".app") {
                guard let exec = bundleExecutable("\(input)/Contents/Info.plist") ?? bundleExecutable("\(input)/Info.plist") else {
                    throw ScanError("couldn't read CFBundleExecutable from \(name)")
                }
                let candidates = ["\(input)/Contents/MacOS/\(exec)", "\(input)/\(exec)"] // macOS, then iOS layout
                guard let bin = candidates.first(where: { isMachO($0) }) else {
                    throw ScanError("couldn't find the main executable inside \(name)")
                }
                return Resolved(kind: "app",
                                targets: [ScanTarget(path: bin, displayName: name,
                                                     origin: Origin(kind: .firstParty, artifact: name))],
                                warnings: ["Scanned the main executable only; embedded frameworks aren't recursed yet."])
            }
            throw ScanError("unsupported bundle: \(name) (expected .app or .framework)")
        }

        // A plain file.
        guard isMachO(input) else {
            throw ScanError("not a Mach-O binary: \(input)")
        }
        let name = (input as NSString).lastPathComponent
        let isDylib = name.hasSuffix(".dylib")
        return Resolved(kind: isDylib ? "dylib" : "machO",
                        targets: [ScanTarget(path: input, displayName: name,
                                             origin: Origin(kind: isDylib ? .dependency : .firstParty, artifact: name))],
                        warnings: [])
    }

    /// Read the first 4 bytes and compare against Mach-O / fat magic (either endianness).
    static func isMachO(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let d = try? fh.read(upToCount: 4), d.count == 4 else { return false }
        let magic = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let known: Set<UInt32> = [
            0xfeedface, 0xcefaedfe,   // MH_MAGIC / swapped (32-bit)
            0xfeedfacf, 0xcffaedfe,   // MH_MAGIC_64 / swapped
            0xcafebabe, 0xbebafeca,   // FAT_MAGIC / swapped
            0xcafebabf, 0xbfbafeca,   // FAT_MAGIC_64 / swapped
        ]
        return known.contains(magic)
    }

    private static func bundleExecutable(_ infoPlistPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: infoPlistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleExecutable"] as? String
    }
}

/// Spawns `xcrun lipo/nm/otool` to pull symbols out of a Mach-O, then hands the
/// text to the pure parsers in `SwiftServeScan`.
enum SymbolExtractor {
    static func architectures(of binary: String) -> [String] {
        guard let out = xcrun(["lipo", "-archs", binary]) else { return [] }
        return out.split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init).filter { !$0.isEmpty }
    }

    static func extract(binary: String, origin: Origin, arches: [String]) -> [ExtractedSymbol] {
        // Empty arches → invoke without -arch (thin/native).
        let archFlagSets: [[String]] = arches.isEmpty ? [[]] : arches.map { ["-arch", $0] }
        var symbols: [ExtractedSymbol] = []
        for archFlags in archFlagSets {
            if let nm = xcrun(["nm"] + archFlags + ["-u", binary]) {
                symbols += OutputParsers.parseNmSymbols(nm, origin: origin)
            }
            if let meth = xcrun(["otool"] + archFlags + ["-s", "__TEXT", "__objc_methname", binary]) {
                symbols += OutputParsers.parseObjCMethnames(meth, origin: origin)
            }
        }
        return symbols
    }

    /// Run an Xcode tool via `xcrun`, returning stdout (nil only if it can't launch).
    /// Reads to EOF before waiting, and discards stderr, to avoid pipe-buffer deadlocks.
    private static func xcrun(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
