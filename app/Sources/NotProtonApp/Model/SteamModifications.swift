import Foundation

struct SteamModifications: Sendable {
    let file: URL
    let legacyRecord: URL

    static var shared: Self {
        Self(file: SupportPaths.applicationSupport.appending(path: "notproton-steam-bundles.json"),
             legacyRecord: DeploymentContent.record(beside: SupportPaths.deployedVersion))
    }

    enum State: Equatable {
        case unreachable, absent, clean, modified
    }

    func paths() throws -> [URL] {
        do {
            return try JSONDecoder().decode([String].self, from: Data(contentsOf: file))
                .map { URL(filePath: $0, directoryHint: .notDirectory) }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {}
        if try DeploymentContent.readBuild(at: legacyRecord) != nil {
            return [SupportPaths.Steam.defaultApp]
        }
        return []
    }

    func prepare() throws {
        try write(paths())
    }

    func mark(_ app: URL) throws {
        try write(paths() + [app])
    }

    @discardableResult
    func retireIfClean(_ app: URL) throws -> Bool {
        switch try Self.inspect(app) {
        case .unreachable, .modified: return false
        case .absent, .clean:
            try write(paths().filter { $0.path != app.standardizedFileURL.path })
            return true
        }
    }

    private func write(_ paths: [URL]) throws {
        let paths = Set(paths.map { $0.standardizedFileURL.path }).sorted()
        try atomicReplace(file, with: JSONEncoder().encode(paths), step: Uninstall.step)
    }

    static func inspect(_ app: URL) throws -> State {
        let files = FileManager.default
        do {
            _ = try files.attributesOfItem(atPath: app.path(percentEncoded: false))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
            return SupportPaths.Steam.isUnreachable(app) ? .unreachable : .absent
        }
        let plist = SupportPaths.Steam.infoPlist(inBundle: app)
        let data = try Data(contentsOf: plist)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = value as? [String: Any] else {
            throw StepFailure(step: Uninstall.step,
                              detail: String(localized: "\(plist.path(percentEncoded: false)) could not be read as a property list."))
        }
        let environment = dictionary[SteamBundle.environmentKey] as? [String: Any] ?? [:]
        let insert = environment[SteamBundle.insertKey] as? String ?? ""
        let injected = insert.split(separator: ":").contains {
            URL(filePath: String($0)).lastPathComponent == SupportPaths.dylibName
        }
        let dylib = SupportPaths.Steam.deployedDylib(inBundle: app)
        if injected || environment[SteamBundle.controllerBlockKey] as? String == SteamBundle.controllerBlockValue
            || files.fileExists(atPath: dylib.path(percentEncoded: false)) {
            return .modified
        }
        let signature = try Shell.run("/usr/bin/codesign", ["--verify", "--strict", app.path(percentEncoded: false)])
        return signature.succeeded ? .clean : .modified
    }
}
