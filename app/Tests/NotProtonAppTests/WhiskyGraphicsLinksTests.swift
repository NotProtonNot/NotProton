import Foundation
import Testing

@testable import NotProtonApp

@Suite("Whisky D3DMetal links")
struct WhiskyGraphicsLinksTests {
    private func fixture() throws -> URL {
        let root = try RuntimeFixture.scratch("gptk-links")
        let external = root.appending(path: "Wine/lib/external")
        let unix = root.appending(path: "Wine/lib/wine/x86_64-unix")
        try FileManager.default.createDirectory(at: external.appending(path: "D3DMetal.framework"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
        try Data("framework".utf8).write(to: external.appending(path: "D3DMetal.framework/D3DMetal"))
        try Data("shared library".utf8).write(to: external.appending(path: "libd3dshared.dylib"))
        for name in WhiskyGraphicsLinks.names {
            try FileManager.default.createSymbolicLink(atPath: unix.appending(path: name).path,
                withDestinationPath: WhiskyGraphicsLinks.destination)
        }
        return root
    }

    @Test("Setup repairs a flattened runtime copy without changing the source")
    func setupAndRepair() throws {
        let source = try fixture()
        let scratch = try RuntimeFixture.scratch("gptk-copy")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: scratch)
        }
        let copy = scratch.appending(path: "copy")
        try RunnerInstaller.copyRuntime(from: source, to: copy)
        let wine = copy.appending(path: "Wine")
        #expect(WhiskyGraphicsLinks.verify(in: wine).count == 4)
        let build = RunnerBuild.native(name: "winecx-gptk", version: "4.8.22")
        let bridge = scratch.appending(path: "bridge")
        for builtin in RunnerPatcher.builtins(in: wine) {
            let file = bridge.appending(path: "\(builtin.arch)/\(builtin.name)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("bridge".utf8).write(to: file)
        }
        let outcome = try RunnerPatcher.install(build: build, root: wine, bridge: bridge)
        #expect(outcome.graphicsLinks == WhiskyGraphicsLinks.names)
        #expect(!outcome.wroteNothing)
        #expect(RunnerPatcher.verify(build: build, root: wine, bridge: bridge).isEmpty)
        #expect(try RunnerPatcher.install(build: build, root: wine, bridge: bridge).wroteNothing)
        for name in WhiskyGraphicsLinks.names {
            for runtime in [source, copy] {
                let file = runtime.appending(path: "Wine/lib/wine/x86_64-unix/\(name)")
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == WhiskyGraphicsLinks.destination)
                #expect(file.resolvingSymlinksInPath().path.hasPrefix(runtime.resolvingSymlinksInPath().path + "/"))
                #expect(try Data(contentsOf: file) == Data("shared library".utf8))
            }
        }
    }

