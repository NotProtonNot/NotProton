import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner allow list")
struct SupportedRunnerTests {

    // The arches a build carries need both hashes: an input with no output leaves the patch
    // unverified, and an output with no input patches a file nothing had checked.
    @Test("Every row's pin hashes are complete for the arches it claims")
    func rowsAreComplete() {
        #expect(!SupportedRunners.all.isEmpty)

        for build in SupportedRunners.all {
            expectSHA256(build.loaderSHA256, "loader for \(build.id)")
            #expect(!build.cleanNtdll.isEmpty, "\(build.id) patches nothing")
            #expect(Set(build.cleanNtdll.keys) == Set(build.patchedNtdll.keys), "\(build.id) is lopsided")

            for (arch, clean) in build.cleanNtdll {
                let patched = build.patchedNtdll[arch]
                expectSHA256(clean, "clean \(arch.rawValue)")
                expectSHA256(patched ?? "", "patched \(arch.rawValue)")

                // A patch that produced its own input would mean the patcher did
                // nothing, and the launch path would silently run stock ntdll.
                #expect(clean != patched)
            }
        }
    }

    @Test("Identities are unique so lookup is unambiguous")
    func identitiesAreUnique() {
        // Versions are deliberately not unique here: CodeWeavers ships flavors sharing one,
        // which is why neither the lookup key nor the clone directory is the version.
        let ids = SupportedRunners.all.map(\.id)
        #expect(Set(ids).count == ids.count)

        // One combined distribution can have separate FEX and bundled Rosetta
        // patch profiles, but its source lookup must still select one default.
        let sources = SupportedRunners.all.filter { !$0.usesBundledRosetta }
        let loaders = sources.map(\.loaderSHA256)
        #expect(Set(loaders).count == loaders.count)
        for source in sources {
            #expect(SupportedRunners.build(loaderSHA256: source.loaderSHA256) == source)
        }
    }

    @Test("The first supported build keeps a bare version as its id")
    func firstBuildKeepsBareVersionID() {
        // Its clone is already on disk as crossover-<version>, and a machine whose CrossOver
        // has since been replaced by another flavor could not produce that clone again.
        let build = SupportedRunners.all[0]
        #expect(build.flavor == nil)
        #expect(build.id == build.bundleVersion)
    }

    // Picking the FEX CrossOver used to read "Build 27.0.0.40921", the same as the Rosetta one.
    // Which had been picked only became visible once the clone directory carried the flavor.
    @Test("A build is named by its flavor as well as its version")
    func buildsAreNamedByFlavor() {
        let rosetta = try! #require(SupportedRunners.build(id: "27.0.0.40921"))
        let fex = try! #require(SupportedRunners.build(id: "27.0.0.40921-fex"))

        #expect(rosetta.bundleVersion == fex.bundleVersion)
        #expect(rosetta.releaseVersion == fex.releaseVersion)
        #expect(rosetta.displayVersion == "20260821 Rosetta")
        #expect(fex.displayVersion == "20260821 FEX")
        #expect(rosetta.displayVersion != fex.displayVersion)
    }

    // The installed row has only the clone directory name, which is the id.
    @Test("An installed build is named the same way the picked one is")
    func installedBuildsReadBackTheSame() {
        for build in SupportedRunners.all {
            #expect(SupportedRunners.displayVersion(forID: build.id) == build.displayVersion)
            #expect(!SupportedRunners.displayVersion(forID: build.id).contains("-fex"))
        }

        // A tree off the allow list still has to say something, and its directory name is
        // all there is to say.
        #expect(SupportedRunners.displayVersion(forID: "26.0.1.1234") == "26.0.1.1234")
    }

    @Test("Lookup matches on an exact loader hash only")
    func lookupIsExact() {
        let build = SupportedRunners.all[0]
        #expect(SupportedRunners.build(loaderSHA256: build.loaderSHA256) != nil)
        #expect(SupportedRunners.build(loaderSHA256: String(build.loaderSHA256.dropLast())) == nil)
        #expect(SupportedRunners.build(loaderSHA256: build.loaderSHA256 + " ") == nil)
        #expect(SupportedRunners.build(id: build.id) != nil)
        #expect(SupportedRunners.build(id: build.id + " ") == nil)
    }

    private func expectSHA256(_ value: String, _ label: String) {
        #expect(value.count == 64, "\(label) is not a sha256")
        #expect(value.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(label) is not lowercase hex")
    }
}

@Suite("Runner store")
struct RunnerStoreTests {

    @Test("The build comes out of the crossover- path component")
    func buildIdentifierParsing() {
        #expect(RunnerStore.buildIdentifier(
            inPath: "crossover-27.0.0.40921/CrossOver Preview.app/Contents/SharedSupport/CrossOver"
        ) == "27.0.0.40921")

        #expect(RunnerStore.buildIdentifier(
            inPath: "../runners/crossover-1.2.3/CrossOver Preview.app/Contents/SharedSupport/CrossOver"
        ) == "1.2.3")

        #expect(RunnerStore.buildIdentifier(inPath: "CrossOver Preview.app/Contents") == nil)
        #expect(RunnerStore.buildIdentifier(inPath: "") == nil)
    }
}

@Suite("Signature database selection")
struct SignatureSelectionTests {

    @Test("The highest numbered database wins, not the first listed")
    func picksHighestBuild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "np-signature-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["1788400362.json", "999999999.json", "1788400363.json", "notes.txt"] {
            try Data().write(to: directory.appending(path: name))
        }

        #expect(PayloadInspector.newestSignatureDatabase(in: directory) == "1788400363.json")
    }

    @Test("An empty or absent directory reports nothing staged")
    func handlesEmptyDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "np-signature-empty-\(UUID().uuidString)")
        #expect(PayloadInspector.newestSignatureDatabase(in: directory) == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(PayloadInspector.newestSignatureDatabase(in: directory) == nil)
    }
}

@Suite("Support paths")
struct SupportPathTests {

    // These strings are a contract with the dylib and RUN_SCRIPT rather than a
    // preference, so they are pinned here to make a rename visible.
    @Test("Paths match what the dylib and the run script use")
    func pathsAreStable() {
        let support = SupportPaths.support.path(percentEncoded: false)
        #expect(support.hasSuffix("/Library/Application Support/notproton"))

        #expect(SupportPaths.signatures.path(percentEncoded: false)
            .hasSuffix("/notproton/signatures/macos.arm64"))
        #expect(SupportPaths.overlayShim.path(percentEncoded: false)
            .hasSuffix("/notproton/overlay-shim.dylib"))
        #expect(SupportPaths.currentRunner.path(percentEncoded: false)
            .hasSuffix("/notproton/runners/current"))
        #expect(SupportPaths.Steam.deployedDylib.path(percentEncoded: false)
            == "/Applications/Steam.app/Contents/MacOS/notproton.dylib")
        #expect(SupportPaths.Steam.infoPlist.path(percentEncoded: false)
            == "/Applications/Steam.app/Contents/Info.plist")
    }
}
