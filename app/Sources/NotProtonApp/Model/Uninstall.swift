// Self-explanatory I think

import Foundation

enum UninstallPhase: Sendable {
    case stoppingClient
    case detaching
    case restoring(RepairPhase)
    case removing
    case finished

    var label: String {
        switch self {
        case .stoppingClient: String(localized: "Stopping Steam")
        case .detaching: String(localized: "Detaching from Steam")
        case .restoring(let phase): phase.label
        case .removing: String(localized: "Removing files")
        case .finished: String(localized: "Done")
        }
    }
}

struct UninstallOutcome: Sendable {
    let stoppedClient: Bool
    let detached: Bool
    let steamInstalled: Bool
    let restoredValveSignature: Bool
    let removed: [String]
    var unreachableSteam: URL? = nil

    var steamNeedsRedownload: Bool { steamInstalled && !restoredValveSignature }

    var partialRemoval: String? {
        unreachableSteam.map {
            String(localized: "NotProton has been partially removed, because Steam at \($0.path(percentEncoded: false)) cannot be found. Delete that copy of Steam and reinstall it to fully remove NotProton.")
        }
    }
}

enum Uninstall {
    static let step = String(localized: "Remove NotProton")

    // Not the chosen Steam, which can be changed away from a copy on an unplugged drive.
    static func installedSteam(record: URL = DeploymentContent.record(beside: SupportPaths.deployedVersion)) -> URL? {
        guard let build = try? DeploymentContent.readBuild(at: record) else { return nil }
        return URL(filePath: build.steamApp ?? SupportPaths.Steam.defaultApp.path(percentEncoded: false))
    }

    static func unreachableSteam(installed: URL? = installedSteam()) -> URL? {
        installed.flatMap { SupportPaths.Steam.isUnreachable($0) ? $0 : nil }
    }

    typealias Repair = @Sendable (@escaping @Sendable (RepairPhase) -> Void) async throws -> Void

    typealias Stop = @Sendable (@Sendable () -> Void) throws -> Bool

    static func run(
        app: URL = SupportPaths.Steam.app,
        innerPlist: URL = SupportPaths.Steam.innerInfoPlist,
        updateBlocks: [URL] = UpdateBlock.paths,
        legacyCompat: URL = SupportPaths.Steam.legacyCompat,
        compatTools: [URL] = SupportPaths.Steam.notprotonTools(),
        directories: [URL] = [
            SupportPaths.support,
            SupportPaths.packageDownloads.deletingLastPathComponent(),
        ],
        libraries: [SteamLibrary] = PrefixStore.libraries(),
        installedSteam: URL? = installedSteam(),
        report: @escaping @Sendable (UninstallPhase) -> Void = { _ in },
        repair: Repair = { report in _ = try await SteamRepair.run(report: report) },
        stop: Stop = { onStopping in try SteamBundle.stopClient(step: step, onStopping: onStopping) }
    ) async throws -> UninstallOutcome {
        let stopped = try stop { report(.stoppingClient) }

        report(.detaching)
        let detached = try detach(from: app, innerPlist: innerPlist, updateBlocks: updateBlocks)

        // Validate if Steam is present before restoring
        let steamInstalled = FileManager.default.fileExists(atPath: app.path(percentEncoded: false))
        var restored = false
        if steamInstalled {
            do {
                try await repair { report(.restoring($0)) }
                restored = true
            } catch {}
        }

        report(.removing)
        var removed = try remove(
            legacyCompat: legacyCompat, compatTools: compatTools, directories: directories
        )
        removed += try removeSteamDLLLinks(to: legacyCompat, in: libraries)
        let templateFailures = RunnerInstaller.removePrefixTemplates(
            keeping: [], libraries: libraries, removingFolder: true)
        if !templateFailures.isEmpty {
            throw StepFailure(step: step, detail: templateFailures.map(\.detail).joined(separator: "\n"))
        }

        report(.finished)
        return UninstallOutcome(
            stoppedClient: stopped,
            detached: detached,
            steamInstalled: steamInstalled,
            restoredValveSignature: restored,
            removed: removed,
            unreachableSteam: unreachableSteam(installed: installedSteam)
        )
    }

    static func detach(from app: URL, innerPlist: URL, updateBlocks: [URL]) throws -> Bool {
        let files = FileManager.default
        let plist = app.appending(path: "Contents/Info.plist")
        let dylib = app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)")
        let executable = app.appending(path: "Contents/MacOS/steam_osx")

        _ = try SteamRepair.clearInsert(at: innerPlist)
        _ = try UpdateBlock.remove(from: updateBlocks)

        let cleared = try SteamRepair.clearInsert(at: plist)
        var droppedDylib = false
        do {
            if files.fileExists(atPath: dylib.path(percentEncoded: false)) {
                try files.removeItem(at: dylib)
                droppedDylib = true
            }

            guard cleared || droppedDylib else { return false }

            try SteamInstaller.adHocSign(executable, step: step)
            try SteamInstaller.adHocSign(app, step: step)
        } catch {
            if cleared || droppedDylib {
                try? SteamInstaller.adHocSign(executable, step: step)
                try? SteamInstaller.adHocSign(app, step: step)
            }
            throw error
        }
        return true
    }

    static func remove(legacyCompat: URL, compatTools: [URL], directories: [URL]) throws -> [String] {
        let files = FileManager.default
        var removed: [String] = []

        for target in [legacyCompat] + compatTools + directories {
            let path = target.path(percentEncoded: false)
            guard files.fileExists(atPath: path) else { continue }
            try WriteRefused.catching(path) { try files.removeItem(at: target) }
            removed.append(target.lastPathComponent)
        }
        return removed
    }

    // Links the run script made point at legacycompat. Anything else at that name is left alone.
    static func removeSteamDLLLinks(to legacyCompat: URL, in libraries: [SteamLibrary]) throws -> [String] {
        let files = FileManager.default
        let target = legacyCompat.appending(path: "Steam.dll").path(percentEncoded: false)
        var removed: [String] = []
        for library in libraries {
            let link = library.steamapps.appending(path: "common/Steam.dll")
            let path = link.path(percentEncoded: false)
            guard (try? files.destinationOfSymbolicLink(atPath: path)) == target else { continue }
            try WriteRefused.catching(path) { try files.removeItem(at: link) }
            removed.append(link.lastPathComponent)
        }
        return removed
    }
}
