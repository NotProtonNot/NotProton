// Logic for the Repair button

import Foundation

enum RepairPhase: Sendable {
    case downloading(PinnedDownload.Progress)
    case unpacking
    case checking
    case stoppingClient
    case replacing
    case clearingInsert
    case removingUpdateBlock
    case registering
    case finished

    var label: String {
        switch self {
        case .downloading(let progress): progress.label
        case .unpacking: L10n.tr("Unpacking")
        case .checking: L10n.tr("Verifying")
        case .stoppingClient: L10n.tr("Stopping Steam")
        case .replacing: L10n.tr("Restoring Steam")
        case .clearingInsert: L10n.tr("Cleaning up")
        case .removingUpdateBlock: L10n.tr("Cleaning up")
        case .registering: L10n.tr("Finishing up")
        case .finished: L10n.tr("Done")
        }
    }
}

struct RepairOutcome: Sendable {
    let stoppedClient: Bool
    let bundleVersion: String?
    let clearedInnerInsert: Bool
    let removedUpdateBlocks: [String]
    let removedStaleBackup: Bool
}

enum SteamRepair {

    static let valveTeam = "MXGJJ98X76"
    static let valveIdentifier = "com.valvesoftware.steam"

    private static let step = L10n.tr("Repair Steam")

    static func run(
        manifest suppliedManifest: ValvePackageManifest? = nil,
        app: URL = SupportPaths.Steam.app,
        innerPlist: URL = SupportPaths.Steam.innerInfoPlist,
        updateBlocks: [URL] = UpdateBlock.paths,
        backups: URL = SupportPaths.backups,
        downloads: URL = SupportPaths.packageDownloads,
        report: @Sendable (RepairPhase) -> Void = { _ in }
    ) async throws -> RepairOutcome {
        let manifest = try suppliedManifest ?? ValvePackageManifest.bundled()
        guard let bundle = manifest.bundle else {
            throw StepFailure(
                step: step,
                detail: L10n.tr("This copy of NotProton cannot repair Steam. Please reinstall NotProton.")
            )
        }

        let staged = try await stage(bundle, bases: manifest.bases, downloads: downloads, report: report)

        report(.checking)
        try verifyValveSignature(staged)

        let stopped = try SteamBundle.stopClient(app: app, step: step) { report(.stoppingClient) }

        report(.replacing)
        try replace(app, with: staged)

        report(.clearingInsert)
        let clearedInner = try clearInsert(at: innerPlist)

        report(.removingUpdateBlock)
        let removed = try UpdateBlock.remove(from: updateBlocks)

        report(.registering)
        SteamBundle.register(app)

        try verifyValveSignature(app)
        let plist = app.appending(path: "Contents/Info.plist")
        if let insert = SteamBundle.currentInsert(at: plist), !insert.isEmpty {
            AppLog.note("repair: restored bundle still declares \(insert)")
            throw StepFailure(
                step: step,
                detail: L10n.tr("Steam could not be fully restored. Please run Repair Steam again.")
            )
        }

        let removedBackup = try removeStaleBackup(from: backups)

        report(.finished)
        return RepairOutcome(
            stoppedClient: stopped,
            bundleVersion: version(of: app),
            clearedInnerInsert: clearedInner,
            removedUpdateBlocks: removed,
            removedStaleBackup: removedBackup
        )
    }

    static func stage(
        _ bundle: ValveBundle,
        bases: [URL],
        downloads: URL,
        work suppliedWork: URL? = nil,
        report: @Sendable (RepairPhase) -> Void = { _ in }
    ) async throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: downloads, withIntermediateDirectories: true)

        let archive = try await PinnedDownload.obtain(
            file: bundle.file, sha256: bundle.sha256, bases: bases, into: downloads, step: step
        ) { report(.downloading($0)) }

        report(.unpacking)

        let work = suppliedWork ?? downloads.appending(path: "bundle")
        try? files.removeItem(at: work)
        try files.createDirectory(at: work, withIntermediateDirectories: true)

        try Shell.check("/usr/bin/unzip", [
            "-q", "-o", archive.path(percentEncoded: false), bundle.innerArchive,
            "-d", work.path(percentEncoded: false),
        ])
        try Shell.check("/usr/bin/tar", [
            "-xzf", work.appending(path: bundle.innerArchive).path(percentEncoded: false),
            "-C", work.path(percentEncoded: false),
        ])

        let staged = work.appending(path: bundle.bundleName)
        guard files.fileExists(atPath: staged.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: L10n.tr("\(bundle.innerArchive) did not contain \(bundle.bundleName).")
            )
        }
        return staged
    }

    static func verifyValveSignature(_ url: URL) throws {
        let path = url.path(percentEncoded: false)

        let strict = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", path])
        guard strict.succeeded else {
            throw StepFailure(
                step: step,
                detail: L10n.tr("\(path) does not verify against its own signature. ")
                    + strict.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let described = try Shell.run("/usr/bin/codesign", ["-dvv", path])
        let text = described.stdout + described.stderr

        let fields = Set(
            text.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )

        guard fields.contains("TeamIdentifier=\(valveTeam)") else {
            throw StepFailure(
                step: step,
                detail: L10n.tr("\(path) is not signed by Valve. Expected TeamIdentifier=\(valveTeam).")
            )
        }
        guard fields.contains("Identifier=\(valveIdentifier)") else {
            throw StepFailure(
                step: step,
                detail: L10n.tr("\(path) is not the Steam bundle. Expected Identifier=\(valveIdentifier).")
            )
        }
    }

    static func replace(_ app: URL, with staged: URL) throws {
        let files = FileManager.default
        try WriteRefused.catching(app) {
            guard files.fileExists(atPath: app.path(percentEncoded: false)) else {
                try files.moveItem(at: staged, to: app)
                return
            }
            _ = try files.replaceItemAt(app, withItemAt: staged)
        }
    }

    static func clearInsert(at plist: URL) throws -> Bool {
        guard var dict = SteamBundle.readInfoPlist(at: plist),
              var environment = dict[SteamBundle.environmentKey] as? [String: Any]
        else { return false }

        let removed = [SteamBundle.insertKey, SteamBundle.controllerBlockKey]
            .compactMap { environment.removeValue(forKey: $0) }
        guard !removed.isEmpty else { return false }
        dict[SteamBundle.environmentKey] = environment
        try SteamBundle.writeInfoPlist(dict, at: plist)
        return true
    }

    static func removeStaleBackup(from backups: URL) throws -> Bool {
        let backup = backups.appending(path: SteamBundle.plistBackupName)
        let path = backup.path(percentEncoded: false)
        let files = FileManager.default
        guard files.fileExists(atPath: path) else { return false }

        try WriteRefused.catching(path) { try files.removeItem(at: backup) }
        return true
    }

    static func version(of app: URL) -> String? {
        guard let dict = SteamBundle.readInfoPlist(at: app.appending(path: "Contents/Info.plist"))
        else { return nil }
        return dict["CFBundleVersion"] as? String
    }
}