    @Test("Repair restores a Mach-O bridge's relative framework lookup")
    func frameworkLookup() throws {
        let source = try fixture()
        let scratch = try RuntimeFixture.scratch("gptk-dlopen")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: scratch)
        }
        let external = source.appending(path: "Wine/lib/external")
        let code = scratch.appending(path: "probe.c")
        try Data("""
            #include <dlfcn.h>
            void *open_framework(void) {
                return dlopen("@rpath/D3DMetal.framework/D3DMetal", RTLD_NOW);
            }
            """.utf8).write(to: code)
        try Shell.check("/usr/bin/clang", ["-dynamiclib", code.path, "-Wl,-rpath,@loader_path",
            "-o", external.appending(path: "libd3dshared.dylib").path])
        try Data("int framework(void) { return 42; }".utf8).write(to: code)
        try Shell.check("/usr/bin/clang", ["-dynamiclib", code.path,
            "-o", external.appending(path: "D3DMetal.framework/D3DMetal").path])
        try Data("""
            #include <dlfcn.h>
            int main(int c, char **v) {
                void *lib = dlopen(v[1], RTLD_NOW);
                if (!lib) return 2;
                void *(*probe)(void) = dlsym(lib, "open_framework");
                return probe && probe() ? 0 : 1;
            }
            """.utf8).write(to: code)
        let probe = scratch.appending(path: "probe")
        try Shell.check("/usr/bin/clang", [code.path, "-o", probe.path])
        let copy = scratch.appending(path: "copy")
        try RunnerInstaller.copyRuntime(from: source, to: copy)
        let wine = copy.appending(path: "Wine")
        let bridge = wine.appending(path: "lib/wine/x86_64-unix/d3d11.so")
        #expect(try Shell.run(probe.path, [bridge.path]).status == 1)
        #expect(try WhiskyGraphicsLinks.repair(in: wine) == WhiskyGraphicsLinks.names)
        #expect(try Shell.run(probe.path, [bridge.path]).status == 0)
    }

    @Test("Optional NVAPI and GPTK aliases are repaired when present")
    func optionalAliases() throws {
        let source = try fixture()
        let scratch = try RuntimeFixture.scratch("gptk-aliases")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: scratch)
        }
        let aliases = ["nvapi.so", "nvapi64.so", "nvngx.so", "d3dmt.so", "dxgm.so"]
        for name in aliases {
            try FileManager.default.createSymbolicLink(
                atPath: source.appending(path: "Wine/lib/wine/x86_64-unix/\(name)").path,
                withDestinationPath: WhiskyGraphicsLinks.destination)
        }
        let copy = scratch.appending(path: "copy")
        try RunnerInstaller.copyRuntime(from: source, to: copy)
        let wine = copy.appending(path: "Wine")
        #expect(try WhiskyGraphicsLinks.repair(in: wine) == WhiskyGraphicsLinks.names + aliases)
        #expect(WhiskyGraphicsLinks.verify(in: wine).isEmpty)
        #expect(try WhiskyGraphicsLinks.repair(in: wine).isEmpty)
    }

    @Test("Unexpected bridge bytes are refused before any links are changed")
    func refusesUnexpectedBytes() throws {
        let source = try fixture()
        let scratch = try RuntimeFixture.scratch("gptk-modified")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: scratch)
        }
        let copy = scratch.appending(path: "copy")
        try RunnerInstaller.copyRuntime(from: source, to: copy)
        let root = copy.appending(path: "Wine")
        let unix = root.appending(path: "lib/wine/x86_64-unix")
        try Data("custom bridge".utf8).write(to: unix.appending(path: "dxgi.so"))
        #expect(throws: StepFailure.self) { try WhiskyGraphicsLinks.repair(in: root) }
        for name in WhiskyGraphicsLinks.names {
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: unix.appending(path: name).path)) == nil)
        }
        #expect(try Data(contentsOf: unix.appending(path: "dxgi.so")) == Data("custom bridge".utf8))
    }

    @Test("Runtimes without the optional GPTK payload need no repairs")
    func noPayload() throws {
        let root = try RuntimeFixture.scratch("no-gptk")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WhiskyGraphicsLinks.verify(in: root).isEmpty)
        #expect(try WhiskyGraphicsLinks.repair(in: root).isEmpty)
    }

    @Test("A shared library outside the managed runtime is refused")
    func refusesExternalLibrary() throws {
        let runtime = try fixture()
        let external = try RuntimeFixture.scratch("gptk-external")
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: external)
        }
        let library = runtime.appending(path: "Wine/lib/external/libd3dshared.dylib")
        let original = external.appending(path: "library")
        try FileManager.default.moveItem(at: library, to: original)
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: original)
        #expect(WhiskyGraphicsLinks.verify(in: runtime.appending(path: "Wine")).count == 1)
        #expect(throws: StepFailure.self) { try WhiskyGraphicsLinks.repair(in: runtime.appending(path: "Wine")) }
        #expect(try Data(contentsOf: original) == Data("shared library".utf8))
    }
}
