// Give the staged Wine loader its game app identity by atomically replacing
// a private copy, preserving the shared runner inode.
import Darwin
import Foundation
import Security

enum PrepareError: Error { case invalid(String) }

// Sizes and offsets below are from mach_header_64, segment_command_64 and section_64.
private enum MachOLayout {
    static let magic64: UInt64 = 0xfeed_facf
    static let segment64: UInt64 = 0x19
    static let headerSize = 32
    static let segmentSize = 72
    static let sectionSize = 80
}

struct EmbeddedPlistSection {
    let contents: Range<Int>
    let sizeOffset: Int
}

func readLittleEndianInteger(_ data: Data, _ offset: Int, _ size: Int) throws -> UInt64 {
    guard offset >= 0, (1...8).contains(size), offset <= data.count - size else {
        throw PrepareError.invalid("Truncated Mach-O")
    }
    return (0..<size).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
}

func embeddedPlistSection(_ data: Data) throws -> EmbeddedPlistSection? {
    guard try readLittleEndianInteger(data, 0, 4) == MachOLayout.magic64 else {
        throw PrepareError.invalid("Expected a thin 64-bit Wine loader")
    }
    let count = Int(try readLittleEndianInteger(data, 16, 4))
    let commandBytes = Int(try readLittleEndianInteger(data, 20, 4))
    guard data.count >= MachOLayout.headerSize,
        commandBytes <= data.count - MachOLayout.headerSize,
        count <= commandBytes / 8
    else {
        throw PrepareError.invalid("Invalid Mach-O load command table")
    }
    let commandsEnd = MachOLayout.headerSize + commandBytes
    var position = MachOLayout.headerSize
    var plist: EmbeddedPlistSection?
    for _ in 0..<count {
        guard position <= commandsEnd - 8 else {
            throw PrepareError.invalid("Truncated Mach-O load command")
        }
        let command = try readLittleEndianInteger(data, position, 4)
        let size = Int(try readLittleEndianInteger(data, position + 4, 4))
        guard size >= 8, size % 8 == 0, size <= commandsEnd - position else {
            throw PrepareError.invalid("Invalid Mach-O load command size")
        }
        if command == MachOLayout.segment64 {
            guard size >= MachOLayout.segmentSize else {
                throw PrepareError.invalid("Truncated Mach-O segment")
            }
            let sections = Int(try readLittleEndianInteger(data, position + 64, 4))
            guard sections <= (size - MachOLayout.segmentSize) / MachOLayout.sectionSize else {
                throw PrepareError.invalid("Invalid section table")
            }
            for index in 0..<sections {
                let entry = position + MachOLayout.segmentSize + index * MachOLayout.sectionSize
                let name = String(
                    decoding: data[entry..<entry + 16].prefix { $0 != 0 }, as: UTF8.self)
                let segment = String(
                    decoding: data[entry + 16..<entry + 32].prefix { $0 != 0 }, as: UTF8.self)
                if name == "__info_plist" && segment == "__TEXT" {
                    let length = try readLittleEndianInteger(data, entry + 40, 8)
                    let start = Int(try readLittleEndianInteger(data, entry + 48, 4))
                    guard plist == nil, start >= commandsEnd, start <= data.count,
                        length <= UInt64(data.count - start)
                    else {
                        throw PrepareError.invalid("Invalid embedded plist section")
                    }
                    plist = EmbeddedPlistSection(
                        contents: start..<start + Int(length), sizeOffset: entry + 40)
                }
            }
        }
        position += size
    }
    guard position == commandsEnd else {
        throw PrepareError.invalid("Mach-O command count does not match its table")
    }
    return plist
}

func runCodesign(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw PrepareError.invalid("codesign failed") }
}

func signingInformation(_ target: URL) throws -> [String: Any] {
    var code: SecStaticCode?
    let status = SecStaticCodeCreateWithPath(target as CFURL, [], &code)
    guard status == errSecSuccess, let code else {
        throw PrepareError.invalid("Cannot read Wine code signature (\(status))")
    }
    var information: CFDictionary?
    let result = SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
    if result == errSecCSUnsigned { return [:] }
    guard result == errSecSuccess, let values = information as? [String: Any] else {
        throw PrepareError.invalid("Cannot read Wine signing metadata (\(result))")
    }
    return values
}

