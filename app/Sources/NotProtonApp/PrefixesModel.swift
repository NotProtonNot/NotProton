// Prefix logic that drives the prefix view itself.

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PrefixesModel {

    private(set) var prefixes: [WinePrefix] = []
    private(set) var usage: [String: PrefixUsage] = [:]
    private(set) var isLoading = false
    private(set) var arch: [String: PrefixArch] = [:]
    private(set) var expectedArch: PrefixArch = .arm64

    func isForeign(_ prefix: WinePrefix) -> Bool {
        guard let built = arch[prefix.id] else { return false }
        return built != expectedArch
    }

    private(set) var hasLoaded = false
    private(set) var busy = Set<WinePrefix.ID>()

    var isBusy: Bool { !busy.isEmpty }
    var outcome: String?
    private(set) var report: FailureReport?

    var failure: String? { report?.message }

    var selection = Set<WinePrefix.ID>()

    var pendingConfirmation: Confirmation?

    private(set) var backups: [PrefixBackup] = []

    var backupBytes: Int64 { backups.reduce(into: Int64(0)) { $0 += $1.bytes } }

    enum Confirmation: Equatable {
        case delete([WinePrefix])
        case rebuild([WinePrefix])
        case backUp([WinePrefix])
        case deleteBackups([PrefixBackup])
    }

    var selectedPrefix: WinePrefix? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return prefixes.first { $0.id == id }
    }

    var selectedPrefixes: [WinePrefix] {
        prefixes.filter { selection.contains($0.id) }
    }

    private let libraries: @Sendable () -> [SteamLibrary]
    private let runnerArch: @Sendable () -> PrefixArch
    private let rebuild: @Sendable (WinePrefix, Bool) throws -> URL?
    private let makeBackup: @Sendable (WinePrefix) throws -> URL

    init(
        libraries: @escaping @Sendable () -> [SteamLibrary] = { PrefixStore.libraries() },
        runnerArch: @escaping @Sendable () -> PrefixArch = { PrefixTools.prefixArch() },
        rebuild: @escaping @Sendable (WinePrefix, Bool) throws -> URL? = {
            try PrefixTools.recreate($0, keepBackup: $1)
        },
        makeBackup: @escaping @Sendable (WinePrefix) throws -> URL = {
            try PrefixTools.backUp($0)
        }
    ) {
        self.libraries = libraries
        self.runnerArch = runnerArch
        self.rebuild = rebuild
        self.makeBackup = makeBackup
    }

    private var loadGeneration = 0
    func load() async {
        loadGeneration += 1
        let run = loadGeneration
        isLoading = true
        defer { if run == loadGeneration { isLoading = false } }

        let roots = libraries()
        let found = await Task.detached { PrefixStore.all(libraries: roots) }.value
        guard run == loadGeneration else { return }
        prefixes = found
        usage = [:]
        expectedArch = runnerArch()
        arch = await Task.detached {
            found.reduce(into: [String: PrefixArch]()) { built, prefix in
                if let found = PrefixStore.arch(of: prefix) { built[prefix.id] = found }
            }
        }.value
        guard run == loadGeneration else { return }
        selection = selection.filter { id in found.contains { $0.id == id } }

        var kept: [PrefixBackup] = []
        for prefix in found {
            let details = await Task.detached { PrefixStore.backupDetails(of: prefix) }.value
            guard run == loadGeneration else { return }
            kept.append(contentsOf: details)
        }
        kept.sort { ($0.taken ?? .distantPast) > ($1.taken ?? .distantPast) }
        backups = kept

        for prefix in found {
            let measured = await Task.detached { PrefixStore.usage(of: prefix) }.value
            guard run == loadGeneration else { return }
            usage[prefix.id] = measured
        }

        hasLoaded = true
    }

    func open(_ tool: WineTool, for prefix: WinePrefix) {
        act(on: prefix) {
            try PrefixTools.launch(tool, in: prefix)
            return "Launch requested for \(tool.label) in \(prefix.title)."
        }
    }

    func reveal(_ prefix: WinePrefix) {
        PrefixTools.reveal(prefix)
    }

    func delete(_ targets: [WinePrefix]) async {
        await eachInTurn(targets, { try PrefixTools.delete($0) }) { deleted in
            if deleted.count == 1 {
                return "Deleted the prefix for \(deleted[0].prefix.title). Steam will make a new "
                    + "prefix if the game is launched again."
            }
            guard deleted.count > 1 else { return nil }
            return "Deleted \(deleted.count) prefixes. Steam will make a new prefix if a game "
                + "is launched again."
        }
    }

    func backUp(_ targets: [WinePrefix]) async {
        await eachInTurn(targets, makeBackup) { saved in
            guard let first = saved.first else { return nil }
            guard saved.count == 1 else { return "Backed up \(saved.count) prefixes." }
            return "Backed up the prefix for \(first.prefix.title)."
        }
    }

    func recreate(_ targets: [WinePrefix], keepBackup: Bool = true) async {
        let make = rebuild
        await eachInTurn(targets, { try make($0, keepBackup) }) { rebuilt in
            let kept = rebuilt.compactMap(\.made)
            if rebuilt.count == 1 {
                let title = rebuilt[0].prefix.title
                guard let backup = kept.first else { return "Rebuilt the prefix for \(title)." }
                return "Rebuilt the prefix for \(title). The original is at "
                    + "\(backup.path(percentEncoded: false)). Check that your save is present in "
                    + "the game, then delete the backup to save space."
            }
            guard rebuilt.count > 1 else { return nil }
            guard !kept.isEmpty else { return "Rebuilt \(rebuilt.count) prefixes." }
            return "Rebuilt \(rebuilt.count) prefixes. Each original is kept beside the game's "
                + "prefix. Check that your saves are present in the games, then delete the "
                + "backups to save space."
        }
    }

    func reveal(_ backup: PrefixBackup) {
        PrefixTools.reveal(at: backup.url)
    }

    func forgetOutcome() {
        report = nil
        outcome = nil
    }

    func deleteBackups(_ targets: [PrefixBackup]) async {
        guard !targets.isEmpty else { return }
        forgetOutcome()
        isLoading = true

        var cleared: [PrefixBackup] = []
        var refused: [Error] = []
        for backup in targets {
            do {
                try await Task.detached { try PrefixTools.deleteBackup(backup.url) }.value
                cleared.append(backup)
            } catch {
                refused.append(error)
            }
        }

        outcome = clearedSentence(cleared)
        report = FailureReport(refused)
        let gone = Set(cleared.map(\.id))
        backups.removeAll { gone.contains($0.id) }
        isLoading = false
        await load()
    }

    private func clearedSentence(_ cleared: [PrefixBackup]) -> String? {
        guard !cleared.isEmpty else { return nil }
        let games = Set(cleared.map(\.prefix.id)).count
        if cleared.count == 1 {
            return "Deleted the backup for \(cleared[0].title)."
        }
        if games == 1 {
            return "Deleted \(cleared.count) backups for \(cleared[0].title)."
        }
        return "Deleted \(cleared.count) backups across \(games) prefixes."
    }

    private typealias Step<Made> = (prefix: WinePrefix, made: Made)

    @discardableResult
    private func eachInTurn<Made: Sendable>(
        _ targets: [WinePrefix],
        _ work: @escaping @Sendable (WinePrefix) throws -> Made,
        saying sentence: ([Step<Made>]) -> String?
    ) async -> [Step<Made>] {
        guard !targets.isEmpty else { return [] }
        forgetOutcome()
        isLoading = true
        busy = Set(targets.map(\.id))

        var done: [Step<Made>] = []
        var refused: [Error] = []
        for prefix in targets {
            do {
                let made = try await Task.detached { try work(prefix) }.value
                done.append((prefix: prefix, made: made))
            } catch {
                refused.append(error)
            }
            busy.remove(prefix.id)
        }

        outcome = sentence(done)
        report = FailureReport(refused)

        busy = []
        isLoading = false
        await load()
        return done
    }

    func chooseExecutable(for prefix: WinePrefix) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = PrefixTools.runnableTypes
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = "Run"
        panel.message = "Choose a Windows program to run in \(prefix.title)."
        panel.directoryURL = PrefixStore.installDirectory(of: prefix)
            ?? prefix.pfx.appending(path: "drive_c")

        guard panel.runModal() == .OK, let picked = panel.url else { return }
        run(picked, in: prefix)
    }

    func run(_ executable: URL, in prefix: WinePrefix) {
        act(on: prefix) {
            try PrefixTools.run(executable, in: prefix)
            return "Launch requested for \(executable.lastPathComponent) in \(prefix.title)."
        }
    }

    private func act(on prefix: WinePrefix, _ body: @escaping @Sendable () throws -> String) {
        guard busy.isEmpty else { return }
        forgetOutcome()
        busy = [prefix.id]
        Task {
            defer { busy = [] }
            do {
                outcome = try await Task.detached(operation: body).value
            } catch {
                report = FailureReport([error])
            }
        }
    }
}
