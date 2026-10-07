import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner runtime requirements")
struct RunnerRuntimeTests {
    @Test("The combined Preview chooses bundled Rosetta when FEX is unavailable")
    func selectsBundledRosetta() throws {
        let source = try #require(SupportedRunners.build(id: "27.0.0.41069-fex"))
        let rosetta = SupportedRunners.runtimeBuild(for: source, fexAvailable: false)
        #expect(rosetta.id == "27.0.0.41069-bundled-rosetta")
        #expect(rosetta.cleanNtdll[.x86_64Windows] != nil)
        #expect(rosetta.cleanNtdll[.aarch64Windows] == nil)
        #expect(SupportedRunners.runtimeBuild(for: source, fexAvailable: true) == source)
    }

    @Test("A distribution without pinned Rosetta inputs is not silently substituted")
    func unknownFallbackIsRefused() throws {
        let source = try #require(SupportedRunners.build(id: "27.0.0.40921-fex"))
        #expect(SupportedRunners.runtimeBuild(for: source, fexAvailable: false) == source)
    }

    @Test("Every runtime profile has a complete patch table")
    func patchTablesCoverAllProfiles() {
        #expect(Set(NtdllPatcher.byBuild.keys) == Set(SupportedRunners.all.map(\.id)))
        for build in SupportedRunners.all {
            #expect(Set(NtdllPatcher.patches(for: build).map(\.arch)) == Set(build.cleanNtdll.keys))
        }
    }

    @Test("The runtime marker selects matching x86 loader, server, prefix and bridge")
    func markerKeepsComponentsTogether() throws {
        let files = FileManager.default
        let root = URL.temporaryDirectory.appending(path: "np-runtime-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        for path in ["lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine",
                     "bin/wineserver-arm64", "lib/wine/x86_64-unix/wine", "bin/wineserver-x86"] {
            let file = root.appending(path: path)
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }
        try "rosetta\n".write(to: root.appending(path: RunnerRuntime.selectionFile),
                               atomically: true, encoding: .utf8)
        let layout = PrefixTools.layout(runner: root)
        #expect(layout.unixDir.lastPathComponent == "x86_64-unix")
        #expect(layout.server.lastPathComponent == "wineserver-x86")
        #expect(PrefixTools.prefixArch(runner: root) == .x86_64)
        #expect(RunnerPatcher.unixArch(in: root) == "x86_64-unix")
        let prefix = WinePrefix(
            appID: "480", name: nil, library: SteamLibrary(root: root), lastUsed: nil)
        #expect(PrefixTools.environment(prefix: prefix, runner: root)["WINEARCH"] == "win64")
    }

    @Test("The Steam launcher reads the same runtime selection as the app")
    func selectionAgreesWithSteamLauncher() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repo.appending(path: "dylib/feats/compat_run.sh"),
                                encoding: .utf8)
        #expect(source.contains("$CX_ROOT/\(RunnerRuntime.selectionFile)"))
        #expect(source.contains(#"[ "$runtime_selection" = rosetta ]"#))
        #expect(source.contains("export WINEARCH=win64"))
    }

    @Test("FEX without the page-size API reports the Rosetta remedy")
    func fexRequiresPageSizeSupport() throws {
        let failure = try #require(throws: StepFailure.self) {
            try RunnerRuntime.requireSupported(usesFEX: true, fexAvailable: false)
        }
        #expect(failure.detail.contains("macOS 26"))
        #expect(failure.detail.contains("Rosetta"))
        #expect(failure.detail.contains("backup"))
    }

    @Test("Rosetta does not require the FEX-only API")
    func rosettaWorksWithoutFexAPI() throws {
        try RunnerRuntime.requireSupported(usesFEX: false, fexAvailable: false)
    }

    @Test("FEX is allowed when the required API exists")
    func fexAllowedOnSupportedOS() throws {
        try RunnerRuntime.requireSupported(usesFEX: true, fexAvailable: true)
    }
}
