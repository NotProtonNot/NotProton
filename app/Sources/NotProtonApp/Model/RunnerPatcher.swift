// Patcher logic

import Foundation

enum RunnerPatcher {

    static let step = String(localized: "Patch the compatibility tool")

    private static let dyldEntitlement = "com.apple.security.cs.allow-dyld-environment-variables"

    private static let libraryEntitlement = "com.apple.security.cs.disable-library-validation"

    static let windowsBuiltins = [
        (arch: "i386-windows", name: "lsteamclient.dll"),
        (arch: "x86_64-windows", name: "lsteamclient.dll"),
    ]

    static func builtins(in root: URL) -> [(arch: String, name: String)] {
        windowsBuiltins + unixArches(in: root).map { (arch: $0, name: "lsteamclient.so") }
    }

    static func unixArches(in root: URL) -> [String] {
        let arches = unixLoaders(in: root).compactMap { loader in
            loader.pathComponents.last { $0.hasSuffix("-unix") }
        }
        let present = ["aarch64-unix", "x86_64-unix"].filter { arches.contains($0) }
        return present.isEmpty ? ["x86_64-unix"] : present
    }

    static func unixArch(in root: URL) -> String {
        unixArches(in: root)[0]
    }

    struct Outcome: Sendable {
        var ntdll: [WineArch] = []
        var builtins: [String] = []
        var loaders: [String] = []
        var graphicsLinks: [String] = []

        var wroteNothing: Bool { ntdll.isEmpty && builtins.isEmpty && loaders.isEmpty && graphicsLinks.isEmpty }
    }

    static func install(
        build: RunnerBuild, root: URL, bridge: URL = SupportPaths.bridge
    ) throws -> Outcome {
        var outcome = Outcome()
        if build.provider == .whisky {
            outcome.graphicsLinks = try WhiskyGraphicsLinks.repair(in: root)
        }
        outcome.ntdll = try installNtdll(build: build, root: root, bridge: bridge)
        outcome.builtins = try installBuiltins(root: root, bridge: bridge)
        outcome.loaders = try grantLoaderEntitlement(root: root)
        return outcome
    }

    static func verify(
        build: RunnerBuild, root: URL, bridge: URL = SupportPaths.bridge
    ) -> [String] {
        var wrong = build.provider == .whisky ? WhiskyGraphicsLinks.verify(in: root) : []
        for arch in WineArch.allCases {
            guard let expected = build.patchedNtdll[arch] else { continue }
            let live = root.appending(path: "lib/wine/\(arch.rawValue)/ntdll.dll")
            guard let actual = Digest.sha256IfPresent(live) else {
                wrong.append(String(localized: "\(arch.rawValue)/ntdll.dll is missing"))
                continue
            }
            if actual != expected {
                wrong.append(String(localized: "\(arch.rawValue)/ntdll.dll is not the patched copy"))
            }
        }
        for builtin in builtins(in: root) {
            let installed = Digest.sha256IfPresent(
                root.appending(path: "lib/wine/\(builtin.arch)/\(builtin.name)"))
            guard let installed else {
                wrong.append(String(localized: "\(builtin.arch)/\(builtin.name) is missing"))
                continue
            }

            let staged = Digest.sha256IfPresent(
                bridge.appending(path: "\(builtin.arch)/\(builtin.name)"))
            if let staged, staged != installed {
                wrong.append(String(localized: "\(builtin.arch)/\(builtin.name) is out of date"))
            }
        }

        for loader in unixLoaders(in: root) {
            let granted = entitlements(of: loader)
            if granted?.contains(restrictedEntitlement) == true {
                if !signatureIsValid(signingTarget(for: loader)) {
                    wrong.append(String(localized: "\(name(of: loader)) has a broken signature"))
                }
            } else {
                if granted?.contains(dyldEntitlement) != true {
                    wrong.append(String(localized: "\(name(of: loader)) is missing the dyld entitlement"))
                }
                if granted?.contains(libraryEntitlement) != true {
                    wrong.append(String(localized: "\(name(of: loader)) is missing the library validation entitlement"))
                }
            }
        }

        return wrong
    }

