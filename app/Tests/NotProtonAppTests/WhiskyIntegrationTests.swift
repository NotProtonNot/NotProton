import Foundation
import Testing

@testable import NotProtonApp

@Suite("Whisky and CrossOver integration")
struct WhiskyIntegrationTests {
    private let fm = FileManager.default

    @Test("Both providers keep distinct runner paths and Whisky is the default tool")
    func mixedProviders() throws {
        let base = try RuntimeFixture.scratch("mixed-runtimes")
        defer { try? fm.removeItem(at: base) }
        let runners = base.appending(path: "runners")
        let source = try RuntimeFixture.make(at: base.appending(path: "source"), version: (4, 9, 1))
        let whisky = try RunnerInstaller.clone(from: RuntimeSource.inspect(root: source), runners: runners)
        let crossOver = SupportedRunners.crossOver[0]
        let cxRoot = SupportPaths.clonedRoot(forBuild: crossOver.id, runners: runners)
        try fm.createDirectory(at: cxRoot.appending(path: "lib/wine"), withIntermediateDirectories: true)
        let builds = RunnerStore.installedBuilds(in: runners)
        #expect(Set(builds.map(\.id)) == [whisky.id, crossOver.id])
        #expect(cxRoot.path.hasSuffix("crossover-\(crossOver.id)/CrossOver"))
        #expect(SupportPaths.clonedRoot(forBuild: whisky.id, runners: runners).path.hasSuffix("\(whisky.id)/Wine"))
        let tools = SupportedRunners.tools(for: builds)
        #expect(tools.first?.build == whisky.id)
        #expect(tools.contains { $0.name == crossOver.tools[0].name })
        #expect(NtdllPatcher.patches(for: whisky).isEmpty)
        #expect(try Data(contentsOf: RuntimeLayout.ntdll(in: source, arch: .x86_64Windows))
            == Data("ntdll for x86_64-windows".utf8))
        try Data("changed clone".utf8).write(to: SupportPaths.clonedRoot(forBuild: whisky.id, runners: runners)
            .appending(path: "lib/wine/x86_64-windows/ntdll.dll"))
        #expect(try Data(contentsOf: RuntimeLayout.ntdll(in: source, arch: .x86_64Windows))
            == Data("ntdll for x86_64-windows".utf8))
    }

    @Test("The newest native Whisky version sorts first and CrossOver's legacy name stays owned")
    func preferenceAndLegacy() {
        let older = RunnerBuild.native(name: "winecx-gptk", version: "4.9.2")
        let newer = RunnerBuild.native(name: "winecx-gptk", version: "4.9.10")
        let cx = SupportedRunners.crossOver.first { $0.id == "27.0.0.40921" }!
        let tools = SupportedRunners.tools(for: [older, cx, newer], legacy: .build(cx.id))
        #expect(tools.first?.build == newer.id)
        let renamed = RunnerBuild.native(name: "aaa-whisky", version: "4.10.0")
        #expect(SupportedRunners.tools(for: [older, renamed]).first?.build == renamed.id)
        #expect(tools.first { $0.name == "notproton" }?.build == cx.id)
        #expect(SupportedRunners.tools(for: [cx]).map(\.name) == cx.tools.map(\.name))
    }

    @Test("An explicit CrossOver selection survives Whisky becoming the default")
    func explicitSelection() throws {
        let base = try RuntimeFixture.scratch("runtime-selection")
        defer { try? fm.removeItem(at: base) }
        let cx = SupportedRunners.crossOver[0]
        let tools = SupportedRunners.tools(for: [.native(name: "winecx-gptk", version: "4.9.1"), cx])
        let prefix = WinePrefix(appID: "123", name: "Game", library: SteamLibrary(root: base), lastUsed: nil)
        try fm.createDirectory(at: prefix.root, withIntermediateDirectories: true)
        try Data("\(cx.id)\n\(cx.tools[0].display)\n".utf8).write(to: prefix.root.appending(path: "notproton-build"))
        #expect(PrefixTools.tool(for: prefix, among: tools)?.build == cx.id)
    }

    @Test("Preparing Whisky never checks a CrossOver license and preserves the legacy symlink")
    func prepareWithoutLicense() throws {
        let base = try RuntimeFixture.scratch("prepare-whisky")
        defer { try? fm.removeItem(at: base) }
        let runners = base.appending(path: "runners")
        let source = try RuntimeFixture.make(at: base.appending(path: "source"), version: (4, 9, 1))
        let build = try RunnerInstaller.clone(from: RuntimeSource.inspect(root: source), runners: runners)
        let compat = base.appending(path: "tools")
        let oldTool = compat.appending(path: "notproton")
        try fm.createDirectory(at: oldTool, withIntermediateDirectories: true)
        let script = oldTool.appending(path: "run")
        try Data("#!/bin/sh\n# /runners/current\n".utf8).write(to: script)
        let current = runners.appending(path: "current")
        try fm.createSymbolicLink(atPath: current.path, withDestinationPath: build.id)
        let result = try RunnerSetup.prepare(build, runners: runners, bridge: base.appending(path: "bridge"),
            toolList: base.appending(path: "list"), compatTools: compat, runScript: { script },
            license: { _ in Issue.record("Whisky must not request a CrossOver license")
                return CrossOverLicense.Status(licensed: false, detail: "test", diagnostic: "test") },
            stage: { build, _, _ in
                #expect(NtdllPatcher.patches(for: build).isEmpty)
                return []
            }, patch: { _, _, _ in RunnerPatcher.Outcome() })
        #expect(result.toolsChanged)
        #expect(try fm.destinationOfSymbolicLink(atPath: current.path) == build.id)
        #expect(try String(contentsOf: base.appending(path: "list"), encoding: .utf8)
            .contains("notproton\t\(build.id)\trosetta\t"))
    }

    @Test("Removing Whisky leaves the source and CrossOver clone intact")
    func removeOnlyWhisky() throws {
        let base = try RuntimeFixture.scratch("remove-whisky")
        defer { try? fm.removeItem(at: base) }
        let runners = base.appending(path: "runners")
        let source = try RuntimeFixture.make(at: base.appending(path: "source"), version: (4, 9, 1))
        let build = try RunnerInstaller.clone(from: RuntimeSource.inspect(root: source), runners: runners)
        let cx = SupportedRunners.crossOver[0]
        let cxRoot = SupportPaths.clonedRoot(forBuild: cx.id, runners: runners)
        try fm.createDirectory(at: cxRoot.appending(path: "lib/wine"), withIntermediateDirectories: true)
        _ = try RunnerInstaller.removeClone(forBuild: build.id, runners: runners,
            bridge: base.appending(path: "bridge"), toolList: base.appending(path: "list"),
            compatTools: base.appending(path: "tools"), libraries: [], running: { _ in false })
        #expect(RuntimeLayout.hasWine(in: source))
        #expect(RunnerInstaller.hasClone(forBuild: cx.id, runners: runners))
        #expect(!RunnerInstaller.hasClone(forBuild: build.id, runners: runners))
    }

    @Test("A failed replacement preserves the existing Whisky clone")
    func failedReplacement() throws {
        let base = try RuntimeFixture.scratch("replace-whisky")
        defer { try? fm.removeItem(at: base) }
        let runners = base.appending(path: "runners")
        let source = try RuntimeFixture.make(at: base.appending(path: "source"), version: (4, 9, 1))
        let install = RuntimeSource.inspect(root: source)
        let build = try RunnerInstaller.clone(from: install, runners: runners)
        try fm.removeItem(at: source.appending(path: "WhiskyWineVersion.plist"))
        #expect(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, replacingExisting: true, runners: runners)
        }
        #expect(RunnerInstaller.hasClone(forBuild: build.id, runners: runners))
        #expect(!fm.fileExists(atPath: runners.appending(path: ".\(build.id).new").path))
    }

    @Test("Whisky prefix tools use the Wine root and steamuser without CrossOver's environment")
    func prefixEnvironment() throws {
        let base = try RuntimeFixture.scratch("whisky-tools")
        defer { try? fm.removeItem(at: base) }
        let runtime = try RuntimeFixture.make(at: base.appending(path: "runtime"))
        let prefix = WinePrefix(appID: "123", name: "Game", library: SteamLibrary(root: base), lastUsed: nil)
        let environment = PrefixTools.environment(prefix: prefix, runner: runtime.appending(path: "Wine"), flavor: .rosetta)
        #expect(environment["CX_ROOT"] == nil)
        #expect(environment["CX_HOME"] == nil)
        #expect(environment["WINEUSERNAME"] == "steamuser")
        #expect(environment["WINELOADER"]?.hasSuffix("Wine/lib/wine/x86_64-unix/wine") == true)
    }

    @Test("A symlinked Wine directory is copied without modifying its source")
    func linkedWineIsIsolated() throws {
        let base = try RuntimeFixture.scratch("linked-whisky")
        defer { try? fm.removeItem(at: base) }
        let source = try RuntimeFixture.make(at: base.appending(path: "source"), version: (4, 9, 1))
        let linked = base.appending(path: "linked")
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        try fm.copyItem(at: source.appending(path: "WhiskyWineVersion.plist"),
                        to: linked.appending(path: "WhiskyWineVersion.plist"))
        try fm.createSymbolicLink(at: linked.appending(path: "Wine"), withDestinationURL: source.appending(path: "Wine"))
        let runners = base.appending(path: "runners")
        let build = try RunnerInstaller.clone(from: RuntimeSource.inspect(root: linked), runners: runners)
        let clone = SupportPaths.clonedRoot(forBuild: build.id, runners: runners)
        #expect(try clone.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        try Data("clone".utf8).write(to: clone.appending(path: "lib/wine/x86_64-windows/ntdll.dll"))
        #expect(try Data(contentsOf: RuntimeLayout.ntdll(in: source, arch: .x86_64Windows))
            == Data("ntdll for x86_64-windows".utf8))
    }

    @Test("A native runtime bypasses detours even if its version has pinned patches")
    func nativePinnedVersion() {
        let build = RunnerBuild.native(name: "winecx-gptk", version: "4.7.54")
        #expect(NtdllPatcher.byBuild[build.id]?.isEmpty == false)
        #expect(NtdllPatcher.patches(for: build).isEmpty)
    }

    @Test("The Whisky prototype keeps its legacy compatibility tool name during migration")
    func legacyWhiskyTool() throws {
        let base = try RuntimeFixture.scratch("legacy-whisky")
        defer { try? fm.removeItem(at: base) }
        let build = RunnerBuild.native(name: "winecx-gptk", version: "4.9.1")
        let runners = base.appending(path: "runners")
        try fm.createDirectory(at: runners, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: runners.appending(path: "current").path, withDestinationPath: build.id)
        let holder = CompatToolList.legacyHolder(builds: [build], listed: nil, runners: runners)
        #expect(holder == .build(build.id))
        #expect(SupportedRunners.tools(for: [build], legacy: holder).first?.name == "notproton")
    }

    @Test("A runtime with a bin-only loader still receives signing and layout checks")
    func binOnlyLoader() throws {
        let base = try RuntimeFixture.scratch("bin-only-whisky")
        defer { try? fm.removeItem(at: base) }
        let runtime = try RuntimeFixture.make(at: base.appending(path: "runtime"))
        try fm.removeItem(at: runtime.appending(path: "Wine/lib/wine/x86_64-unix/wine"))
        let wine = runtime.appending(path: "Wine")
        #expect(RunnerPatcher.unixLoaders(in: wine) == [wine.appending(path: "bin/wine64")])
        #expect(PrefixTools.loader(runner: wine, flavor: .rosetta) == wine.appending(path: "bin/wine64"))
    }

    @Test("Malformed or oversized metadata cannot create paths or tools")
    func unsafeMetadata() throws {
        let base = try RuntimeFixture.scratch("unsafe-whisky")
        defer { try? fm.removeItem(at: base) }
        for name in ["../escape", "bad\tname", "crossover-27.0", String(repeating: "x", count: 70)] {
            let root = try RuntimeFixture.make(at: base.appending(path: UUID().uuidString), name: name)
            #expect(RuntimeMetadata.read(root: root) == nil)
            #expect(!RuntimeSource.inspect(root: root).isUsable)
        }
    }
}
