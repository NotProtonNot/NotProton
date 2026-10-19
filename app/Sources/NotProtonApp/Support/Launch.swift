import Foundation

@main
enum Launch {
    static func main() {
        if CommandLine.arguments.dropFirst().first == RebuildPrefixCommand.flag {
            do {
                try RebuildPrefixCommand.run(Array(CommandLine.arguments.dropFirst(2)))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if CommandLine.arguments.dropFirst().contains(RemoveEverythingCommand.flag) {
            RemoveEverythingCommand.run()
        }
        NotProtonApp.main()
    }
}

enum RebuildPrefixCommand {
    static let flag = "--rebuild-prefix"
    static let executableRecord = "app-executable"

    struct Request {
        let prefix: WinePrefix
        let tool: InstalledTool
        let keepBackup: Bool
    }

    static func request(_ arguments: [String], tools: [InstalledTool]) throws -> Request {
        func refused(_ detail: String) -> StepFailure {
            StepFailure(step: "Rebuild prefix", detail: detail)
        }
        guard arguments.count == 5,
            ["keep-backup", "discard-backup"].contains(arguments[4]),
            arguments[0].hasPrefix("/")
        else { throw refused("Invalid rebuild arguments.") }
        let root = URL(filePath: arguments[0]).standardizedFileURL
        let appID = root.lastPathComponent
        let compatdata = root.deletingLastPathComponent()
        let steamapps = compatdata.deletingLastPathComponent()
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }),
            compatdata.lastPathComponent == "compatdata", steamapps.lastPathComponent == "steamapps",
            FileManager.default.fileExists(atPath: root.appending(path: "pfx").path(percentEncoded: false))
        else { throw refused("The game prefix could not be found under steamapps/compatdata.") }
        guard let tool = tools.first(where: {
            $0.name == arguments[1] && $0.build == arguments[2] && $0.tool.flavor.rawValue == arguments[3]
        }) else { throw refused("The selected compatibility tool is unavailable. Set it up in NotProton first.") }
        let library = SteamLibrary(root: steamapps.deletingLastPathComponent())
        return Request(
            prefix: WinePrefix(appID: appID, name: PrefixStore.appName(appID: appID, in: library),
                               library: library, lastUsed: nil),
            tool: tool, keepBackup: arguments[4] == "keep-backup"
        )
    }

    static func run(_ arguments: [String]) throws {
        let lock = try DeploymentContent.acquireInstallationLock()
        defer { lock.release() }
        let request = try request(arguments, tools: CompatToolList.installed())
        try PrefixTools.recreate(request.prefix, as: request.tool, keepBackup: request.keepBackup)
    }

    static func recordExecutable(_ executable: URL, in support: URL) throws {
        try atomicReplace(support.appending(path: executableRecord),
                          with: Data(executable.path(percentEncoded: false).utf8), step: "Record NotProton app")
    }
}
