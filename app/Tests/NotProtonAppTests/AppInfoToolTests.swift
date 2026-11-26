import Foundation
import Testing

@testable import NotProtonApp

// The launcher builds a game's bundle name and icon from what this tool prints, so a parse
// that reads the wrong key mislabels a bundle. Caches are synthetic: the installed one is v29.
@Suite("appinfo tool")
struct AppInfoToolTests {

    private struct Cache {
        var bytes: [UInt8] = []

        mutating func u32(_ v: UInt32) {
            for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) }
        }

        mutating func u64(_ v: UInt64) {
            for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
        }

        mutating func cstring(_ s: String) {
            bytes.append(contentsOf: Array(s.utf8))
            bytes.append(0)
        }
    }

    private static let fields = [
        ("name", "Dark Messiah of Might & Magic"),
        ("icon", "5a08cd17d14ccb07a14f316dfa222b18a20960fd"),
        ("clienticon", "0d652160dff1ab3d1352aa83c9cf14a20146519e"),
    ]

    // Key data is identical in both formats apart from how a key is named, so the
    // caller decides that and the section nesting stays shared.
    private static func keyData(_ key: (String) -> [UInt8]) -> [UInt8] {
        var kv = Cache()
        kv.bytes.append(0x00)
        kv.bytes.append(contentsOf: key("appinfo"))
        kv.bytes.append(0x00)
        kv.bytes.append(contentsOf: key("common"))
        for (name, value) in fields {
            kv.bytes.append(0x01)
            kv.bytes.append(contentsOf: key(name))
            kv.cstring(value)
        }
        // One terminator closes common, one closes appinfo, and one closes the root
        // section the tool starts reading at. A real entry ends 08 08 08 for that reason.
        kv.bytes.append(contentsOf: [0x08, 0x08, 0x08])
        return kv.bytes
    }

    private static func entry(appID: UInt32, keyData: [UInt8]) -> [UInt8] {
        var e = Cache()
        e.u32(appID)
        // The size counts everything after itself, and the 60 byte header in between
        // is what the tool has to skip to reach the keys.
        e.u32(UInt32(60 + keyData.count))
        e.bytes.append(contentsOf: [UInt8](repeating: 0, count: 60))
        e.bytes.append(contentsOf: keyData)
        return e.bytes
    }

    private static func v29(appID: UInt32) -> Data {
        let table = ["appinfo", "common"] + fields.map(\.0)
        let index = { (key: String) -> [UInt8] in
            var c = Cache()
            c.u32(UInt32(table.firstIndex(of: key)!))
            return c.bytes
        }
        let body = entry(appID: appID, keyData: keyData(index))

        var file = Cache()
        file.u32(0x0756_4429)
        file.u32(1)
        // Header, entry and the zero appid that ends the list all precede the table.
        file.u64(UInt64(16 + body.count + 4))
        file.bytes.append(contentsOf: body)
        file.u32(0)
        file.u32(UInt32(table.count))
        for s in table { file.cstring(s) }
        return Data(file.bytes)
    }

    private static func v28(appID: UInt32) -> Data {
        let inline = { (key: String) -> [UInt8] in
            var c = Cache()
            c.cstring(key)
            return c.bytes
        }
        var file = Cache()
        file.u32(0x0756_4428)
        file.u32(1)
        file.bytes.append(contentsOf: entry(appID: appID, keyData: keyData(inline)))
        file.u32(0)
        return Data(file.bytes)
    }

    private static func platformEntry(
        _ appID: UInt32, _ oslist: String?, common: Bool = true, table: [String]? = nil
    ) -> [UInt8] {
        entry(appID: appID, keyData: platformKeys(appID, oslist, common: common, table: table))
    }

    private static func platformKeys(
        _ appID: UInt32, _ oslist: String?, common: Bool = true, table: [String]? = nil
    ) -> [UInt8] {
        var kv = Cache()
        func key(_ name: String) {
            if let table { kv.u32(UInt32(table.firstIndex(of: name)!)) }
            else { kv.cstring(name) }
        }
        kv.bytes.append(0x00)
        key("appinfo")
        if common {
            kv.bytes.append(0x00)
            key("common")
            kv.bytes.append(0x01)
            key("name")
            kv.cstring("App \(appID)")
            if let oslist {
                kv.bytes.append(0x01)
                key("oslist")
                kv.cstring(oslist)
            }
            kv.bytes.append(0x08)
        }
        kv.bytes.append(contentsOf: [0x08, 0x08])
        return kv.bytes
    }

    private static let shardTable = ["appinfo", "common", "name", "oslist"] + fields.map(\.0)

    private static func shardIndex(_ key: String) -> [UInt8] {
        var c = Cache()
        c.u32(UInt32(shardTable.firstIndex(of: key)!))
        return c.bytes
    }

    private static func shard(_ apps: [(UInt32, [UInt8])], recordSize: UInt32? = nil) -> Data {
        var index = Cache()
        var data = Cache()
        for (appID, keys) in apps {
            index.u32(appID)
            index.u32(UInt32(data.bytes.count))
            index.u32(recordSize ?? UInt32(20 + keys.count))
            index.u32(64)
            index.bytes.append(contentsOf: [UInt8](repeating: 0, count: 64))
            data.bytes.append(contentsOf: [UInt8](repeating: 0, count: 20))
            data.bytes.append(contentsOf: keys)
        }
        var strings = Cache()
        for key in shardTable { strings.cstring(key) }
        var file = Cache()
        file.u32(0x0756_442A)
        file.u32(1)
        file.u32(0)
        file.u32(256)
        file.u32(UInt32(apps.count))
        file.u32(UInt32(index.bytes.count))
        file.u32(UInt32(shardTable.count))
        file.u32(UInt32(strings.bytes.count))
        file.u32(UInt32(data.bytes.count))
        file.u64(0)
        file.bytes += index.bytes + strings.bytes + data.bytes
        return Data(file.bytes)
    }

    private static func platformShards() -> [Data] {
        [
            shard([10, 20, 30].map { ($0, platformKeys($0, [10: "windows,macos", 20: "windows"][$0], table: shardTable)) }),
            shard([
                (40, platformKeys(40, "linux", table: shardTable)),
                (50, platformKeys(50, "macos", table: shardTable)),
                (60, platformKeys(60, nil, common: false, table: shardTable)),
            ]),
        ]
    }

    private static func platforms(
        ended: Bool = true, firstSize: UInt32? = nil, stringTable: Bool = false
    ) -> Data {
        let table = stringTable ? ["appinfo", "common", "name", "oslist"] : nil
        var entries = Cache()
        var first = platformEntry(10, "windows,macos", table: table)
        if let firstSize {
            var size = Cache()
            size.u32(firstSize)
            first.replaceSubrange(4..<8, with: size.bytes)
        }
        entries.bytes.append(contentsOf: first)
        entries.bytes.append(contentsOf: platformEntry(20, "windows", table: table))
        entries.bytes.append(contentsOf: platformEntry(30, nil, table: table))
        entries.bytes.append(contentsOf: platformEntry(40, "linux", table: table))
        entries.bytes.append(contentsOf: platformEntry(50, "macos", table: table))
        entries.bytes.append(contentsOf: platformEntry(60, nil, common: false, table: table))
        if ended { entries.u32(0) }
        var file = Cache()
        file.u32(stringTable ? 0x0756_4429 : 0x0756_4428)
        file.u32(1)
        if let table {
            file.u64(UInt64(16 + entries.bytes.count))
            file.bytes.append(contentsOf: entries.bytes)
            file.u32(UInt32(table.count))
            for key in table { file.cstring(key) }
        } else {
            file.bytes.append(contentsOf: entries.bytes)
        }
        return Data(file.bytes)
    }

    private func read(_ cache: Data, _ appID: String) throws -> CommandResult {
        let tool = try InstallPayload.locate().appinfo
        let path = URL.temporaryDirectory.appending(path: "np-appinfo-\(UUID().uuidString).vdf")
        try cache.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let result = try Shell.run(
            tool.path(percentEncoded: false), [path.path(percentEncoded: false), appID])
        #expect(
            !result.outputLost,
            "appinfo ran but its output was never collected, so every field below reads as absent")
        return result
    }

    private func read(shards: [Data], _ appID: String) throws -> CommandResult {
        let tool = try InstallPayload.locate().appinfo
        let dir = URL.temporaryDirectory.appending(path: "np-appinfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, shard) in shards.enumerated() {
            try shard.write(to: dir.appending(path: String(format: "appinfo_%02x.vdf", i)))
        }
        let result = try Shell.run(
            tool.path(percentEncoded: false), [dir.path(percentEncoded: false), appID])
        #expect(!result.outputLost)
        return result
    }

    private func values(_ result: CommandResult) -> [String: String] {
        var out: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard let split = line.firstIndex(of: "=") else { continue }
            out[String(line[line.startIndex..<split])] = String(line[line.index(after: split)...])
        }
        return out
    }

    @Test("A v29 cache resolves the client icon, which is not the icon we used to guess")
    func readsStringTableFormat() throws {
        let result = try read(Self.v29(appID: 2100), "2100")
        let fields = values(result)

        #expect(result.status == 0)
        #expect(fields["clienticon"] == "0d652160dff1ab3d1352aa83c9cf14a20146519e")
        #expect(fields["icon"] == "5a08cd17d14ccb07a14f316dfa222b18a20960fd")
        // A name carrying an ampersand is what broke the generated plist before, so it
        // has to survive the parse intact for the caller to escape it.
        #expect(fields["name"] == "Dark Messiah of Might & Magic")
    }

    @Test("A v28 cache with inline keys resolves the same values")
    func readsInlineKeyFormat() throws {
        let result = try read(Self.v28(appID: 42700), "42700")
        let fields = values(result)

        #expect(result.status == 0)
        #expect(fields["clienticon"] == "0d652160dff1ab3d1352aa83c9cf14a20146519e")
        #expect(fields["name"] == "Dark Messiah of Might & Magic")
    }

    @Test("An app the cache does not carry prints nothing and fails")
    func refusesUnknownApp() throws {
        let result = try read(Self.v29(appID: 2100), "10180")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty, "a caller reading key=value lines must get none")
    }

    @Test("--platforms lists Mac games, and Windows games including those with no oslist or a Mac build too",
          arguments: [false, true])
    func listsPlatforms(stringTable: Bool) throws {
        let result = try read(Self.platforms(stringTable: stringTable), "--platforms")

        #expect(result.status == 0)
        #expect(result.stdout == "mac=10,50\nwindows=10,20,30\n")
    }

    @Test("--platforms on a cache that stops early prints nothing and fails", arguments: [false, true])
    func refusesTruncatedPlatforms(stringTable: Bool) throws {
        let result = try read(Self.platforms(ended: false, stringTable: stringTable), "--platforms")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty, "a half list would hide the rest of the library")
    }

    @Test("--platforms rejects invalid entry sizes", arguments: [UInt32(1), 59, UInt32.max], [false, true])
    func refusesInvalidPlatformEntrySize(_ size: UInt32, stringTable: Bool) throws {
        let result = try read(Self.platforms(firstSize: size, stringTable: stringTable), "--platforms")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("An app cannot borrow its section terminator from outside its entry")
    func refusesKeysOutsideEntry() throws {
        var cache = Self.v28(appID: 2100)
        var size = Cache()
        size.u32(UInt32(cache.count - 8 - 8 - 4 - 1))
        cache.replaceSubrange(12..<16, with: size.bytes)
        let result = try read(cache, "2100")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("Deeply nested appinfo sections fail without crashing the helper", arguments: [false, true])
    func refusesExcessiveNesting(stringTable: Bool) throws {
        let depth = 32_768
        var keys = Cache()
        for _ in 0..<depth {
            keys.bytes.append(0x00)
            if stringTable { keys.u32(0) }
            else { keys.cstring("nested") }
        }
        keys.bytes.append(contentsOf: repeatElement(UInt8(0x08), count: depth + 1))
        let body = Self.entry(appID: 2100, keyData: keys.bytes)
        var file = Cache()
        file.u32(stringTable ? 0x0756_4429 : 0x0756_4428)
        file.u32(1)
        if stringTable { file.u64(UInt64(16 + body.count + 4)) }
        file.bytes.append(contentsOf: body)
        file.u32(0)
        if stringTable {
            file.u32(1)
            file.cstring("nested")
        }

        let result = try read(Data(file.bytes), "--platforms")
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("cannot parse"))
    }

    @Test("An appinfo folder resolves an app from whichever shard holds it")
    func readsShardFolder() throws {
        let other = Self.shard([(10, Self.platformKeys(10, "windows", table: Self.shardTable))])
        let result = try read(shards: [other, Self.shard([(2100, Self.keyData(Self.shardIndex))])], "2100")
        let fields = values(result)

        #expect(result.status == 0)
        #expect(fields["clienticon"] == "0d652160dff1ab3d1352aa83c9cf14a20146519e")
        #expect(fields["name"] == "Dark Messiah of Might & Magic")
    }

    @Test("--platforms on an appinfo folder lists the apps of every shard")
    func listsShardPlatforms() throws {
        let result = try read(shards: Self.platformShards(), "--platforms")

        #expect(result.status == 0)
        #expect(result.stdout == "mac=10,50\nwindows=10,20,30\n")
    }

    @Test("--platforms fails when any shard is cut short")
    func refusesTruncatedShard() throws {
        var shards = Self.platformShards()
        shards[1].removeLast()
        let result = try read(shards: shards, "--platforms")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("A shard record cannot point past its shard's data", arguments: [UInt32(19), 4096, UInt32.max])
    func refusesInvalidShardRecord(_ size: UInt32) throws {
        let shard = Self.shard([(2100, Self.keyData(Self.shardIndex))], recordSize: size)
        let result = try read(shards: [shard], "2100")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("An empty appinfo folder fails")
    func refusesEmptyShardFolder() throws {
        let result = try read(shards: [], "--platforms")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("A cache that is not a cache fails instead of printing garbage")
    func refusesUnparsableFile() throws {
        let result = try read(Data(repeating: 0xab, count: 4096), "2100")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    private static let starRail: UInt32 = 2_612_745_101
    private static let mine = "54303850"
    private static let theirs = "678157147"

    private static func shortcuts(
        _ apps: [(UInt32, String)], idKey: String = "appid", nameKey: String = "AppName"
    ) -> Data {
        var f = Cache()
        f.bytes.append(0x00)
        f.cstring("shortcuts")
        for (i, app) in apps.enumerated() {
            f.bytes.append(0x00)
            f.cstring(String(i))
            f.bytes.append(0x02)
            f.cstring(idKey)
            f.u32(app.0)
            f.bytes.append(0x01)
            f.cstring(nameKey)
            f.cstring(app.1)
            f.bytes.append(0x01)
            f.cstring("Exe")
            f.cstring("\"/Volumes/Games/launcher.exe\"")
            f.bytes.append(0x08)
        }
        f.bytes.append(contentsOf: [0x08, 0x08])
        return Data(f.bytes)
    }

    private static func loginUsers(_ logins: [(String, String)]) -> String {
        var text = "\"users\"\n{\n"
        for (folder, login) in logins {
            let id = 76_561_197_960_265_728 + UInt64(folder)!
            text += "\t\"\(id)\"\n\t{\n\t\t\"AccountName\"\t\t\"\(login)\"\n"
            text += "\t\t\"PersonaName\"\t\t\"\(login) in public\"\n\t\t\"timestamp\"\t\t\"1795719111\"\n\t}\n"
        }
        return text + "}\n"
    }

    private func shortcut(
        accounts: [(String, Data)], logins: [(String, String)]? = nil, _ appID: UInt32 = starRail,
        login: String? = nil
    ) throws -> CommandResult {
        let tool = try InstallPayload.locate().appinfo
        let fm = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "np-shortcut-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let userdata = root.appending(path: "userdata")
        try fm.createDirectory(at: userdata, withIntermediateDirectories: true)
        for (i, account) in accounts.enumerated() {
            let config = userdata.appending(path: "\(account.0)/config")
            try fm.createDirectory(at: config, withIntermediateDirectories: true)
            let file = config.appending(path: "shortcuts.vdf")
            try account.1.write(to: file)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_795_000_000 + Double(i) * 86400)],
                ofItemAtPath: file.path(percentEncoded: false))
        }
        if let logins {
            let config = root.appending(path: "config")
            try fm.createDirectory(at: config, withIntermediateDirectories: true)
            try Self.loginUsers(logins).write(
                to: config.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)
        }
        var arguments = ["--shortcut", userdata.path(percentEncoded: false), String(appID)]
        if let login { arguments.append(login) }
        let result = try Shell.run(tool.path(percentEncoded: false), arguments)
        #expect(!result.outputLost)
        return result
    }

    private static let twoAccounts = [
        (mine, shortcuts([(4_054_248_690, "HoYoPlay"), (starRail, "Honkai Star Rail")])),
        (theirs, shortcuts([(starRail, "Star Rail (theirs)")])),
    ]
    private static let twoLogins = [(mine, "first_login"), (theirs, "second_login")]

    @Test("--shortcut names a non-Steam game from shortcuts.vdf")
    func namesShortcut() throws {
        let result = try shortcut(accounts: [Self.twoAccounts[0]])

        #expect(result.status == 0)
        #expect(result.stdout == "name=Honkai Star Rail\n")
    }

    @Test("--shortcut reads the keys in whatever case Steam wrote them",
          arguments: [("appid", "AppName"), ("AppId", "appname"), ("APPID", "APPNAME")])
    func namesShortcutInAnyKeyCase(_ keys: (String, String)) throws {
        let file = Self.shortcuts([(Self.starRail, "Honkai Star Rail")], idKey: keys.0, nameKey: keys.1)
        let result = try shortcut(accounts: [(Self.mine, file)])

        #expect(values(result)["name"] == "Honkai Star Rail")
    }

    @Test("--shortcut with a login reads that account, not the newest file",
          arguments: ["first_login", "FIRST_LOGIN"])
    func namesShortcutFromLoggedInAccount(_ login: String) throws {
        let result = try shortcut(accounts: Self.twoAccounts, logins: Self.twoLogins, login: login)

        #expect(result.status == 0)
        #expect(values(result)["name"] == "Honkai Star Rail")
    }

    @Test("--shortcut does not borrow a name from another account when the login is known")
    func refusesOtherAccountsShortcut() throws {
        let result = try shortcut(
            accounts: Self.twoAccounts, logins: Self.twoLogins, 4_054_248_690, login: "second_login")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("--shortcut without a usable login takes the most recently written file",
          arguments: [nil, "nobody"])
    func namesShortcutFromNewestFile(_ login: String?) throws {
        let result = try shortcut(accounts: Self.twoAccounts, logins: Self.twoLogins, login: login)

        #expect(values(result)["name"] == "Star Rail (theirs)")
    }

    @Test("--shortcut falls back to the newest file when loginusers.vdf is missing")
    func namesShortcutWithoutLoginUsers() throws {
        let result = try shortcut(accounts: Self.twoAccounts, login: "first_login")

        #expect(values(result)["name"] == "Star Rail (theirs)")
    }

    @Test("--shortcut skips a file it cannot parse and reads the next one")
    func skipsUnparsableShortcuts() throws {
        let cut = Self.twoAccounts[1].1.prefix(20)
        let result = try shortcut(accounts: [Self.twoAccounts[0], (Self.theirs, Data(cut))])

        #expect(values(result)["name"] == "Honkai Star Rail")
    }

    @Test("--shortcut prints a name with line breaks on one line")
    func flattensShortcutName() throws {
        let file = Self.shortcuts([(Self.starRail, "Star\nRail\r\nicon=x")])
        let result = try shortcut(accounts: [(Self.mine, file)])

        #expect(result.stdout == "name=Star Rail  icon=x\n")
    }

    @Test("--shortcut fails for an appid no shortcut has, an empty name, and a missing userdata folder")
    func refusesUnknownShortcut() throws {
        let unknown = try shortcut(accounts: Self.twoAccounts, 730)
        let unnamed = try shortcut(accounts: [(Self.mine, Self.shortcuts([(Self.starRail, "")]))])
        let missing = try shortcut(accounts: [])

        for result in [unknown, unnamed, missing] {
            #expect(result.status != 0)
            #expect(result.stdout.isEmpty)
        }
    }
}
