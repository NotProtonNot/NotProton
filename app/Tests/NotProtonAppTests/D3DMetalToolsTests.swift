import Foundation
import Testing

@testable import NotProtonApp

@Suite("D3DMetal tools")
struct D3DMetalToolsTests {

    private func createTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "d3dm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSamplePrefix(in root: URL, appID: String = "1574480", name: String = "Agent 64") -> WinePrefix {
        let library = SteamLibrary(root: root)
        return WinePrefix(
            appID: appID,
            name: name,
            library: library,
            lastUsed: nil
        )
    }

    @Test("Cache directory resolves under Darwin cache dir")
    func cacheDirectoryResolves() {
        let dir = D3DMetalTools.cacheDirectory()
        #expect(dir != nil)
        #expect(dir?.lastPathComponent == "d3dm")
    }

    @Test("Candidate executable names match prefix title and name")
    func candidateNames() throws {
        let root = try createTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = makeSamplePrefix(in: root, appID: "1574480", name: "Agent 64")
        let candidates = D3DMetalTools.candidateExecutableNames(for: prefix)

        #expect(candidates.contains("agent 64"))
        #expect(candidates.contains("agent 64.exe"))
        #expect(candidates.contains("1574480"))
        #expect(candidates.contains("1574480.exe"))
    }

    @Test("Candidate executable names discover nested game binaries in subdirectories")
    func candidateNamesNestedDiscovery() throws {
        let root = try createTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = makeSamplePrefix(in: root, appID: "1091500", name: "Cyberpunk 2077")
        let common = prefix.library.steamapps.appending(path: "common/Cyberpunk 2077")
        let nestedBin = common.appending(path: "bin/x64")
        try FileManager.default.createDirectory(at: nestedBin, withIntermediateDirectories: true)
        try "dummy".write(to: nestedBin.appending(path: "Cyberpunk2077.exe"), atomically: true, encoding: .utf8)

        // Manifest linking installdir
        let manifest = prefix.library.steamapps.appending(path: "appmanifest_1091500.acf")
        let acf = """
        "AppState"
        {
        \t"appid"\t\t"1091500"
        \t"installdir"\t\t"Cyberpunk 2077"
        }
        """
        try acf.write(to: manifest, atomically: true, encoding: .utf8)

        let candidates = D3DMetalTools.candidateExecutableNames(for: prefix)
        #expect(candidates.contains("cyberpunk2077.exe"))
    }

    @Test("Shader cache clearing for specific prefix clears only that game's cache")
    func clearShaderCacheForPrefix() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheDir = tempDir.appending(path: "d3dm")
        let game1Dir = cacheDir.appending(path: "Agent 64.exe/shaders.cache")
        let game2Dir = cacheDir.appending(path: "GTA5.exe/shaders.cache")

        try FileManager.default.createDirectory(at: game1Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game2Dir, withIntermediateDirectories: true)
        try "cached1".write(to: game1Dir.appending(path: "cache.bin"), atomically: true, encoding: .utf8)
        try "cached2".write(to: game2Dir.appending(path: "cache.bin"), atomically: true, encoding: .utf8)

        let prefix = makeSamplePrefix(in: tempDir, appID: "1574480", name: "Agent 64")
        let cleared = try D3DMetalTools.clearShaderCache(for: prefix, cacheDir: cacheDir)

        #expect(cleared == 1)
        #expect(!FileManager.default.fileExists(atPath: game1Dir.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: game2Dir.path(percentEncoded: false)))
    }

    @Test("Shader cache clearing all caches removes every cache")
    func clearAllShaderCaches() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheDir = tempDir.appending(path: "d3dm")
        let game1Dir = cacheDir.appending(path: "Game1.exe/shaders.cache")
        let game2Dir = cacheDir.appending(path: "Game2.exe/shaders.cache")

        try FileManager.default.createDirectory(at: game1Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: game2Dir, withIntermediateDirectories: true)

        let cleared = try D3DMetalTools.clearAllShaderCaches(cacheDir: cacheDir)
        #expect(cleared == 2)
        #expect(!FileManager.default.fileExists(atPath: game1Dir.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: game2Dir.path(percentEncoded: false)))
    }

    @Test("Locating D3DMetal source detects direct, redist/lib, and lib folders")
    func locateSource() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let direct = tempDir.appending(path: "direct")
        try FileManager.default.createDirectory(at: direct.appending(path: "external"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: direct.appending(path: "wine"), withIntermediateDirectories: true)
        #expect(D3DMetalTools.locateSource(in: direct) == direct)

        let redist = tempDir.appending(path: "gptk_volume")
        let redistLib = redist.appending(path: "redist/lib")
        try FileManager.default.createDirectory(at: redistLib.appending(path: "external"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redistLib.appending(path: "wine"), withIntermediateDirectories: true)
        #expect(D3DMetalTools.locateSource(in: redist) == redistLib)

        let empty = tempDir.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(D3DMetalTools.locateSource(in: empty) == nil)
    }

    @Test("Update D3DMetal deploys new libraries, prepares MetalFX, and cleans up temporary backups")
    func updateD3DMetal() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fm = FileManager.default

        // Set up dummy runner with existing apple_gptk
        let runnerRoot = tempDir.appending(path: "runner")
        let gptk = runnerRoot.appending(path: "lib64/apple_gptk")
        let oldExt = gptk.appending(path: "external")
        let oldWine = gptk.appending(path: "wine")
        try fm.createDirectory(at: oldExt, withIntermediateDirectories: true)
        try fm.createDirectory(at: oldWine, withIntermediateDirectories: true)
        try "old_d3d".write(to: oldExt.appending(path: "libd3dshared.dylib"), atomically: true, encoding: .utf8)
        try "old_wine".write(to: oldWine.appending(path: "wine.txt"), atomically: true, encoding: .utf8)

        // Set up dummy evaluation environment distribution
        let gptkDist = tempDir.appending(path: "Evaluation environment for Windows games 4.0 beta 3")
        let distLib = gptkDist.appending(path: "redist/lib")
        let newExt = distLib.appending(path: "external")
        let newWine = distLib.appending(path: "wine")
        let newUnix = newWine.appending(path: "x86_64-unix")
        let newWin = newWine.appending(path: "x86_64-windows")
        try fm.createDirectory(at: newExt, withIntermediateDirectories: true)
        try fm.createDirectory(at: newUnix, withIntermediateDirectories: true)
        try fm.createDirectory(at: newWin, withIntermediateDirectories: true)

        try "new_d3d".write(to: newExt.appending(path: "libd3dshared.dylib"), atomically: true, encoding: .utf8)
        try "metalfx_so".write(to: newUnix.appending(path: "nvngx-on-metalfx.so"), atomically: true, encoding: .utf8)
        try "metalfx_dll".write(to: newWin.appending(path: "nvngx-on-metalfx.dll"), atomically: true, encoding: .utf8)
        try "nvapi_dll".write(to: newWin.appending(path: "nvapi64.dll"), atomically: true, encoding: .utf8)

        // Set up dummy prefix
        let prefix = makeSamplePrefix(in: tempDir, appID: "1574480", name: "Agent 64")
        let system32 = prefix.pfx.appending(path: "drive_c/windows/system32")
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)

        // Dummy cache dir
        let cacheDir = tempDir.appending(path: "d3dm")
        try fm.createDirectory(at: cacheDir.appending(path: "Agent 64.exe/shaders.cache"), withIntermediateDirectories: true)

        let outcome = try D3DMetalTools.update(
            runnerRoot: runnerRoot,
            from: gptkDist,
            prefixes: [prefix],
            cacheDir: cacheDir
        )

        #expect(outcome.metalFXPrepared)
        #expect(outcome.prefixesUpdated == 1)
        #expect(outcome.shaderCachesCleared == 1)

        // Verify old backups were cleaned up on success
        #expect(!fm.fileExists(atPath: gptk.appending(path: "external.old").path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: gptk.appending(path: "wine.old").path(percentEncoded: false)))

        // Verify new files were deployed
        let deployedD3D = try String(contentsOf: gptk.appending(path: "external/libd3dshared.dylib"), encoding: .utf8)
        #expect(deployedD3D == "new_d3d")

        // Verify MetalFX was prepared
        #expect(fm.fileExists(atPath: gptk.appending(path: "wine/x86_64-unix/nvngx.so").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: gptk.appending(path: "wine/x86_64-windows/nvngx.dll").path(percentEncoded: false)))

        // Verify prefix system32 received nvngx.dll and nvapi64.dll
        #expect(fm.fileExists(atPath: system32.appending(path: "nvngx.dll").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: system32.appending(path: "nvapi64.dll").path(percentEncoded: false)))
    }

    @Test("Reading D3DMetal version from plist")
    func d3dMetalVersionInspection() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runnerRoot = tempDir.appending(path: "CrossOver")
        let resources = runnerRoot.appending(path: "lib64/apple_gptk/external/D3DMetal.framework/Versions/A/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>4.0b3</string>
        </dict>
        </plist>
        """
        try plistContent.write(to: resources.appending(path: "version.plist"), atomically: true, encoding: .utf8)

        let ver = D3DMetalTools.d3dMetalVersion(runnerRoot: runnerRoot)
        #expect(ver == "4.0b3")
    }

    @Test("Cached versions filters incomplete or corrupted directories")
    func cachedVersionsFilter() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runnerRoot = tempDir.appending(path: "CrossOver")
        let versionsDir = D3DMetalTools.versionsCacheDirectory(runnerRoot: runnerRoot)

        // 1. Valid version folder (has external and wine)
        let validVer = versionsDir.appending(path: "3.0")
        try FileManager.default.createDirectory(at: validVer.appending(path: "external"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: validVer.appending(path: "wine"), withIntermediateDirectories: true)

        // 2. Corrupt version folder (empty, missing libraries)
        let corruptVer = versionsDir.appending(path: "4.0_corrupt")
        try FileManager.default.createDirectory(at: corruptVer, withIntermediateDirectories: true)

        // 3. Hidden directory (.DS_Store or .temp)
        let hiddenDir = versionsDir.appending(path: ".temp")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)

        // Extract cached versions using runnerRoot directly
        let entries = (try? FileManager.default.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil)) ?? []
        let validVersions = entries
            .filter { entry in
                !entry.lastPathComponent.hasPrefix(".") && D3DMetalTools.locateSource(in: entry) != nil
            }
            .map(\.lastPathComponent)

        #expect(validVersions == ["3.0"])
        #expect(!validVersions.contains("4.0_corrupt"))
        #expect(!validVersions.contains(".temp"))
    }

    @Test("Version parsing from DMG filenames")
    func versionFromFilename() {
        #expect(D3DMetalTools.versionFromFilename("Evaluation environment for Windows games 4.0 beta 3.dmg") == "4.0b3")
        #expect(D3DMetalTools.versionFromFilename("Evaluation environment for Windows games 4.0b3.dmg") == "4.0b3")
        #expect(D3DMetalTools.versionFromFilename("Evaluation Environment for Windows Games 3.0.dmg") == "3.0")
        #expect(D3DMetalTools.versionFromFilename("Game_Porting_Toolkit_1.0.dmg") == "1.0")
        #expect(D3DMetalTools.versionFromFilename("random_file.dmg") == nil)
    }

    @Test("Install, list, and remove D3DMetal variant")
    func d3dMetalVariantLifecycle() throws {
        let tempDir = try createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let supportDir = tempDir.appending(path: "notproton")
        let runnersDir = supportDir.appending(path: "runners")
        let sourceDir = tempDir.appending(path: "source_gptk")

        // Create dummy source tree
        let srcExt = sourceDir.appending(path: "external/D3DMetal.framework/Versions/A/Resources")
        let srcWineWin = sourceDir.appending(path: "wine/x86_64-windows")
        let srcWineUnix = sourceDir.appending(path: "wine/x86_64-unix")
        try FileManager.default.createDirectory(at: srcExt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcWineWin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcWineUnix, withIntermediateDirectories: true)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>4.0b3</string>
        </dict>
        </plist>
        """
        try plist.write(to: srcExt.appending(path: "version.plist"), atomically: true, encoding: .utf8)
        try "dummy-dll".write(to: srcWineWin.appending(path: "d3d12.dll"), atomically: true, encoding: .utf8)
        try "dummy-so".write(to: srcWineUnix.appending(path: "d3d12.so"), atomically: true, encoding: .utf8)
        try "metalfx-dll".write(to: srcWineWin.appending(path: "nvngx-on-metalfx.dll"), atomically: true, encoding: .utf8)

        // Install variant
        let variant = try D3DMetalTools.installVariant(
            from: sourceDir,
            name: "d3dmetal-4.0b3",
            label: "D3DMetal 4.0 Beta 3",
            supportDir: supportDir
        )

        #expect(variant.name == "d3dmetal-4.0b3")
        #expect(variant.label == "D3DMetal 4.0 Beta 3")
        #expect(variant.version == "4.0b3")
        #expect(FileManager.default.fileExists(atPath: variant.confURL.path(percentEncoded: false)))

        // Verify conf content
        let confContent = try String(contentsOf: variant.confURL, encoding: .utf8)
        #expect(confContent.contains("[d3dmetal-4.0b3]"))
        #expect(confContent.contains("variant = D3DMetal"))
        #expect(confContent.contains("dst     = lib64/apple_gptk"))

        // Verify metalfx was prepared
        let winTarget = variant.src.appending(path: "wine/x86_64-windows")
        #expect(FileManager.default.fileExists(atPath: winTarget.appending(path: "nvngx.dll").path(percentEncoded: false)))

        // List variants
        let installed = D3DMetalTools.installedVariants(supportDir: supportDir)
        #expect(installed.count == 1)
        #expect(installed[0].name == "d3dmetal-4.0b3")
        #expect(installed[0].label == "D3DMetal 4.0 Beta 3")

        // Create dummy assembled runner clone
        let runnerClone = runnersDir.appending(path: "crossover-26.3+d3dmetal-4.0b3@abc123")
        try FileManager.default.createDirectory(at: runnerClone, withIntermediateDirectories: true)

        // Remove variant
        try D3DMetalTools.removeVariant(name: "d3dmetal-4.0b3", supportDir: supportDir, runners: runnersDir)
        #expect(!FileManager.default.fileExists(atPath: variant.confURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: variant.src.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: runnerClone.path(percentEncoded: false)))
        #expect(D3DMetalTools.installedVariants(supportDir: supportDir).isEmpty)
    }
}
