// Prefix rebuild feature, experimental, blah blah.

import Foundation

extension PrefixTools {
    @discardableResult
    static func recreate(
        _ prefix: WinePrefix,
        as tool: InstalledTool,
        runners: URL = SupportPaths.runners,
        now: Date = .now,
        keepBackup: Bool = true
    ) throws -> URL? {
        let kept = try recreate(
            prefix, runner: SupportPaths.clonedRoot(forBuild: tool.build, runners: runners),
            flavor: tool.tool.flavor, now: now, keepBackup: keepBackup
        )
        try writeBuildRecord(tool, for: prefix)
        return kept
    }

    @discardableResult
    static func recreate(
        _ prefix: WinePrefix,
        runner: URL,
        flavor: CompatTool.Flavor = .fex,
        now: Date = .now,
        keepBackup: Bool = true
    ) throws -> URL? {
        guard !PrefixStore.isInUse(prefix) else {
            throw StepFailure(
                step: L10n.tr("Recreate prefix"),
                detail: L10n.tr("\(prefix.title) is running. Quit the game first.")
            )
        }

        if let held = PrefixStore.backups(of: prefix).last,
            !FileManager.default.fileExists(
                atPath: prefix.pfx.appending(path: "user.reg").path(percentEncoded: false))
        {
            throw StepFailure(
                step: L10n.tr("Recreate prefix"),
                detail: L10n.tr("\(held.path(percentEncoded: false)) is left from a rebuild that did not finish and may hold the only copy of the saves. Move it somewhere safe, then try again.")
            )
        }

        let loader = loader(runner: runner, flavor: flavor)
        guard FileManager.default.isExecutableFile(atPath: loader.path(percentEncoded: false)) else {
            throw StepFailure(
                step: L10n.tr("Recreate prefix"),
                detail: L10n.tr("No compatibility tool at \(loader.path(percentEncoded: false)). Use Set Up Compatibility Tool first.")
            )
        }

        let fm = FileManager.default
        let fresh = prefix.root.appending(path: "pfx.rebuild")
        if fm.fileExists(atPath: fresh.path(percentEncoded: false)) {
            try fm.removeItem(at: fresh)
        }
        defer { try? fm.removeItem(at: fresh) }
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)

        var environment = environment(prefix: prefix, runner: runner, flavor: flavor)
        environment["WINEPREFIX"] = fresh.path(percentEncoded: false)
        layOutProfile(in: fresh)
        _ = try Shell.check(loader.path(percentEncoded: false), ["wineboot", "--init"], environment: environment)

        let carry = Carry(from: prefix.pfx, to: fresh)
        carry.userData()
        carry.strayFolders()

        if let first = carry.lost.first {
            AppLog.note("rebuild \(prefix.appID) refused, did not carry: \(carry.lost.joined(separator: ", "))")
            throw StepFailure(
                step: L10n.tr("Recreate prefix"),
                detail: L10n.tr("\(first) could not be copied out of the prefix. The prefix has been left as it was and nothing has been lost. Check free space and permissions, then try again.")
            )
        }

        let parked = fm.fileExists(atPath: prefix.pfx.path(percentEncoded: false))
        let previous = backupSlot(in: prefix.root, at: now)
        if parked {
            try fm.moveItem(at: prefix.pfx, to: previous)
        }
        do {
            try fm.moveItem(at: fresh, to: prefix.pfx)
        } catch {
            if parked { try? fm.moveItem(at: previous, to: prefix.pfx) }
            throw error
        }
        guard parked else { return nil }
        guard keepBackup else {
            try? fm.removeItem(at: previous)
            return nil
        }
        return previous
    }

    @discardableResult
    static func backUp(_ prefix: WinePrefix, now: Date = .now) throws -> URL {
        guard !PrefixStore.isInUse(prefix) else {
            throw StepFailure(
                step: L10n.tr("Back up prefix"),
                detail: L10n.tr("\(prefix.title) is running. Quit the game first.")
            )
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: prefix.pfx.path(percentEncoded: false)) else {
            throw StepFailure(
                step: L10n.tr("Back up prefix"),
                detail: L10n.tr("\(prefix.title) does not appear to have a prefix to back up.")
            )
        }

        let slot = backupSlot(in: prefix.root, at: now)
        do {
            try fm.copyItem(at: prefix.pfx, to: slot)
        } catch {
            try? fm.removeItem(at: slot)
            throw error
        }
        return slot
    }

    private static func backupSlot(in root: URL, at now: Date) -> URL {
        let stamp = PrefixStore.backupClock().string(from: now)

        let fm = FileManager.default
        var slot = root.appending(path: "\(PrefixStore.backupPrefix)-\(stamp)")
        var next = 2
        while fm.fileExists(atPath: slot.path(percentEncoded: false)) {
            slot = root.appending(path: "\(PrefixStore.backupPrefix)-\(stamp)-\(next)")
            next += 1
        }
        return slot
    }

    private static func layOutProfile(in fresh: URL) {
        let fm = FileManager.default
        let users = fresh.appending(path: "drive_c/users")
        let profile = users.appending(path: "steamuser")
        try? fm.createDirectory(at: profile, withIntermediateDirectories: true)

        for folder in [
            "Documents", "Desktop", "Downloads", "Music", "Pictures", "Videos", "Templates",
            "AppData/Local", "AppData/Roaming",
        ] {
            try? fm.createDirectory(
                at: profile.appending(path: folder), withIntermediateDirectories: true)
        }

        for (legacy, target) in [
            ("Local Settings/Application Data", "../AppData/Local"),
            ("Application Data", "./AppData/Roaming"),
            ("My Documents", "./Documents"),
        ] {
            let link = profile.appending(path: legacy)
            try? fm.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(
                atPath: link.path(percentEncoded: false), withDestinationPath: target)
        }
        try? fm.createSymbolicLink(
            atPath: users.appending(path: "crossover").path(percentEncoded: false),
            withDestinationPath: "steamuser")
    }
}

