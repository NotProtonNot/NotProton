import Foundation
import Testing

@testable import NotProtonApp

// A WhiskyWine runtime root holding only what detection and cloning read, so the
// tests do not need a real 2G runtime. The ntdll bytes are placeholders, so a
// fixture is only supported when it declares the lsteamclient capability or is
// handed a build describing those exact bytes.
enum RuntimeFixture {

    static func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "np-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func make(
        at root: URL,
        name: String? = "winecx-gptk",
        version: (Int, Int, Int) = (4, 7, 54),
        native: Bool = true,
        withPlist: Bool = true,
        withWine: Bool = true,
        extra: [String: Any] = [:]
    ) throws -> URL {
        let fm = FileManager.default
        let wine = root.appending(path: "Wine")

        if withWine {
            for arch in WineArch.allCases {
                let dir = wine.appending(path: "lib/wine/\(arch.rawValue)")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data("ntdll for \(arch.rawValue)".utf8).write(to: dir.appending(path: "ntdll.dll"))
            }
            try executable(wine.appending(path: "lib/wine/x86_64-unix/wine"))
            try executable(wine.appending(path: "bin/wine64"))
            try executable(wine.appending(path: "bin/wineserver"))
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }

        if withPlist {
            var dict: [String: Any] = [
                "version": ["major": version.0, "minor": version.1, "patch": version.2],
                "capabilities": ["lsteamclient": native, "dxvk": true],
            ]
            if let name { dict["name"] = name }
            dict.merge(extra) { _, new in new }
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: root.appending(path: "WhiskyWineVersion.plist"))
        }
        return root
    }

    // A pinned-style build whose clean hashes are the fixture's placeholder bytes.
    static func pinnedBuild(for root: URL, name: String = "winecx-gptk", version: String = "4.7.54") throws -> RunnerBuild {
        var clean: [WineArch: String] = [:]
        for arch in WineArch.allCases {
            clean[arch] = try Digest.sha256(of: RuntimeLayout.ntdll(in: root, arch: arch))
        }
        return RunnerBuild.whisky(name: name, version: version, cleanNtdll: clean, patchedNtdll: [:])
    }

    private static func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }
}
