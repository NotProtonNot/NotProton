// Clones CrossOver, throws it in bridge, invokes ntdll patch,

import Foundation

enum RunnerSetup {

    enum Phase: Sendable {
        case cloning
        case staging
        case patching
        case finished

        var label: String {
            switch self {
            case .cloning: "Copying CrossOver"
            case .staging: "Patching"
            case .patching: "Installing compatibility tool"
            case .finished: "Done"
            }
        }
    }

    struct Outcome: Sendable {
        let build: RunnerBuild
        let staged: [WineArch]
        let installed: RunnerPatcher.Outcome

        var stagedNothing: Bool { staged.isEmpty && installed.wroteNothing }
    }

    static func run(
        from install: CrossOverInstall,
        replacingExisting: Bool = false,
        report: @Sendable (Phase) -> Void = { _ in }
    ) throws -> Outcome {
        try CrossOverLicense.requireValid(for: install)

        report(.cloning)
        let build = try RunnerInstaller.clone(from: install, replacingExisting: replacingExisting)
        return try activate(build, report: report)
    }

    static let switchStep = "Switch compatibility tool"

    static func activate(
        _ build: RunnerBuild,
        runners: URL = SupportPaths.runners,
        bridge: URL = SupportPaths.bridge,
        license: (URL) -> CrossOverLicense.Status = { CrossOverLicense.check(crossOverRoot: $0) },
        verify: (RunnerBuild, URL) throws -> Void = RunnerInstaller.verifyClone,
        stage: (RunnerBuild, URL, URL) throws -> [WineArch] = {
            try NtdllPatcher.stage(build: $0, runnerRoot: $1, bridge: $2)
        },
        patch: (RunnerBuild, URL, URL) throws -> RunnerPatcher.Outcome = {
            try RunnerPatcher.install(build: $0, root: $1, bridge: $2)
        },
        report: @Sendable (Phase) -> Void = { _ in }
    ) throws -> Outcome {
        guard RunnerInstaller.hasClone(forBuild: build.id, runners: runners) else {
            throw StepFailure(
                step: switchStep, detail: "Build \(build.displayVersion) has not been set up."
            )
        }

        let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        let status = license(root)
        guard status.licensed else {
            throw StepFailure(step: "Verify CrossOver license", detail: status.detail)
        }

        let previous = RunnerStore.currentBuild(runners: runners)
            .flatMap(SupportedRunners.build(id:))
            .flatMap { $0 != build && RunnerInstaller.hasClone(forBuild: $0.id, runners: runners) ? $0 : nil }

        try verify(build, root)

        do {
            report(.staging)
            let staged = try stage(build, root, bridge)

            report(.patching)
            let installed = try patch(build, root, bridge)
            try RunnerInstaller.pointCurrent(atBuild: build.id, runners: runners)

            report(.finished)
            return Outcome(build: build, staged: staged, installed: installed)
        } catch {
            if let previous {
                do {
                    _ = try stage(
                        previous, SupportPaths.clonedRoot(forBuild: previous.id, runners: runners), bridge
                    )
                } catch let restorationError {
                    throw StepFailure(
                        step: switchStep,
                        detail: "\(error.localizedDescription) Restoring the previous build also failed: "
                            + restorationError.localizedDescription
                    )
                }
            }
            throw error
        }
    }
}
