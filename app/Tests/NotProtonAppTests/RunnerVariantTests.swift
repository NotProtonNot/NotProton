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
        try Data("\(String(repeating: "a", count: 40))\n".utf8).write(to: marker)
        #expect(RunnerVariant.declared(crossOverRoot: root) == String(repeating: "a", count: RunnerVariant.maxLength))
    }

    @Test("The longest variant of every build still fits the dylib's tool fields")
    func fitsToolList() {
        // compat.c: name[64], build[64], display[96], each with its terminator.
        let longest = String(repeating: "a", count: RunnerVariant.maxLength) + "-d3dm99"
        let builds = SupportedRunners.all.map { $0.withVariant(longest) }
        for tool in SupportedRunners.tools(for: builds, d3dmetal: { _ in "99" }) {
            #expect(tool.name.utf8.count < 64)
            #expect(tool.build.utf8.count < 64)
            #expect(tool.display.utf8.count < 96)
        }
        let plain = SupportedRunners.all.map { $0.withVariant(String(repeating: "a", count: RunnerVariant.maxLength)) }
        for tool in SupportedRunners.tools(for: plain, d3dmetal: { _ in "99" }) {
            #expect(tool.display.utf8.count < 96)
        }
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

    @Test("The D3DMetal in apple_gptk is the one the bundle's own runner gets")
    func activeToolkit() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        try toolkit(root, "lib64/apple_gptk", "4.0b2")
        try toolkit(root, "lib64/apple_gptk_3", "3.0")
        #expect(RunnerVariant.activeMajor(crossOverRoot: root) == "4")
    }

    @Test("Every tool names the D3DMetal its runner's copy runs, once")
    func toolsNameTheirD3DMetal() throws {
        let pinned = try #require(SupportedRunners.all.first { $0.flavor == nil })
        let toolkit = pinned.withVariant("d3dm3")
        let tools = SupportedRunners.tools(for: [pinned, toolkit]) { $0.id == pinned.id ? "4" : "3" }
        #expect(tools.filter { $0.build == pinned.id }.allSatisfy { $0.display.hasSuffix(" · D3DMetal 4") })
        #expect(tools.filter { $0.build == toolkit.id }.allSatisfy { $0.display.hasSuffix(" · D3DMetal 3") })
        #expect(!tools.contains { $0.display.contains("D3DMetal 3 · D3DMetal") })
    }

    @Test("A toolkit runner whose copy runs another D3DMetal is refused")
    func cloneRunsWrongToolkit() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let build = try #require(SupportedRunners.all.first { $0.flavor == nil }).withVariant("mycopy-d3dm3")
        #expect(RunnerVariant.d3dmetal(of: build) == "3")
        try toolkit(root, "lib64/apple_gptk", "4.0b2")
        let wrong = #expect(throws: StepFailure.self) { try RunnerInstaller.verifyClone(build: build, root: root) }
        #expect(wrong?.detail.contains("D3DMetal 4, not 3") == true)

        try toolkit(root, "lib64/apple_gptk", "3.0")
        let next = #expect(throws: StepFailure.self) { try RunnerInstaller.verifyClone(build: build, root: root) }
        #expect(next?.detail.contains("D3DMetal") == false)
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

@Suite("Copies changed by GPTK Patcher")
struct PatchedCopyTests {

    private func root(receipt: String?, marker: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "patched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let receipt { try Data(receipt.utf8).write(to: root.appending(path: RunnerVariant.patcherReceipt)) }
        if let marker { try Data(marker.utf8).write(to: root.appending(path: RunnerVariant.markerName)) }
        return root
    }

    @Test("A copy is named after the toolkit and DXMT the patcher put in")
    func namedByReceipt() throws {
        let both = try root(receipt: #"{"tool":"GPTKPatcher 1.0.9","gptkD3DMetalVersion":"4.0b2","dxmtVersion":"0.80","environment":{}}"#)
        let toolkitOnly = try root(receipt: #"{"gptkD3DMetalVersion":"4.0b2","environment":{}}"#)
        let dxmtOnly = try root(receipt: #"{"gptkD3DMetalVersion":null,"dxmtVersion":"0.80"}"#)
        let broken = try root(receipt: "not json")
        defer { for dir in [both, toolkitOnly, dxmtOnly, broken] { try? FileManager.default.removeItem(at: dir) } }
        #expect(RunnerVariant.declared(crossOverRoot: both) == "gptk40b2-dxmt080")
        #expect(RunnerVariant.declared(crossOverRoot: toolkitOnly) == "gptk40b2")
        #expect(RunnerVariant.declared(crossOverRoot: dxmtOnly) == "dxmt080")
        #expect(RunnerVariant.declared(crossOverRoot: broken) == nil)
    }

    @Test("A marker still names the copy, and a long receipt is capped")
    func markerWins() throws {
        let marked = try root(receipt: #"{"gptkD3DMetalVersion":"4.0b2"}"#, marker: "Mine\n")
        let long = try root(receipt: #"{"gptkD3DMetalVersion":"4.0.12345b6","dxmtVersion":"0.80"}"#)
        defer { for dir in [marked, long] { try? FileManager.default.removeItem(at: dir) } }
        #expect(RunnerVariant.declared(crossOverRoot: marked) == "mine")
        let capped = try #require(RunnerVariant.declared(crossOverRoot: long))
        #expect(capped.count <= RunnerVariant.maxLength && RunnerVariant.isVariant(capped))
    }

    @Test("Patched ids resolve, with or without a toolkit runner, and read as versions")
    func resolvesAndLabels() throws {
        let pinned = try #require(SupportedRunners.all.first { $0.flavor == nil })
        let build = try #require(SupportedRunners.build(id: "\(pinned.id)-gptk40b2-dxmt080-d3dm3"))
        #expect(build.baseID == pinned.id)
        #expect(build.displayVersion.hasSuffix(" · GPTK 4.0b2 · DXMT 0.80 · D3DMetal 3"))
        #expect(RunnerVariant.d3dmetal(of: build) == "3")
        #expect(RunnerVariant.label("gptkfoo-dxmt") == "gptkfoo · dxmt")
        #expect(SupportedRunners.build(id: "\(pinned.id)-a-b-c-d") == nil)
    }

    @Test("The stock toolkit the patcher kept is offered as its own runner")
    func stockToolkitOffered() throws {
        let dir = try root(receipt: nil); defer { try? FileManager.default.removeItem(at: dir) }
        for (path, version) in [("lib64/apple_gptk", "4.0b2"), ("lib64/apple_gptk.stock", "3.0")] {
            let resources = dir.appending(path: "\(path)/external/D3DMetal.framework/Versions/A/Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            (["CFBundleShortVersionString": version] as NSDictionary).write(to: resources.appending(path: "Info.plist"), atomically: true)
        }
        #expect(RunnerVariant.otherToolkits(crossOverRoot: dir).map(\.path) == ["lib64/apple_gptk.stock"])
    }

    @Test("CrossOver 27 keeps apple_gptk in lib, and its D3DMetal is still read")
    func previewToolkitRead() throws {
        let dir = try root(receipt: nil); defer { try? FileManager.default.removeItem(at: dir) }
        let resources = dir.appending(path: "lib/apple_gptk/external/D3DMetal.framework/Versions/A/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        (["CFBundleShortVersionString": "4.0b2"] as NSDictionary).write(to: resources.appending(path: "Info.plist"), atomically: true)
        #expect(RunnerVariant.activeMajor(crossOverRoot: dir) == "4")
        #expect(RunnerVariant.otherToolkits(crossOverRoot: dir).isEmpty)
    }
}
