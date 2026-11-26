// Reads Steam's appinfo.vdf cache and prints key=value metadata for one app on
// stdout. Usage: appinfo <appinfo.vdf> <appid>.
// With --platforms instead of an appid it prints mac= and windows= appid lists.
// With --shortcut <userdata> <appid> [login] it prints a non-Steam shortcut's name.
//
// common/icon is a 32x32 thumbnail. common/clienticon is the real multi-res
// icon, and the two hashes differ for most apps, so the icon cannot be
// inferred from the filesystem. Exits non-zero without printing on read
// failure.

import Foundation

let args = CommandLine.arguments

func sameBundle(_ left: String, _ right: String) throws -> Bool {
    let fm = FileManager.default
    let a = try fm.attributesOfItem(atPath: left)
    let b = try fm.attributesOfItem(atPath: right)
    guard let kind = a[.type] as? FileAttributeType,
          kind == b[.type] as? FileAttributeType else { return false }
    switch kind {
    case .typeSymbolicLink:
        return try fm.destinationOfSymbolicLink(atPath: left)
            == fm.destinationOfSymbolicLink(atPath: right)
    case .typeDirectory:
        let names = try fm.contentsOfDirectory(atPath: left)
        let other = try fm.contentsOfDirectory(atPath: right)
        // Bytes, not String: == treats NFC and NFD names as equal.
        guard Set(names.map { Array($0.utf8) }) == Set(other.map { Array($0.utf8) }) else { return false }
        for name in names {
            guard try sameBundle((left as NSString).appendingPathComponent(name),
                                 (right as NSString).appendingPathComponent(name)) else { return false }
        }
        return true
    case .typeRegular:
        guard (a[.posixPermissions] as? NSNumber) == (b[.posixPermissions] as? NSNumber) else { return false }
        return fm.contentsEqual(atPath: left, andPath: right)
    default:
        throw CocoaError(.fileReadUnknown)
    }
}

if args.count == 4, args[1] == "--same-bundle" {
    do {
        exit(try sameBundle(args[2], args[3]) ? 0 : 1)
    } catch {
        exit(2)
    }
}

func userdataFolder(_ userdata: String, _ account: String) -> String? {
    guard let text = try? String(contentsOfFile: "\(userdata)/../config/loginusers.vdf", encoding: .utf8) else { return nil }
    var id: UInt64?
    for line in text.split(whereSeparator: \.isNewline) {
        let quoted = line.split(separator: "\"", omittingEmptySubsequences: false)
        if quoted.count == 3, let key = UInt64(quoted[1]) { id = key }
        if quoted.count == 5, quoted[1].lowercased() == "accountname", let id,
           quoted[3].lowercased() == account.lowercased() {
            return String(UInt32(truncatingIfNeeded: id))
        }
    }
    return nil
}

