import Darwin
import Foundation
import Testing
@testable import NotProtonApp

@Suite("Issue 36: targeted codesign metadata repair")
struct SigningMetadataTests {
    private func attribute(_ name: String, bytes: Data, at url: URL) throws {
        let result = bytes.withUnsafeBytes { data in
            url.path.withCString { path in
                name.withCString { setxattr(path, $0, data.baseAddress, data.count, 0, 0) }
            }
        }
        #expect(result == 0)
    }

    @Test("Finder metadata no longer blocks signing; other attributes survive")
    func signsWithFinderMetadata() throws {
        let work = URL.temporaryDirectory.appending(path: "np-signing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let target = work.appending(path: "true")
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: target)
        try attribute("com.apple.FinderInfo", bytes: Data(repeating: 1, count: 32), at: target)
        try attribute("com.apple.ResourceFork", bytes: Data("test fork".utf8), at: target)
        try attribute("com.notproton.keep", bytes: Data("preserve".utf8), at: target)
        try attribute("com.apple.quarantine", bytes: Data("0081;00000000;test;".utf8), at: target)
        let before = try Shell.run("/usr/bin/codesign", ["-f", "-s", "-", target.path])
        #expect(!before.succeeded)
        #expect(before.stderr.contains("detritus not allowed"))
        try SteamInstaller.adHocSign(target)
        #expect(try Shell.run("/usr/bin/codesign", ["--verify", "--strict", target.path]).succeeded)
        for name in ["com.notproton.keep", "com.apple.quarantine"] {
            #expect(try Shell.run("/usr/bin/xattr", ["-p", name, target.path]).succeeded)
        }
    }

    @Test("Metadata repair never follows a symlink outside the signed tree")
    func doesNotFollowLinks() throws {
        let work = URL.temporaryDirectory.appending(path: "np-signing-link-\(UUID().uuidString)")
        let tree = work.appending(path: "tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let outside = work.appending(path: "outside")
        try Data("outside".utf8).write(to: outside)
        try attribute("com.apple.FinderInfo", bytes: Data(repeating: 1, count: 32), at: outside)
        try FileManager.default.createSymbolicLink(at: tree.appending(path: "link"), withDestinationURL: outside)
        try SteamInstaller.removeSigningDetritus(at: tree)
        #expect(try Shell.run("/usr/bin/xattr", ["-p", "com.apple.FinderInfo", outside.path]).succeeded)
    }
}
