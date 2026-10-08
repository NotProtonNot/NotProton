// 'Install' logic for the Steam patch componen

import Foundation
import Darwin

enum InstallPhase: Sendable {
    case checkingPayload
    case stagingBridge
    case preflight
    case stoppingClient
    case copyingDylib
    case installingSignatures
    case installingOverlayShim
    case settingInsert
    case signing
    case registering
    case finished

    var label: String {
        switch self {
        case .checkingPayload: "Preparing"
        case .stagingBridge: "Staging components"
        case .preflight: "Checking Steam"
        case .stoppingClient: "Stopping Steam"
        case .copyingDylib: "Installing"
        case .installingSignatures: "Installing signatures"
        case .installingOverlayShim: "Installing components"
        case .settingInsert: "Configuring Steam"
        case .signing: "Signing"
        case .registering: "Finishing up"
        case .finished: "Done"
        }
    }
}

struct InstallOutcome: Sendable {
    let stoppedClient: Bool
    let version: String
    let build: DeploymentContent.Build
    let signatureDatabases: Int
    let backedUpPlist: Bool
    let bridgeStaged: Int
}

enum SteamInstaller {
    static let step = "Install NotProton"

    typealias ClientStopper = @Sendable (URL, () -> Void) throws -> Bool
    typealias BundleRegistrar = @Sendable (URL) -> Void

    static let stopTheClient: ClientStopper = { app, onStopping in
        try SteamBundle.stopClient(app: app, step: step, onStopping: onStopping)
    }

