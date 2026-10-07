import Darwin
import Foundation
import Testing

@testable import NotProtonApp

// Opt-in only: this copies the installed Preview into an isolated test runner
// and never modifies its installation, the active runner, or game prefixes.
@Suite("Real bundled Rosetta", .enabled(if:
    ProcessInfo.processInfo.environment["NOTPROTON_TEST_BUNDLED_ROSETTA"] == "1"))
struct RealBundledRosettaTests {
    private func run(
        _ executable: URL, _ arguments: [String],
        environment: [String: String], logs: URL, timeout: Int = 60
    ) throws -> String {
        let log = logs.appending(path: "\(UUID().uuidString).log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + .seconds(5)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + .seconds(5))
            }
            throw StepFailure(
                step: "Test bundled Rosetta",
                detail: "\(executable.lastPathComponent) timed out: \(arguments.joined(separator: " "))."
            )
        }

        // Files avoid waiting for a wineserver descendant to close a pipe.
        let captured = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandFailure(
                command: executable.lastPathComponent,
                status: process.terminationStatus, stderr: captured)
        }
        return captured
    }

    @Test("The patched bundled runtime boots and runs 64-bit and 32-bit Windows commands")
    func bootsPatchedRuntime() throws {
        let files = FileManager.default
        let base = ProcessInfo.processInfo.environment["NOTPROTON_TEST_TEMP"]
            .map { URL(filePath: $0) } ?? URL.temporaryDirectory
        let test = base.appending(path: "np-bundled-runtime-\(UUID().uuidString)")
        try files.createDirectory(at: test, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: test) }
        let source = ProcessInfo.processInfo.environment["NOTPROTON_TEST_CROSSOVER"]
            ?? "/Applications/CrossOver Preview.app"
        // Exercise the macOS 15 selection even when the test host supports FEX.
        let install = CrossOverSource.inspect(bundle: URL(filePath: source), fexAvailable: false)
        guard case .supported(let build) = install.support, build.usesBundledRosetta else {
            throw StepFailure(
                step: "Test bundled Rosetta",
                detail: "The test requires the supported combined CrossOver Preview 20261006 distribution."
            )
        }
        try CrossOverLicense.requireValid(for: install)
        let runners = test.appending(path: "runners")
        let bridge = test.appending(path: "bridge")
        _ = try BridgePayload.stage(located: BridgePayload.locate(), bridge: bridge)
        _ = try RunnerInstaller.clone(from: install, runners: runners)
        let root = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        _ = try NtdllPatcher.stage(build: build, runnerRoot: root, bridge: bridge)
        _ = try RunnerPatcher.install(build: build, root: root, bridge: bridge)
        #expect(RunnerPatcher.verify(build: build, root: root, bridge: bridge).isEmpty)
        let prefix = WinePrefix(
            appID: "480", name: nil, library: SteamLibrary(root: test), lastUsed: nil)
        try files.createDirectory(at: prefix.root, withIntermediateDirectories: true)
        var environment = PrefixTools.environment(prefix: prefix, runner: root)
        environment["WINEDEBUG"] = "-all"
        let layout = PrefixTools.layout(runner: root)
        defer { _ = try? run(layout.server, ["-k"], environment: environment, logs: test, timeout: 10) }
        _ = try run(layout.loader, ["wineboot", "--init"], environment: environment, logs: test)
        let output64 = try run(
            layout.loader, ["cmd", "/c", "echo NP_ROSETTA_64_OK"],
            environment: environment, logs: test)
        #expect(output64.contains("NP_ROSETTA_64_OK"))
        let cmd32 = prefix.pfx.appending(path: "drive_c/windows/syswow64/cmd.exe")
        let output32 = try run(
            layout.loader, [cmd32.path(percentEncoded: false), "/c", "echo NP_ROSETTA_32_OK"],
            environment: environment, logs: test)
        #expect(output32.contains("NP_ROSETTA_32_OK"))
        #expect(PrefixStore.arch(of: prefix) == .x86_64)
    }
}
