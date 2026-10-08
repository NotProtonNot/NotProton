import Foundation
import Testing

@testable import NotProtonApp

@Suite("Free WineHQ engine")
struct FreeEngineTests {

    private func makeEngines() throws -> URL {
        let engines = FileManager.default.temporaryDirectory
            .appending(path: "np-engines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true)
        return engines
    }

    @Test("The pinned release names a free build NotProton knows how to patch")
    func releaseIsSupported() throws {
        let build = try #require(SupportedRunners.build(id: FreeEngine.current.build))
        #expect(build.isFree)
        #expect(!NtdllPatcher.patches(for: build).isEmpty)
        #expect(SupportedRunners.all.filter(\.isFree).map(\.id) == [FreeEngine.current.build])
    }

    @Test("A CrossOver-shaped tree whose loader is not a free build still needs a license")
    func crossOverKeepsItsLicenseCheck() throws {
        let engines = try makeEngines()
        defer { try? FileManager.default.removeItem(at: engines) }

        let root = engines.appending(path: "Fake.app/Contents/SharedSupport/CrossOver")
        let loader = CrossOverSource.unixLoader(inRoot: root)
        try FileManager.default.createDirectory(
            at: loader.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not wine".utf8).write(to: loader)

        #expect(CrossOverLicense.freeBuild(at: root) == nil)
        #expect(!CrossOverLicense.check(crossOverRoot: root, searchDirs: []).licensed)
    }

    // Runs against the real archive once it has been downloaded, by NotProton or by hand
    // into the cache NotProton uses.
    @Test("Unpacking the real archive yields a supported, license-free, patchable engine")
    func unpacksRealArchive() throws {
        let archive = FreeEngine.downloads.appending(path: FreeEngine.current.archive)
        guard Digest.sha256IfPresent(archive) == FreeEngine.current.sha256 else { return }

        let engines = try makeEngines()
        defer { try? FileManager.default.removeItem(at: engines) }

        let renderer = FreeEngine.downloads.appending(path: FreeEngine.current.renderer.archive)
        let haveRenderer = Digest.sha256IfPresent(renderer) == FreeEngine.current.renderer.sha256
        let install = try FreeEngine.unpack(
            archive, renderer: haveRenderer ? renderer : nil, release: FreeEngine.current, engines: engines
        )
        guard case .supported(let build) = install.support else {
            Issue.record("unpacked engine is \(install.support)")
            return
        }
        #expect(build.id == FreeEngine.current.build)
        #expect(install.isFree)
        #expect(FreeEngine.isInstalled(engines: engines) == haveRenderer)
        #expect(FreeEngine.hasRenderer(root: install.crossOverRoot) == haveRenderer)
        #expect(CrossOverLicense.check(crossOverRoot: install.crossOverRoot).licensed)
        try RunnerInstaller.verifyClone(build: build, root: install.crossOverRoot)

        for patch in NtdllPatcher.patches(for: build) {
            let source = NtdllPatcher.cleanSource(inRoot: install.crossOverRoot, arch: patch.arch)
            let patched = try NtdllPatcher.apply(
                patch, to: try Data(contentsOf: source), payload: try NtdllPatcher.payload(for: patch)
            )
            #expect(Digest.sha256(of: patched) == build.patchedNtdll[patch.arch])
        }
    }
}
