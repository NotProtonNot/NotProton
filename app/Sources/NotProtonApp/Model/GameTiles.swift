// Fixes up Games app entries without waiting for each game's next launch
import Foundation

enum GameTiles {
    static func refresh(
        launchers: URL = SupportPaths.launchers,
        libraryFolders: URL = SupportPaths.Steam.libraryFoldersVDF,
        userdata: URL = SupportPaths.Steam.userData.appending(path: "userdata"),
        run: URL,
        execute: ([String]) -> Void = { arguments in
            let result = try? Shell.run("/bin/sh", arguments)
            if result?.status != 0 { AppLog.note("game tiles: \(arguments.dropFirst().joined(separator: " ")) failed") }
        }
    ) {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: launchers.path(percentEncoded: false))) ?? []
        let libraries = steamLibraries(vdf: libraryFolders)
        let shortcuts = shortcutIDs(in: userdata)
        let script = run.path(percentEncoded: false)
        for id in ids.sorted() {
            guard let gameID = gameID(id), let appID = UInt32(id) else { continue }
            let folder = launchers.appending(path: id).path(percentEncoded: false)
            let shortcut = appID >= 0x8000_0000
            let installed = shortcut ? shortcuts?.contains(appID) == true : libraries.steamapps.contains {
                FileManager.default.fileExists(atPath: $0.appending(path: "appmanifest_\(id).acf").path(percentEncoded: false))
            }
            if installed {
                execute([script, "game-tile", id, String(gameID), folder])
            } else if shortcut ? shortcuts != nil : libraries.complete {
                execute([script, "game-untile", id, folder])
            }
        }
    }

    static func gameID(_ appID: String) -> UInt64? {
        guard let id = UInt64(appID), id > 0, id <= UInt32.max else { return nil }
        return id >= 0x8000_0000 ? id << 32 | 0x0200_0000 : id
    }

    static func steamLibraries(vdf: URL) -> (steamapps: [URL], complete: Bool) {
        let steamapps = PrefixStore.libraries(vdf: vdf).map(\.steamapps)
        guard let text = try? String(contentsOf: vdf, encoding: .utf8), text.contains("\"path\"") else {
            return (steamapps, false)
        }
        var isDirectory: ObjCBool = false
        let complete = !steamapps.isEmpty && steamapps.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false), isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return (steamapps, complete)
    }

    static func shortcutIDs(in userdata: URL) -> Set<UInt32>? {
        let users = (try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil)) ?? []
        let name = Array("appid".utf8)
        var ids: Set<UInt32>?
        for user in users {
            guard let data = try? Data(contentsOf: user.appending(path: "config/shortcuts.vdf")) else { continue }
            var found = ids ?? []
            let bytes = Array(data)
            var i = 0
            while i + name.count + 6 <= bytes.count {
                let field = bytes[(i + 1)...(i + name.count)]
                if bytes[i] == 2, bytes[i + name.count + 1] == 0,
                   zip(field, name).allSatisfy({ $0 | 0x20 == $1 }) {
                    let start = i + name.count + 2
                    found.insert(bytes[start..<(start + 4)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                    i = start + 4
                } else {
                    i += 1
                }
            }
            ids = found
        }
        return ids
    }
}