func prepare(_ target: URL, _ info: URL) throws {
    let original = try Data(contentsOf: target)
    guard let section = try embeddedPlistSection(original) else {
        print("Game Mode: no embedded plist; keeping app metadata")
        return
    }
    var bytes = original.subdata(in: section.contents)
    if !bytes.starts(with: "bplist00".utf8) {
        while bytes.last == 0 || bytes.last == 32 { bytes.removeLast() }
    }
    guard
        let old = try PropertyListSerialization.propertyList(from: bytes, format: nil)
            as? [String: Any],
        let app = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: info), format: nil) as? [String: Any],
        let identity = app["CFBundleIdentifier"] as? String,
        identity.hasPrefix("com.notproton.launcher."),
        let name = app["CFBundleName"] as? String,
        target.lastPathComponent == "wine"
    else {
        throw PrepareError.invalid("Not a staged NotProton game loader")
    }
    var updated = old.filter {
        [
            "CFBundleAllowMixedLocalizations", "CFBundleDevelopmentRegion",
            "CFBundleInfoDictionaryVersion", "CFBundleShortVersionString", "CFBundleVersion",
            // Wine promotes an agent to a regular app and activates it when showing a window.
            "LSUIElement",
        ].contains($0.key)
    }
    updated.merge([
        "CFBundleIdentifier": identity, "CFBundleName": name,
        "CFBundleExecutable": "wine", "CFBundlePackageType": "APPL",
        "NSPrincipalClass": "WineApplication",
        "NSHighResolutionCapable": true, "LSApplicationCategoryType": "public.app-category.games",
        "LSSupportsGameMode": true,
    ]) { _, new in new }
    for key in ["NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSLocalNetworkUsageDescription"] {
        if let description = app[key] as? String {
            updated[key] = description
        }
    }
    // Binary plist fits the fixed section; XML round-tripping makes its key order reproducible.
    let xml = try PropertyListSerialization.data(
        fromPropertyList: updated, format: .xml, options: 0)
    let ordered = try PropertyListSerialization.propertyList(from: xml, format: nil)
    let compact = try PropertyListSerialization.data(
        fromPropertyList: ordered, format: .binary, options: 0)
    guard compact.count <= section.contents.count else {
        throw PrepareError.invalid("Game metadata exceeds reserved section")
    }
    var replacement = original
    replacement.replaceSubrange(
        section.contents, with: compact + Data(repeating: 0, count: section.contents.count - compact.count))
    // A binary plist's trailer must be at the end of its declared section, before padding.
    var size = UInt64(compact.count).littleEndian
    withUnsafeBytes(of: &size) {
        replacement.replaceSubrange(section.sizeOffset..<section.sizeOffset + 8, with: $0)
    }
    if replacement == original { return }
    let files = FileManager.default
    let temporary = target.deletingLastPathComponent().appendingPathComponent(
        ".game-loader-" + UUID().uuidString)
    try files.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: temporary) }
    let staged = temporary.appendingPathComponent("wine")
    try replacement.write(to: staged)
    let attributes = try files.attributesOfItem(atPath: target.path)
    try files.setAttributes(
        [.posixPermissions: attributes[.posixPermissions] ?? 0o755], ofItemAtPath: staged.path)
    let signing = try signingInformation(target)
    let flags = (signing[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    var arguments = ["--force", "--sign", "-", "--identifier", identity]
    // Adding hardening to a plain loader can prevent DYLD from loading its libraries.
    if SecCodeSignatureFlags(rawValue: flags).contains(.runtime) {
        arguments += ["--options", "runtime"]
    }
    if let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
        let file = temporary.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(
            fromPropertyList: entitlements, format: .xml, options: 0).write(to: file)
        arguments += ["--entitlements", file.path]
    }
    try runCodesign(arguments + [staged.path])
    try runCodesign(["--verify", "--strict", staged.path])
    guard rename(staged.path, target.path) == 0 else {
        throw PrepareError.invalid("Atomic replacement failed: \(errno)")
    }
    print("Game Mode: staged Wine metadata updated for \(identity)")
}

do {
    guard CommandLine.arguments.count == 3 else { exit(64) }
    try prepare(
        URL(fileURLWithPath: CommandLine.arguments[1]),
        URL(fileURLWithPath: CommandLine.arguments[2]))
} catch {
    fputs("Game Mode: \(error)\n", stderr)
    exit(1)
}
