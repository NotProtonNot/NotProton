import Foundation
import Testing
@testable import NotProtonApp

@Suite("Setup write access")
@MainActor
struct SteamWriteAccessTests {
    @Test("Unverified and denied access never enable Continue; returning after approval rechecks")
    func permissionChanges() {
        let access = SteamWriteAccess()
        #expect(!access.isReady)
        access.check(probe: { _ in throw WriteRefused(path: "/Applications/Steam.app/Contents/MacOS") })
        #expect(!access.isReady)
        access.check(probe: { _ in })
        #expect(access.isReady)
        access.check(probe: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(!access.isReady)
    }

    @Test("The probe preserves existing files and symlinks and leaves no temporary file")
    func uniqueProbe() throws {
        let app = URL.temporaryDirectory.appending(path: "np-access-\(UUID().uuidString).app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let original = macOS.appending(path: "steam_osx")
        try Data("unchanged".utf8).write(to: original)
        let oldProbe = macOS.appending(path: ".notproton-write-probe")
        try FileManager.default.createSymbolicLink(at: oldProbe, withDestinationURL: original)
        try SteamInstaller.assertBundleIsWritable(app)
        #expect(try Data(contentsOf: original) == Data("unchanged".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: macOS.path).sorted()
                == [".notproton-write-probe", "steam_osx"])
    }
}
