import Foundation
import Testing
@testable import NotProtonApp

@Suite("Runner variants")
struct RunnerVariantTests {

    private var pinned: RunnerBuild { SupportedRunners.all[0] }

    @Test("A variant id resolves to the pinned build it copies")
    func parsesVariantID() throws {
        let build = try #require(SupportedRunners.build(id: "\(pinned.id)-patched"))
        #expect(build.baseID == pinned.id)
        #expect(build.variant == "patched")
        #expect(build.loaderSHA256 == pinned.loaderSHA256)
    }

    @Test("Pinned ids resolve as before")
    func pinnedUnchanged() {
        for build in SupportedRunners.all { #expect(SupportedRunners.build(id: build.id) == build) }
    }

    @Test("A variant of a FEX build stays with the FEX build")
    func fexVariant() throws {
        let fex = try #require(SupportedRunners.all.first { $0.flavor == "fex" })
        #expect(SupportedRunners.build(id: "\(fex.id)-patched")?.baseID == fex.id)
    }

    @Test("Other suffixes are not builds")
    func refusesOtherSuffixes() {
        #expect(SupportedRunners.build(id: "\(pinned.id)-") == nil)
        #expect(SupportedRunners.build(id: "\(pinned.id)-Two Words") == nil)
    }

    @Test("A variant has its own tools")
    func ownTools() {
        let variant = pinned.withVariant("patched")
        #expect(variant.tools.map(\.name) == pinned.tools.map { "\($0.name)-patched" })
        #expect(variant.tools.allSatisfy { $0.display.hasSuffix(" · patched") })
        #expect(SupportedRunners.tools(for: [pinned, variant]).map(\.build).contains(variant.id))
    }

    @Test("A copy names itself in its marker; without one it is the build")
    func readsMarker() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "variant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appending(path: RunnerVariant.markerName)
        #expect(RunnerVariant.declared(crossOverRoot: root) == nil)
        try Data("My Copy 2\nignored\n".utf8).write(to: marker)
        #expect(RunnerVariant.declared(crossOverRoot: root) == "mycopy2")
        try Data("FEX\n".utf8).write(to: marker)
        #expect(RunnerVariant.declared(crossOverRoot: root) == nil)
    }

    @Test("A variant is patched with its build's hooks")
    func patchedLikeItsBuild() {
        #expect(!NtdllPatcher.patches(for: pinned).isEmpty)
        #expect(NtdllPatcher.patches(for: pinned.withVariant("patched")).map(\.arch)
                == NtdllPatcher.patches(for: pinned).map(\.arch))
    }
}

@Suite("One runner per toolkit")
struct RunnerToolkitTests {

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "toolkits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func toolkit(_ root: URL, _ path: String, _ version: String) throws {
        let dir = root.appending(path: path)
        let resources = dir.appending(path: "external/D3DMetal.framework/Versions/A/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        (["CFBundleShortVersionString": version] as NSDictionary).write(to: resources.appending(path: "Info.plist"), atomically: true)
        try Data(version.utf8).write(to: dir.appending(path: "version"))
    }

    @Test("Other toolkits are offered once per D3DMetal major apple_gptk lacks")
    func otherToolkits() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try toolkit(root, "lib64/apple_gptk", "4.0b2")
        try toolkit(root, "lib64/apple_gptk_3", "3.0")
        try toolkit(root, "lib64/apple_gptk_3b", "3.1")
        try toolkit(root, "lib64/apple_gptk_4", "4.0")
        let found = RunnerVariant.otherToolkits(crossOverRoot: root)
        #expect(found.map(\.path) == ["lib64/apple_gptk_3"])
        #expect(found.map(\.major) == ["3"])
    }

    @Test("A CrossOver that picks its D3DMetal itself (lib/) gets no extra runners")
    func ignoresLib() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try toolkit(root, "lib/apple_gptk", "4.0b2")
        try toolkit(root, "lib/apple_gptk3", "3.0")
        #expect(RunnerVariant.otherToolkits(crossOverRoot: root).isEmpty)
    }

    @Test("The chosen toolkit replaces apple_gptk in the runner's copy")
    func usesToolkit() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try toolkit(root, "lib/apple_gptk", "4.0")
        try toolkit(root, "lib/apple_gptk3", "3.0")
        try RunnerInstaller.useToolkit("lib/apple_gptk3", in: root)
        #expect(try String(contentsOf: root.appending(path: "lib/apple_gptk/version"), encoding: .utf8) == "3.0")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "lib/apple_gptk3").path(percentEncoded: false)))
    }

    @Test("Toolkit variants resolve and are labelled with their D3DMetal")
    func toolkitIDs() throws {
        let pinned = SupportedRunners.all[0]
        #expect(SupportedRunners.build(id: "\(pinned.id)-d3dm3")?.displayVersion.hasSuffix(" · D3DMetal 3") == true)
        #expect(SupportedRunners.build(id: "\(pinned.id)-patched-d3dm3")?.displayVersion.hasSuffix(" · patched · D3DMetal 3") == true)
    }
}