func shortcutName(_ userdata: String, _ appID: UInt32, _ account: String?) -> String? {
    let fm = FileManager.default
    var folders = (try? fm.contentsOfDirectory(atPath: userdata)) ?? []
    if let account, let mine = userdataFolder(userdata, account) { folders = [mine] }
    let files = folders
        .map { "\(userdata)/\($0)/config/shortcuts.vdf" }
        .compactMap { path -> (String, Date)? in
            guard let at = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
            return (path, at)
        }
        .sorted { $0.1 > $1.1 }
    for (path, _) in files {
        guard let data = fm.contents(atPath: path) else { continue }
        var c = Cursor(b: [UInt8](data), p: 0)
        guard let root = try? readSection(&c, nil), case .section(let list)? = root["shortcuts"] else { continue }
        for case .section(let entry) in list.values {
            let keys = Dictionary(entry.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
            guard case .number(let id)? = keys["appid"], UInt32(truncatingIfNeeded: id) == appID,
                  case .string(let name)? = keys["appname"], !name.isEmpty else { continue }
            return name
        }
    }
    return nil
}

if args.count == 4 || args.count == 5, args[1] == "--shortcut" {
    guard let want = UInt32(args[3]),
          let name = shortcutName(args[2], want, args.count == 5 ? args[4] : nil) else { exit(1) }
    print("name=" + name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
    exit(0)
}

let platforms = args.count == 3 && args[2] == "--platforms"
guard args.count == 3, platforms || UInt32(args[2]) != nil else {
    fputs("usage: appinfo <appinfo.vdf|appinfo folder> <appid>|--platforms\n", stderr)
    exit(2)
}

func cacheFiles(_ path: String) -> [String]? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
    guard isDir.boolValue else { return [path] }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
    let shards = names.filter { $0.hasPrefix("appinfo_") && $0.hasSuffix(".vdf") }.sorted()
    return shards.isEmpty ? nil : shards.map { (path as NSString).appendingPathComponent($0) }
}

let files = cacheFiles(args[1]) ?? []
let caches = files.compactMap { FileManager.default.contents(atPath: $0).map { [UInt8]($0) } }
guard !files.isEmpty, caches.count == files.count else {
    fputs("appinfo: cannot read \(args[1])\n", stderr)
    exit(1)
}

enum VDFError: Error {
    case truncated
    case unknownType(UInt8)
    case unknownMagic(UInt32)
    case badStringIndex(UInt32)
    case excessiveNesting
}

indirect enum Value {
    case string(String)
    case number(Int64)
    case section([String: Value])
}

struct Cursor {
    let b: [UInt8]
    var p: Int
    let end: Int

    init(b: [UInt8], p: Int, end: Int? = nil) {
        self.b = b
        self.p = p
        self.end = end ?? b.count
    }

    mutating func u8() throws -> UInt8 {
        guard p < end else { throw VDFError.truncated }
        defer { p += 1 }
        return b[p]
    }

    mutating func u32() throws -> UInt32 {
        guard p + 4 <= end else { throw VDFError.truncated }
        defer { p += 4 }
        return UInt32(b[p]) | UInt32(b[p + 1]) << 8
            | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            guard p + i < end else { throw VDFError.truncated }
            v |= UInt64(b[p + i]) << (8 * UInt64(i))
        }
        p += 8
        return v
    }

    // Values and, before the string table existed, keys are NUL terminated.
    mutating func cstring() throws -> String {
        var end = p
        while end < self.end && b[end] != 0 { end += 1 }
        guard end < self.end else { throw VDFError.truncated }
        let s = String(decoding: b[p..<end], as: UTF8.self)
        p = end + 1
        return s
    }

    // A wide string ends at a NUL pair, not a single NUL.
    mutating func wcstring() throws -> String {
        var end = p
        while end + 1 < self.end && !(b[end] == 0 && b[end + 1] == 0) { end += 2 }
        guard end + 1 < self.end else { throw VDFError.truncated }
        var units: [UInt16] = []
        var i = p
        while i < end {
            units.append(UInt16(b[i]) | UInt16(b[i + 1]) << 8)
            i += 2
        }
        p = end + 2
        return String(decoding: units, as: UTF16.self)
    }

    mutating func skip(_ n: Int) throws {
        guard p + n <= end else { throw VDFError.truncated }
        p += n
    }
}

// v29 moved every key into one table at the end of the file and left an index
// in its place, so the table has to be read before any app can be parsed.
func readStringTable(_ b: [UInt8], at offset: Int) throws -> [String] {
    var c = Cursor(b: b, p: offset)
    let count = try c.u32()
    var out: [String] = []
    out.reserveCapacity(Int(count))
    for _ in 0..<count { out.append(try c.cstring()) }
    return out
}

func readSection(_ c: inout Cursor, _ table: [String]?, depth: Int = 0) throws -> [String: Value] {
    guard depth < 64 else { throw VDFError.excessiveNesting }
    var out: [String: Value] = [:]
    while true {
        let type = try c.u8()
        // 0x0b is the alternate section terminator the format also allows.
        if type == 0x08 || type == 0x0b { return out }
        let key: String
        if let table = table {
            let i = try c.u32()
            guard Int(i) < table.count else { throw VDFError.badStringIndex(i) }
            key = table[Int(i)]
        } else {
            key = try c.cstring()
        }
        switch type {
        // Handles every type the format defines. An unused-but-legal type inside
        // an app entry would otherwise drop the whole entry and its name.
        case 0x00: out[key] = .section(try readSection(&c, table, depth: depth + 1))
        case 0x01: out[key] = .string(try c.cstring())
        case 0x02: out[key] = .number(Int64(Int32(bitPattern: try c.u32())))
        case 0x03: try c.skip(4)
        case 0x04: try c.skip(4)
        case 0x05: out[key] = .string(try c.wcstring())
        case 0x06: try c.skip(4)
        case 0x07: out[key] = .number(Int64(bitPattern: try c.u64()))
        case 0x0a: out[key] = .number(Int64(bitPattern: try c.u64()))
        default: throw VDFError.unknownType(type)
        }
    }
}

