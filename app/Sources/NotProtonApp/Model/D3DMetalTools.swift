// Tools for managing D3DMetal libraries and clearing shader cache.
// Handles updating D3DMetal from Apple's Game Porting Toolkit evaluation environment
// and clearing $(getconf DARWIN_USER_CACHE_DIR)/d3dm/<game>/shaders.cache.

import Darwin
import Foundation

enum D3DMetalTools: Sendable {

    public struct UpdateOutcome: Sendable, Equatable {
        public let runnerRoot: URL
        public let sourceURL: URL
        public let metalFXPrepared: Bool
        public let prefixesUpdated: Int
        public let shaderCachesCleared: Int
    }

    public struct DiscoveredSource: Sendable, Equatable {
        public let url: URL
        public let version: String
        public let isMountedVolume: Bool
    }

    /// Reads the D3DMetal version string from the runner's D3DMetal.framework.
    public static func d3dMetalVersion(forBuild buildID: String) -> String? {
        let runnerRoot = SupportPaths.clonedRoot(forBuild: buildID)
        return d3dMetalVersion(runnerRoot: runnerRoot)
    }

    /// Reads the D3DMetal version string from a library directory (containing external/ and wine/).
    public static func d3dMetalVersion(atLibRoot libRoot: URL) -> String? {
        let plistURL = libRoot
            .appending(path: "external/D3DMetal.framework/Versions/A/Resources/version.plist")
        let altPlistURL = libRoot
            .appending(path: "external/D3DMetal.framework/Versions/A/Resources/Info.plist")
        let flatPlistURL = libRoot
            .appending(path: "external/D3DMetal.framework/Resources/version.plist")
        for url in [plistURL, altPlistURL, flatPlistURL] {
            guard let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String) else {
                continue
            }
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Reads the D3DMetal version string from the given runner root.
    public static func d3dMetalVersion(runnerRoot: URL) -> String? {
        if let ver = d3dMetalVersion(atLibRoot: runnerRoot.appending(path: "lib64/apple_gptk")) {
            return ver
        }
        return d3dMetalVersion(atLibRoot: runnerRoot.appending(path: "lib/apple_gptk"))
    }

    /// Extracts a version string from a filename like "Evaluation environment for Windows games 4.0 beta 3.dmg"
    public static func versionFromFilename(_ filename: String) -> String? {
        let pattern = #"(\d+(?:\.\d+)*(?:\s*(?:beta|b)\s*\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
              let range = Range(match.range(at: 1), in: filename) else {
            return nil
        }
        var ver = String(filename[range])
        // Normalize "4.0 beta 3" -> "4.0b3"
        ver = ver.replacingOccurrences(of: #"\s*beta\s*"#, with: "b", options: .regularExpression)
        return ver.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Discovers all available Evaluation Environment sources currently mounted in /Volumes
    /// (including nested DMGs inside mounted volumes like /Volumes/Game Porting Toolkit),
    /// sorted by newest version first.
    /// Fast and non-blocking — never spawns subprocesses during view rendering.
    public static func discoverSources() -> [DiscoveredSource] {
        var found: [DiscoveredSource] = []
        let fm = FileManager.default
        let volumesURL = URL(filePath: "/Volumes")

        guard let volumes = try? fm.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: nil) else {
            return []
        }

        // 1. Check directly mounted D3DMetal volumes (fastest and most accurate)
        for vol in volumes {
            guard let source = locateSource(in: vol) else { continue }
            let ver = d3dMetalVersion(atLibRoot: source) ?? "Latest"
            found.append(DiscoveredSource(url: source, version: ver, isMountedVolume: true))
        }

        // 2. Check for nested Evaluation environment DMGs inside mounted volumes (e.g. /Volumes/Game Porting Toolkit/*.dmg)
        var seenVersions = Set(found.map(\.version))
        for vol in volumes {
            if vol.lastPathComponent == "Macintosh HD" || locateSource(in: vol) != nil { continue }
            guard let entries = try? fm.contentsOfDirectory(at: vol, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension.lowercased() == "dmg" {
                let name = entry.lastPathComponent
                if name.localizedCaseInsensitiveContains("evaluation") ||
                   name.localizedCaseInsensitiveContains("porting") ||
                   name.localizedCaseInsensitiveContains("gptk") {
                    let ver = versionFromFilename(name) ?? "Latest"
                    if !seenVersions.contains(ver) {
                        seenVersions.insert(ver)
                        found.append(DiscoveredSource(url: entry, version: ver, isMountedVolume: false))
                    }
                }
            }
        }

        // Sort descending by version (e.g. 4.0b3 > 3.0)
        found.sort { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        return found
    }

    /// Automatically discovers any mounted Evaluation Environment volume in /Volumes,
    /// or checks for an Evaluation environment DMG in common directories and attaches it.
    public static func discoverSource() -> DiscoveredSource? {
        discoverSources().first
    }

    /// Directory where alternate D3DMetal versions are saved for 1-click switching.
    public static func versionsCacheDirectory(runnerRoot: URL) -> URL {
        runnerRoot.appending(path: "lib64/apple_gptk_versions")
    }

    /// Returns all valid cached D3DMetal versions stored on disk for this runner, sorted ascending.
    public static func cachedVersions(forBuild buildID: String) -> [String] {
        let runnerRoot = SupportPaths.clonedRoot(forBuild: buildID)
        let dir = versionsCacheDirectory(runnerRoot: runnerRoot)
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { entry in
                !entry.lastPathComponent.hasPrefix(".") && locateSource(in: entry) != nil
            }
            .map(\.lastPathComponent)
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Saves the current libraries into the local version cache.
    public static func cacheCurrentVersion(runnerRoot: URL) {
        guard let currentVer = d3dMetalVersion(runnerRoot: runnerRoot) else { return }
        let currentTarget = runnerRoot.appending(path: "lib64/apple_gptk")
        let cacheTarget = versionsCacheDirectory(runnerRoot: runnerRoot).appending(path: currentVer)
        let fm = FileManager.default

        // If cache directory exists but is incomplete or damaged, remove it
        if fm.fileExists(atPath: cacheTarget.path(percentEncoded: false)) {
            if locateSource(in: cacheTarget) != nil {
                return
            }
            try? fm.removeItem(at: cacheTarget)
        }

        try? fm.createDirectory(at: cacheTarget, withIntermediateDirectories: true)
        let result = try? Shell.run("/usr/bin/ditto", [
            currentTarget.path(percentEncoded: false),
            cacheTarget.path(percentEncoded: false)
        ])
        if result?.succeeded != true {
            try? fm.removeItem(at: cacheTarget)
        }
    }

    /// Switches the runner to a previously cached D3DMetal version.
    public static func switchToCachedVersion(
        _ version: String,
        forBuild buildID: String,
        prefixes: [WinePrefix] = PrefixStore.all()
    ) throws -> UpdateOutcome {
        let step = String(localized: "Switch D3DMetal")
        let runnerRoot = SupportPaths.clonedRoot(forBuild: buildID)
        if RunnerInstaller.isRunning(from: runnerRoot) {
            throw StepFailure(
                step: step,
                detail: String(localized: "Quit running Windows applications before changing D3DMetal versions.")
            )
        }
        let cached = versionsCacheDirectory(runnerRoot: runnerRoot).appending(path: version)
        guard FileManager.default.fileExists(atPath: cached.path(percentEncoded: false)),
              locateSource(in: cached) != nil else {
            throw StepFailure(step: step, detail: String(localized: "Cached version \(version) not found or corrupted."))
        }
        return try update(runnerRoot: runnerRoot, from: cached, prefixes: prefixes)
    }

    /// Reads the stock D3DMetal version string from an installed CrossOver bundle.
    public static func stockD3DMetalVersion(for install: CrossOverInstall?) -> String? {
        guard let bundle = install?.bundle else { return nil }
        let root = SupportPaths.crossOverRoot(inBundle: bundle)
        return d3dMetalVersion(runnerRoot: root)
    }

    /// Returns true if the runner's D3DMetal version differs from the stock CrossOver bundle's version.
    public static func canRestoreStock(forBuild buildID: String, install: CrossOverInstall?) -> Bool {
        guard let install, let stockVer = stockD3DMetalVersion(for: install) else { return false }
        let currentVer = d3dMetalVersion(forBuild: buildID)
        return currentVer != stockVer
    }

    /// Restores stock D3DMetal from the CrossOver bundle to the runner.
    public static func restoreStock(forBuild buildID: String, install: CrossOverInstall) throws {
        let runnerRoot = SupportPaths.clonedRoot(forBuild: buildID)
        let stockGptk = SupportPaths.crossOverRoot(inBundle: install.bundle).appending(path: "lib64/apple_gptk")
        _ = try update(runnerRoot: runnerRoot, from: stockGptk)
    }

    /// Returns Darwin's per-user cache directory under which D3DMetal creates its cache,
    /// usually /var/folders/.../C/d3dm.
    static func cacheDirectory() -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard len > 0 else { return nil }

        let path: String?
        if len > buffer.count {
            var dynamicBuffer = [CChar](repeating: 0, count: len)
            _ = confstr(_CS_DARWIN_USER_CACHE_DIR, &dynamicBuffer, len)
            path = dynamicBuffer.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) }
            }
        } else {
            path = buffer.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) }
            }
        }

        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(filePath: trimmed).appending(path: "d3dm")
    }

    /// Finds candidate game executable names for a given Wine prefix.
    /// Traverses up to 3 levels deep in the game's install directory to capture
    /// executables located inside nested folders (e.g. bin/x64/ or Binaries/Win64/).
    static func candidateExecutableNames(for prefix: WinePrefix) -> Set<String> {
        var names = Set<String>()
        if let name = prefix.name {
            names.insert(name.lowercased())
            names.insert("\(name).exe".lowercased())
        }
        names.insert(prefix.title.lowercased())
        names.insert("\(prefix.title).exe".lowercased())
        names.insert(prefix.appID)
        names.insert("\(prefix.appID).exe")

        if let installDir = PrefixStore.installDirectory(of: prefix) {
            names.insert(installDir.lastPathComponent.lowercased())
            names.insert("\(installDir.lastPathComponent).exe".lowercased())

            let fm = FileManager.default
            if let enumerator = fm.enumerator(
                at: installDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if enumerator.level > 3 {
                        enumerator.skipDescendants()
                        continue
                    }
                    if fileURL.pathExtension.lowercased() == "exe" {
                        names.insert(fileURL.lastPathComponent.lowercased())
                    }
                }
            }
        }
        return names
    }

    /// Clears the D3DMetal shader cache for a specific prefix, or all caches if prefix is nil.
    /// Returns the number of game caches cleared.
    @discardableResult
    static func clearShaderCache(for prefix: WinePrefix? = nil, cacheDir: URL? = cacheDirectory()) throws -> Int {
        guard let dir = cacheDir, FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else {
            return 0
        }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard !entries.isEmpty else { return 0 }

        let targets: [URL]
        if let prefix {
            let candidates = candidateExecutableNames(for: prefix)
            targets = entries.filter { entry in
                let name = entry.lastPathComponent.lowercased()
                let base = name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
                return candidates.contains(name) || candidates.contains(base)
            }
        } else {
            targets = entries
        }

        var cleared = 0
        for target in targets {
            guard fm.fileExists(atPath: target.path(percentEncoded: false)) else { continue }
            try fm.removeItem(at: target)
            cleared += 1
        }
        return cleared
    }

    /// Clears all D3DMetal shader caches in the system.
    @discardableResult
    static func clearAllShaderCaches(cacheDir: URL? = cacheDirectory()) throws -> Int {
        try clearShaderCache(for: nil, cacheDir: cacheDir)
    }

    /// Locates the `external` and `wine` directory source in a user-provided URL
    /// (e.g. mounted evaluation environment DMG volume, redist/lib folder, etc.)
    static func locateSource(in url: URL) -> URL? {
        let fm = FileManager.default
        func isD3DMetalSource(_ dir: URL) -> Bool {
            let external = dir.appending(path: "external")
            let wine = dir.appending(path: "wine")
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: external.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue &&
                   fm.fileExists(atPath: wine.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
        }

        if isD3DMetalSource(url) { return url }

        let redistLib = url.appending(path: "redist/lib")
        if isD3DMetalSource(redistLib) { return redistLib }

        let lib = url.appending(path: "lib")
        if isD3DMetalSource(lib) { return lib }

        return nil
    }

    /// Resolves a source URL whether it points to a mounted directory, an unmounted .dmg file,
    /// or a directory/volume containing a nested Evaluation environment .dmg.
    public static func resolveSource(at url: URL, maxDepth: Int = 2) -> URL? {
        guard maxDepth >= 0 else { return nil }

        if url.pathExtension.lowercased() == "dmg" {
            let attach = try? Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", url.path(percentEncoded: false)])
            if attach?.succeeded == true {
                let volumesURL = URL(filePath: "/Volumes")
                if let volumes = try? FileManager.default.contentsOfDirectory(at: volumesURL, includingPropertiesForKeys: nil) {
                    for vol in volumes {
                        if let src = locateSource(in: vol) {
                            return src
                        }
                    }
                    // If no volume directly contained external/wine, check mounted volumes for nested DMGs
                    for vol in volumes {
                        if vol.lastPathComponent == "Macintosh HD" { continue }
                        if let contents = try? FileManager.default.contentsOfDirectory(at: vol, includingPropertiesForKeys: nil) {
                            for nested in contents where nested.pathExtension.lowercased() == "dmg" {
                                if let src = resolveSource(at: nested, maxDepth: maxDepth - 1) {
                                    return src
                                }
                            }
                        }
                    }
                }
            }
        }

        if let direct = locateSource(in: url) {
            return direct
        }

        // If the URL is a directory or mounted volume containing a nested DMG
        if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            let dmgs = contents.filter { $0.pathExtension.lowercased() == "dmg" }
            for dmg in dmgs where dmg.lastPathComponent.localizedCaseInsensitiveContains("evaluation") ||
                                  dmg.lastPathComponent.localizedCaseInsensitiveContains("porting") ||
                                  dmg.lastPathComponent.localizedCaseInsensitiveContains("gptk") {
                if let nested = resolveSource(at: dmg, maxDepth: maxDepth - 1) {
                    return nested
                }
            }
            for dmg in dmgs {
                if let nested = resolveSource(at: dmg, maxDepth: maxDepth - 1) {
                    return nested
                }
            }
        }

        return nil
    }

    /// Updates D3DMetal in a runner root from the evaluation environment distribution.
    /// Also handles MetalFX integration prep (renaming nvngx-on-metalfx to nvngx and copying
    /// to prefix system32 directories if provided).
    @discardableResult
    static func update(
        runnerRoot: URL,
        from source: URL,
        prefixes: [WinePrefix] = [],
        cacheDir: URL? = cacheDirectory()
    ) throws -> UpdateOutcome {
        let step = String(localized: "Update D3DMetal")
        if RunnerInstaller.isRunning(from: runnerRoot) {
            throw StepFailure(
                step: step,
                detail: String(localized: "Quit running Windows applications before changing D3DMetal versions.")
            )
        }

        guard let d3dmSource = resolveSource(at: source) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(source.lastPathComponent) does not contain D3DMetal libraries (expected external and wine folders).")
            )
        }

        let target = runnerRoot.appending(path: "lib64/apple_gptk")
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path(percentEncoded: false)) {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }

        // Cache current version for instant 1-click switching later
        cacheCurrentVersion(runnerRoot: runnerRoot)

        // 1. Back up existing libraries
        let ext = target.appending(path: "external")
        let extOld = target.appending(path: "external.old")
        if fm.fileExists(atPath: ext.path(percentEncoded: false)) {
            try? fm.removeItem(at: extOld)
            try fm.moveItem(at: ext, to: extOld)
        }

        let wine = target.appending(path: "wine")
        let wineOld = target.appending(path: "wine.old")
        if fm.fileExists(atPath: wine.path(percentEncoded: false)) {
            try? fm.removeItem(at: wineOld)
            try fm.moveItem(at: wine, to: wineOld)
        }

        // 2. Copy new external and wine folders atomically
        do {
            try fm.copyItem(at: d3dmSource.appending(path: "external"), to: ext)
            try fm.copyItem(at: d3dmSource.appending(path: "wine"), to: wine)
        } catch {
            // Restore backups if copy failed
            try? fm.removeItem(at: ext)
            try? fm.removeItem(at: wine)
            if fm.fileExists(atPath: extOld.path(percentEncoded: false)) {
                try? fm.moveItem(at: extOld, to: ext)
            }
            if fm.fileExists(atPath: wineOld.path(percentEncoded: false)) {
                try? fm.moveItem(at: wineOld, to: wine)
            }
            throw StepFailure(step: step, detail: error.localizedDescription)
        }

        // Clean up backups on success to keep disk usage tidy
        try? fm.removeItem(at: extOld)
        try? fm.removeItem(at: wineOld)

        // Cache newly installed version
        cacheCurrentVersion(runnerRoot: runnerRoot)

        // 3. Prepare MetalFX integration
        var metalFXPrepared = false
        let unixDir = wine.appending(path: "x86_64-unix")
        let nvngxUnixSrc = unixDir.appending(path: "nvngx-on-metalfx.so")
        let nvngxUnixDst = unixDir.appending(path: "nvngx.so")
        if fm.fileExists(atPath: nvngxUnixSrc.path(percentEncoded: false)) {
            try? fm.removeItem(at: nvngxUnixDst)
            try? fm.copyItem(at: nvngxUnixSrc, to: nvngxUnixDst)
            metalFXPrepared = true
        } else if fm.fileExists(atPath: nvngxUnixDst.path(percentEncoded: false)) {
            metalFXPrepared = true
        }

        let winDir = wine.appending(path: "x86_64-windows")
        let nvngxWinSrc = winDir.appending(path: "nvngx-on-metalfx.dll")
        let nvngxWinDst = winDir.appending(path: "nvngx.dll")
        if fm.fileExists(atPath: nvngxWinSrc.path(percentEncoded: false)) {
            try? fm.removeItem(at: nvngxWinDst)
            try? fm.copyItem(at: nvngxWinSrc, to: nvngxWinDst)
            metalFXPrepared = true
        } else if fm.fileExists(atPath: nvngxWinDst.path(percentEncoded: false)) {
            metalFXPrepared = true
        }

        // 4. Deploy nvngx.dll and nvapi64.dll to prefix system32 directories
        var prefixesUpdated = 0
        let nvapi64Dll = winDir.appending(path: "nvapi64.dll")
        for prefix in prefixes {
            let system32 = prefix.pfx.appending(path: "drive_c/windows/system32")
            guard fm.fileExists(atPath: system32.path(percentEncoded: false)) else { continue }
            var updatedAny = false
            if fm.fileExists(atPath: nvngxWinDst.path(percentEncoded: false)) {
                let dest = system32.appending(path: "nvngx.dll")
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: nvngxWinDst, to: dest)
                updatedAny = true
            }
            if fm.fileExists(atPath: nvapi64Dll.path(percentEncoded: false)) {
                let dest = system32.appending(path: "nvapi64.dll")
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: nvapi64Dll, to: dest)
                updatedAny = true
            }
            if updatedAny { prefixesUpdated += 1 }
        }

        // 5. Invalidate shader cache
        let cleared = (try? clearAllShaderCaches(cacheDir: cacheDir)) ?? 0

        return UpdateOutcome(
            runnerRoot: runnerRoot,
            sourceURL: d3dmSource,
            metalFXPrepared: metalFXPrepared,
            prefixesUpdated: prefixesUpdated,
            shaderCachesCleared: cleared
        )
    }

    public struct D3DMetalVariant: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let label: String
        public let src: URL
        public let version: String?
        public let confURL: URL

        public init(name: String, label: String, src: URL, version: String?, confURL: URL) {
            self.name = name
            self.label = label
            self.src = src
            self.version = version
            self.confURL = confURL
        }
    }

    /// Installs D3DMetal as a runner variant (variants/<name>.conf) conforming to NotProton's variant grammar.
    @discardableResult
    public static func installVariant(
        from source: URL,
        name: String? = nil,
        label: String? = nil,
        supportDir: URL = SupportPaths.support,
        cacheDir: URL? = cacheDirectory()
    ) throws -> D3DMetalVariant {
        let step = String(localized: "Install D3DMetal Variant")
        guard let d3dmSource = resolveSource(at: source) else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(source.lastPathComponent) does not contain D3DMetal libraries (expected external and wine folders).")
            )
        }

        let ver = d3dMetalVersion(atLibRoot: d3dmSource) ?? versionFromFilename(source.lastPathComponent) ?? "custom"
        let variantName: String
        if let customName = name, !customName.isEmpty {
            variantName = customName
        } else {
            variantName = "d3dmetal-\(ver)"
        }

        let variantsDir = supportDir.appending(path: "variants")
        let fm = FileManager.default
        if !fm.fileExists(atPath: variantsDir.path(percentEncoded: false)) {
            try fm.createDirectory(at: variantsDir, withIntermediateDirectories: true)
        }

        let targetDir = variantsDir.appending(path: variantName)
        let extDst = targetDir.appending(path: "external")
        let wineDst = targetDir.appending(path: "wine")

        try? fm.removeItem(at: targetDir)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try fm.copyItem(at: d3dmSource.appending(path: "external"), to: extDst)
        try fm.copyItem(at: d3dmSource.appending(path: "wine"), to: wineDst)

        // Prepare MetalFX integration if nvngx.dll not present
        let winDir = wineDst.appending(path: "x86_64-windows")
        let nvngxWinSrc = winDir.appending(path: "nvngx-on-metalfx.dll")
        let nvngxWinDst = winDir.appending(path: "nvngx.dll")
        if fm.fileExists(atPath: nvngxWinSrc.path(percentEncoded: false)) && !fm.fileExists(atPath: nvngxWinDst.path(percentEncoded: false)) {
            try? fm.copyItem(at: nvngxWinSrc, to: nvngxWinDst)
        }

        let unixDir = wineDst.appending(path: "x86_64-unix")
        let nvngxUnixSrc = unixDir.appending(path: "nvngx-on-metalfx.so")
        let nvngxUnixDst = unixDir.appending(path: "nvngx.so")
        if fm.fileExists(atPath: nvngxUnixSrc.path(percentEncoded: false)) && !fm.fileExists(atPath: nvngxUnixDst.path(percentEncoded: false)) {
            try? fm.copyItem(at: nvngxUnixSrc, to: nvngxUnixDst)
        }

        let confURL = variantsDir.appending(path: "\(variantName).conf")
        let displayLabel = label ?? "D3DMetal \(ver)"
        let confContent = """
        # Written by NotProton. The runner is assembled from src at launch.
        [\(variantName)]
        variant = D3DMetal
        src     = variants/\(variantName)
        dst     = lib64/apple_gptk
        label   = \(displayLabel)

        """
        try confContent.write(to: confURL, atomically: true, encoding: .utf8)

        // Invalidate shader cache
        _ = try? clearAllShaderCaches(cacheDir: cacheDir)

        return D3DMetalVariant(
            name: variantName,
            label: displayLabel,
            src: targetDir,
            version: ver,
            confURL: confURL
        )
    }

    /// Lists all installed D3DMetal variants in the variants directory.
    public static func installedVariants(supportDir: URL = SupportPaths.support) -> [D3DMetalVariant] {
        let variantsDir = supportDir.appending(path: "variants")
        guard let files = try? FileManager.default.contentsOfDirectory(at: variantsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var variants: [D3DMetalVariant] = []
        for file in files where file.pathExtension == "conf" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: .newlines)
            var currentID: String?
            var currentLabel: String?
            var currentSrc: String?
            var currentDst: String?
            var currentGroup: String?

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    currentID = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("variant") && trimmed.contains("=") {
                    currentGroup = trimmed.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("label") && trimmed.contains("=") {
                    currentLabel = trimmed.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("src") && trimmed.contains("=") {
                    currentSrc = trimmed.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("dst") && trimmed.contains("=") {
                    currentDst = trimmed.split(separator: "=", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                }
            }

            guard let id = currentID, (currentGroup == "D3DMetal" || currentDst?.contains("apple_gptk") == true) else {
                continue
            }

            let srcURL: URL
            if let src = currentSrc {
                if src.hasPrefix("/") {
                    srcURL = URL(filePath: src)
                } else if src.hasPrefix("~/") {
                    srcURL = URL(filePath: NSString(string: src).expandingTildeInPath)
                } else {
                    srcURL = supportDir.appending(path: src)
                }
            } else {
                srcURL = variantsDir.appending(path: id)
            }

            let ver = d3dMetalVersion(atLibRoot: srcURL)
            variants.append(D3DMetalVariant(
                name: id,
                label: currentLabel ?? id,
                src: srcURL,
                version: ver,
                confURL: file
            ))
        }

        return variants.sorted { $0.name < $1.name }
    }

    /// Removes a D3DMetal variant descriptor, its tree (if located in variants dir), and any assembled runners.
    public static func removeVariant(
        name: String,
        supportDir: URL = SupportPaths.support,
        runners: URL = SupportPaths.runners
    ) throws {
        let fm = FileManager.default
        let variantsDir = supportDir.appending(path: "variants")
        let confURL = variantsDir.appending(path: "\(name).conf")
        let targetDir = variantsDir.appending(path: name)

        if fm.fileExists(atPath: confURL.path(percentEncoded: false)) {
            try? fm.removeItem(at: confURL)
        }
        if fm.fileExists(atPath: targetDir.path(percentEncoded: false)) {
            try? fm.removeItem(at: targetDir)
        }

        // Remove any runners assembled with this variant: crossover-<build>+<name>...
        if let entries = try? fm.contentsOfDirectory(at: runners, includingPropertiesForKeys: nil) {
            for entry in entries {
                let filename = entry.lastPathComponent
                if filename.contains("+\(name)") {
                    try? fm.removeItem(at: entry)
                }
            }
        }
    }
}
