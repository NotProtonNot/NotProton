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

    @Test("A cache that is not a cache fails instead of printing garbage")
    func refusesUnparsableFile() throws {
        let result = try read(Data(repeating: 0xab, count: 4096), "2100")

        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }
}
