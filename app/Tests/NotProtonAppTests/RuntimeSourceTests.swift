import Foundation
import Testing

@testable import NotProtonApp

@Suite("Choosing between installed runtimes")
struct RuntimeSourceTests {

    private func install(
        _ version: String, _ support: RuntimeSupport,
        root: String = "/Runtimes", isManual: Bool = false
    ) -> RuntimeInstall {
        RuntimeInstall(
            root: URL(filePath: "\(root)/winecx-gptk-\(version)"),
            metadata: RuntimeMetadata(name: "winecx-gptk", version: version),
            support: support,
            isManual: isManual
        )
    }

    private func picked(_ installs: [RuntimeInstall]) -> RuntimeInstall? {
        installs.sorted(by: RuntimeSource.preferred).first(where: \.isUsable)
    }

    private static let build = SupportedRunners.whisky[0]

    @Test("The newest usable runtime is chosen")
    func prefersNewest() {
        let older = install("4.7.9", .supported(.native(name: "winecx-gptk", version: "4.7.9")))
        let newer = install("4.7.54", .supported(Self.build))

        // 4.7.9 sorts after 4.7.54 as text, which is the ordering this guards against.
        #expect(picked([older, newer])?.metadata?.version == "4.7.54")
        #expect(picked([newer, older])?.metadata?.version == "4.7.54")
    }

    @Test("An unsupported newer runtime does not shadow a usable older one")
    func skipsUnsupported() {
        let newer = install("4.8.0", .unsupportedBuild("winecx-gptk 4.8.0"))
        let older = install("4.7.54", .supported(Self.build))

        #expect(picked([newer, older])?.metadata?.version == "4.7.54")
    }

    @Test("With no usable runtime, nothing is chosen")
    func nonePickedWhenAllUnusable() {
        #expect(picked([install("4.8.0", .unsupportedBuild("x")), install("4.7.1", .unreadable)]) == nil)
    }

    @Test("The same runtime in two places resolves to the same one every sort")
    func breaksTieByPath() {
        let preview = install("4.7.54", .supported(Self.build), root: "/A")
        let whisky = install("4.7.54", .supported(Self.build), root: "/B")

        #expect(picked([preview, whisky])?.root.path(percentEncoded: false) == "/A/winecx-gptk-4.7.54")
        #expect(picked([whisky, preview])?.root.path(percentEncoded: false) == "/A/winecx-gptk-4.7.54")
    }

    @Test("A runtime the user named is taken over one the search found")
    func prefersNamedRuntime() {
        let found = install("4.7.54", .supported(Self.build))
        let named = install("4.7.1", .supported(.native(name: "winecx-gptk", version: "4.7.1")),
                            root: "/Volumes/Spare", isManual: true)

        #expect(picked([found, named])?.isManual == true)
        #expect(picked([named, found])?.isManual == true)
    }

    @Test("A runtime that loads lsteamclient itself is supported without a pin")
    func nativeRuntimeIsSupported() throws {
        let root = try RuntimeFixture.make(at: RuntimeFixture.scratch("rt-native"), version: (4, 9, 1))
        defer { try? FileManager.default.removeItem(at: root) }

        let found = RuntimeSource.inspect(root: root)
        #expect(found.support == .supported(.native(name: "winecx-gptk", version: "4.9.1")))
        #expect(found.build?.patchesNtdll == false)
        #expect(found.build?.id == "winecx-gptk-4.9.1")
    }

    @Test("A runtime whose ntdll is not a pinned build is refused, not called modified")
    func unknownNtdllIsUnsupported() throws {
        let root = try RuntimeFixture.make(at: RuntimeFixture.scratch("rt-unknown"), native: false)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(RuntimeSource.inspect(root: root).support == .unsupportedBuild("winecx-gptk 4.7.54"))
    }

    @Test("A runtime with no version plist is unreadable")
    func missingPlistIsUnreadable() throws {
        let root = try RuntimeFixture.make(at: RuntimeFixture.scratch("rt-noplist"), withPlist: false)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(RuntimeSource.inspect(root: root).support == .unreadable)
        #expect(!RuntimeSource.looksLikeRuntime(root))
    }

    @Test("An older plist with no name or capabilities still reads")
    func readsMinimalPlist() throws {
        let root = try RuntimeFixture.make(at: RuntimeFixture.scratch("rt-minimal"), name: nil, version: (3, 1, 1))
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata = try #require(RuntimeMetadata.read(root: root))
        #expect(metadata.name == RuntimeMetadata.fallbackName)
        #expect(metadata.version == "3.1.1")
    }

