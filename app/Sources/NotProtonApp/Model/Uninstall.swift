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
        case .stoppingClient: L10n.tr("Stopping Steam")
        case .detaching: L10n.tr("Detaching from Steam")
        case .restoring(let phase): phase.label
        case .removing: L10n.tr("Removing files")
        case .finished: L10n.tr("Done")
        }
    }
}

struct UninstallOutcome: Sendable {
    let stoppedClient: Bool
    let detached: Bool
    let restoredValveSignature: Bool
    let removed: [String]
}

enum Uninstall {
    static let step = L10n.tr("Remove NotProton")

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
        report: @escaping @Sendable (UninstallPhase) -> Void = { _ in },
        repair: Repair = { report in _ = try await SteamRepair.run(report: report) },
        stop: Stop = { onStopping in try SteamBundle.stopClient(step: step, onStopping: onStopping) }
    ) async throws -> UninstallOutcome {
        let stopped = try stop { report(.stoppingClient) }

        report(.detaching)
        let detached = try detach(from: app, innerPlist: innerPlist, updateBlocks: updateBlocks)

        let restored: Bool
        do {
            try await repair { report(.restoring($0)) }
            restored = true
        } catch {
            restored = false
        }

        report(.removing)
        let removed = try remove(
            legacyCompat: legacyCompat, compatTools: compatTools, directories: directories
        )
        let templateFailures = RunnerInstaller.removePrefixTemplates(keeping: [], libraries: libraries)
        if !templateFailures.isEmpty {
            throw StepFailure(step: step, detail: templateFailures.map(\.detail).joined(separator: "\n"))
        }

        report(.finished)
        return UninstallOutcome(
            stoppedClient: stopped,
            detached: detached,
            restoredValveSignature: restored,
            removed: removed
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
}
