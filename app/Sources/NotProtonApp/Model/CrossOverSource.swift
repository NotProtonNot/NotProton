// Finds CrossOver installs on disk and checks for support

import Foundation

enum CrossOverSupport: Sendable, Equatable {
    case supported(RunnerBuild)
    case unsupportedBuild(String)
    case unreadable
}

struct CrossOverInstall: Sendable, Identifiable {
    let bundle: URL
    let releaseVersion: String?
    let support: CrossOverSupport

    // Selected by the user rather than found on disk by tool.
    var isManual = false

    // A toolkit directory (relative to the CrossOver root) the runner loads
    // instead of apple_gptk. Nil means the bundle as it is.
    var toolkit: String? = nil

    // The D3DMetal major this install's runner gets, shown on its row.
    var d3dmetal: String? = nil

    var id: String { bundle.path(percentEncoded: false) + (toolkit.map { "#\($0)" } ?? "") }
    var name: String { bundle.deletingPathExtension().lastPathComponent }
    var crossOverRoot: URL { SupportPaths.crossOverRoot(inBundle: bundle) }

    var isPreview: Bool { name.localizedCaseInsensitiveContains("Preview") }

    var isUsable: Bool {
        if case .supported = support { return true }
        return false
    }
}

enum CrossOverSource {

    static let searchRoots: [URL] = [
        URL(filePath: "/Applications", directoryHint: .isDirectory),
        SupportPaths.home.appending(path: "Applications", directoryHint: .isDirectory),
    ]

    private static let manualKey = "manualCrossOverPaths"
    // 1.0/1.0.1 kept a single chosen copy under this key.
    private static let legacyManualKey = "manualCrossOverPath"

