// Shortcuts to launch the Wine tools (winecfg/regedit/task manager) against
// a selected prefix, opens prefix directory in finder, etc.

import AppKit
import Foundation
import UniformTypeIdentifiers

enum WineTool: String, CaseIterable, Sendable {
    case winecfg
    case regedit
    case taskmgr

    var label: String {
        switch self {
        case .winecfg: "Wine Configuration"
        case .regedit: "Registry Editor"
        case .taskmgr: "Task Manager"
        }
    }
}

enum PrefixTools {

    static func syncBackend(prefix: WinePrefix) -> String {
        let marker = prefix.root.appending(path: "notproton-msync")
        let recorded = try? String(contentsOf: marker, encoding: .utf8)
        return recorded?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "1" : "0"
    }

    static func environment(prefix: WinePrefix, runner: URL = SupportPaths.currentRunner) -> [String: String] {
        let root = runner.path(percentEncoded: false)
        var environment = ProcessInfo.processInfo.environment
        environment["CX_ROOT"] = root
        environment["CX_HOME"] = SupportPaths.applicationSupport
            .appending(path: "CrossOver").path(percentEncoded: false)
        let wine = layout(runner: runner)
        if RunnerRuntime.usesBundledRosetta(in: runner) { environment["WINEARCH"] = "win64" }
        environment["WINELOADER"] = wine.loader.path(percentEncoded: false)
        environment["WINESERVER"] = wine.server.path(percentEncoded: false)
        environment["WINEDLLPATH"] = "\(root)/lib/wine/x86_64-windows:"
            + wine.unixDir.path(percentEncoded: false)
        environment["WINEPREFIX"] = prefix.pfx.path(percentEncoded: false)
        environment["WINEMSYNC"] = syncBackend(prefix: prefix)
        environment["PATH"] = "\(root)/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }

    static func loader(runner: URL = SupportPaths.currentRunner) -> URL {
        layout(runner: runner).loader
    }

    struct WineLayout {
        let loader: URL
        let server: URL
        let unixDir: URL
    }

    static func layout(runner: URL = SupportPaths.currentRunner) -> WineLayout {
        let fm = FileManager.default
        let bin = runner.appending(path: "bin")
        func executable(_ url: URL) -> Bool {
            fm.isExecutableFile(atPath: url.path(percentEncoded: false))
        }

        let arm = runner.appending(path: "lib/wine/aarch64-unix")
        let armLoader = arm.appending(path: "wine.app/Contents/MacOS/wine")
        let armServer = bin.appending(path: "wineserver-arm64")
        if !RunnerRuntime.usesBundledRosetta(in: runner), executable(armLoader), executable(armServer) {
            return WineLayout(loader: armLoader, server: armServer, unixDir: arm)
        }

        let unix = runner.appending(path: "lib/wine/x86_64-unix")
        let server = bin.appending(path: "wineserver")
        return WineLayout(
            loader: unix.appending(path: "wine"),
            server: executable(server) ? server : bin.appending(path: "wineserver-x86"),
            unixDir: unix
        )
    }

    private static func readyLoader(step: String, prefix: WinePrefix, runner: URL) throws -> URL {
        let loader = loader(runner: runner)
        guard FileManager.default.isExecutableFile(atPath: loader.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: "No compatibility tool at \(loader.path(percentEncoded: false)). "
                    + "Use Set Up Compatibility Tool first."
            )
        }
        guard FileManager.default.fileExists(atPath: prefix.pfx.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: "\(prefix.title) has no prefix at \(prefix.pfx.path(percentEncoded: false))."
            )
        }
        try RunnerRuntime.requireSupported(
            usesFEX: layout(runner: runner).unixDir.lastPathComponent == "aarch64-unix")
        return loader
    }

    static func launch(_ tool: WineTool, in prefix: WinePrefix, runner: URL = SupportPaths.currentRunner) throws {
        let loader = try readyLoader(step: "Open \(tool.label)", prefix: prefix, runner: runner)
        try Shell.detach(
            loader.path(percentEncoded: false),
            [tool.rawValue],
            environment: environment(prefix: prefix, runner: runner),
            log: prefix.root.appending(path: "notproton-tools.log")
        )
    }

    static func run(
        _ executable: URL,
        in prefix: WinePrefix,
        runner: URL = SupportPaths.currentRunner
    ) throws {
        let step = "Run \(executable.lastPathComponent)"
        let loader = try readyLoader(step: step, prefix: prefix, runner: runner)
        guard FileManager.default.fileExists(atPath: executable.path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: "No file at \(executable.path(percentEncoded: false)).")
        }
        guard let arguments = arguments(for: executable) else {
            throw StepFailure(
                step: step,
                detail: "\(executable.lastPathComponent) is not a Windows program. "
                    + "Pick an exe, msi, bat or cmd file."
            )
        }

        try Shell.detach(
            loader.path(percentEncoded: false),
            arguments,
            environment: environment(prefix: prefix, runner: runner),
            currentDirectory: executable.deletingLastPathComponent(),
            log: prefix.root.appending(path: "notproton-tools.log")
        )
    }

    static func arguments(for executable: URL) -> [String]? {
        let path = executable.path(percentEncoded: false)
        switch executable.pathExtension.lowercased() {
        case "exe", "bat", "cmd": return [path]
        case "msi": return ["msiexec", "/i", path]
        default: return nil
        }
    }

    static var runnableTypes: [UTType] {
        ["exe", "msi", "bat", "cmd"].compactMap { UTType(filenameExtension: $0) }
    }

    static func reveal(_ prefix: WinePrefix) {
        NSWorkspace.shared.selectFile(
            prefix.pfx.path(percentEncoded: false),
            inFileViewerRootedAtPath: prefix.root.path(percentEncoded: false)
        )
    }

    static func reveal(at url: URL) {
        NSWorkspace.shared.selectFile(
            url.path(percentEncoded: false),
            inFileViewerRootedAtPath: url.deletingLastPathComponent().path(percentEncoded: false)
        )
    }

    static func deleteBackup(_ backup: URL) throws {
        try WriteRefused.catching(backup.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: backup)
        }
    }

    static func delete(_ prefix: WinePrefix) throws {
        guard !PrefixStore.isInUse(prefix) else {
            throw StepFailure(
                step: "Delete prefix",
                detail: "\(prefix.title) is running. Quit the game first."
            )
        }
        try WriteRefused.catching(prefix.root) {
            try FileManager.default.removeItem(at: prefix.root)
        }
    }

    static func prefixArch(runner: URL = SupportPaths.currentRunner) -> PrefixArch {
        layout(runner: runner).unixDir.lastPathComponent == "aarch64-unix" ? .arm64 : .x86_64
    }
}