private final class Carry {
    private let old: URL
    private let fresh: URL
    private let fm = FileManager.default

    private(set) var lost: [String] = []

    private var carried: Set<String> = []

    private var pendingLinks: [(from: URL, to: URL)] = []

    init(from old: URL, to fresh: URL) {
        self.old = old
        self.fresh = fresh
    }

    func userData() {
        let source = old.appending(path: "drive_c/users")
        let destination = fresh.appending(path: "drive_c/users")

        let profiles = realEntries(in: source).filter(directoryExists)
        for profile in profiles {
            merge(profile, into: landing(forProfile: profile, under: destination))
        }
        for link in pendingLinks { carryLinks(from: link.from, to: link.to) }
        carryLinks(from: source, to: destination)

        let registry = old.appending(path: "user.reg")
        guard fm.fileExists(atPath: registry.path(percentEncoded: false)) else { return }
        let landing = fresh.appending(path: "user.reg")
        try? fm.removeItem(at: landing)
        attempt(registry) { try fm.copyItem(at: registry, to: landing) }
    }

    func strayFolders() {
        let source = old.appending(path: "drive_c")
        let destination = fresh.appending(path: "drive_c")
        guard directoryExists(source) else { return }
        let template = Set(
            (try? fm.contentsOfDirectory(atPath: destination.path(percentEncoded: false))) ?? [])
        var names: [String] = []
        attempt(source) {
            names = try fm.contentsOfDirectory(atPath: source.path(percentEncoded: false))
        }
        for name in names where !template.contains(name) {
            let stray = source.appending(path: name)
            attempt(stray) {
                try fm.copyItem(at: stray, to: destination.appending(path: name))
            }
        }
    }

    private func attempt(_ source: URL, _ work: () throws -> Void) {
        do { try work() } catch { lost.append(source.path(percentEncoded: false)) }
    }

    private func landing(forProfile profile: URL, under users: URL) -> URL {
        let name = profile.lastPathComponent
        let shared = name == "crossover" || name == "steamuser"
        return users.appending(path: shared ? "steamuser" : name)
    }

    private func merge(_ source: URL, into landing: URL) {
        if isBrokenLink(landing) { try? fm.removeItem(at: landing) }
        guard !escapes(landing) else {
            park(source, beside: landing)
            return
        }
        var landingIsDirectory: ObjCBool = false
        let occupied = fm.fileExists(
            atPath: landing.path(percentEncoded: false), isDirectory: &landingIsDirectory)

        guard directoryExists(source) else {
            if occupied {
                guard !landingIsDirectory.boolValue else {
                    park(source, beside: landing)
                    return
                }
                guard carried.insert(identity(of: landing)).inserted else {
                    park(source, beside: landing)
                    return
                }
                try? fm.removeItem(at: landing)
            } else {
                carried.insert(identity(of: landing))
            }
            attempt(source) { try fm.copyItem(at: source, to: landing) }
            return
        }
        if !occupied {
            attempt(source) {
                try fm.createDirectory(at: landing, withIntermediateDirectories: true)
            }
            carried.insert(identity(of: landing))
        } else if !landingIsDirectory.boolValue {
            park(source, beside: landing)
            return
        } else if carried.contains(identity(of: landing)) {
            park(source, beside: landing)
            return
        }
        for entry in realEntries(in: source) {
            merge(entry, into: landing.appending(path: entry.lastPathComponent))
        }
        pendingLinks.append((from: source, to: landing))
    }

    private func park(_ source: URL, beside landing: URL) {
        let parent = landing.deletingLastPathComponent()
        var name = landing.lastPathComponent + " BACKUP"
        var next = 2
        while fm.fileExists(atPath: parent.appending(path: name).path(percentEncoded: false)) {
            name = landing.lastPathComponent + " BACKUP \(next)"
            next += 1
        }
        attempt(source) { try fm.copyItem(at: source, to: parent.appending(path: name)) }
    }

    private func identity(of landing: URL) -> String {
        landing.deletingLastPathComponent().resolvingSymlinksInPath()
            .appending(path: landing.lastPathComponent).path(percentEncoded: false)
    }

    private func isBrokenLink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink == true else { return false }
        return !fm.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func escapes(_ landing: URL) -> Bool {
        let values = try? landing.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink == true else { return false }
        let inside = fresh.resolvingSymlinksInPath().path(percentEncoded: false)
        return !landing.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(inside)
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let found = fm.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    private func realEntries(in url: URL) -> [URL] {
        guard directoryExists(url) else { return [] }
        var found: [URL] = []
        attempt(url) {
            found = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        }
        return found
            .filter { entry in
                (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func carryLinks(from old: URL, to fresh: URL) {
        guard directoryExists(old) else { return }
        var entries: [URL] = []
        attempt(old) {
            entries = try fm.contentsOfDirectory(
                at: old, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
        }
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink == true else { continue }
            let landing = fresh.appending(path: entry.lastPathComponent)
            guard !fm.fileExists(atPath: landing.path(percentEncoded: false)) else { continue }
            guard let points = try? fm.destinationOfSymbolicLink(
                atPath: entry.path(percentEncoded: false)) else { continue }
            attempt(entry) {
                try fm.createSymbolicLink(atPath: landing.path(percentEncoded: false),
                                          withDestinationPath: points)
            }
        }
    }
}
