import Foundation

enum RemoveEverythingCommand {
    static let flag = "--remove-everything"

    static func run() -> Never {
        Task.detached { exit(await perform()) }
        dispatchMain()
    }

    private static func perform() async -> Int32 {
        do {
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            let output = Output()
            let result = try await Uninstall.run { phase in
                if case .restoring(.finished) = phase { return }
                output.say(phase.label)
            }
            output.say(
                result.partialRemoval ?? (result.steamNeedsRedownload
                    ? "NotProton has been removed. Steam could not be restored. "
                        + "Reinstall Steam from steampowered.com before using it again."
                    : "NotProton has been removed.")
            )
            return result.partialRemoval == nil ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("\(failureMessage(error))\n".utf8))
            return 1
        }
    }

    static func failureMessage(_ error: Error) -> String {
        guard let refused = error as? WriteRefused else { return error.localizedDescription }
        let advice = switch refused.remedy {
        case .appManagement:
            "Allow your terminal app in System Settings > Privacy & Security > App Management, then run it again."
        case .otherAccount:
            "Steam was installed by another account on this Mac. Run this again while logged in to that account."
        case .ownership:
            "Check permissions, make sure your user owns the folder."
        }
        return "Could not write \(refused.path). \(advice)"
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var last: String?

        func say(_ line: String) {
            lock.withLock {
                guard line != last else { return }
                last = line
                FileHandle.standardOutput.write(Data("\(line)\n".utf8))
            }
        }
    }
}
