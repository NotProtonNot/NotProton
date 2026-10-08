// Downloads a free WineHQ build and lays it out like a CrossOver bundle, so the
// rest of the runner setup treats it as just another source to clone from.

import Foundation

struct FreeEngineRelease: Sendable {
    let build: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let bundleName: String
    // Path of the Wine tree inside the archive.
    let wineTree: String
    let renderer: RendererRelease
    // sha256 of the winemac.so NotProton ships for this build (winemac-patch/), which
    // exports the macdrv entry points DXMT needs to put Metal into a window.
    let macDriver: String
}

// DXMT replaces Wine's own D3D10/11 and DXGI. Wine's wined3d goes through macOS
// OpenGL 4.1, which tops out below feature level 11 and so fails any Unreal or
// Unity game that needs it, and DXVK pays for a second translation through
// MoltenVK. DXMT goes to Metal directly, the way D3DMetal does, and is MIT licensed.
struct RendererRelease: Sendable {
    let name: String
    let archive: String
    let sha256: String
    let bases: [URL]
    let tree: String
    // arch/file -> sha256 of the file the engine should end up carrying under lib/wine.
    let files: [String: String]
}

enum FreeEngine {

    static let step = "Download free Wine engine"

    // Gcenx's WineHQ packages. 11.15 is the Wine the bridge components are built
    // against (bridge/setup-wine-tree.sh), so the unix halves speak its protocol.
    static let current = FreeEngineRelease(
        build: "winehq-11.15",
        archive: "wine-devel-11.15-osx64.tar.xz",
        sha256: "3f8e89a4874953a69e7be3dcdcc262d0346e462a9374bd116770fffb9e2a99d2",
        bases: [URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.15")!],
        bundleName: "WineHQ 11.15.app",
        wineTree: "Wine Devel.app/Contents/Resources/wine",
        renderer: RendererRelease(
            name: "DXMT 0.80",
            archive: "dxmt-v0.80-builtin.tar.gz",
            sha256: "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
            bases: [URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80")!],
            tree: "v0.80",
            // nvapi64 and nvngx are left out: they only serve DLSS to MetalFX, and an
            // nvapi that answers makes some games take NVIDIA-only paths.
            files: [
                "x86_64-unix/winemetal.so": "3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca",
                "x86_64-windows/d3d10core.dll": "833d26971abc8661efc8b5cc18548c70ce8e482e4ea4b1d3f69a367612264d26",
                "x86_64-windows/d3d11.dll": "7ca382af0eb32d8a432f6efb14d594fefb45673663be1f7e6682254bff885c47",
                "x86_64-windows/dxgi.dll": "fc58aae0aba511a1ec4d2417e5bba6adb888bb14315d0f59cccdfd27f670d544",
                "x86_64-windows/winemetal.dll": "514245d533c750599614311a792c45ed600aef52948571d98c0fc70fd3df16e0",
                "i386-windows/d3d10core.dll": "c5a26310d14a30c3e1700a4d0c9865be28a11351a5c4dc5b83ab1bd8fcf7662f",
                "i386-windows/d3d11.dll": "9afc2b3419818618c4c87274435a28935b0df002caa4b9a8d3a88d3dc846b17d",
                "i386-windows/dxgi.dll": "7df8cdf66e12a108410002abc77b01f70aa59b8a36a70fa0bc6ae3b056841319",
                "i386-windows/winemetal.dll": "20a6865facebdaac92b6c06fadf37d2efb5a242b22ca1c349bb57d7ad43df8e3",
            ]
        ),
        macDriver: "68d1c10cb4ec80beb2e97dcb8df5f81768f4f6e62848932d6bee5270dcf54982"
    )

    static let macDriverPath = "lib/wine/x86_64-unix/winemac.so"

    static var downloads: URL {
        SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/engines")
    }

    static func bundle(for release: FreeEngineRelease = current, engines: URL = SupportPaths.engines) -> URL {
        engines.appending(path: release.bundleName, directoryHint: .isDirectory)
    }

    static func isInstalled(_ release: FreeEngineRelease = current, engines: URL = SupportPaths.engines) -> Bool {
        let install = CrossOverSource.inspect(bundle: bundle(for: release, engines: engines))
        guard case .supported(let build) = install.support, build.id == release.build else { return false }
        return hasRenderer(root: install.crossOverRoot, release: release)
    }

    // An engine unpacked before this renderer was part of it still runs, but D3D11
    // games either fail on it or run slowly.
    static func hasRenderer(root: URL, release: FreeEngineRelease = current) -> Bool {
        release.renderer.files.allSatisfy { path, hash in
            Digest.sha256IfPresent(root.appending(path: "lib/wine/\(path)")) == hash
        } && Digest.sha256IfPresent(root.appending(path: macDriverPath)) == release.macDriver
    }

    // Upstream Wine hides the macdrv functions DXMT looks up, so without this DXMT can
    // create a device but no swapchain, and games abort on their first window.
    static func installMacDriver(root: URL, release: FreeEngineRelease) throws {
        guard let source = Bundle.module.url(forResource: "winemac-\(release.build)", withExtension: "so"),
              Digest.sha256IfPresent(source) == release.macDriver
        else {
            throw StepFailure(step: step, detail: "NotProton is missing its winemac.so for \(release.build).")
        }
        let destination = root.appending(path: macDriverPath)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    enum Phase: Sendable {
        case downloading(PinnedDownload.Progress)
        case unpacking

        var label: String {
            switch self {
            case .downloading(let progress): progress.label
            case .unpacking: "Unpacking Wine"
            }
        }
    }

    static func install(
        _ release: FreeEngineRelease = current,
        engines: URL = SupportPaths.engines,
        report: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> CrossOverInstall {
        let archive = try await PinnedDownload.obtain(
            file: release.archive, sha256: release.sha256, bases: release.bases,
            into: downloads, step: step, source: "GitHub",
            report: { report(.downloading($0)) }
        )
        let renderer = try await PinnedDownload.obtain(
            file: release.renderer.archive, sha256: release.renderer.sha256, bases: release.renderer.bases,
            into: downloads, step: step, source: "GitHub",
            report: { report(.downloading($0)) }
        )
        report(.unpacking)
        return try unpack(archive, renderer: renderer, release: release, engines: engines)
    }

    static func unpack(
        _ archive: URL, renderer: URL?, release: FreeEngineRelease, engines: URL
    ) throws -> CrossOverInstall {
        let fm = FileManager.default
        let target = bundle(for: release, engines: engines)
        let staging = engines.appending(path: ".\(release.bundleName).new", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let extracted = staging.appending(path: "extract", directoryHint: .isDirectory)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try untar(archive, into: extracted)

        let wine = extracted.appending(path: release.wineTree, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: wine.appending(path: "lib/wine").path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: "\(release.archive) has no Wine tree at \(release.wineTree).")
        }

        let shaped = staging.appending(path: release.bundleName, directoryHint: .isDirectory)
        let root = SupportPaths.crossOverRoot(inBundle: shaped)
        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: wine, to: root)

        if let renderer {
            try untar(renderer, into: extracted)
            let tree = extracted.appending(path: release.renderer.tree, directoryHint: .isDirectory)
            for (path, hash) in release.renderer.files.sorted(by: { $0.key < $1.key }) {
                let source = tree.appending(path: path)
                guard Digest.sha256IfPresent(source) == hash else {
                    throw StepFailure(step: step, detail: "\(release.renderer.archive) has no pinned \(path).")
                }
                let destination = root.appending(path: "lib/wine/\(path)")
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: source, to: destination)
            }
            try installMacDriver(root: root, release: release)
        }

        // WineHQ already keeps its unix loader beside the unix libraries, where
        // CrossOver keeps its own, so the Wine tree needs no reshaping inside.
        let info: [String: Any] = [
            "CFBundleIdentifier": "org.winehq.wine.notproton",
            "CFBundleName": release.bundleName.replacingOccurrences(of: ".app", with: ""),
            "CFBundleShortVersionString": release.build.replacingOccurrences(of: "winehq-", with: ""),
            "CFBundleVersion": release.build,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: shaped.appending(path: "Contents/Info.plist"))
        RunnerInstaller.scrubDownloadMarkers(at: shaped)

        let install = CrossOverSource.inspect(bundle: shaped)
        guard case .supported(let build) = install.support, build.id == release.build else {
            throw StepFailure(
                step: step,
                detail: "The unpacked Wine loader is not the \(release.build) build NotProton was made for."
            )
        }

        try fm.createDirectory(at: engines, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path(percentEncoded: false)) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: shaped, to: target)
        return CrossOverSource.inspect(bundle: target)
    }

    private static func untar(_ archive: URL, into directory: URL) throws {
        let result = try Shell.run("/usr/bin/tar", [
            "-xf", archive.path(percentEncoded: false), "-C", directory.path(percentEncoded: false),
        ])
        guard result.status == 0 else {
            throw StepFailure(
                step: step,
                detail: "Unpacking \(archive.lastPathComponent) failed. "
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
