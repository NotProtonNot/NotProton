import Darwin
import Foundation

enum DeploymentContent {
    struct Build: Codable, Equatable, Sendable {
        let version: String
        let builtAt: Int64
        var dylibHashes: [String]? = nil

        func isNewer(than other: Build) -> Bool {
            let order = version.compare(other.version, options: .numeric)
            return order == .orderedDescending || (order == .orderedSame && builtAt > other.builtAt)
        }
    }

    struct File: Sendable {
        let source: URL
        let destination: URL
        let name: String
        var allowsResigning = false
        var executable = false

        func matches() throws -> Bool {
            let expected = try Digest.sha256(of: source)
            var info = stat()
            guard lstat(destination.path(percentEncoded: false), &info) == 0,
                info.st_mode & S_IFMT == S_IFREG else { return false }
            if executable && !FileManager.default.isExecutableFile(atPath: destination.path(percentEncoded: false)) {
                return false
            }
            if Digest.sha256IfPresent(destination) == expected { return true }
            guard allowsResigning else { return false }
            return try MachOBuild.matchesIgnoringSignature(source, destination)
        }
    }

    enum Status: Equatable, Sendable {
        case unchecked
        case current
        case update([String])
        case repair([String])
        case unrecorded([String])
        case newerInstalled
        case unavailable(String)

        var blocksInstallation: Bool {
            switch self {
            case .newerInstalled, .unavailable: true
            default: false
            }
        }
    }

    static func record(beside versionFile: URL) -> URL {
        versionFile.deletingLastPathComponent().appending(path: "install-build.json")
    }

