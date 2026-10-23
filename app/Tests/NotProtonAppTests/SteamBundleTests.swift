import Foundation
import Testing

@testable import NotProtonApp

@Suite("Steam bundle")
struct SteamBundleTests {

    // The bug this guards was live: the sweep covered only the bundle being replaced, and the
    // helpers do not run from there, so an ipcserver survived a stop that reported success.
    @Test("The process sweep covers the helpers as well as the bundle being modified")
    func sweepCoversHelpers() {
        let patterns = SteamBundle.sweepPatterns(
            app: SupportPaths.Steam.app, helpers: [SupportPaths.Steam.innerApp]
        )

        #expect(patterns.count == 2)
        #expect(patterns.contains(#"/Applications/Steam\.app/"#))
        #expect(
            patterns.contains { $0.hasSuffix(#"/Steam\.AppBundle/Steam/"#) },
            "the inner bundle, where ipcserver and the helpers actually run, is not swept"
        )
    }

    // Without it, the pattern matches any process whose command line merely mentions the
    // path, including this test runner.
    @Test("Every pattern is directory-scoped")
    func patternsAreDirectoryScoped() {
        let patterns = SteamBundle.sweepPatterns(
            app: URL(filePath: "/tmp/Some.app"), helpers: [URL(filePath: "/tmp/Inner")]
        )

        #expect(patterns.allSatisfy { $0.hasSuffix("/") })
        #expect(patterns == [#"/tmp/Some\.app/"#, "/tmp/Inner/"])
    }

    @Test("Sweeping nothing is possible, so a test can stop short of killing helpers")
    func helpersCanBeEmpty() {
        let patterns = SteamBundle.sweepPatterns(app: URL(filePath: "/tmp/A.app"), helpers: [])
        #expect(patterns == [#"/tmp/A\.app/"#])
    }

    @Test("pkill gets the path with regular expression characters escaped")
    func patternsAreEscaped() {
        let patterns = SteamBundle.sweepPatterns(app: URL(filePath: "/Volumes/Games (SSD)+/Steam.app"), helpers: [])
        #expect(patterns == [#"/Volumes/Games \(SSD\)\+/Steam\.app/"#])
    }

    private enum Insert {
        case absent
        case own
        case ownWithoutControllerBlock
        case other(String)
    }

    private func deployment(
        insert: Insert, dylib: Bool, version: String?, steam: Bool = true
    ) throws -> SteamDeployment {
        let root = URL.temporaryDirectory.appending(path: "np-deploy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Steam.app")
        let versionFile = root.appending(path: "dylib.version")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let version { try Data("\(version)\n".utf8).write(to: versionFile) }
        if steam { try stubBundle(app, insert: insert, dylib: dylib) }
        return SteamBundle.deployment(bundledVersion: "0.2.0", app: app, versionFile: versionFile)
    }

    private func stubBundle(_ app: URL, insert: Insert, dylib: Bool) throws {
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        var plist: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam"]
        switch insert {
        case .absent:
            break
        case .own:
            let own = SupportPaths.Steam.deployedDylib(inBundle: app)
            plist[SteamBundle.environmentKey] = [
                SteamBundle.insertKey: own.path(percentEncoded: false),
                SteamBundle.controllerBlockKey: SteamBundle.controllerBlockValue,
            ]
        case .ownWithoutControllerBlock:
            let own = SupportPaths.Steam.deployedDylib(inBundle: app)
            plist[SteamBundle.environmentKey] = [
                SteamBundle.insertKey: own.path(percentEncoded: false)
            ]
        case .other(let value):
            plist[SteamBundle.environmentKey] = [SteamBundle.insertKey: value]
        }
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))

        if dylib {
            try Data("stand-in\n".utf8).write(to: macOS.appending(path: SupportPaths.dylibName))
        }
    }

    @Test("A bundle patched for this account with a matching version reads as installed")
    func installedForThisAccount() throws {
        #expect(try deployment(insert: .own, dylib: true, version: "0.2.0") == .installed(version: "0.2.0"))
    }

    @Test("A bundle patched by another account reports no version rather than a clean install")
    func patchedByAnotherAccount() throws {
        #expect(try deployment(insert: .own, dylib: true, version: nil) == .installed(version: nil))
    }

    @Test("A plist naming a dylib that is not there reads as not installed")
    func namedDylibMissing() throws {
        #expect(try deployment(insert: .own, dylib: false, version: "0.2.0") == .notInstalled)
    }

    @Test("An older recorded version reads as outdated")
    func outdatedVersion() throws {
        #expect(
            try deployment(insert: .own, dylib: true, version: "0.1.0")
                == .outdated(deployed: "0.1.0", bundled: "0.2.0")
        )
    }

    @Test("A bundle patched before the controller block reads as outdated")
    func missingControllerBlock() throws {
        #expect(
            try deployment(insert: .ownWithoutControllerBlock, dylib: true, version: "0.2.0")
                == .outdated(deployed: "0.2.0", bundled: "0.2.0")
        )
    }

    @Test("Somebody else's insert is left alone")
    func foreignInsert() throws {
        #expect(
            try deployment(insert: .other("/opt/other/thing.dylib"), dylib: true, version: nil)
                == .foreign(insert: "/opt/other/thing.dylib")
        )
    }

    // The insert still names the bundle's old location, so the next install has to rewrite it
    @Test("A patched bundle moved after install reads as not installed, not foreign")
    func movedBundle() throws {
        #expect(
            try deployment(insert: .other("/Applications/Steam.app/Contents/MacOS/notproton.dylib"), dylib: true, version: "0.2.0")
                == .notInstalled
        )
    }

    @Test("An unpatched bundle reads as not installed")
    func unpatched() throws {
        #expect(try deployment(insert: .absent, dylib: false, version: nil) == .notInstalled)
    }

    @Test("A missing bundle reads as Steam missing")
    func steamMissing() throws {
        #expect(
            try deployment(insert: .absent, dylib: false, version: "0.2.0", steam: false) == .steamMissing
        )
    }
}
