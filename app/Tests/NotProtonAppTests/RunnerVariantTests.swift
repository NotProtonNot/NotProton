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
