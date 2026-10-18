import Darwin
import Foundation
import Testing

@testable import NotProtonApp

@Suite("Prefix template cleanup")
struct TemplateCleanupTests {
    private struct Layout {
        let root: URL
        var runners: URL { root.appending(path: "runners") }
        var library: SteamLibrary { SteamLibrary(root: root.appending(path: "library")) }
        var folder: URL { library.compatdata.appending(path: SupportPaths.prefixTemplateFolder) }
        var template: URL { SupportPaths.prefixTemplates(forBuild: "26.3.0.39832", in: library)[0] }
        var lock: URL { library.compatdata.appending(path: ".notproton-template.lock") }

        init() throws {
            root = try scratchDirectory("template-cleanup")
            try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        }

        func removeBuild() throws {
            let build = "1.2.3.4567"
            try FileManager.default.createDirectory(
                at: SupportPaths.runnerRoot(forBuild: build, runners: runners),
                withIntermediateDirectories: true)
            try Data("old tool list\n".utf8).write(to: root.appending(path: "tools"))
            try RunnerInstaller.removeClone(
                forBuild: build, runners: runners, bridge: root.appending(path: "bridge"),
                toolList: root.appending(path: "tools"), compatTools: root.appending(path: "compat-tools"),
                libraries: [library], running: { _ in false })
        }
    }

    @Test("A linked template root cannot delete the directory it points at")
    func refusesLinkedRoot() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let outside = layout.root.appending(path: "outside")
        try FileManager.default.moveItem(at: layout.folder, to: outside)
        try FileManager.default.createSymbolicLink(at: layout.folder, withDestinationURL: outside)

        let failures = RunnerInstaller.removeStalePrefixTemplates(runners: layout.runners, libraries: [layout.library])

