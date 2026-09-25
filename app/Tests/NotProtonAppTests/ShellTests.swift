import Foundation
import Testing

@testable import NotProtonApp

@Suite("Shell")
struct ShellTests {

    private func absentPath() -> String {
        URL.temporaryDirectory
            .appending(path: "np-absent-\(UUID().uuidString)")
            .path(percentEncoded: false)
    }

    @Test("Output bigger than the pipe buffer comes back whole")
    func drainsMoreThanThePipeBufferHolds() throws {
        let root = URL.temporaryDirectory.appending(path: "np-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "big.txt")

        // Several megabytes against a 64K pipe buffer. A child filling the pipe while the parent
        // waits for it to exit cannot progress, so this hangs if the two reads stop overlapping.
        let chunk = Data(String(repeating: "notproton ", count: 1024).utf8)
        var payload = Data()
        for _ in 0..<512 { payload.append(chunk) }
        try payload.write(to: file)

        let result = try Shell.run("/bin/cat", [file.path(percentEncoded: false)])

        #expect(!result.outputLost, "the output was never collected, so the count below reads as zero")
        #expect(result.succeeded)
        #expect(result.stdout.utf8.count == payload.count)
    }

    @Test("A command that fails is reported, not thrown")
    func reportsANonZeroExit() throws {
        let result = try Shell.run("/usr/bin/false", [])

        #expect(!result.succeeded)
        #expect(result.status == 1)
    }

    @Test("The two streams are kept apart")
    func separatesStderrFromStdout() throws {
        let result = try Shell.run("/bin/cat", [absentPath()])

        #expect(!result.outputLost, "the output was never collected, so both streams read as empty")
        #expect(!result.succeeded)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("No such file"))
    }

    @Test("A checked command carries the command, status and stderr")
    func checkReportsWhatFailed() throws {
        let failure = #expect(throws: CommandFailure.self) {
            try Shell.check("/bin/cat", [absentPath()])
        }

        #expect(failure?.command == "cat")
        #expect(failure?.status != 0)
        #expect(failure?.errorDescription?.contains("No such file") == true)
    }

    // A backgrounded grandchild holds both write ends open after the child is gone, as
    // wineserver does. The drain gives up, and lost output must not read as empty output.
    @Test("Output that could not be collected is reported as lost, not as empty")
    func reportsOutputItCouldNotCollect() throws {
        let result = try Shell.run(
            "/bin/sh", ["-c", "printf hello; sleep 3 & exit 3"], drainTimeout: .milliseconds(200))

        #expect(result.status == 3)
        #expect(result.outputLost)
        #expect(result.stdout.isEmpty)
    }

    @Test("Output that was collected is not reported as lost")
    func doesNotReportCollectedOutputAsLost() throws {
        let result = try Shell.run("/bin/echo", ["hello"], drainTimeout: .milliseconds(200))

        #expect(result.succeeded)
        #expect(!result.outputLost)
        #expect(result.stdout == "hello\n")
    }

    @Test("A checked command says so when its output was lost")
    func checkSaysWhenOutputWasLost() throws {
        let failure = #expect(throws: CommandFailure.self) {
            try Shell.check(
                "/bin/sh", ["-c", "sleep 3 & exit 3"], drainTimeout: .milliseconds(200))
        }

        #expect(failure?.status == 3)
        #expect(failure?.errorDescription?.contains("still open") == true)
    }

    private func stubPgrep(body: String) throws -> (String, URL) {
        let dir = URL.temporaryDirectory.appending(path: "np-pgrep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "pgrep")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path.path(percentEncoded: false))
        return (path.path(percentEncoded: false), dir)
    }

    // A match whose pid list never arrived used to report nothing running.
    @Test("A match still counts when its output is not collected")
    func aMatchWithLostOutputStillCounts() throws {
        let (pgrep, dir) = try stubPgrep(body: "echo 123; sleep 3 & exit 0")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(Shell.processIsRunning(
            named: "anything", pgrep: pgrep, drainTimeout: .milliseconds(200)))
    }

    @Test("Nothing matching reports nothing running")
    func noMatchReportsNothingRunning() throws {
        let (pgrep, dir) = try stubPgrep(body: "exit 1")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(Shell.processIsRunning(named: "anything", pgrep: pgrep) == false)
        #expect(Shell.processIsRunning(named: "anything", pgrep: absentPath()) == false)
    }
}
