// Clones Wine runtimes into ~/Library/Application Support/notproton/runners

import Darwin
import Foundation

enum RunnerInstaller {

    static func clone(
        from install: RuntimeInstall, replacingExisting: Bool = false,
        runners: URL = SupportPaths.runners
    ) throws -> RunnerBuild {
        guard let build = install.build else {
            throw StepFailure(step: step, detail: String(localized: "Unsupported Whisky runtime."))
        }
        let fm = FileManager.default
        let target = SupportPaths.runnerRoot(forBuild: build.id, runners: runners)
        if !hasClone(forBuild: build.id, runners: runners) || replacingExisting {
            try fm.createDirectory(at: runners, withIntermediateDirectories: true)
            let staging = runners.appending(path: ".\(build.id).new")
            try? fm.removeItem(at: staging)
            defer { try? fm.removeItem(at: staging) }
            try copyRuntime(from: install.root, to: staging)
            try verifyClone(build: build, root: staging.appending(path: "Wine"))
            if fm.fileExists(atPath: target.path(percentEncoded: false)) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        } else {
            try verifyClone(build: build, root: target.appending(path: "Wine"))
        }
        return build
    }

    static func copyRuntime(from source: URL, to target: URL) throws {
        let from = source.resolvingSymlinksInPath().path(percentEncoded: false)
        var copied = try Shell.run("/bin/cp", ["-c", "-R", "-L", from, target.path(percentEncoded: false)])
        if !copied.succeeded {
            try? FileManager.default.removeItem(at: target)
            copied = try Shell.run("/bin/cp", ["-R", "-L", from, target.path(percentEncoded: false)])
        }
        guard copied.succeeded else { throw StepFailure(step: step, detail: copied.stderr) }
        scrubDownloadMarkers(at: target)
    }

    static let step = String(localized: "Copy runtime")

    static func clone(
        from install: CrossOverInstall,
        replacingExisting: Bool = false,
        runners: URL = SupportPaths.runners
    ) throws -> RunnerBuild {
        guard case .supported(let build) = install.support else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(install.name) is not a supported build. Supported: \(SupportedRunners.versionList).")
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
            defer { try? fm.removeItem(at: staging) }
            try copyPayload(from: install.crossOverRoot, to: staging)
            try verifyClone(build: build, root: staging.appending(path: "CrossOver"))
            if occupied {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: staging, to: target)
            return build
        }

        let cloned = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        try verifyClone(build: build, root: cloned)

