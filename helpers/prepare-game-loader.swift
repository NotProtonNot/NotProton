// Give the staged Wine loader its game app identity by atomically replacing
// a private copy, preserving the shared runner inode.
import Darwin
import Foundation

enum PrepareError: Error { case invalid(String) }

// Sizes and offsets below are from mach_header_64, segment_command_64 and section_64.
private enum MachOLayout {
    static let magic64: UInt64 = 0xfeed_facf
    static let segment64: UInt64 = 0x19
    static let headerSize = 32
    static let segmentSize = 72
    static let sectionSize = 80
}

func readLittleEndianInteger(_ data: Data, _ offset: Int, _ size: Int) throws -> UInt64 {
    guard offset >= 0, (1...8).contains(size), offset <= data.count - size else {
        throw PrepareError.invalid("Truncated Mach-O")
    }
    return (0..<size).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
}

func embeddedPlistSection(_ data: Data) throws -> Range<Int>? {
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
    var plist: Range<Int>?
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
                    plist = start..<start + Int(length)
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

func runCodesign(_ arguments: [String]) throws -> Data {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = arguments
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw PrepareError.invalid("codesign failed") }
    return data
}

func prepare(_ target: URL, _ info: URL) throws {
    let original = try Data(contentsOf: target)
    guard let section = try embeddedPlistSection(original) else {
        print("Game Mode: no embedded plist; keeping app metadata")
        return
    }
    var bytes = original.subdata(in: section)
    while bytes.last == 0 || bytes.last == 32 { bytes.removeLast() }
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
        ].contains($0.key)
    }
    updated.merge([
        "CFBundleIdentifier": identity, "CFBundleName": name,
        "CFBundleExecutable": "wine", "CFBundlePackageType": "APPL",
        "NSPrincipalClass": "WineApplication",
        "NSHighResolutionCapable": true, "LSApplicationCategoryType": "public.app-category.games",
        "LSSupportsGameMode": true,
    ]) { _, new in new }
    let xml = try PropertyListSerialization.data(
        fromPropertyList: updated, format: .xml, options: 0)
    let compact = Data(
        String(decoding: xml, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined().utf8)
    guard compact.count <= section.count else {
        throw PrepareError.invalid("Game metadata exceeds reserved section")
    }
    var replacement = original
    replacement.replaceSubrange(
        section, with: compact + Data(repeating: 32, count: section.count - compact.count))
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
    let entitlements = try runCodesign(["-d", "--entitlements", ":-", target.path])
    var arguments = ["--force", "--sign", "-", "--identifier", identity, "--options", "runtime"]
    if !entitlements.isEmpty {
        _ = try PropertyListSerialization.propertyList(from: entitlements, format: nil)
        let file = temporary.appendingPathComponent("entitlements.plist")
        try entitlements.write(to: file)
        arguments += ["--entitlements", file.path]
    }
    _ = try runCodesign(arguments + [staged.path])
    _ = try runCodesign(["--verify", "--strict", staged.path])
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
