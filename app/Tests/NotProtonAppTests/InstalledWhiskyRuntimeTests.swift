import Foundation
import Testing

@testable import NotProtonApp

// Read installed runtimes, writing patched files only to a disposable bridge.
@Suite("Installed Whisky runtime patches")
struct InstalledWhiskyRuntimeTests {
    static let roots: [URL] = RuntimeSource.candidates().filter { root in
        guard let metadata = RuntimeMetadata.read(root: root) else { return false }
        return SupportedRunners.whisky.contains {
            $0.version == metadata.version && ($0.name == metadata.name || metadata.name == RuntimeMetadata.fallbackName)
        }
    }

    @Test("Discovery and Swift patching reproduce the independently built hashes", arguments: InstalledWhiskyRuntimeTests.roots)
    func reproduce(root: URL) throws {
        let install = RuntimeSource.inspect(root: root)
        let build = try #require(install.build, "Installed runtime must be recognized: \(root.path)")
        try RuntimeSource.verifyPatchInputs(root: root, build: build)
        let bridge = try RuntimeFixture.scratch("installed-whisky-patches")
        defer { try? FileManager.default.removeItem(at: bridge) }
        let wine = RuntimeLayout.wine(in: root)
        let before = Dictionary(uniqueKeysWithValues: try build.cleanNtdll.keys.map {
            ($0, try Digest.sha256(of: NtdllPatcher.cleanSource(inRoot: wine, arch: $0)))
        })
        let staged = try NtdllPatcher.stage(build: build, runnerRoot: wine, bridge: bridge)
        #expect(Set(staged) == Set(build.patchedNtdll.keys))
        for (arch, expected) in build.patchedNtdll {
            #expect(Digest.sha256IfPresent(NtdllPatcher.stagedCopy(of: arch, build: build.id, in: bridge)) == expected)
            #expect(try Digest.sha256(of: NtdllPatcher.cleanSource(inRoot: wine, arch: arch)) == before[arch])
        }
    }

    @Test("A modified copy of a pinned runtime stays unsupported", arguments: InstalledWhiskyRuntimeTests.roots)
    func rejectModified(root: URL) throws {
        let metadata = try #require(RuntimeMetadata.read(root: root))
        let install = RuntimeSource.inspect(root: root)
        let build = try #require(install.build)
        let copy = try RuntimeFixture.make(at: RuntimeFixture.scratch("modified-whisky"), name: metadata.name, native: false)
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.removeItem(at: copy.appending(path: "WhiskyWineVersion.plist"))
        try FileManager.default.copyItem(at: root.appending(path: "WhiskyWineVersion.plist"),
                                        to: copy.appending(path: "WhiskyWineVersion.plist"))
        for arch in build.cleanNtdll.keys {
            let source = NtdllPatcher.cleanSource(inRoot: RuntimeLayout.wine(in: root), arch: arch)
            try Data(contentsOf: source).write(to: RuntimeLayout.ntdll(in: copy, arch: arch))
        }
        #expect(RuntimeSource.inspect(root: copy).build?.id == build.id)
        let x64 = RuntimeLayout.ntdll(in: copy, arch: .x86_64Windows)
        var bytes = try Data(contentsOf: x64)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: x64)
        #expect(!RuntimeSource.inspect(root: copy).isUsable)
        #expect(throws: StepFailure.self) {
            try RuntimeSource.verifyPatchInputs(root: copy, build: build)
        }
    }
}