        #expect(failures.count == 1)
        #expect(failures.first?.detail.contains(layout.folder.path) == true)
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: layout.template.lastPathComponent).path))
    }

    @Test("Only recognized template names are removed")
    func preservesUnknownChildren() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let names = ["notes", "crossover--x86_64-unix", "crossover-bad_build-x86_64-unix", "crossover-26.3.0.39832-i386-unix"]
        for name in names {
            try Data("keep".utf8).write(to: layout.folder.appending(path: name))
        }

        let failures = RunnerInstaller.removeStalePrefixTemplates(runners: layout.runners, libraries: [layout.library])

        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.template.path))
        for name in names {
            #expect(FileManager.default.fileExists(atPath: layout.folder.appending(path: name).path))
        }
    }

    @Test("The drive's bridge copy stays while any build is set up and goes with the last")
    func bridgeCacheGoesWithLastBuild() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let cache = layout.folder.appending(path: SupportPaths.bridgeCacheFolder)
        try FileManager.default.createDirectory(at: cache.appending(path: "x86_64-unix"), withIntermediateDirectories: true)
        try Data("bridge".utf8).write(to: cache.appending(path: "x86_64-unix/lsteamclient.so"))

        #expect(RunnerInstaller.removePrefixTemplates(keeping: ["26.3.0.39832"], libraries: [layout.library]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: cache.appending(path: "x86_64-unix/lsteamclient.so").path))
        #expect(FileManager.default.fileExists(atPath: layout.template.path))

        #expect(RunnerInstaller.removePrefixTemplates(keeping: [], libraries: [layout.library]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(!FileManager.default.fileExists(atPath: layout.template.path))
    }

    @Test("Removing every build takes the empty template folder but keeps the lock and game prefixes")
    func fullRemovalKeepsLockAndPrefixes() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let save = layout.library.compatdata.appending(path: "700330/pfx/drive_c/save.dat")
        try FileManager.default.createDirectory(at: save.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("save".utf8).write(to: save)
        let opened = open(layout.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(opened >= 0)
        guard opened >= 0 else { return }
        defer { close(opened) }

        #expect(RunnerInstaller.removePrefixTemplates(keeping: [], libraries: [layout.library], removingFolder: true).isEmpty)

        #expect(!FileManager.default.fileExists(atPath: layout.folder.path))
        #expect(FileManager.default.fileExists(atPath: layout.lock.path))
        #expect(FileManager.default.fileExists(atPath: save.path))
        #expect(flock(opened, LOCK_EX | LOCK_NB) == 0)
        let next = open(layout.lock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(next >= 0)
        guard next >= 0 else { return }
        defer { close(next) }
        #expect(flock(next, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK)
    }

    @Test("A template folder with unknown files keeps the folder and its lock")
    func unknownFilesKeepFolderAndLock() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try Data("keep".utf8).write(to: layout.folder.appending(path: "notes"))

        #expect(RunnerInstaller.removePrefixTemplates(keeping: [], libraries: [layout.library], removingFolder: true).isEmpty)

        #expect(FileManager.default.fileExists(atPath: layout.folder.appending(path: "notes").path))
        #expect(FileManager.default.fileExists(atPath: layout.lock.path))
    }

    @MainActor
    @Test("The bridge copies on every drive are counted once")
    func countsBridgeCopies() async throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let other = SteamLibrary(root: layout.root.appending(path: "second-library"))
        for library in [layout.library, other] {
            let cache = library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                .appending(path: SupportPaths.bridgeCacheFolder)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 4 << 20).write(to: cache.appending(path: "steam.exe"))
        }
        let status = SystemStatus()

        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library, other], cleanTemplates: false)

        #expect(status.bridgeCopyBytes >= 8 << 20)
        #expect(status.bridgeCopyBytes < 9 << 20)
    }

    @Test("Linked template children are unlinked without touching their targets")
    func unlinksChildrenOnly() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let outside = layout.root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appending(path: "keep")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: layout.template.appending(path: "Documents"), withDestinationURL: outside)
        let linked = SupportPaths.prefixTemplates(forBuild: "26.3.0.39832", in: layout.library)[1]
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        let failures = RunnerInstaller.removeStalePrefixTemplates(runners: layout.runners, libraries: [layout.library])

        #expect(failures.isEmpty)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: linked.path)) == nil)
    }

    @Test("A busy template lock leaves the cache intact and reports the skipped cleanup")
    func reportsBusyLock() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let fd = open(layout.lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)

        #expect(throws: StepFailure.self) { try layout.removeBuild() }
        #expect(FileManager.default.fileExists(atPath: layout.template.path))
        #expect(!FileManager.default.fileExists(atPath: SupportPaths.runnerRoot(forBuild: "1.2.3.4567", runners: layout.runners).path))
        #expect(try String(contentsOf: layout.root.appending(path: "tools"), encoding: .utf8).isEmpty)
    }

    @Test("A linked lock file cannot authorize template cleanup")
    func refusesLinkedLock() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let outside = layout.root.appending(path: "lock-target")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: layout.lock, withDestinationURL: outside)

        #expect(throws: StepFailure.self) { try layout.removeBuild() }
        #expect(FileManager.default.fileExists(atPath: layout.template.path))
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
    }

    @Test("A refused template deletion is reported after runner removal")
    func reportsDeletionFailure() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try #require(chflags(layout.template.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(layout.template.path, 0) }

        #expect(throws: StepFailure.self) { try layout.removeBuild() }
        #expect(FileManager.default.fileExists(atPath: layout.template.path))
    }

    @MainActor
    @Test("Refresh skips a busy template lock without a report and cleans up once it is free")
    func refreshRetriesWithoutRunners() async throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let fd = open(layout.lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let status = SystemStatus()

        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library])
        #expect(status.templateCleanupFailure == nil)
        #expect(FileManager.default.fileExists(atPath: layout.template.path))

        try #require(flock(fd, LOCK_UN) == 0)
        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library])
        #expect(status.templateCleanupFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.template.path))
        #expect(FileManager.default.fileExists(atPath: layout.lock.path))
        #expect(!FileManager.default.fileExists(atPath: layout.runners.path))
    }

    @MainActor
    @Test("A library that returns after runner removal is cleaned on refresh")
    func refreshCleansRemountedLibrary() async throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let unmounted = layout.root.appending(path: "unmounted-library")
        try FileManager.default.moveItem(at: layout.library.root, to: unmounted)
        let status = SystemStatus()

        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library])
        #expect(!FileManager.default.fileExists(atPath: layout.library.root.path))
        #expect(status.templateCleanupFailure == nil)

        try FileManager.default.moveItem(at: unmounted, to: layout.library.root)
        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library])
        #expect(!FileManager.default.fileExists(atPath: layout.template.path))
        #expect(status.templateCleanupFailure == nil)
    }

    @MainActor
    @Test("Template allocated footprints include every mounted library and refresh after changes")
    func refreshesTemplateSizes() async throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let build = "26.3.0.39832"
        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: build, runners: layout.runners).appending(path: "lib/wine"),
            withIntermediateDirectories: true)
        let other = SteamLibrary(root: layout.root.appending(path: "second-library"))
        let otherTemplate = SupportPaths.prefixTemplates(forBuild: build, in: other)[1]
        try FileManager.default.createDirectory(at: otherTemplate, withIntermediateDirectories: true)
        let file = layout.template.appending(path: "ntdll.dll")
        try Data(repeating: 7, count: 4 << 20).write(to: file)
        try #require(clonefile(file.path, otherTemplate.appending(path: "ntdll.dll").path, 0) == 0)
        let status = SystemStatus()

        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library, other])
        #expect(try #require(status.templateSizes[build]?.values.reduce(0, +)) >= 8 << 20)
        #expect(try #require(status.runnerSizes[build]) < 1 << 20)
        let before = try #require(status.templateSizes[build]?.values.reduce(0, +))

        try Data(repeating: 8, count: 4 << 20).write(to: layout.template.appending(path: "new-file"))
        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library, other])
        #expect(try #require(status.templateSizes[build]?.values.reduce(0, +)) >= before + (4 << 20))

        await status.refreshRunnerStorage(runners: layout.runners, libraries: [other])
        #expect(try #require(status.templateSizes[build]?.values.reduce(0, +)) < 5 << 20)
    }

    @MainActor
    @Test("A build with a FEX and a Rosetta tool measures each tool's template on its own")
    func measuresTemplatesPerTool() async throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let build = "27.0.0.40921-fex"
        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: build, runners: layout.runners).appending(path: "lib/wine"),
            withIntermediateDirectories: true)
        for (flavor, size) in [(CompatTool.Flavor.fex, 4 << 20), (.rosetta, 1 << 20)] {
            let template = SupportPaths.prefixTemplate(forBuild: build, flavor: flavor, in: layout.library)
            try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
            try Data(repeating: 7, count: size).write(to: template.appending(path: "system.reg"))
        }
        let status = SystemStatus()

        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library])
        let sizes = try #require(status.templateSizes[build])
        #expect(try #require(sizes[.fex]) >= 4 << 20)
        #expect(try #require(sizes[.rosetta]) >= 1 << 20)
        #expect(try #require(sizes[.rosetta]) < 2 << 20)
    }

    @MainActor
    @Test("Refresh keeps a reinstalling build's templates while the installation lock is held")
    func refreshDuringRunnerReplacement() async throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let fm = FileManager.default
        let replacing = "27.0.0.41069-fex"
        let other = "27.0.0.41073-fex"
        for build in [replacing, other] {
            try fm.createDirectory(
                at: SupportPaths.clonedRoot(forBuild: build, runners: layout.runners).appending(path: "lib/wine"),
                withIntermediateDirectories: true)
            for template in SupportPaths.prefixTemplates(forBuild: build, in: layout.library) {
                try fm.createDirectory(at: template, withIntermediateDirectories: true)
                try Data(repeating: 7, count: 65536).write(to: template.appending(path: "system.reg"))
            }
        }
        let target = SupportPaths.runnerRoot(forBuild: replacing, runners: layout.runners)
        let staging = layout.runners.appending(path: ".crossover-\(replacing).new")
        let lock = try DeploymentContent.acquireInstallationLock(in: layout.root, steamFolder: nil)
        var held = true
        defer { if held { lock.release() } }
        try fm.moveItem(at: target, to: staging)
        let status = SystemStatus()

        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library],
            acquireInstallationLock: {
                try DeploymentContent.acquireInstallationLock(in: layout.root, steamFolder: nil)
            })

        #expect(status.templateCleanupFailure == nil)
        #expect(status.runnerSizes[other] != nil)
        for flavor in CompatTool.Flavor.allCases {
            #expect(fm.fileExists(atPath: SupportPaths.prefixTemplate(
                forBuild: replacing, flavor: flavor, in: layout.library).path))
            #expect(try #require(status.templateSizes[other]?[flavor]) >= 65536)
        }

        try fm.moveItem(at: staging, to: target)
        lock.release()
        held = false
        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library],
            acquireInstallationLock: {
                try DeploymentContent.acquireInstallationLock(in: layout.root, steamFolder: nil)
            })

        #expect(status.templateCleanupFailure == nil)
        #expect(!fm.fileExists(atPath: layout.template.path))
        for build in [replacing, other] {
            for flavor in CompatTool.Flavor.allCases {
                #expect(try #require(status.templateSizes[build]?[flavor]) >= 65536)
            }
        }
    }

    @Test("The size line names each tool's templates only when a build has more than one tool")
    func sizeTextNamesTools() {
        func labels(_ templates: [CompatTool.Flavor: Int64], _ flavors: [CompatTool.Flavor]) -> [String] {
            StatusView.sizeText(runner: 2_000_000, templates: templates, flavors: flavors)
                .components(separatedBy: "\n")
                .map { $0.components(separatedBy: " ").dropLast(2).joined(separator: " ") }
        }
        #expect(labels([.fex: 871_000_000, .rosetta: 417_000_000], [.fex, .rosetta])
                == ["Runner", "FEX templates", "Rosetta templates"])
        #expect(labels([.fex: 871_000_000, .rosetta: 0], [.fex, .rosetta]) == ["Runner", "FEX templates"])
        #expect(labels([.rosetta: 371_000_000], [.rosetta]) == ["Runner", "Templates"])
        #expect(labels([:], [.rosetta]) == ["Runner"])
    }

    @Test("A failed child does not prevent cleanup in other mounted libraries")
    func continuesAfterFailure() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let other = SteamLibrary(root: layout.root.appending(path: "other"))
        let template = SupportPaths.prefixTemplates(forBuild: "26.3.0.39832", in: other)[0]
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        try #require(chflags(layout.template.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(layout.template.path, 0) }

        let failures = RunnerInstaller.removeStalePrefixTemplates(runners: layout.runners, libraries: [layout.library, other])

        #expect(failures.count == 1)
        #expect(failures.first?.detail.contains(layout.template.path) == true)
        #expect(!FileManager.default.fileExists(atPath: template.path))
    }

    @Test("An offline library is not created by template cleanup")
    func leavesOfflineLibrariesAbsent() throws {
        let root = try scratchDirectory("template-offline")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SteamLibrary(root: root.appending(path: "offline"))

        let failures = RunnerInstaller.removeStalePrefixTemplates(runners: root.appending(path: "runners"), libraries: [library])

        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: library.root.path))
    }

    @MainActor
    @Test("A blocked installation can measure storage without cleaning another build's templates")
    func skipsMaintenanceForNewerBuild() async throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let status = SystemStatus()
        await status.refreshRunnerStorage(runners: layout.runners, libraries: [layout.library], cleanTemplates: false)
        #expect(FileManager.default.fileExists(atPath: layout.template.path))
        #expect(!FileManager.default.fileExists(atPath: layout.lock.path))
    }

    @Test("A read-only library without a cache needs no cleanup lock")
    func skipsMissingCacheOnReadOnlyLibrary() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        try FileManager.default.removeItem(at: layout.folder)
        try #require(chmod(layout.library.compatdata.path, 0o500) == 0)
        defer { chmod(layout.library.compatdata.path, 0o700) }

        let failures = RunnerInstaller.removePrefixTemplates(keeping: [], libraries: [layout.library])

        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.lock.path))
    }

    @Test("A Swift template lock blocks the shell lock until released")
    func swiftLockBlocksShell() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let fd = open(layout.lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        let arguments = ["-c", #"exec 9>> "$1"; /usr/bin/lockf -s -t 0 9"#, "fixture", layout.lock.path]

        #expect(try Shell.run("/bin/sh", arguments).status == 75)
        try #require(flock(fd, LOCK_UN) == 0)
        #expect(try Shell.run("/bin/sh", arguments).status == 0)
    }

    @Test("A shell template lock blocks Swift cleanup until released")
    func shellLockBlocksCleanup() throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = URL(filePath: "/bin/sh")
        child.arguments = ["-ec", #"exec 9>> "$1"; /usr/bin/lockf -s -t 0 9; printf 'ready\n'; read -r release"#, "fixture", layout.lock.path]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        try #require(ready == Data("ready\n".utf8))

        let failures = RunnerInstaller.removePrefixTemplates(keeping: [], libraries: [layout.library])
        #expect(failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: layout.template.path))

        try input.fileHandleForWriting.write(contentsOf: Data("release\n".utf8))
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        #expect(RunnerInstaller.removePrefixTemplates(keeping: [], libraries: [layout.library]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: layout.template.path))
    }
}
