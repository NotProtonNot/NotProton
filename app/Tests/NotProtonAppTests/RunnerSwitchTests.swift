import Foundation
import Testing

@testable import NotProtonApp

// Switching points runners/current at a clone that already exists. The steps that hash and
// sign real CrossOver files are stood in for, so what is checked is the order they run in and
// what is left behind when one of them fails.
@Suite("Switching between installed builds")
struct RunnerSwitchTests {

    private static let rosetta = SupportedRunners.all.first { $0.flavor == nil }!
    private static let fex = SupportedRunners.all.first { $0.flavor == "fex" }!

    private static let licensed = CrossOverLicense.Status(
        licensed: true, detail: "CrossOver is activated.", diagnostic: "test"
    )
    private static let unlicensed = CrossOverLicense.Status(
        licensed: false, detail: CrossOverLicense.notActivated, diagnostic: "test"
    )

    private final class Calls: @unchecked Sendable {
        var staged: [String] = []
        var patched: [String] = []
        var currentWhilePatching: String?
    }

    private func makeRunners(cloning builds: [RunnerBuild]) throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-switch-\(UUID().uuidString)")
        for build in builds {
            try FileManager.default.createDirectory(
                at: SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
                    .appending(path: "lib/wine"),
                withIntermediateDirectories: true
            )
        }
        return runners
    }

    private func activate(
        _ build: RunnerBuild,
        runners: URL,
        calls: Calls,
        license: CrossOverLicense.Status = licensed,
        failPatch: Bool = false
    ) throws -> RunnerSetup.Outcome {
        try RunnerSetup.activate(
            build,
            runners: runners,
            bridge: runners.appending(path: "bridge"),
            license: { _ in license },
            verify: { _, _ in },
            stage: { build, _, _ in
                calls.staged.append(build.id)
                return []
            },
            patch: { build, _, _ in
                calls.patched.append(build.id)
                calls.currentWhilePatching = RunnerStore.currentBuild(runners: runners)
                if failPatch { throw StepFailure(step: "test", detail: "patch failed") }
                return RunnerPatcher.Outcome()
            }
        )
    }

    @Test("Switching moves the link to the other build")
    func switchesBuild() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        try RunnerInstaller.pointCurrent(atBuild: Self.rosetta.id, runners: runners)

        let calls = Calls()
        let outcome = try activate(Self.fex, runners: runners, calls: calls)

        #expect(outcome.build == Self.fex)
        #expect(RunnerStore.currentBuild(runners: runners) == Self.fex.id)
        #expect(calls.staged == [Self.fex.id])
        #expect(calls.patched == [Self.fex.id])

        // And back again, which is the point of keeping both clones.
        _ = try activate(Self.rosetta, runners: runners, calls: calls)
        #expect(RunnerStore.currentBuild(runners: runners) == Self.rosetta.id)
    }

    // A launch in between would otherwise find the new build before its ntdll is patched.
    @Test("The link only moves once the target is patched")
    func linkMovesLast() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        try RunnerInstaller.pointCurrent(atBuild: Self.rosetta.id, runners: runners)

        let calls = Calls()
        _ = try activate(Self.fex, runners: runners, calls: calls)

        #expect(calls.currentWhilePatching == Self.rosetta.id)
    }

    // The bridge holds one build's ntdll, and FEX staging prunes the x86_64 copy Rosetta needs.
    @Test("A failed switch keeps the old build and restages its ntdll")
    func failedSwitchRestoresPrevious() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        try RunnerInstaller.pointCurrent(atBuild: Self.rosetta.id, runners: runners)

        let calls = Calls()
        #expect(throws: StepFailure.self) {
            try activate(Self.fex, runners: runners, calls: calls, failPatch: true)
        }

        #expect(RunnerStore.currentBuild(runners: runners) == Self.rosetta.id)
        #expect(calls.staged == [Self.fex.id, Self.rosetta.id])
    }

    @Test("A failed bridge restore reports both failures")
    func failedRestoreIsReported() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        try RunnerInstaller.pointCurrent(atBuild: Self.rosetta.id, runners: runners)

        var staged: [String] = []
        let failure = try #require(throws: StepFailure.self) {
            try RunnerSetup.activate(
                Self.fex,
                runners: runners,
                license: { _ in Self.licensed },
                verify: { _, _ in },
                stage: { build, _, _ in
                    staged.append(build.id)
                    if build == Self.rosetta {
                        throw StepFailure(step: "restore", detail: "disk full")
                    }
                    return []
                },
                patch: { _, _, _ in
                    throw StepFailure(step: "patch", detail: "patch failed")
                }
            )
        }

        #expect(staged == [Self.fex.id, Self.rosetta.id])
        #expect(RunnerStore.currentBuild(runners: runners) == Self.rosetta.id)
        #expect(failure.detail.contains("patch failed"))
        #expect(failure.detail.contains("Restoring the previous build also failed"))
        #expect(failure.detail.contains("disk full"))
    }

    @Test("A build with no clone is refused without touching anything")
    func refusesMissingClone() throws {
        let runners = try makeRunners(cloning: [Self.rosetta])
        defer { try? FileManager.default.removeItem(at: runners) }
        try RunnerInstaller.pointCurrent(atBuild: Self.rosetta.id, runners: runners)

        let calls = Calls()
        let failure = try #require(throws: StepFailure.self) {
            try activate(Self.fex, runners: runners, calls: calls)
        }

        #expect(failure.detail.contains("has not been set up"))
        #expect(calls.staged.isEmpty)
        #expect(RunnerStore.currentBuild(runners: runners) == Self.rosetta.id)
    }

    // Setting up checks the license, so switching to a clone must not be a way around it.
    @Test("Switching is refused when CrossOver is not activated")
    func refusesUnlicensed() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }
        try RunnerInstaller.pointCurrent(atBuild: Self.rosetta.id, runners: runners)

        let calls = Calls()
        #expect(throws: StepFailure.self) {
            try activate(Self.fex, runners: runners, calls: calls, license: Self.unlicensed)
        }

        #expect(calls.staged.isEmpty)
        #expect(RunnerStore.currentBuild(runners: runners) == Self.rosetta.id)
    }

    @Test("Installed builds are supported clones that still have their payload")
    func installedBuildsListing() throws {
        let runners = try makeRunners(cloning: [Self.rosetta, Self.fex])
        defer { try? FileManager.default.removeItem(at: runners) }

        // An unknown build and a clone that lost its payload are not switch targets.
        try FileManager.default.createDirectory(
            at: SupportPaths.clonedRoot(forBuild: "1.0.0.1", runners: runners)
                .appending(path: "lib/wine"),
            withIntermediateDirectories: true
        )
        try FileManager.default.removeItem(
            at: SupportPaths.clonedRoot(forBuild: Self.fex.id, runners: runners)
        )

        #expect(RunnerStore.installedBuilds(in: runners) == [Self.rosetta])
    }
}