func forEachShardApp(_ b: [UInt8], _ visit: (UInt32, () throws -> [String: Value]) throws -> Bool) throws -> Bool {
    var head = Cursor(b: b, p: 4)
    _ = try head.u32()
    _ = try head.u32()
    _ = try head.u32()
    let count = Int(try head.u32())
    let indexSize = Int(try head.u32())
    let stringCount = Int(try head.u32())
    let stringsSize = Int(try head.u32())
    let dataSize = Int(try head.u32())
    let indexStart = 0x2c
    guard indexStart + indexSize + stringsSize + dataSize == b.count else { throw VDFError.truncated }
    var strings = Cursor(b: b, p: indexStart + indexSize, end: indexStart + indexSize + stringsSize)
    var table: [String] = []
    table.reserveCapacity(stringCount)
    for _ in 0..<stringCount { table.append(try strings.cstring()) }
    let dataStart = indexStart + indexSize + stringsSize

    var record = Cursor(b: b, p: indexStart, end: indexStart + indexSize)
    for _ in 0..<count {
        let id = try record.u32()
        let offset = Int(try record.u32())
        let size = Int(try record.u32())
        try record.skip(Int(try record.u32()))
        guard size >= 20, offset <= dataSize, size <= dataSize - offset else { throw VDFError.truncated }
        let start = dataStart + offset + 20
        let end = dataStart + offset + size
        let keys = { () throws -> [String: Value] in
            var kv = Cursor(b: b, p: start, end: end)
            let root = try readSection(&kv, table)
            if case .section(let inner)? = root["appinfo"] { return inner }
            return root
        }
        if try !visit(id, keys) { return true }
    }
    guard record.p == indexStart + indexSize else { throw VDFError.truncated }
    return true
}

// Returns false when the list runs out before the zero appid that ends it.
func forEachApp(_ b: [UInt8], _ visit: (UInt32, () throws -> [String: Value]) throws -> Bool) throws -> Bool {
    var head = Cursor(b: b, p: 0)
    let magic = try head.u32()
    if magic == 0x0756_442A { return try forEachShardApp(b, visit) }
    _ = try head.u32()

    var table: [String]? = nil
    var pos: Int
    var entriesEnd = b.count
    // The sha1 of the entry's own binary vdf arrived in v28, which moves the
    // start of the key data 20 bytes further into every app entry.
    var entryHeader = 60
    switch magic {
    case 0x0756_4429:
        let offset = try head.u64()
        guard offset >= 16, offset < UInt64(b.count) else { throw VDFError.truncated }
        table = try readStringTable(b, at: Int(offset))
        entriesEnd = Int(offset)
        pos = 16
    case 0x0756_4428:
        pos = 8
    case 0x0756_4427:
        pos = 8
        entryHeader = 40
    default:
        throw VDFError.unknownMagic(magic)
    }

    while pos + 4 <= entriesEnd {
        var e = Cursor(b: b, p: pos, end: entriesEnd)
        let id = try e.u32()
        if id == 0 { return true }
        let size = Int(try e.u32())
        guard size >= entryHeader, size <= entriesEnd - pos - 8 else { throw VDFError.truncated }
        let entryEnd = pos + 8 + size
        let start = pos + 8 + entryHeader
        let keys = { () throws -> [String: Value] in
            var kv = Cursor(b: b, p: start, end: entryEnd)
            let root = try readSection(&kv, table)
            // Each entry wraps its keys in one "appinfo" section.
            if case .section(let inner)? = root["appinfo"] { return inner }
            return root
        }
        if try !visit(id, keys) { return true }
        pos = entryEnd
    }
    return false
}

func findApp(_ caches: [[UInt8]], _ appID: UInt32) throws -> [String: Value]? {
    var found: [String: Value]?
    for b in caches where found == nil {
        _ = try forEachApp(b) { id, keys in
            guard id == appID else { return true }
            found = try keys()
            return false
        }
    }
    return found
}

// Steam treats an app without an oslist as Windows only.
// oslist can still say macos for a 32-bit build that no longer runs.
func printPlatforms(_ caches: [[UInt8]]) throws {
    var mac: [UInt32] = []
    var windows: [UInt32] = []
    for b in caches {
        let complete = try forEachApp(b) { id, keys in
            guard case .section(let common)? = try keys()["common"] else { return true }
            guard case .string(let oslist)? = common["oslist"] else {
                windows.append(id)
                return true
            }
            let systems = oslist.split(separator: ",")
            if systems.contains("macos") { mac.append(id) }
            if systems.contains("windows") { windows.append(id) }
            return true
        }
        guard complete else { throw VDFError.truncated }
    }
    print("mac=" + mac.map(String.init).joined(separator: ","))
    print("windows=" + windows.map(String.init).joined(separator: ","))
}

do {
    if platforms {
        try printPlatforms(caches)
        exit(0)
    }
    let wantAppID = UInt32(args[2])!
    guard let app = try findApp(caches, wantAppID) else {
        fputs("appinfo: no entry for appid \(wantAppID)\n", stderr)
        exit(1)
    }
    guard case .section(let common)? = app["common"] else {
        fputs("appinfo: appid \(wantAppID) has no common section\n", stderr)
        exit(1)
    }
    // A newline in a value would break the key=value framing the caller reads.
    for key in ["name", "icon", "clienticon", "logo"] {
        guard case .string(let v)? = common[key], !v.isEmpty else { continue }
        let flat = v.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        print("\(key)=\(flat)")
    }
} catch {
    fputs("appinfo: cannot parse \(args[1]): \(error)\n", stderr)
    exit(1)
}
