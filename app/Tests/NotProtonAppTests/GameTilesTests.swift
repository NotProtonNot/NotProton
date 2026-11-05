import Foundation
import Testing

@testable import NotProtonApp

@Suite("Game tiles")
struct GameTilesTests {

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [[String]] = []
        func add(_ arguments: [String]) { lock.withLock { seen.append(arguments) } }
        var all: [[String]] { lock.withLock { seen } }
    }

    private struct Layout {
        let root: URL
        let launchers: URL
        let vdf: URL
        let userdata: URL
        let run: URL

        func folder(_ id: String) -> String { launchers.appending(path: id).path(percentEncoded: false) }
        var script: String { run.path(percentEncoded: false) }
    }

    private func layout(games: [String], manifests: [String: String] = [:], libraries: [String] = ["main"],
                        missing: [String] = [], shortcuts: [UInt32]? = []) throws -> Layout {
        let root = try scratchDirectory("tiles")
        let launchers = root.appending(path: "launchers")
        for id in games {
            try FileManager.default.createDirectory(at: launchers.appending(path: id), withIntermediateDirectories: true)
        }
        var vdf = "\"libraryfolders\"\n{\n"
        for (n, name) in libraries.enumerated() {
            let library = root.appending(path: name)
            vdf += "\t\"\(n)\"\n\t{\n\t\t\"path\"\t\t\"\(library.path(percentEncoded: false))\"\n\t}\n"
            guard !missing.contains(name) else { continue }
            try FileManager.default.createDirectory(at: library.appending(path: "steamapps"), withIntermediateDirectories: true)
        }
        vdf += "}\n"
        let vdfURL = root.appending(path: "libraryfolders.vdf")
        try Data(vdf.utf8).write(to: vdfURL)
        for (id, name) in manifests {
            try Data("\"AppState\"\n{\n}\n".utf8).write(to: root.appending(path: "\(name)/steamapps/appmanifest_\(id).acf"))
        }
        let userdata = root.appending(path: "userdata")
        if let shortcuts {
            let config = userdata.appending(path: "12345/config")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try shortcutsVDF(shortcuts).write(to: config.appending(path: "shortcuts.vdf"))
        }
        return Layout(root: root, launchers: launchers, vdf: vdfURL, userdata: userdata, run: root.appending(path: "run"))
    }

    private func shortcutsVDF(_ ids: [UInt32], key: String = "appid") -> Data {
        var bytes: [UInt8] = [0] + Array("shortcuts".utf8) + [0]
        for (n, id) in ids.enumerated() {
            bytes += [0] + Array(String(n).utf8) + [0]
            bytes += [2] + Array(key.utf8) + [0] + withUnsafeBytes(of: id.littleEndian, Array.init)
            bytes += [1] + Array("AppName".utf8) + [0] + Array("Game \(n)".utf8) + [0]
            bytes += [8]
        }
        return Data(bytes + [8, 8])
    }

    private func refresh(_ layout: Layout, vdf: URL? = nil) -> [[String]] {
        let calls = Calls()
        GameTiles.refresh(launchers: layout.launchers, libraryFolders: vdf ?? layout.vdf, userdata: layout.userdata,
                          run: layout.run, execute: calls.add)
        return calls.all
    }

    @Test("installed games get a tile, uninstalled ones leave the Games app")
    func installedAndUninstalled() throws {
        let l = try layout(games: ["1574480", "1422450", "983870", "notagame"],
                           manifests: ["1574480": "main", "983870": "external"], libraries: ["main", "external"])
        #expect(refresh(l) == [
            [l.script, "game-untile", "1422450", l.folder("1422450")],
            [l.script, "game-tile", "1574480", "1574480", l.folder("1574480")],
            [l.script, "game-tile", "983870", "983870", l.folder("983870")],
        ])
    }

    @Test("nothing leaves while a library is missing")
    func unpluggedDrive() throws {
        let l = try layout(games: ["1574480", "983870"], manifests: ["1574480": "main"],
                           libraries: ["main", "external"], missing: ["external"])
        #expect(refresh(l) == [[l.script, "game-tile", "1574480", "1574480", l.folder("1574480")]])
    }

    @Test("nothing leaves when Steam's library list can't be read")
    func unreadableLibraryList() throws {
        let l = try layout(games: ["1422450"])
        #expect(refresh(l, vdf: l.root.appending(path: "missing.vdf")).isEmpty)
        let empty = l.root.appending(path: "empty.vdf")
        try Data("\"libraryfolders\"\n{\n}\n".utf8).write(to: empty)
        #expect(refresh(l, vdf: empty).isEmpty)
    }

    @Test("non-Steam shortcuts open by game ID and leave once removed from Steam")
    func shortcuts() throws {
        let l = try layout(games: ["2898422707", "3000000000"], shortcuts: [2_898_422_707])
        #expect(refresh(l) == [
            [l.script, "game-tile", "2898422707", String(UInt64(2_898_422_707) << 32 | 0x0200_0000), l.folder("2898422707")],
            [l.script, "game-untile", "3000000000", l.folder("3000000000")],
        ])
    }

    @Test("shortcuts stay when no shortcuts.vdf can be read")
    func unreadableShortcuts() throws {
        let l = try layout(games: ["3000000000"], shortcuts: nil)
        #expect(refresh(l).isEmpty)
    }

    @Test("shortcuts.vdf appids are read whatever the key's case")
    func shortcutIDs() throws {
        let userdata = try scratchDirectory("tiles")
        for (user, key, id) in [("1", "appid", UInt32(2_898_422_707)), ("2", "AppID", UInt32(3_000_000_001))] {
            let config = userdata.appending(path: "\(user)/config")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try shortcutsVDF([id], key: key).write(to: config.appending(path: "shortcuts.vdf"))
        }
        #expect(GameTiles.shortcutIDs(in: userdata) == [2_898_422_707, 3_000_000_001])
        #expect(GameTiles.shortcutIDs(in: userdata.appending(path: "missing")) == nil)
    }

    @Test("game IDs")
    func gameIDs() {
        #expect(GameTiles.gameID("1574480") == 1_574_480)
        #expect(GameTiles.gameID("2898422707") == UInt64(2_898_422_707) << 32 | 0x0200_0000)
        #expect(GameTiles.gameID("0") == nil)
        #expect(GameTiles.gameID("4294967296") == nil)
        #expect(GameTiles.gameID("abc") == nil)
    }
}