    static func acquireInstallationLock(for app: URL) throws -> Int32 {
        let parent = app.deletingLastPathComponent().path(percentEncoded: false)
        let fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw StepFailure(step: SteamInstaller.step, detail: L10n.tr("Could not lock the installation at \(parent): \(String(cString: strerror(errno)))."))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw StepFailure(step: SteamInstaller.step, detail: L10n.tr("Another installation operation is changing files here. Wait for it to finish."))
        }
        return fd
    }

    static func readBuild(at file: URL) throws -> Build? {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        let build = try JSONDecoder().decode(Build.self, from: Data(contentsOf: file))
        guard !build.version.isEmpty, build.builtAt > 0 else {
            throw StepFailure(step: L10n.tr("Check installed files"), detail: L10n.tr("The installed build record is invalid."))
        }
        return build
    }

    static func inspect(files: [File], bundled: Build, installed: Build?, legacyVersion: String? = nil,
                        additionalDifferences: [String] = []) throws -> Status {
        if let installed, installed.isNewer(than: bundled) { return .newerInstalled }
        if let legacyVersion, legacyVersion.compare(bundled.version, options: .numeric) == .orderedDescending {
            return .newerInstalled
        }
        let changed = try files.filter { try !$0.matches() }
        let differences = changed.map(\.name) + additionalDifferences
        guard !differences.isEmpty else { return .current }
        guard let installed else {
            if let legacyVersion, legacyVersion.compare(bundled.version, options: .numeric) == .orderedAscending {
                return .update(differences)
            }
            return .unrecorded(differences)
        }
        if let hashes = installed.dylibHashes,
            let dylib = changed.first(where: \.allowsResigning),
            try Shell.run("/usr/bin/codesign", ["--verify", "--strict", dylib.destination.path(percentEncoded: false)]).succeeded,
            let deployed = try MachOBuild.hashesIgnoringSignature(of: dylib.destination),
            hashes != deployed
        {
            throw StepFailure(step: L10n.tr("Check installed files"),
                              detail: L10n.tr("Steam's installed dylib does not match this account's build record. Finish or repair its installation with the NotProton app that last installed it."))
        }
        return bundled.isNewer(than: installed) ? .update(differences) : .repair(differences)
    }

    static func files(
        payload: InstallPayload.Located, bridgePayload: BridgePayload.Located,
        app: URL, bridge: URL, signatures: URL, overlayShim: URL, iconmaker: URL, appinfo: URL,
        compatTools: URL, tools: [InstalledTool], runners: URL
    ) -> [File] {
        var files = [
            File(source: payload.dylib, destination: SupportPaths.Steam.deployedDylib(inBundle: app),
                 name: "notproton.dylib", allowsResigning: true),
            File(source: payload.overlayShim, destination: overlayShim, name: "overlay-shim.dylib"),
            File(source: payload.iconmaker, destination: iconmaker, name: "iconmaker", executable: true),
            File(source: payload.appinfo, destination: appinfo, name: "appinfo", executable: true),
        ]
        files += payload.signatures.map {
            File(source: $0, destination: signatures.appending(path: $0.lastPathComponent),
                 name: "signatures/\($0.lastPathComponent)")
        }
        for entry in bridgePayload.sources {
            files += entry.bridgePaths.map {
                File(source: entry.source, destination: bridge.appending(path: $0), name: "bridge/\($0)")
            }
        }
        files += tools.map {
            File(source: payload.run, destination: compatTools.appending(path: "\($0.name)/run"),
                 name: "\($0.name)/run", executable: true)
        }
        for build in Set(tools.map(\.build)).sorted() {
            let root = SupportPaths.clonedRoot(forBuild: build, runners: runners)
            for builtin in RunnerPatcher.builtins(in: root) {
                let path = "\(builtin.arch)/\(builtin.name)"
                if let entry = bridgePayload.sources.first(where: { $0.bridgePaths.contains(path) }) {
                    files.append(File(source: entry.source, destination: root.appending(path: "lib/wine/\(path)"),
                                      name: "crossover-\(build)/\(path)"))
                }
            }
        }
        return files
    }

    static func current(version: String) -> Status {
        do {
            let payload = try InstallPayload.locate()
            let bridge = try BridgePayload.locate()
            let pinned = try pinnedFiles(bridge: SupportPaths.bridge, runners: SupportPaths.runners)
                .filter { Digest.sha256IfPresent($0.destination) != $0.hash }.map(\.name)
            let files = files(payload: payload, bridgePayload: bridge, app: SupportPaths.Steam.app,
                              bridge: SupportPaths.bridge, signatures: SupportPaths.signatures,
                              overlayShim: SupportPaths.overlayShim, iconmaker: SupportPaths.iconmaker,
                              appinfo: SupportPaths.appinfo, compatTools: SupportPaths.Steam.compatTools,
                              tools: CompatToolList.installed(), runners: SupportPaths.runners)
            return try inspect(files: files, bundled: Build(version: version, builtAt: payload.builtAt),
                               installed: readBuild(at: record(beside: SupportPaths.deployedVersion)),
                               legacyVersion: SteamBundle.deployedVersion(), additionalDifferences: pinned.sorted())
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func pinnedFiles(bridge: URL, runners: URL) throws -> [(destination: URL, hash: String, name: String)] {
        let manifest = try ValvePackageManifest.bundled()
        var files = manifest.files.map {
            (destination: bridge.appending(path: $0.bridgePath), hash: $0.sha256, name: "bridge/\($0.bridgePath)")
        }
        let list = runners.deletingLastPathComponent().appending(path: "tools")
        let tools = CompatToolList.installed(runners: runners, file: list)
        if !tools.isEmpty || FileManager.default.fileExists(atPath: list.path(percentEncoded: false)) {
            files.append((list, Digest.sha256(of: Data(CompatToolList.contents(tools).utf8)), "tools"))
        }
        for build in RunnerStore.installedBuilds(in: runners) {
            for (arch, hash) in build.patchedNtdll {
                let file = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
                    .appending(path: "lib/wine/\(arch.rawValue)/ntdll.dll")
                files.append((file, hash, "crossover-\(build.id)/\(arch.rawValue)/ntdll.dll"))
                files.append((NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge), hash,
                              "bridge/wine/\(build.id)/\(arch.rawValue)/ntdll.dll"))
            }
        }
        return files
    }
}
