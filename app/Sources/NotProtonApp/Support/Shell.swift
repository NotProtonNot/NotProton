// Install function needs to shell out, this handles it

import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let outputLost: Bool

    init(status: Int32, stdout: String, stderr: String, outputLost: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.outputLost = outputLost
    }

    var succeeded: Bool { status == 0 }
}

struct CommandFailure: LocalizedError {
    let command: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty { return L10n.tr("\(command) failed with status \(status).") }
        return L10n.tr("\(command) failed with status \(status): \(detail)")
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum Shell {

    private static let outputDrainTimeout: DispatchTimeInterval = .seconds(10)

    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        drainTimeout: DispatchTimeInterval = outputDrainTimeout
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()

        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()

        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        process.waitUntilExit()

        if group.wait(timeout: .now() + drainTimeout) == .timedOut {
            AppLog.note("\(executable) exited but left its output open")
            return CommandResult(
                status: process.terminationStatus, stdout: "", stderr: "", outputLost: true)
        }

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: outBox.data, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self)
        )
    }

    @discardableResult
    static func check(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        drainTimeout: DispatchTimeInterval = outputDrainTimeout
    ) throws -> String {
        let result = try run(
            executable, arguments, environment: environment, currentDirectory: currentDirectory,
            drainTimeout: drainTimeout)
        guard result.succeeded else {
            let reason = result.stderr.isEmpty ? result.stdout : result.stderr
            throw CommandFailure(
                command: (executable as NSString).lastPathComponent,
                status: result.status,
                stderr: reason.isEmpty && result.outputLost
                    ? L10n.tr("Its output was still open when it exited, so none was captured.")
                    : reason
            )
        }
        return result.stdout
    }

    // For the wine tools
    static func detach(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func processIsRunning(
        named name: String, pgrep: String = "/usr/bin/pgrep",
        drainTimeout: DispatchTimeInterval = outputDrainTimeout
    ) -> Bool {
        guard let result = try? run(pgrep, ["-x", name], drainTimeout: drainTimeout)
        else { return false }
        return result.succeeded
    }
}
