// Steam app bundle patching component

import Foundation

enum SteamDeployment: Sendable, Equatable {
    case steamMissing
    case notInstalled
    case installed(version: String?)
    case outdated(deployed: String, bundled: String)
    // If the user has something else installed, maybe let's not deploy?
    case foreign(insert: String)
}

// Reading and writing the injection
enum SteamBundle {

    static let insertKey = "DYLD_INSERT_LIBRARIES"
    static let controllerBlockKey = "SDL_JOYSTICK_BLACKLIST_DEVICES"
    static let controllerBlockValue = "0x05ac/0x0004"

    static let plistBackupName = "Info.plist.before-notproton"
    static let environmentKey = "LSEnvironment"

    static var isPresent: Bool {
        FileManager.default.fileExists(atPath: SupportPaths.Steam.app.path(percentEncoded: false))
    }

    static var isRunning: Bool {

        Shell.processIsRunning(named: "steam_osx")
    }

    static func deployment(
        bundledVersion: String,
        app: URL = SupportPaths.Steam.app,
        versionFile: URL = SupportPaths.deployedVersion
    ) -> SteamDeployment {
        let files = FileManager.default
        guard files.fileExists(atPath: app.path(percentEncoded: false)) else { return .steamMissing }

        let plist = SupportPaths.Steam.infoPlist(inBundle: app)
        guard let insert = currentInsert(at: plist), !insert.isEmpty else { return .notInstalled }

        let deployedDylib = SupportPaths.Steam.deployedDylib(inBundle: app)
            .path(percentEncoded: false)
        let components = insert.split(separator: ":").map(String.init)
        guard components.contains(deployedDylib) else { return .foreign(insert: insert) }

        guard files.fileExists(atPath: deployedDylib) else { return .notInstalled }

        guard currentControllerBlock(at: plist) == controllerBlockValue else {
            return .outdated(deployed: deployedVersion(at: versionFile) ?? "", bundled: bundledVersion)
        }

        guard let deployed = deployedVersion(at: versionFile) else { return .installed(version: nil) }
        if deployed == bundledVersion { return .installed(version: deployed) }
        return .outdated(deployed: deployed, bundled: bundledVersion)
    }

    static func currentInsert(at url: URL = SupportPaths.Steam.infoPlist) -> String? {
        guard let dict = readInfoPlist(at: url),
              let environment = dict[environmentKey] as? [String: Any]
        else { return nil }
        return environment[insertKey] as? String
    }

    static func currentControllerBlock(at url: URL = SupportPaths.Steam.infoPlist) -> String? {
        guard let dict = readInfoPlist(at: url),
              let environment = dict[environmentKey] as? [String: Any]
        else { return nil }
        return environment[controllerBlockKey] as? String
    }

    static func deployedVersion(at url: URL = SupportPaths.deployedVersion) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func stopClient(
        app: URL = SupportPaths.Steam.app,
        helpers: [URL] = [SupportPaths.Steam.innerApp],
        step: String,
        onStopping: () -> Void = {}
    ) throws -> Bool {
        guard isRunning else { return false }
        onStopping()

        _ = try? Shell.run("/usr/bin/pkill", ["-x", "steam_osx"])
        for _ in 0..<60 where isRunning {
            Thread.sleep(forTimeInterval: 0.5)
        }

        if isRunning {
            _ = try? Shell.run("/usr/bin/pkill", ["-9", "-x", "steam_osx"])
            Thread.sleep(forTimeInterval: 1)
        }

        guard !isRunning else {
            throw StepFailure(
                step: step,
                detail: L10n.tr("Steam is running, please close Steam.")
            )
        }

        for pattern in sweepPatterns(app: app, helpers: helpers) {
            _ = try? Shell.run("/usr/bin/pkill", ["-f", pattern])
        }
        return true
    }

    static func sweepPatterns(app: URL, helpers: [URL]) -> [String] {
        ([app] + helpers).map { $0.path(percentEncoded: false) + "/" }
    }

    static func register(_ app: URL = SupportPaths.Steam.app) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try? Shell.run(lsregister, ["-f", app.path(percentEncoded: false)])
    }

    static func readInfoPlist(at url: URL = SupportPaths.Steam.infoPlist) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    static func writeInfoPlist(_ dict: [String: Any], at url: URL = SupportPaths.Steam.infoPlist) throws {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let data = try? Data(contentsOf: url) {
            _ = try? PropertyListSerialization.propertyList(from: data, format: &format)
        }

        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
        try WriteRefused.catching(url) { try data.write(to: url, options: .atomic) }
    }
}