    static func manualBundles(_ defaults: UserDefaults = .standard) -> [URL] {
        let paths = defaults.stringArray(forKey: manualKey)
            ?? defaults.string(forKey: legacyManualKey).map { [$0] } ?? []
        return paths.filter { !$0.isEmpty }.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func setManualBundles(_ bundles: [URL], _ defaults: UserDefaults = .standard) {
        defaults.set(bundles.map { $0.path(percentEncoded: false) }, forKey: manualKey)
        defaults.removeObject(forKey: legacyManualKey)
    }

    static func addManualBundle(_ bundle: URL, _ defaults: UserDefaults = .standard) {
        let current = manualBundles(defaults)
        guard !current.contains(where: { same($0, bundle) }) else { return }
        setManualBundles(current + [bundle], defaults)
    }

    static func removeManualBundle(_ bundle: URL, _ defaults: UserDefaults = .standard) {
        setManualBundles(manualBundles(defaults).filter { !same($0, bundle) }, defaults)
    }

    static func isSearched(_ bundle: URL) -> Bool {
        let parent = bundle.standardizedFileURL.deletingLastPathComponent()
        return searchRoots.contains { same($0, parent) }
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path(percentEncoded: false) == b.standardizedFileURL.path(percentEncoded: false)
    }

    // A CrossOver bundle without this directory is bad!
    static func looksLikeCrossOver(_ bundle: URL) -> Bool {
        let root = SupportPaths.crossOverRoot(inBundle: bundle)
        return FileManager.default.fileExists(
            atPath: root.appending(path: "lib/wine").path(percentEncoded: false)
        )
    }

    static func discover() -> [CrossOverInstall] {
        let fm = FileManager.default
        var found: [CrossOverInstall] = []
        var seen: Set<String> = []

        func consider(_ bundle: URL, isManual: Bool) {
            let key = bundle.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(key), looksLikeCrossOver(bundle) else { return }
            seen.insert(key)
            found += inspectAll(bundle: bundle, isManual: isManual)
        }

        for manual in manualBundles() where !isSearched(manual) { consider(manual, isManual: true) }

        for root in searchRoots {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where entry.pathExtension == "app" {
                // Recognised by what it carries, not by its name: copies made by
                // other tools are called whatever those tools call them.
                consider(entry, isManual: false)
            }
        }

        return found.sorted(by: preferred)
    }

    static func preferred(_ a: CrossOverInstall, _ b: CrossOverInstall) -> Bool {
        if a.isManual != b.isManual { return a.isManual }
        if a.isUsable != b.isUsable { return a.isUsable }
        if a.isPreview != b.isPreview { return a.isPreview }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }

    // The bundle as it is, plus one install per other D3DMetal toolkit in it.
    // CrossOver 26 only loads apple_gptk, so another D3DMetal needs another runner.
    static func inspectAll(bundle: URL, isManual: Bool = false) -> [CrossOverInstall] {
        var own = inspect(bundle: bundle, isManual: isManual)
        // The pinned build with this copy's hashes, which differ for a rebuild such as China's.
        guard case .supported(let build) = own.support,
              let base = SupportedRunners.build(id: build.baseID)?.matching(loaderSHA256: build.loaderSHA256)
        else { return [own] }
        own.d3dmetal = RunnerVariant.activeMajor(crossOverRoot: own.crossOverRoot)
        return [own] + RunnerVariant.otherToolkits(crossOverRoot: own.crossOverRoot).map { toolkit in
            let variant = [build.variant, "d3dm\(toolkit.major)"].compactMap { $0 }.joined(separator: "-")
            var install = CrossOverInstall(bundle: bundle, releaseVersion: own.releaseVersion,
                                           support: .supported(base.withVariant(variant)), isManual: isManual)
            install.toolkit = toolkit.path
            install.d3dmetal = toolkit.major
            return install
        }
    }

    static func inspect(bundle: URL, isManual: Bool = false) -> CrossOverInstall {
        guard let version = releaseVersion(of: bundle) else {
            return CrossOverInstall(bundle: bundle, releaseVersion: nil, support: .unreadable, isManual: isManual)
        }
        guard let hash = Digest.sha256IfPresent(unixLoader(inBundle: bundle)) else {
            return CrossOverInstall(
                bundle: bundle, releaseVersion: version, support: .unreadable, isManual: isManual
            )
        }

        guard let build = SupportedRunners.build(loaderSHA256: hash) else {
            return CrossOverInstall(
                bundle: bundle, releaseVersion: version,
                support: .unsupportedBuild(version), isManual: isManual
            )
        }

        let variant = RunnerVariant.declared(crossOverRoot: SupportPaths.crossOverRoot(inBundle: bundle))
        return CrossOverInstall(
            bundle: bundle, releaseVersion: version, support: .supported(build.withVariant(variant)),
            isManual: isManual
        )
    }

    // CrossOver puts the build date here and the version number in
    // CFBundleVersion, so this is the string its download page shows.
    static func releaseVersion(of bundle: URL) -> String? {
        let plist = bundle.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    static func unixLoader(inBundle bundle: URL) -> URL {
        unixLoader(inRoot: SupportPaths.crossOverRoot(inBundle: bundle))
    }

    static func unixLoader(inRoot root: URL) -> URL {
        root.appending(path: "lib/wine/x86_64-unix/wine")
    }

    static func verifyPatchInputs(root: URL, build: RunnerBuild) throws {
        for arch in WineArch.allCases {
            guard let expected = build.cleanNtdll[arch] else { continue }
            let ntdll = NtdllPatcher.cleanSource(inRoot: root, arch: arch)
            guard let actual = Digest.sha256IfPresent(ntdll) else {
                throw StepFailure(
                    step: "Verify CrossOver",
                    detail: "\(arch.rawValue)/ntdll.dll is missing from \(root.path(percentEncoded: false))."
                )
            }
            guard actual == expected else {
                throw StepFailure(
                    step: "Verify CrossOver",
                    detail: "\(arch.rawValue)/\(ntdll.lastPathComponent) is not the build "
                        + "\(build.bundleVersion) copy. Expected \(expected.prefix(16)), "
                        + "found \(actual.prefix(16))."
                )
            }
        }
    }
}