@MainActor
@Suite("Choosing which CrossOver to set up from")
struct SetupSourceTests {

    private func install(_ name: String, _ build: RunnerBuild) -> CrossOverInstall {
        CrossOverInstall(
            bundle: URL(filePath: "/Applications/\(name).app"),
            releaseVersion: build.releaseVersion,
            support: .supported(build)
        )
    }

    private func status(runner: RunnerState, installs: [CrossOverInstall]) -> SystemStatus {
        let status = SystemStatus()
        status.snapshot = StatusSnapshot(
            steam: .steamMissing,
            steamRunning: false,
            updateBlocked: false,
            crossOver: installs,
            crossOverLicense: nil,
            runner: runner,
            payload: PayloadInspector.inspect(bridge: FileManager.default.temporaryDirectory)
        )
        return status
    }

    // Copy Again on a FEX tool must not quietly recopy the Rosetta CrossOver listed first.
    @Test("A recopy comes from the install the current build was cloned from")
    func prefersCurrentBuild() {
        let rosetta = install("CrossOver", SupportedRunners.all[0])
        let fex = install("CrossOver FEX", SupportedRunners.all[1])

        let status = status(
            runner: .cloned(build: SupportedRunners.all[1].id, supported: true),
            installs: [rosetta, fex]
        )

        #expect(status.setupSource?.id == fex.id)
    }

    @Test("With no tool set up, the preferred install is used")
    func fallsBackToPreferred() {
        let rosetta = install("CrossOver", SupportedRunners.all[0])
        let fex = install("CrossOver FEX", SupportedRunners.all[1])

        let status = status(runner: .none, installs: [rosetta, fex])

        #expect(status.setupSource?.id == rosetta.id)
        #expect(status.usableCrossOvers.map(\.id) == [rosetta.id, fex.id])
    }
}