    static func run(
        payload suppliedPayload: InstallPayload.Located? = nil,
        bridgePayload suppliedBridge: BridgePayload.Located? = nil,
        version: String = AppVersion.bundled,
        app: URL = SupportPaths.Steam.app,
        bridge: URL = SupportPaths.bridge,
        signatures: URL = SupportPaths.signatures,
        overlayShim: URL = SupportPaths.overlayShim,
        iconmaker: URL = SupportPaths.iconmaker,
        appinfo: URL = SupportPaths.appinfo,
        deployedVersion: URL = SupportPaths.deployedVersion,
        backups: URL = SupportPaths.backups,
        compatTools: URL = SupportPaths.Steam.compatTools,
        holdingInstallationLock: Bool = false,
        runnerIsRunning: @Sendable (URL) -> Bool = { RunnerInstaller.isRunning(from: $0) },
        verifyRunner: (RunnerBuild, URL) throws -> Void = RunnerInstaller.verifyClone,
        patchRunner: (RunnerBuild, URL, URL) throws -> Void = { build, root, bridge in
            _ = try NtdllPatcher.stage(build: build, runnerRoot: root, bridge: bridge)
            _ = try RunnerPatcher.install(build: build, root: root, bridge: bridge)
        },
        stopClient: ClientStopper = stopTheClient,
        register: BundleRegistrar = { SteamBundle.register($0) },
        resetInputAccess: () -> Void = resetInputAccess,
        report: @escaping @Sendable (InstallPhase) -> Void = { _ in }
    ) throws -> InstallOutcome {
        report(.checkingPayload)
        let payload = try suppliedPayload ?? InstallPayload.locate()
        let bridgeLocated = try suppliedBridge ?? BridgePayload.locate()

        report(.preflight)
        let plist = app.appending(path: "Contents/Info.plist")
        let dylib = app.appending(path: "Contents/MacOS/\(SupportPaths.dylibName)")
        try assertBundleIsPresent(app)
        try assertInsertIsDeployedOrAbsent(at: plist, dylib: dylib)
        let installationLock = holdingInstallationLock ? -1 : try DeploymentContent.acquireInstallationLock(for: app)
        defer { if installationLock >= 0 { close(installationLock) } }
        guard let dylibHashes = try MachOBuild.hashesIgnoringSignature(of: payload.dylib) else {
            throw StepFailure(step: step, detail: "The bundled NotProton dylib is invalid.")
        }
        let build = DeploymentContent.Build(version: version, builtAt: payload.builtAt,
                                            dylibHashes: dylibHashes)
        let record = DeploymentContent.record(beside: deployedVersion)
        let previousBuild = try DeploymentContent.readBuild(at: record)
        let support = deployedVersion.deletingLastPathComponent()
        let runners = support.appending(path: "runners")
        let tools = CompatToolList.installed(runners: runners, file: support.appending(path: "tools"))
        let files = DeploymentContent.files(
            payload: payload, bridgePayload: bridgeLocated, app: app, bridge: bridge,
            signatures: signatures, overlayShim: overlayShim, iconmaker: iconmaker, appinfo: appinfo,
            compatTools: compatTools, tools: tools, runners: runners)
        let content = try DeploymentContent.inspect(files: files, bundled: build, installed: previousBuild,
                                                   legacyVersion: SteamBundle.deployedVersion(at: deployedVersion))
        guard content != .newerInstalled else {
            throw StepFailure(step: step, detail: "A newer NotProton build is installed. Use that build to update or repair the installed files.")
        }
        func refuseRunningRunners() throws {
            for id in RunnerStore.clonedBuilds(in: runners) where runnerIsRunning(SupportPaths.runnerRoot(forBuild: id, runners: runners)) {
                throw StepFailure(step: step, detail: "A game or Wine tool is running on build \(id). Quit it before updating NotProton.")
            }
        }
        try refuseRunningRunners()
        let builds = RunnerStore.installedBuilds(in: runners)
        for build in builds {
            try verifyRunner(build, SupportPaths.clonedRoot(forBuild: build.id, runners: runners))
        }
        let patching = try needsPatching(plist: plist, dylib: dylib, shipping: payload.dylib, app: app)
        let replacingFiles = try files.contains {
            try !$0.matches() && FileManager.default.fileExists(atPath: $0.destination.path(percentEncoded: false))
        }
        let pinned = try DeploymentContent.pinnedFiles(bridge: bridge, runners: runners)
        let existingAccount = previousBuild != nil || SteamBundle.deployedVersion(at: deployedVersion) != nil
            || pinned.contains { FileManager.default.fileExists(atPath: $0.destination.path(percentEncoded: false)) }
        let replacingPinned = existingAccount && pinned.contains { Digest.sha256IfPresent($0.destination) != $0.hash }

        var stopped = false
        if patching || replacingFiles || replacingPinned {
            stopped = try stopClient(app) { report(.stoppingClient) }
        }
        try refuseRunningRunners()
        _ = try CompatToolList.sync(runners: runners, bridge: bridge,
                                   file: support.appending(path: "tools"), compatTools: compatTools)

        report(.stagingBridge)
        let bridgeResult = try BridgePayload.stage(located: bridgeLocated, bridge: bridge)
        for build in builds {
            try patchRunner(build, SupportPaths.clonedRoot(forBuild: build.id, runners: runners), bridge)
        }

        if patching {
            report(.copyingDylib)
            try install(payload.dylib, at: dylib)
        }

        report(.installingSignatures)
        report(.installingOverlayShim)
        for file in files where file.destination != dylib {
            try installIfChanged(file)
        }

        var backedUp = false
        if patching {
            report(.settingInsert)
            backedUp = try backUpPlist(plist, into: backups)

            let priorPlist = try? Data(contentsOf: plist)
            let priorHash = cdhash(of: app)
            do {
                try setInsert(at: plist, to: dylib)

                report(.signing)
                try adHocSign(dylib)
                try adHocSign(app.appending(path: "Contents/MacOS/steam_osx"))
                try adHocSign(app)
            } catch {
                revertPlist(priorPlist, at: plist, app: app)
                throw error
            }
            if cdhash(of: app) != priorHash {
                resetInputAccess()
            }
        }

        report(.registering)
        register(app)

        let landed = SteamBundle.currentInsert(at: plist)
        guard landed == dylib.path(percentEncoded: false) else {
            AppLog.note("install: bundle declares \(landed ?? "no insert")")
            throw StepFailure(
                step: step,
                detail: "Steam is set up to inject a different dylib. Please repair Steam "
                    + "before installing NotProton."
            )
        }

        let remaining = try files.filter { try !$0.matches() }.map(\.name)
        guard remaining.isEmpty else {
            throw StepFailure(step: step, detail: "These files did not update: \(remaining.joined(separator: ", ")).")
        }

        report(.finished)
        return InstallOutcome(
            stoppedClient: stopped,
            version: version,
            build: build,
            signatureDatabases: payload.signatures.count,
            backedUpPlist: backedUp,
            bridgeStaged: bridgeResult.staged.count
        )
    }

