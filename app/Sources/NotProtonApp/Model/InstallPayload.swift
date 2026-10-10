// Deploys core NotProton components into the copy of CrossOver that NotProton deploys to the Steam location

import Foundation

enum InstallPayload {
    static let step = L10n.tr("Find NotProton's components")

    struct Located: Sendable {
        let dylib: URL
        let overlayShim: URL
        let iconmaker: URL
        let appinfo: URL
        let run: URL
        let builtAt: Int64

        let signatures: [URL]
    }

    static func root(in bundle: Bundle = AppResources.bundle) throws -> URL {
        guard let url = bundle.url(forResource: "payload", withExtension: nil) else {
            throw StepFailure(
                step: step,
                detail: L10n.tr("This build of NotProton carries no components at all.")
            )
        }
        return url
    }

    static func locate(in bundle: Bundle = AppResources.bundle) throws -> Located {
        try locate(root: try root(in: bundle))
    }

    static func locate(root: URL) throws -> Located {
        let files = FileManager.default

        let dylib = root.appending(path: SupportPaths.dylibName)
        let shim = root.appending(path: "overlay-shim.dylib")
        let iconmaker = root.appending(path: "iconmaker")
        let appinfo = root.appending(path: "appinfo")
        let run = root.appending(path: "run")
        let stamp = try? String(contentsOf: root.appending(path: "build-time"), encoding: .utf8)
        let builtAt = stamp.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        var missing: [String] = []
        if !files.fileExists(atPath: dylib.path(percentEncoded: false)) {
            missing.append(SupportPaths.dylibName)
        }
        if !files.fileExists(atPath: shim.path(percentEncoded: false)) {
            missing.append("overlay-shim.dylib")
        }
        if !files.fileExists(atPath: iconmaker.path(percentEncoded: false)) {
            missing.append("iconmaker")
        }
        if !files.fileExists(atPath: appinfo.path(percentEncoded: false)) {
            missing.append("appinfo")
        }
        if !files.fileExists(atPath: run.path(percentEncoded: false)) { missing.append("run") }
        if (builtAt ?? 0) <= 0 { missing.append("build-time") }

        let signatureDir = root.appending(path: "signatures/macos.arm64")
        let signatures = ((try? files.contentsOfDirectory(
            at: signatureDir, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if signatures.isEmpty { missing.append("signatures/macos.arm64/*.json") }

        guard missing.isEmpty, let builtAt, builtAt > 0 else {
            throw StepFailure(
                step: step,
                detail: L10n.tr("These components are missing: \(missing.joined(separator: ", ")). Run make app-payload and build the app again.")
            )
        }

        return Located(
            dylib: dylib, overlayShim: shim, iconmaker: iconmaker,
            appinfo: appinfo, run: run, builtAt: builtAt, signatures: signatures
        )
    }
}
