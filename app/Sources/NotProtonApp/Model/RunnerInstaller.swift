// Clones CrossOver's Wine runtime into ~/Library/Application Support/notproton/runners

import Foundation

enum RunnerInstaller {

    static let step = "Clone CrossOver"

    static func clone(
        from install: CrossOverInstall,
        replacingExisting: Bool = false,
        runners: URL = SupportPaths.runners
    ) throws -> RunnerBuild {
        guard case .supported(let build) = install.support else {
            throw StepFailure(
                step: step,
                detail: "\(install.name) is not a supported build. Supported: \(SupportedRunners.versionList)."
            )
        }

        let fm = FileManager.default
        let target = SupportPaths.runnerRoot(forBuild: build.id, runners: runners)

        let existing = hasClone(forBuild: build.id, runners: runners)
        let occupied = fm.fileExists(atPath: target.path(percentEncoded: false))

        if !existing || replacingExisting {
            let staging = target.deletingLastPathComponent()
                .appending(path: ".\(target.lastPathComponent).new")
            try? fm.removeItem(at: staging)
            try copyPayload(from: install.crossOverRoot, to: staging)
            if occupied {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: staging, to: target)
        }

        let cloned = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        try verifyClone(build: build, root: cloned)

        return build
    }

    static let removeStep = "Remove build"

    static func removeClone(forBuild build: String, runners: URL = SupportPaths.runners) throws {
        let target = SupportPaths.runnerRoot(forBuild: build, runners: runners)
        let path = target.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: path) else {
            throw StepFailure(step: removeStep, detail: "Build \(build) is not set up.")
        }
        guard RunnerStore.currentBuild(runners: runners) != build else {
            throw StepFailure(
                step: removeStep,
                detail: "Build \(build) is the active build. Switch to another build first."
            )
        }

        try WriteRefused.catching(path) { try FileManager.default.removeItem(at: target) }
    }

    static func hasClone(forBuild build: String, runners: URL = SupportPaths.runners) -> Bool {
        let root = SupportPaths.clonedRoot(forBuild: build, runners: runners)
        return FileManager.default.fileExists(
            atPath: root.appending(path: "lib/wine").path(percentEncoded: false)
        )
    }

    static func copyPayload(from payload: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)

        let source = payload.path(percentEncoded: false)
        let landing = target.appending(path: "CrossOver")
        let destination = landing.path(percentEncoded: false)

        let cloned = try Shell.run("/bin/cp", ["-c", "-R", source, destination])
        if cloned.status == 0 {
            scrubDownloadMarkers(at: landing)
            return
        }

        try? fm.removeItem(at: landing)
        let copied = try Shell.run("/bin/cp", ["-R", source, destination])
        guard copied.status == 0 else {
            throw StepFailure(
                step: step,
                detail: "Copying \(source) failed. \(copied.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        scrubDownloadMarkers(at: landing)
    }

    static func scrubDownloadMarkers(at payload: URL) {
        for marker in ["com.apple.quarantine", "com.apple.provenance"] {
            _ = try? Shell.run("/usr/bin/xattr", ["-r", "-d", marker, payload.path(percentEncoded: false)])
        }
    }

    static func verifyClone(build: RunnerBuild, root: URL) throws {
        let loader = Clean.copy(of: CrossOverSource.unixLoader(inRoot: root))
        guard let hash = Digest.sha256IfPresent(loader) else {
            throw StepFailure(step: step, detail: "The clone has no Wine loader at \(loader.lastPathComponent).")
        }
        guard hash == build.loaderSHA256 else {
            throw StepFailure(
                step: step,
                detail: "The cloned Wine loader at \(loader.lastPathComponent) does not match build "
                    + "\(build.id). Expected \(build.loaderSHA256.prefix(16)), found \(hash.prefix(16))."
            )
        }

        try CrossOverSource.verifyPatchInputs(root: root, build: build)
    }

    static func pointCurrent(atBuild build: String, runners: URL = SupportPaths.runners) throws {
        let fm = FileManager.default
        let relative = "crossover-\(build)/CrossOver"
        let staging = runners.appending(path: ".current.new")

        try? fm.removeItem(at: staging)
        try fm.createSymbolicLink(
            atPath: staging.path(percentEncoded: false), withDestinationPath: relative
        )

        let current = runners.appending(path: "current").path(percentEncoded: false)
        if rename(staging.path(percentEncoded: false), current) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: staging)
            throw StepFailure(step: step, detail: "Could not point the compatibility tool at \(relative). \(reason)")
        }
    }
}