    static func finish(
        _ outcome: InstallOutcome,
        deployedVersion: URL = SupportPaths.deployedVersion,
        isCurrent: (String) -> Bool = { DeploymentContent.current(version: $0) == .current }
    ) throws {
        guard isCurrent(outcome.version) else {
            throw StepFailure(step: step,
                              detail: "Installed content could not be verified. Refresh the Status view for the files that still need attention.")
        }
        try write(outcome.version, to: deployedVersion)
        try atomicReplace(DeploymentContent.record(beside: deployedVersion),
                          with: JSONEncoder().encode(outcome.build), step: step)
    }

    static func installIfChanged(_ file: DeploymentContent.File) throws {
        if try file.matches() { return }
        try install(file.source, at: file.destination)
        if file.executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.destination.path(percentEncoded: false))
        }
    }


    static func assertBundleIsPresent(_ app: URL) throws {
        guard FileManager.default.fileExists(atPath: app.path(percentEncoded: false)) else {
            throw StepFailure(
                step: step,
                detail: "\(app.path(percentEncoded: false)) is not there, so there is nothing to install into."
            )
        }
    }

    static func assertInsertIsDeployedOrAbsent(at plist: URL, dylib: URL) throws {
        guard let insert = SteamBundle.currentInsert(at: plist), !insert.isEmpty else { return }

        let deployed = dylib.path(percentEncoded: false)
        let foreign = insert.split(separator: ":").map(String.init).filter { $0 != deployed }
        guard foreign.isEmpty else {
            throw StepFailure(
                step: step,
                detail: "Another dylib is present. Repair your Steam install before "
                    + "installing NotProton."
            )
        }
    }

    static func needsPatching(plist: URL, dylib: URL, shipping: URL, app: URL) throws -> Bool {
        let deployed = SteamBundle.currentInsert(at: plist) == dylib.path(percentEncoded: false)
            && SteamBundle.currentControllerBlock(at: plist) == SteamBundle.controllerBlockValue
        let file = DeploymentContent.File(source: shipping, destination: dylib, name: "notproton.dylib", allowsResigning: true)
        if deployed, try file.matches() {
            AppLog.note("install: Steam already carries this dylib, installing for this account only")
            return false
        }

        do {
            try assertBundleIsWritable(app)
        } catch let refusal as WriteRefused where refusal.remedy == .otherAccount {
            throw StepFailure(
                step: step,
                detail: deployed ? Self.mismatchAcrossAccounts : Self.unpatchedAcrossAccounts
            )
        }
        return true
    }

    private static let mismatchAcrossAccounts =
        "Steam has a different copy of NotProton, installed by another account on this Mac. "
        + "Update NotProton from that account, then try again."

    private static let unpatchedAcrossAccounts =
        "Steam has not been set up for NotProton, and this account cannot change it. "
        + "Install from the account that owns Steam."

    static func assertBundleIsWritable(_ app: URL) throws {
        let directory = app.appending(path: "Contents/MacOS")
        let probe = directory.appending(path: ".notproton-write-probe")
        do {
            try Data("probe".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw WriteRefused(path: directory.path(percentEncoded: false))
        } catch {
            throw StepFailure(
                step: step,
                detail: "\(directory.path(percentEncoded: false)) could not be written. "
                    + error.localizedDescription
            )
        }
    }

    static func install(_ source: URL, at destination: URL) throws {
        try WriteRefused.catching(destination) {
            try atomicReplace(destination, from: source, step: step)
        }
    }

    static func write(_ version: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("\(version)\n".utf8).write(to: url)
    }

    static func backUpPlist(_ plist: URL, into backups: URL) throws -> Bool {
        let destination = backups.appending(path: SteamBundle.plistBackupName)
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path(percentEncoded: false)) else { return false }
        guard files.fileExists(atPath: plist.path(percentEncoded: false)) else { return false }

        try files.createDirectory(at: backups, withIntermediateDirectories: true)
        try files.copyItem(at: plist, to: destination)
        return true
    }

    static func revertPlist(_ bytes: Data?, at plist: URL, app: URL) {
        guard let bytes else { return }
        try? bytes.write(to: plist)
        try? adHocSign(app)
    }

    static func setInsert(at plist: URL, to dylib: URL) throws {
        guard var dict = SteamBundle.readInfoPlist(at: plist) else {
            throw StepFailure(
                step: step,
                detail: "\(plist.path(percentEncoded: false)) could not be read as a property list."
            )
        }

        var environment = dict[SteamBundle.environmentKey] as? [String: Any] ?? [:]
        environment[SteamBundle.insertKey] = dylib.path(percentEncoded: false)
        environment[SteamBundle.controllerBlockKey] = SteamBundle.controllerBlockValue
        dict[SteamBundle.environmentKey] = environment
        try SteamBundle.writeInfoPlist(dict, at: plist)
    }

    static func adHocSign(_ url: URL, step: String = step) throws {
        let path = url.path(percentEncoded: false)
        var result = try Shell.run("/usr/bin/codesign", ["-f", "-s", "-", path])
        if !result.succeeded && result.stderr.contains("resource fork, Finder information, or similar detritus not allowed") {
            try removeSigningDetritus(at: url, step: step)
            result = try Shell.run("/usr/bin/codesign", ["-f", "-s", "-", path])
        }
        guard result.succeeded else {
            throw StepFailure(
                step: step,
                detail: "\(path) could not be signed. "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // codesign rejects these two Finder attributes. Keep quarantine, provenance
    // and every other attribute; do not use xattr -cr or follow external symlinks.
    static func removeSigningDetritus(at url: URL, step: String = step) throws {
        var targets = [url]
        if let contents = FileManager.default.enumerator(at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            targets += contents.compactMap { $0 as? URL }
        }
        for target in targets {
            if (try target.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { continue }
            for name in ["com.apple.FinderInfo", "com.apple.ResourceFork"] {
                let result = target.path.withCString { path in
                    name.withCString { removexattr(path, $0, XATTR_NOFOLLOW) }
                }
                let errorNumber = errno
                if result != 0 && errorNumber != ENOATTR {
                    throw StepFailure(step: step, detail: "Could not remove signing metadata from \(target.path): "
                        + String(cString: strerror(errorNumber)))
                }
            }
        }
    }

    static func cdhash(of app: URL) -> String? {
        guard let result = try? Shell.run("/usr/bin/codesign", ["-dvvv", app.path(percentEncoded: false)]) else { return nil }
        return (result.stdout + result.stderr).split(separator: "\n")
            .first { $0.hasPrefix("CDHash=") }
            .map { String($0.dropFirst("CDHash=".count)) }
    }

    // macOS does not automatically clear a pre-existing input access approval, so it needs to be cleared
    // or Steam Input will silently not work.
    static let inputAccessServices = ["Accessibility", "PostEvent", "ListenEvent"]

    static func resetInputAccess() {
        for service in failedInputAccessResets() {
            AppLog.note("install: could not reset \(service) for Steam")
        }
    }

    static func failedInputAccessResets() -> [String] {
        inputAccessServices.filter { service in
            let result = try? Shell.run("/usr/bin/tccutil", ["reset", service, "com.valvesoftware.steam"])
            return result?.succeeded != true
        }
    }

}
