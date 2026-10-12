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
    var unreachableSteam: [URL] = []

    var steamNeedsRedownload: Bool { steamInstalled && !restoredValveSignature }

    var partialRemoval: String? {
        guard !unreachableSteam.isEmpty else { return nil }
        return unreachableSteam.map {
            String(localized: "NotProton has been partially removed, because Steam at \($0.path(percentEncoded: false)) cannot be found. Delete that copy of Steam and reinstall it to fully remove NotProton.")
        }.joined(separator: "\n\n")
    }
}

enum Uninstall {
    static let step = String(localized: "Remove NotProton")

    static func confirmation(modifications: SteamModifications = .shared) -> String {
        let missing = ((try? modifications.paths()) ?? []).filter { SupportPaths.Steam.isUnreachable($0) }
        guard !missing.isEmpty else {
            return String(localized: "Steam is restored to its unmodified state and NotProton is removed, including the compatibility tool that lives inside the Steam folder. Windows games and Steam Play prefixes are not removed.")
        }
        return missing.map {
            String(localized: "Steam at \($0.path(percentEncoded: false)) isn't connected, so NotProton can't be removed from it. All other NotProton data is removed, except for Windows Games and prefixes.")
        }.joined(separator: "\n\n")
    }

    typealias Repair = @Sendable (URL, @escaping @Sendable (RepairPhase) -> Void) async throws -> Void

    typealias Stop = @Sendable (URL, @Sendable () -> Void) throws -> Bool

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
        modifications: SteamModifications = .shared,
        lockFolder: URL = SupportPaths.applicationSupport,
        report: @escaping @Sendable (UninstallPhase) -> Void = { _ in },
        repair: Repair? = nil,
        stop: Stop = { app, onStopping in try SteamBundle.stopClient(app: app, step: step, onStopping: onStopping) }
    ) async throws -> UninstallOutcome {
        let lock = try DeploymentContent.acquireInstallationLock(in: lockFolder, steamFolder: nil)
        defer { lock.release() }
        try modifications.prepare()
        let tracked = try modifications.paths()
        let targets = Set((tracked + [app]).map { $0.standardizedFileURL.path }).sorted()
            .map { URL(filePath: $0, directoryHint: .notDirectory) }
        var stopped = false
        var checkedClient = false
        var detached = false
        var steamInstalled = false
        var restored = true
        var missing: [URL] = []
        var failures: [any Error] = []

        for target in targets {
            do {
                let bundleLock = try DeploymentContent.acquireSteamLock(for: target, holding: lock)
                defer { bundleLock.release() }
                switch try SteamModifications.inspect(target) {
                case .unreachable:
                    if tracked.contains(target) { missing.append(target) }
                    continue
                case .absent, .clean:
                    if tracked.contains(target), try !modifications.retireIfClean(target) {
                        throw StepFailure(step: step, detail: String(localized: "Steam could not be fully restored. Please run Repair Steam again."))
                    }
                    continue
                case .modified: break
                }
                try modifications.mark(target)
                stopped = try stop(target) { report(.stoppingClient) } || stopped
                checkedClient = true
                report(.detaching)
                detached = try detach(from: target, innerPlist: innerPlist, updateBlocks: updateBlocks) || detached
                steamInstalled = true
                do {
                    if let repair {
                        try await repair(target) { report(.restoring($0)) }
                    } else {
                        _ = try await SteamRepair.run(app: target, innerPlist: innerPlist,
                                                     updateBlocks: updateBlocks, modifications: modifications,
                                                     report: { report(.restoring($0)) })
                    }
                } catch { restored = false }
                guard try modifications.retireIfClean(target) else {
                    throw StepFailure(step: step, detail: String(localized: "Steam could not be fully restored. Please run Repair Steam again."))
                }
            } catch {
                if let refusal = error as? WriteRefused {
                    failures.append(refusal)
                } else {
                    failures.append(StepFailure(step: step,
                                                detail: "\(target.path(percentEncoded: false)): \(error.localizedDescription)"))
                }
            }
        }

        if failures.count == 1 { throw failures[0] }
        if !failures.isEmpty {
            throw StepFailure(step: step, detail: failures.map(\.localizedDescription).joined(separator: "\n"))
        }
        if !checkedClient {
            let bundleLock = try DeploymentContent.acquireSteamLock(for: app, holding: lock)
            defer { bundleLock.release() }
            stopped = try stop(app) { report(.stoppingClient) }
        }
        _ = try SteamRepair.clearInsert(at: innerPlist)
        _ = try UpdateBlock.remove(from: updateBlocks)
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
            unreachableSteam: missing
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
