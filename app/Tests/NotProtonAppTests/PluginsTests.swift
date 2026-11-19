import Foundation
import Testing

@testable import NotProtonApp

@Suite("Listing and removing plugins")
struct PluginsTests {

    @Test("A plugin's records, label, games and requires are read")
    func parsesRecords() {
        let text = """
        # comment
        [NOTPROTON_ROSETTA_TRAP_BOOST]
        label = Forza Horizon 6 fix
        label = second label is ignored
        inject = 1
        requires = Library/Application Support/notproton/plugins/boost.dylib
        apps = 2483190
        apps = 1551360

        [NOTPROTON_ENV_HUD_POS]
        type = choice
        empty =
        [ no close
        """
        let records = PluginConf.parse(text)
        #expect(records.map(\.id) == ["NOTPROTON_ROSETTA_TRAP_BOOST", "NOTPROTON_ENV_HUD_POS"])
        #expect(records[0].label == "Forza Horizon 6 fix")
        #expect(records[0].apps == ["2483190", "1551360"])
        #expect(records[0].requires == ["Library/Application Support/notproton/plugins/boost.dylib"])
        #expect(records[1].label == nil)
    }

    @Test("Requires resolve against home the way the launcher does")
    func resolvesLikeTheLauncher() {
        let home = URL(filePath: "/Users/tester")
        #expect(PluginConf.resolve("lib/a.dylib", home: home).path(percentEncoded: false) == "/Users/tester/lib/a.dylib")
        #expect(PluginConf.resolve("~/lib/a.dylib", home: home).path(percentEncoded: false) == "/Users/tester/lib/a.dylib")
        #expect(PluginConf.resolve("$HOME/lib/a.dylib", home: home).path(percentEncoded: false) == "/Users/tester/lib/a.dylib")
        #expect(PluginConf.resolve("/opt/a.dylib", home: home).path(percentEncoded: false) == "/opt/a.dylib")
    }

    @Test("Removing takes only its own files from inside the plugins folder")
    @MainActor
    func removalStaysInsideTheFolder() async throws {
        let home = try scratchDirectory("plugins")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: "plugins")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["own.dylib", "shared.dylib"] {
            try Data().write(to: folder.appending(path: name))
        }
        try Data().write(to: home.appending(path: "outside.dylib"))
        try """
        [NOTPROTON_A]
        label = A
        requires = plugins/own.dylib
        requires = plugins/shared.dylib
        requires = outside.dylib
        requires = plugins/../outside.dylib
        requires = plugins/gone.dylib
        """.write(to: folder.appending(path: "10-a.conf"), atomically: true, encoding: .utf8)
        try "[NOTPROTON_B]\nrequires = ~/plugins/shared.dylib\n"
            .write(to: folder.appending(path: "20-b.conf"), atomically: true, encoding: .utf8)
        try "[NOTPROTON_C]\nrequires = plugins/none.dylib\n"
            .write(to: folder.appending(path: ".hidden.conf"), atomically: true, encoding: .utf8)

        let model = PluginsModel(folder: folder, home: home)
        await model.load()
        #expect(model.plugins.map(\.id) == ["10-a.conf", "20-b.conf"])
        let a = try #require(model.plugins.first)
        let owned = PluginConf.owned(by: a, among: model.plugins, folder: folder, home: home)
        #expect(owned.map(\.lastPathComponent) == ["own.dylib"])
        #expect(model.missing(a) == nil)
        #expect(model.missing(model.plugins[1]) == nil)

        try "[NOTPROTON_D]\nrequires = plugins/gone.dylib\n"
            .write(to: folder.appending(path: "30-d.conf"), atomically: true, encoding: .utf8)
        await model.load()
        #expect(model.missing(model.plugins[2]) == "plugins/gone.dylib")
    }
}
