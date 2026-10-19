// Finds WhiskyWine runtimes on disk and checks for support

import Foundation

// What WhiskyWineVersion.plist says about a runtime. Older runtimes carry only
// the version and the DXVK/DXMT versions, so everything else is optional.
struct RuntimeMetadata: Sendable, Equatable {
    var name: String
    var version: String
    var wineVersion: String?
    var releaseChannel: String?
    var patchset: String?
    var gptkVersion: String?
    var dxvkVersion: String?
    var dxmtVersion: String?
    var capabilities: Set<String> = []

    // A runtime whose own loader redirects steamclient to lsteamclient, so its
    // ntdll is left as shipped.
    var loadsSteamClient: Bool { capabilities.contains("lsteamclient") }

    static let fallbackName = "WhiskyWine"

    static func read(root: URL) -> RuntimeMetadata? {
        guard let dict = plist(at: RuntimeLayout.versionPlist(in: root)),
              let version = dict["version"] as? [String: Any],
              let major = version["major"] as? Int,
              let minor = version["minor"] as? Int,
              let patch = version["patch"] as? Int,
              major >= 0, minor >= 0, patch >= 0
        else { return nil }

        let name = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        guard name.wholeMatch(of: #/[A-Za-z][A-Za-z0-9.-]*/#) != nil,
              !name.hasPrefix("crossover-"), "notproton-whisky-\(name)-\(major).\(minor).\(patch)".utf8.count < 64 else { return nil }
        var capabilities: Set<String> = []
        if dict["gptkCapable"] as? Bool == true { capabilities.insert("gptk") }
        for (key, value) in dict["capabilities"] as? [String: Any] ?? [:] where value as? Bool == true {
            capabilities.insert(key)
        }

        return RuntimeMetadata(
            name: name,
            version: "\(major).\(minor).\(patch)",
            wineVersion: dict["wineVersion"] as? String,
            releaseChannel: dict["releaseChannel"] as? String,
            patchset: dict["patchset"] as? String,
            gptkVersion: plist(at: RuntimeLayout.gptkDeployment(in: root))?["gptkVersion"] as? String,
            dxvkVersion: dict["dxvkVersion"] as? String,
            dxmtVersion: dict["dxmtVersion"] as? String,
            capabilities: capabilities
        )
    }

    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return object as? [String: Any]
    }
}

enum RuntimeSupport: Sendable, Equatable {
    case supported(RunnerBuild)
    case unsupportedBuild(String)
    case unreadable
}

struct RuntimeInstall: Sendable, Identifiable {
    let root: URL
    let metadata: RuntimeMetadata?
    let support: RuntimeSupport

    // Selected by the user rather than found on disk by tool.
    var isManual = false

    var id: String { root.path(percentEncoded: false) }

    var name: String {
        metadata.map { "\($0.name) \($0.version)" } ?? root.lastPathComponent
    }

    var isUsable: Bool {
        if case .supported = support { return true }
        return false
    }

    var build: RunnerBuild? {
        if case .supported(let build) = support { return build }
        return nil
    }

    // The app that downloaded it, for display.
    var owner: String? {
        let path = root.path(percentEncoded: false)
        if path.contains("/com.dappermint.WhiskyPreview/") { return "WhiskyPreview" }
        if path.contains("/com.isaacmarovitz.Whisky/") || path.contains("/com.franke.Whisky/") {
            return "Whisky"
        }
        return nil
    }
}

enum RuntimeSource {

    private static let manualKey = "manualRuntimePath"

    static var manualRoot: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: manualKey), !path.isEmpty else { return nil }
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        set { UserDefaults.standard.set(newValue?.path(percentEncoded: false), forKey: manualKey) }
    }

    static func looksLikeRuntime(_ root: URL) -> Bool {
        RuntimeLayout.hasWine(in: root)
            && FileManager.default.fileExists(
                atPath: RuntimeLayout.versionPlist(in: root).path(percentEncoded: false)
            )
    }

    static func candidates(
        runtimeFolders: [URL] = SupportPaths.whiskyRuntimeFolders,
        libraries: [URL] = SupportPaths.whiskyLibraries
    ) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for folder in runtimeFolders {
            let entries = (try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            found += entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return found + libraries
    }

    static func discover(
        runtimeFolders: [URL] = SupportPaths.whiskyRuntimeFolders,
        libraries: [URL] = SupportPaths.whiskyLibraries,
        manual: URL? = RuntimeSource.manualRoot
    ) -> [RuntimeInstall] {
        var found: [RuntimeInstall] = []
        var seen: Set<String> = []

        func consider(_ root: URL, isManual: Bool) {
            let key = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
            guard !seen.contains(key), looksLikeRuntime(root) else { return }
            seen.insert(key)
            found.append(inspect(root: root, isManual: isManual))
        }

        if let manual { consider(manual, isManual: true) }
        for root in candidates(runtimeFolders: runtimeFolders, libraries: libraries) {
            consider(root, isManual: false)
        }

        return found.sorted(by: preferred)
    }

    static func preferred(_ a: RuntimeInstall, _ b: RuntimeInstall) -> Bool {
        if a.isManual != b.isManual { return a.isManual }
        if a.isUsable != b.isUsable { return a.isUsable }
        let av = a.metadata?.version ?? "", bv = b.metadata?.version ?? ""
        if av != bv { return av.compare(bv, options: .numeric) == .orderedDescending }
        return a.id < b.id
    }

    static func inspect(root: URL, isManual: Bool = false) -> RuntimeInstall {
        guard let metadata = RuntimeMetadata.read(root: root) else {
            return RuntimeInstall(root: root, metadata: nil, support: .unreadable, isManual: isManual)
        }
        return RuntimeInstall(
            root: root, metadata: metadata, support: support(of: root, metadata: metadata), isManual: isManual
        )
    }

    static func support(of root: URL, metadata: RuntimeMetadata) -> RuntimeSupport {
        guard RuntimeLayout.hasWine(in: root) else { return .unreadable }
        if metadata.loadsSteamClient {
            return .supported(.native(name: metadata.name, version: metadata.version))
        }

        let ntdll = Clean.copy(of: RuntimeLayout.ntdll(in: root, arch: .x86_64Windows))
        guard let hash = Digest.sha256IfPresent(ntdll) else { return .unreadable }
        guard let build = SupportedRunners.build(cleanNtdllSHA256: hash) else {
            return .unsupportedBuild("\(metadata.name) \(metadata.version)")
        }
        guard metadata.version == build.version,
              metadata.name == build.name || metadata.name == RuntimeMetadata.fallbackName else {
            return .unsupportedBuild("\(metadata.name) \(metadata.version)")
        }
        return .supported(build)
    }

    static func verifyPatchInputs(root: URL, build: RunnerBuild) throws {
        for arch in WineArch.allCases {
            guard let expected = build.cleanNtdll[arch] else { continue }
            let ntdll = Clean.copy(of: RuntimeLayout.ntdll(in: root, arch: arch))
            guard let actual = Digest.sha256IfPresent(ntdll) else {
                throw StepFailure(
                    step: String(localized: "Verify runtime"),
                    detail: String(localized: "\(arch.rawValue)/ntdll.dll is missing from \(root.path(percentEncoded: false)).")
                )
            }
            guard actual == expected else {
                throw StepFailure(
                    step: String(localized: "Verify runtime"),
                    detail: String(localized: "\(arch.rawValue)/\(ntdll.lastPathComponent) is not the build \(build.id) copy. Expected \(expected.prefix(16)), found \(actual.prefix(16)).")
                )
            }
        }
    }
}