    private static func installNtdll(
        build: RunnerBuild, root: URL, bridge: URL
    ) throws -> [WineArch] {
        var installed: [WineArch] = []

        for arch in WineArch.allCases {
            guard let expected = build.patchedNtdll[arch] else { continue }
            let staged = NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge)

            guard Digest.sha256IfPresent(staged) == expected else {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "The patched \(arch.rawValue) ntdll has not been copied into place.")
                )
            }

            let live = root.appending(path: "lib/wine/\(arch.rawValue)/ntdll.dll")
            if Digest.sha256IfPresent(live) == expected { continue }

            try keepClean(live)
            try atomicReplace(live, with: Data(contentsOf: staged), step: step)
            installed.append(arch)
        }

        return installed
    }

    private static func installBuiltins(root: URL, bridge: URL) throws -> [String] {
        var installed: [String] = []

        for builtin in builtins(in: root) {
            let source = bridge.appending(path: "\(builtin.arch)/\(builtin.name)")
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "\(builtin.arch)/\(builtin.name) is not in the bridge. Install NotProton first.")
                )
            }

            let destination = root.appending(path: "lib/wine/\(builtin.arch)/\(builtin.name)")
            if Digest.sha256IfPresent(source) == Digest.sha256IfPresent(destination) { continue }

            try atomicReplace(destination, with: Data(contentsOf: source), step: step)
            installed.append("\(builtin.arch)/\(builtin.name)")
        }

        return installed
    }

    private static func grantLoaderEntitlement(root: URL) throws -> [String] {
        var signed: [String] = []

        for loader in unixLoaders(in: root) {
            var existing = entitlements(of: loader)
            if existing?.isEmpty != false,
               FileManager.default.fileExists(atPath: root.deletingLastPathComponent()
                   .appending(path: "WhiskyWineVersion.plist").path(percentEncoded: false)) {
                existing = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict/></plist>"
            }
            if existing?.contains(restrictedEntitlement) == true { continue }
            if existing?.contains(dyldEntitlement) == true,
               existing?.contains(libraryEntitlement) == true,
               signatureIsValid(signingTarget(for: loader)) { continue }

            guard let existing, !existing.isEmpty else {
                throw StepFailure(
                    step: step,
                    detail: String(localized: "\(name(of: loader)) carries no entitlements to extend.")
                )
            }

            do {
                try sign(loader, addingTo: existing)
            } catch {
                restoreClean(loader)
                throw error
            }
            signed.append(name(of: loader))
        }

        return signed
    }

    static func unixLoaders(in root: URL) -> [URL] {
        let fm = FileManager.default
        let wine = root.appending(path: "lib/wine")
        let entries = (try? fm.contentsOfDirectory(at: wine, includingPropertiesForKeys: nil)) ?? []

        let loaders = entries
            .filter { $0.lastPathComponent.hasSuffix("-unix") }
            .flatMap { [$0.appending(path: "wine"), $0.appending(path: "wine.app/Contents/MacOS/wine")] }
            .filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
            .sorted { $0.path < $1.path }
        if loaders.isEmpty,
           fm.fileExists(atPath: root.deletingLastPathComponent().appending(path: "WhiskyWineVersion.plist").path(percentEncoded: false)) {
            let loader = root.appending(path: "bin/wine64")
            return fm.isExecutableFile(atPath: loader.path(percentEncoded: false)) ? [loader] : []
        }
        return loaders
    }

    static func name(of loader: URL) -> String {
        let parts = loader.pathComponents
        guard let arch = parts.lastIndex(where: { $0.hasSuffix("-unix") }) else {
            return loader.lastPathComponent
        }
        return parts[arch...].joined(separator: "/")
    }

    private static func entitlements(of loader: URL) -> String? {
        guard let result = try? Shell.run(
            "/usr/bin/codesign", ["-d", "--entitlements", ":-", loader.path(percentEncoded: false)]
        ), result.status == 0 else { return nil }
        return result.stdout
    }

    private static func sign(_ loader: URL, addingTo existing: String) throws {
        let plist = FileManager.default.temporaryDirectory
            .appending(path: "np-entitlements-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: plist) }

        var granted = try PropertyListSerialization.propertyList(
            from: Data(existing.utf8), format: nil) as? [String: Any] ?? [:]
        granted[dyldEntitlement] = true
        // The ad-hoc loader loads Wine and Steam libraries signed independently.
        // Hardened runtime would otherwise reject them before Wine can start.
        granted[libraryEntitlement] = true
        try PropertyListSerialization.data(fromPropertyList: granted, format: .xml, options: 0)
            .write(to: plist)

        try keepClean(loader)
        let target = signingTarget(for: loader)
        let result = try Shell.run("/usr/bin/codesign", [
            "-f", "-s", "-", "--options", "runtime",
            "--entitlements", plist.path(percentEncoded: false),
            target.path(percentEncoded: false),
        ])
        guard result.status == 0 else {
            throw StepFailure(
                step: step,
                detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }


        guard entitlements(of: loader)?.contains(dyldEntitlement) == true else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(name(of: loader)) was re-signed without the dyld entitlement.")
            )
        }
    }

    private static func signingTarget(for loader: URL) -> URL {
        enclosingBundle(of: loader) ?? loader
    }

    private static func enclosingBundle(of loader: URL) -> URL? {
        var candidate = loader.deletingLastPathComponent()
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension == "app" { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    static let restrictedEntitlement = "com.apple.developer.cross-architecture-support"

    private static func signatureIsValid(_ target: URL) -> Bool {
        guard let result = try? Shell.run(
            "/usr/bin/codesign", ["--verify", "--strict", target.path(percentEncoded: false)]
        ) else { return false }
        return result.status == 0
    }

    static func keepClean(_ file: URL, cp: String = "/bin/cp") throws {
        let backup = Clean.copy(of: file)
        guard backup == file else { return }

        let destination = file.appendingPathExtension(Clean.backupSuffix)
        let staging = file.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).new")
        try? FileManager.default.removeItem(at: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let result = try Shell.run(cp, [
            "-p", file.path(percentEncoded: false), staging.path(percentEncoded: false),
        ])
        guard result.status == 0,
            rename(staging.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0
        else {
            throw StepFailure(
                step: step,
                detail: String(localized: "Keeping the shipped \(file.lastPathComponent) failed. ")
                    + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static func restoreClean(_ file: URL) {
        let backup = file.appendingPathExtension(Clean.backupSuffix)
        guard FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) else { return }
        _ = try? Shell.run("/bin/cp", [
            "-p", backup.path(percentEncoded: false), file.path(percentEncoded: false),
        ])
    }

}