        return build
    }

    static let removeStep = String(localized: "Remove build")

    @discardableResult
    static func removeClone(
        forBuild build: String,
        runners: URL = SupportPaths.runners,
        bridge: URL = SupportPaths.bridge,
        toolList: URL = SupportPaths.toolList,
        compatTools: URL = SupportPaths.Steam.compatTools,
        libraries: [SteamLibrary] = PrefixStore.libraries(),
        running: (URL) -> Bool = { RunnerInstaller.isRunning(from: $0) }
    ) throws -> Bool {
        let target = SupportPaths.runnerRoot(forBuild: build, runners: runners)
        let path = target.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: path) else {
            throw StepFailure(step: removeStep, detail: String(localized: "Build \(build) is not set up."))
        }
        guard !running(target) else {
            throw StepFailure(
                step: removeStep,
                detail: String(localized: "A game or Wine tool is still running on build \(build). Quit it first.")
            )
        }

        let fm = FileManager.default
        let trash = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).removing")
        removeLeftoverRemovals(runners: runners)
        try WriteRefused.catching(path) { try fm.moveItem(at: target, to: trash) }
        let changed: Bool
        do {
            changed = try CompatToolList.sync(
                runners: runners, bridge: bridge, file: toolList, compatTools: compatTools
            )
        } catch {
            try? fm.moveItem(at: trash, to: target)
            throw error
        }
        try WriteRefused.catching(trash) { try fm.removeItem(at: trash) }
        let failures = removeStalePrefixTemplates(runners: runners, libraries: libraries)
        if !failures.isEmpty {
            throw StepFailure(step: removeStep, detail: failures.map(\.detail).joined(separator: "\n"))
        }
        return changed
    }

    static func removeLeftoverRemovals(runners: URL) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: runners, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where (entry.lastPathComponent.hasPrefix(".crossover-")
            || SupportPaths.isWhiskyBuild(String(entry.lastPathComponent.dropFirst().dropLast(".removing".count))))
            && entry.lastPathComponent.hasSuffix(".removing") {
            try? fm.removeItem(at: entry)
        }
    }

    // Also catches templates left on a drive that was not present (unplugged or unmounted)
    // at the time the deployed copy of CrossOver was removed.
    static func removeStalePrefixTemplates(
        runners: URL, libraries: [SteamLibrary], reportBusy: Bool = true
    ) -> [StepFailure] {
        removePrefixTemplates(
            keeping: Set(RunnerStore.clonedBuilds(in: runners)), libraries: libraries, reportBusy: reportBusy)
    }

    static func removePrefixTemplates(
        keeping builds: Set<String>, libraries: [SteamLibrary], reportBusy: Bool = true,
        removingFolder: Bool = false
    ) -> [StepFailure] {
        var failures: [StepFailure] = []
        for library in libraries {
            let earlierFailures = failures.count
            let kept = Set(builds.flatMap {
                SupportPaths.prefixTemplates(forBuild: $0, in: library).map(\.lastPathComponent)
            })
            let folder = library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
            do {
                let parent = open(library.compatdata.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parent >= 0 else {
                    if errno == ENOENT { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                defer { close(parent) }
                var cacheInfo = stat()
                guard fstatat(parent, SupportPaths.prefixTemplateFolder, &cacheInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let lock = openat(parent, ".notproton-template.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { FileLock.release(lock) }
                var lockInfo = stat()
                guard fstat(lock, &lockInfo) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard lockInfo.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                    if errno == EWOULDBLOCK && !reportBusy { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }

                let root = openat(parent, SupportPaths.prefixTemplateFolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard root >= 0 else {
                    if errno == ENOENT { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                defer { close(root) }
                var info = stat()
                guard fstat(root, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }

                for name in try templateDirectoryNames(root) where !kept.contains(name) {
                    let template = name.wholeMatch(of: #/crossover-[A-Za-z0-9.-]+-(x86_64|aarch64)-unix/#) != nil
                    guard template || (builds.isEmpty && name == SupportPaths.bridgeCacheFolder) else { continue }
                    do {
                        try removeTemplateEntry(name, in: root, device: info.st_dev)
                    } catch {
                        failures.append(StepFailure(
                            step: removeStep,
                            detail: String(localized: "Could not remove prefix template \(folder.appending(path: name).path(percentEncoded: false)): \(error.localizedDescription) Refresh to retry.")
                        ))
                    }
                }
                if removingFolder, builds.isEmpty, failures.count == earlierFailures {
                    unlinkat(parent, SupportPaths.prefixTemplateFolder, AT_REMOVEDIR)
                }
            } catch {
                failures.append(StepFailure(
                    step: removeStep,
                    detail: String(localized: "Could not clean prefix templates at \(folder.path(percentEncoded: false)): \(error.localizedDescription) Refresh to retry.")
                ))
            }
        }
        return failures
    }

    private static func templateDirectoryNames(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let directory = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    private static func removeTemplateEntry(_ name: String, in parent: Int32, device: dev_t) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard opened.st_dev == device, opened.st_ino == info.st_ino else { throw POSIXError(.EBUSY) }
            for entry in try templateDirectoryNames(child) {
                try removeTemplateEntry(entry, in: child, device: device)
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    // Wine keeps a wineserver running inside the clone, so a process running from there is a
    // live session.
    static func isRunning(from clone: URL, ps: String = "/bin/ps") -> Bool {
        guard let result = try? Shell.run(ps, ["-axww", "-o", "comm="]), result.succeeded
        else { return true }
        let root = clone.standardizedFileURL.path(percentEncoded: false)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return result.stdout.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }
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
                detail: String(localized: "Copying \(source) failed. \(copied.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
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
        if build.provider == .whisky {
            let runtime = root.deletingLastPathComponent()
            guard RuntimeLayout.hasWine(in: runtime),
                  let metadata = RuntimeMetadata.read(root: runtime),
                  metadata.version == build.version,
                  metadata.name == build.name || metadata.name == RuntimeMetadata.fallbackName,
                  build.patchesNtdll || metadata.loadsSteamClient else {
                throw StepFailure(step: step, detail: String(localized: "The Whisky runtime copy does not match the selected build."))
            }
            try RuntimeSource.verifyPatchInputs(root: runtime, build: build)
            return
        }
        let loader = Clean.copy(of: CrossOverSource.unixLoader(inRoot: root))
        guard let hash = Digest.sha256IfPresent(loader) else {
            throw StepFailure(step: step, detail: String(localized: "The clone has no Wine loader at \(loader.lastPathComponent)."))
        }
        guard hash == build.loaderSHA256 else {
            throw StepFailure(
                step: step,
                detail: String(localized: "The cloned Wine loader at \(loader.lastPathComponent) does not match build \(build.id). Expected \(build.loaderSHA256.prefix(16)), found \(hash.prefix(16)).")
            )
        }

        try CrossOverSource.verifyPatchInputs(root: root, build: build)
    }
}
