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
    private(set) var records: [String: PrefixBuildRecord] = [:]
    private(set) var tools: [InstalledTool] = []

    private(set) var stale: Set<String> = []

    // True when no installed compatibility tool matches the version of CrossOver that last
    // booted the prefix.
    func isStale(_ prefix: WinePrefix) -> Bool {
        stale.contains(prefix.id)
    }

    private(set) var currentTools: [String: InstalledTool] = [:]

    func lastTool(_ prefix: WinePrefix) -> String? {
        if let tool = currentTools[prefix.id] { return tool.display }
        guard let record = records[prefix.id] else { return nil }
        return record.display ?? SupportedRunners.displayVersion(forID: record.build)
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
        case rebuild([WinePrefix], InstalledTool)
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
    private let installedTools: @Sendable () -> [InstalledTool]
    private let rebuild: @Sendable (WinePrefix, InstalledTool, Bool) throws -> URL?
    private let mappedTool: @Sendable (String) -> String?
    private let makeBackup: @Sendable (WinePrefix) throws -> URL

    init(
        libraries: @escaping @Sendable () -> [SteamLibrary] = { PrefixStore.libraries() },
        installedTools: @escaping @Sendable () -> [InstalledTool] = { CompatToolList.installed() },
        rebuild: @escaping @Sendable (WinePrefix, InstalledTool, Bool) throws -> URL? = {
            try PrefixTools.recreate($0, as: $1, keepBackup: $2)
        },
        makeBackup: @escaping @Sendable (WinePrefix) throws -> URL = {
            try PrefixTools.backUp($0)
        },
        mappedTool: @escaping @Sendable (String) -> String? = { SteamCompatMapping.tool(forApp: $0) }
    ) {
        self.libraries = libraries
        self.installedTools = installedTools
        self.rebuild = rebuild
        self.makeBackup = makeBackup
        self.mappedTool = mappedTool
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
        usage = usage.filter { id, _ in found.contains { $0.id == id } }
        let listTools = installedTools
        (tools, records, stale, currentTools) = await Task.detached {
            let tools = listTools()
            var records: [String: PrefixBuildRecord] = [:]
            var stale = Set<String>()
            var current: [String: InstalledTool] = [:]
            for prefix in found {
                guard let record = PrefixTools.lastBuild(of: prefix) else { continue }
                records[prefix.id] = record
                if let tool = PrefixTools.tool(for: prefix, among: tools) {
                    current[prefix.id] = tool
                } else {
                    stale.insert(prefix.id)
                }
            }
            return (tools, records, stale, current)
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
            return "Opened \(tool.label) in \(prefix.title)."
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

    @discardableResult
    func confirmRebuild(keepBackup: Bool = true) -> Task<Void, Never>? {
        guard case .rebuild(let targets, let tool) = pendingConfirmation else { return nil }
        pendingConfirmation = nil
        return Task { await recreate(targets, as: tool, keepBackup: keepBackup) }
    }

    func recreate(_ targets: [WinePrefix], as tool: InstalledTool, keepBackup: Bool = true) async {
        let make = rebuild
        let mapped = mappedTool
        let installed = installedTools()
        await eachInTurn(targets, { try make($0, tool, keepBackup) }) { rebuilt in
            let kept = rebuilt.compactMap(\.made)
            // Steam launches with the tool it has for the game, and the prefix now
            // belongs to `tool`. Say so when they differ, or the next launch fails.
            let notes = rebuilt.compactMap { step -> String? in
                guard let current = mapped(step.prefix.appID), current != tool.name else { return nil }
                let shown = installed.first { $0.name == current }?.display ?? current
                return "Steam still runs \(step.prefix.title) with \(shown). "
                    + "Choose \(tool.display) in its Properties > Compatibility."
            }
            let after = notes.map { " " + $0 }.joined()
            if rebuilt.count == 1 {
                let title = rebuilt[0].prefix.title
                guard let backup = kept.first else { return "Rebuilt the prefix for \(title)." + after }
                return "Rebuilt the prefix for \(title). The original is at "
                    + "\(backup.path(percentEncoded: false)). Check that your save is present in "
                    + "the game, then delete the backup to save space." + after
            }
            guard rebuilt.count > 1 else { return nil }
            guard !kept.isEmpty else { return "Rebuilt \(rebuilt.count) prefixes." + after }
            return "Rebuilt \(rebuilt.count) prefixes. Each original is kept beside the game's "
                + "prefix. Check that your saves are present in the games, then delete the "
                + "backups to save space." + after
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
            return "Started \(executable.lastPathComponent) in \(prefix.title)."
        }
    }

    private func act(on prefix: WinePrefix, _ body: () throws -> String) {
        forgetOutcome()
        busy = [prefix.id]
        defer { busy = [] }
        do {
            outcome = try body()
        } catch {
            report = FailureReport([error])
        }
    }
}
