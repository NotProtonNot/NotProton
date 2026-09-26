// Checks CrossOver state for status display

import Foundation

enum RunnerState: Sendable, Equatable {
    case none
    case cloned(build: String, supported: Bool)
    case bundleShaped(build: String)
    case unpatched(build: String, problems: [String])
    case broken(detail: String)

    var buildIdentifier: String? {
        switch self {
        case .cloned(let build, _), .bundleShaped(let build), .unpatched(let build, _): build
        case .none, .broken: nil
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
        let fm = FileManager.default
        let current = runners.appending(path: "current")
        let currentPath = current.path(percentEncoded: false)

        guard let attributes = try? fm.attributesOfItem(atPath: currentPath),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink
        else {
            if fm.fileExists(atPath: currentPath) {
                return .broken(detail: "runners/current is not a symlink.")
            }
            return .none
        }

        guard let target = try? fm.destinationOfSymbolicLink(atPath: currentPath) else {
            return .broken(detail: "runners/current cannot be read.")
        }

        let resolved = current.deletingLastPathComponent().appending(path: target).standardizedFileURL
        guard fm.fileExists(atPath: resolved.appending(path: "lib/wine").path(percentEncoded: false)) else {
            return .broken(detail: "runners/current points at \(target), which has no lib/wine.")
        }

        guard let build = buildIdentifier(inPath: target) else {
            return .broken(detail: "runners/current points at \(target), which has no recognisable build.")
        }

        if target.split(separator: "/").contains(where: { $0.hasSuffix(".app") }) {
            return .bundleShaped(build: build)
        }

        guard let supported = SupportedRunners.build(id: build) else {
            return .cloned(build: build, supported: false)
        }

        let problems = verify(supported, resolved)
        guard problems.isEmpty else { return .unpatched(build: build, problems: problems) }

        return .cloned(build: build, supported: true)
    }

    static func buildIdentifier(inPath path: String) -> String? {
        for component in path.split(separator: "/") where component.hasPrefix("crossover-") {
            return String(component.dropFirst("crossover-".count))
        }
        return nil
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

    static func currentBuild(runners: URL = SupportPaths.runners) -> String? {
        let current = runners.appending(path: "current").path(percentEncoded: false)
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: current))
            .flatMap(buildIdentifier(inPath:))
    }

    static func installedBuilds(in runners: URL = SupportPaths.runners) -> [RunnerBuild] {
        clonedBuilds(in: runners)
            .compactMap(SupportedRunners.build(id:))
            .filter { RunnerInstaller.hasClone(forBuild: $0.id, runners: runners) }
    }
}
