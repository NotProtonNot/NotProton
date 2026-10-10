// Checks CrossOver state for status display

import Foundation

enum RunnerState: Sendable, Equatable {
    case none
    case ready(builds: [String])
    case unpatched(builds: [String], problems: [String])

    var builds: [String] {
        switch self {
        case .none: []
        case .ready(let builds): builds
        case .unpatched(let builds, _): builds
        }
    }
}

enum RunnerStore {

    static func state(
        runners: URL = SupportPaths.runners,
        verify: @Sendable (RunnerBuild, URL) -> [String] = {
            RunnerPatcher.verify(build: $0, root: $1)
        }
    ) -> RunnerState {
        let installed = installedBuilds(in: runners)
        guard !installed.isEmpty else { return .none }

        var unpatched: [String] = []
        var problems: [String] = []
        for build in installed {
            let found = verify(build, SupportPaths.clonedRoot(forBuild: build.id, runners: runners))
            guard !found.isEmpty else { continue }
            unpatched.append(build.id)
            problems += found.map { "\(build.id): \($0)" }
        }
        if unpatched.isEmpty { return .ready(builds: installed.map(\.id)) }
        return .unpatched(builds: unpatched, problems: problems)
    }

    static func clonedBuilds(in runners: URL = SupportPaths.runners) -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: runners, includingPropertiesForKeys: nil)) ?? []
        return entries
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("crossover-") }
            .map { String($0.dropFirst("crossover-".count)) }
            .sorted()
    }

    static func orphanedClones(in runners: URL = SupportPaths.runners) -> [String] {
        clonedBuilds(in: runners).filter { SupportedRunners.build(id: $0) == nil }
    }

    static func damagedClones(in runners: URL = SupportPaths.runners) -> [String] {
        clonedBuilds(in: runners).filter {
            SupportedRunners.build(id: $0) != nil
                && !RunnerInstaller.hasClone(forBuild: $0, runners: runners)
        }
    }

    static func cloneSize(forBuild build: String, runners: URL = SupportPaths.runners) -> Int64 {
        let root = SupportPaths.runnerRoot(forBuild: build, runners: runners)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            )
            let bytes = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(bytes)
        }
        return total
    }

    static func installedBuilds(in runners: URL = SupportPaths.runners) -> [RunnerBuild] {
        clonedBuilds(in: runners)
            .compactMap { build(cloned: $0, runners: runners) }
            .filter { RunnerInstaller.hasClone(forBuild: $0.id, runners: runners) }
    }

    private static func build(cloned id: String, runners: URL) -> RunnerBuild? {
        guard let build = SupportedRunners.build(id: id) else { return nil }
        guard !build.rebuilds.isEmpty else { return build }
        let root = SupportPaths.clonedRoot(forBuild: id, runners: runners)
        let loader = Clean.copy(of: CrossOverSource.unixLoader(inRoot: root))
        return Digest.sha256IfPresent(loader).flatMap(build.matching(loaderSHA256:)) ?? build
    }
}

enum CompatToolList {

    static func contents(_ tools: [InstalledTool]) -> String {
        tools.map { "\($0.name)\t\($0.build)\t\($0.tool.flavor.rawValue)\t\($0.display)\n" }.joined()
    }

    static func installed(
        runners: URL = SupportPaths.runners, file: URL = SupportPaths.toolList
    ) -> [InstalledTool] {
        resolved(runners: runners, file: file).tools
    }

    // legacyHolder reads runners/current, so this has to run before prune deletes that symlink.
    private static func resolved(
        runners: URL, file: URL
    ) -> (builds: [RunnerBuild], listed: String?, tools: [InstalledTool]) {
        let builds = RunnerStore.installedBuilds(in: runners)
        let listed = try? String(contentsOf: file, encoding: .utf8)
        let holder = legacyHolder(builds: builds, listed: listed, runners: runners)
        let tools = SupportedRunners.tools(for: builds, legacy: holder) {
            RunnerVariant.activeMajor(crossOverRoot: SupportPaths.clonedRoot(forBuild: $0.id, runners: runners))
        }
        return (builds, listed, tools)
    }

    // 1.0.x used the single 'notproton' tool name and wrote no tool list, so the
    // runners/current symlink is the record of which version of CrossOver was deployed.
    static func legacyHolder(
        builds: [RunnerBuild], listed: String?, runners: URL = SupportPaths.runners
    ) -> SupportedRunners.LegacyHolder {
        let ids = Set(builds.map(\.id))
        let rows = (listed ?? "").split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            .filter { $0.count > 1 && ids.contains($0[1]) && SupportedRunners.legacyHolders.contains($0[1]) }
        if let held = rows.first(where: { $0[0] == SupportedRunners.legacyToolName }) {
            return .build(held[1])
        }
        if !rows.isEmpty { return .nobody }
        let link = runners.appending(path: "current").path(percentEncoded: false)
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link),
           let id = target.split(separator: "/").first(where: { $0.hasPrefix("crossover-") })
               .map({ String($0.dropFirst("crossover-".count)) }),
           ids.contains(id), SupportedRunners.legacyHolders.contains(id) {
            return .build(id)
        }
        return .nobody
    }

    // Returns true when the list file changed.
    @discardableResult
    static func sync(
        runners: URL = SupportPaths.runners,
        bridge: URL = SupportPaths.bridge,
        file: URL = SupportPaths.toolList,
        compatTools: URL = SupportPaths.Steam.compatTools
    ) throws -> Bool {
        let (builds, listed, tools) = resolved(runners: runners, file: file)
        let text = contents(tools)
        let changed = !(listed == text || (listed == nil && text.isEmpty))
        if changed {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try atomicReplace(file, with: Data(text.utf8), step: "Update compatibility tools")
        }
        prune(keeping: Set(builds.map(\.id)), runners: runners, bridge: bridge, compatTools: compatTools)
        return changed
    }

    private static func prune(
        keeping ids: Set<String>, runners: URL, bridge: URL, compatTools: URL
    ) {
        let legacyInUse = legacyLayoutInUse(compatTools: compatTools)
        NtdllPatcher.pruneBuilds(keeping: ids, in: bridge, keepingLegacy: legacyInUse)
        guard !legacyInUse else { return }
        let legacy = runners.appending(path: "current").path(percentEncoded: false)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: legacy)) != nil {
            try? FileManager.default.removeItem(atPath: legacy)
        }
    }

    // Old run scripts read runners/current and bridge/wine/<arch>. Steam keeps running them
    // until it restarts, so those paths have to keep working until then.
    static func legacyLayoutInUse(compatTools: URL = SupportPaths.Steam.compatTools) -> Bool {
        SupportPaths.Steam.notprotonTools(in: compatTools).contains { tool in
            let run = try? String(contentsOf: tool.appending(path: "run"), encoding: .utf8)
            return run?.contains("/runners/current") == true
        }
    }
}