    @Test("The plist's descriptive keys are carried into the metadata")
    func readsDescriptiveKeys() throws {
        let root = try RuntimeFixture.make(
            at: RuntimeFixture.scratch("rt-meta"),
            extra: [
                "wineVersion": "11.0", "releaseChannel": "canary", "gptkCapable": true,
                "dxvkVersion": "1.10.3", "dxmtVersion": "0.80",
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata = try #require(RuntimeMetadata.read(root: root))
        #expect(metadata.wineVersion == "11.0")
        #expect(metadata.releaseChannel == "canary")
        #expect(metadata.dxvkVersion == "1.10.3")
        #expect(metadata.capabilities.isSuperset(of: ["gptk", "dxvk", "lsteamclient"]))
    }

    @Test("Discovery walks Runtimes folders and Libraries, and skips what is not a runtime")
    func discoversRuntimes() throws {
        let base = try RuntimeFixture.scratch("rt-discover")
        defer { try? FileManager.default.removeItem(at: base) }

        let folder = base.appending(path: "Runtimes")
        try RuntimeFixture.make(at: folder.appending(path: "winecx-gptk-4.9.1"), version: (4, 9, 1))
        try RuntimeFixture.make(at: folder.appending(path: "empty"), withWine: false)
        let libraries = try RuntimeFixture.make(at: base.appending(path: "Libraries"), version: (4, 7, 3))

        let found = RuntimeSource.discover(runtimeFolders: [folder], libraries: [libraries], manual: nil)
        #expect(found.map { $0.metadata?.version } == ["4.9.1", "4.7.3"])
        #expect(found.allSatisfy { $0.isUsable })
    }

    @Test("A named runtime is not listed twice when the search finds it too")
    func manualIsNotDuplicated() throws {
        let base = try RuntimeFixture.scratch("rt-dup")
        defer { try? FileManager.default.removeItem(at: base) }

        let folder = base.appending(path: "Runtimes")
        let root = try RuntimeFixture.make(at: folder.appending(path: "winecx-gptk-4.9.1"), version: (4, 9, 1))

        let found = RuntimeSource.discover(runtimeFolders: [folder], libraries: [], manual: root)
        #expect(found.count == 1)
        #expect(found.first?.isManual == true)
    }
}

// The regression: verifyPatchInputs read Wine/lib/wine/<arch>/ntdll.dll directly, which holds
// the patched file on any launched clone, so it reported a mismatch on a runner that was correct.
@Suite("Patch input verification")
struct WhiskyPatchInputTests {

    private static let cleanBytes = Data("clean ntdll".utf8)
    private static let patchedBytes = Data("patched ntdll".utf8)

    private static var build: RunnerBuild {
        RunnerBuild.whisky(
            name: "test", version: "1.0.0",
            cleanNtdll: [.x86_64Windows: Digest.sha256(of: cleanBytes)],
            patchedNtdll: [.x86_64Windows: Digest.sha256(of: patchedBytes)]
        )
    }

    private func makeRoot(live: Data, backup: Data?) throws -> URL {
        let root = try RuntimeFixture.scratch("patch-input")
        let ntdll = RuntimeLayout.ntdll(in: root, arch: .x86_64Windows)
        try FileManager.default.createDirectory(
            at: ntdll.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try live.write(to: ntdll)
        if let backup {
            try backup.write(to: ntdll.appendingPathExtension(Clean.backupSuffix))
        }
        return root
    }

    @Test("A freshly cloned runner verifies")
    func freshCloneVerifies() throws {
        let root = try makeRoot(live: Self.cleanBytes, backup: nil)
        defer { try? FileManager.default.removeItem(at: root) }

        try RuntimeSource.verifyPatchInputs(root: root, build: Self.build)
    }

    @Test("A runner that has been launched verifies through the backup")
    func launchedCloneVerifies() throws {
        let root = try makeRoot(live: Self.patchedBytes, backup: Self.cleanBytes)
        defer { try? FileManager.default.removeItem(at: root) }

        try RuntimeSource.verifyPatchInputs(root: root, build: Self.build)
    }

    @Test("A patched file with no backup beside it is refused")
    func patchedWithoutBackupIsRefused() throws {
        let root = try makeRoot(live: Self.patchedBytes, backup: nil)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: StepFailure.self) {
            try RuntimeSource.verifyPatchInputs(root: root, build: Self.build)
        }
    }

    @Test("A missing ntdll is refused")
    func missingIsRefused() throws {
        let root = try RuntimeFixture.scratch("patch-input-missing")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: StepFailure.self) {
            try RuntimeSource.verifyPatchInputs(root: root, build: Self.build)
        }
    }

    @Test("A runtime that loads lsteamclient itself has nothing to verify")
    func nativeHasNoInputs() throws {
        let root = try RuntimeFixture.scratch("patch-input-native")
        defer { try? FileManager.default.removeItem(at: root) }

        try RuntimeSource.verifyPatchInputs(root: root, build: .native(name: "x", version: "1.0.0"))
    }
}
