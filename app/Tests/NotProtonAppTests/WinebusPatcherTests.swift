import Foundation
import Testing

@testable import NotProtonApp

// A stand-in x86_64 PE whose one .text section holds a call at the hook site and padding
// after the code, laid out like CrossOver's winebus.sys but small.
private struct StubWinebus {
    static let peOffset = 0x80
    static let textVirtualAddress = 0x1000
    static let textRawOffset = 0x400
    static let textRawSize = 0x2000
    static let codeSize = 0x1800

    static func patch(cavePad: UInt8 = 0x00) -> WinebusPatch {
        WinebusPatch(
            arch: .x86_64Windows,
            cleanSHA256: "unused", patchedSHA256: "unused",
            payloadResource: "unused", payloadSHA256: "unused",
            hookRVA: 0x1200, hookTargetRVA: 0x1100, caveRVA: 0x2800, cavePad: cavePad
        )
    }

    static func offset(_ rva: Int) -> Int { textRawOffset + rva - textVirtualAddress }

    static func make(codeSize: Int = codeSize, pad: UInt8 = 0x00) -> Data {
        var bytes = [UInt8](repeating: 0, count: textRawOffset + textRawSize)
        put(&bytes, 0x3c, UInt32(peOffset))
        put(&bytes, peOffset, UInt32(0x0000_4550))
        put(&bytes, peOffset + 4, UInt16(0x8664))
        put(&bytes, peOffset + 6, UInt16(1))
        put(&bytes, peOffset + 20, UInt16(0xf0))
        put(&bytes, peOffset + 24, UInt16(0x20b))

        let header = peOffset + 24 + 0xf0
        bytes.replaceSubrange(header ..< header + 5, with: Array(".text".utf8))
        put(&bytes, header + 8, UInt32(codeSize))
        put(&bytes, header + 12, UInt32(textVirtualAddress))
        put(&bytes, header + 16, UInt32(textRawSize))
        put(&bytes, header + 20, UInt32(textRawOffset))

        for index in offset(textVirtualAddress) ..< offset(textVirtualAddress + textRawSize) {
            bytes[index] = index < offset(textVirtualAddress + codeSize) ? 0x90 : pad
        }
        let hook = patch().hookRVA
        let call = offset(hook)
        bytes[call] = 0xe8
        put(&bytes, call + 1, Int32(patch().hookTargetRVA - (hook + 5)))
        return Data(bytes)
    }

    static func put<T: FixedWidthInteger>(_ bytes: inout [UInt8], _ offset: Int, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { raw in
            for (index, byte) in raw.enumerated() { bytes[offset + index] = byte }
        }
    }

    static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0 ..< 4).reversed().reduce(0) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }
}

@Suite("winebus patcher")
struct WinebusPatcherTests {

    private let payload = Data((0 ..< 96).map { UInt8($0 + 1) })

    @Test("The hook site's call is pointed at the cave, which gets the payload")
    func patchesStub() throws {
        let patch = StubWinebus.patch()
        let patched = [UInt8](try WinebusPatcher.apply(patch, to: StubWinebus.make(), payload: payload))

        let call = StubWinebus.offset(patch.hookRVA)
        #expect(patched[call] == 0xe8)
        #expect(Int32(bitPattern: StubWinebus.read32(patched, call + 1))
            == Int32(patch.caveRVA - (patch.hookRVA + 5)))

        let cave = StubWinebus.offset(patch.caveRVA)
        #expect(Data(patched[cave ..< cave + payload.count]) == payload)

        let header = StubWinebus.peOffset + 24 + 0xf0
        #expect(Int(StubWinebus.read32(patched, header + 8))
            == patch.caveRVA + payload.count - StubWinebus.textVirtualAddress)

        let field = StubWinebus.peOffset + 24 + 64
        #expect(StubWinebus.read32(patched, field) == WinebusPatcher.checksum(patched, field: field))
    }

    @Test("A cave padded with int3 is patched when the pin expects it, and refused when it does not")
    func honoursCavePad() throws {
        let image = StubWinebus.make(pad: 0xcc)
        _ = try WinebusPatcher.apply(StubWinebus.patch(cavePad: 0xcc), to: image, payload: payload)
        #expect(throws: StepFailure.self) {
            try WinebusPatcher.apply(StubWinebus.patch(), to: image, payload: payload)
        }
    }

    @Test("A hook site that holds something else is refused")
    func refusesForeignHookSite() {
        var bytes = [UInt8](StubWinebus.make())
        bytes[StubWinebus.offset(StubWinebus.patch().hookRVA) + 1] ^= 0xff
        #expect(throws: StepFailure.self) {
            try WinebusPatcher.apply(StubWinebus.patch(), to: Data(bytes), payload: payload)
        }
    }

    @Test("A cave inside the code is refused")
    func refusesCaveInsideCode() {
        let image = StubWinebus.make(codeSize: StubWinebus.patch().caveRVA - StubWinebus.textVirtualAddress + 0x10)
        #expect(throws: StepFailure.self) {
            try WinebusPatcher.apply(StubWinebus.patch(), to: image, payload: payload)
        }
    }

    @Test("A cave that already holds bytes is refused")
    func refusesOccupiedCave() {
        var bytes = [UInt8](StubWinebus.make())
        bytes[StubWinebus.offset(StubWinebus.patch().caveRVA) + 40] = 0xcc
        #expect(throws: StepFailure.self) {
            try WinebusPatcher.apply(StubWinebus.patch(), to: Data(bytes), payload: payload)
        }
    }

    @Test("Every shipped payload is the one its build pins")
    func payloadsMatchPins() throws {
        for patch in WinebusPatcher.byBuild.values.flatMap({ $0 }) {
            _ = try WinebusPatcher.payload(for: patch)
        }
    }

    @Test("Every pin names a supported build and patches each arch at most once")
    func pinsNameSupportedBuilds() {
        for (id, patches) in WinebusPatcher.byBuild {
            #expect(SupportedRunners.build(id: id) != nil, "\(id) is not a supported build")
            #expect(Set(patches.map(\.arch)).count == patches.count, "\(id) patches an arch twice")
            // Only a FEX build ships an aarch64 winebus.sys (loaded by its native FEX tool).
            for patch in patches where patch.arch == .aarch64Windows {
                #expect(id.hasSuffix("-fex"), "\(id) pins an aarch64 winebus.sys but is not a FEX build")
            }
        }
    }

    // Only real CrossOver bytes can show the patch reproduces its pinned hash, so this runs
    // for each pin whose stock winebus.sys is on this machine, in a runner or a CrossOver app.
    private static func cleanCopies() -> [(build: RunnerBuild, patch: WinebusPatch, source: URL)] {
        let roots = RunnerStore.installedBuilds().map { SupportPaths.clonedRoot(forBuild: $0.id) }
            + CrossOverSource.discover().map(\.crossOverRoot)
        var found: [(build: RunnerBuild, patch: WinebusPatch, source: URL)] = []
        for (id, patches) in WinebusPatcher.byBuild.sorted(by: { $0.key < $1.key }) {
            guard let build = SupportedRunners.build(id: id) else { continue }
            for patch in patches {
                let source = roots.lazy
                    .map { Clean.copy(of: WinebusPatcher.live(inRoot: $0, arch: patch.arch)) }
                    .first { Digest.sha256IfPresent($0) == patch.cleanSHA256 }
                if let source { found.append((build, patch, source)) }
            }
        }
        return found
    }

    @Test("The checksum matches the one CrossOver stored in its winebus.sys")
    func checksumMatchesShipped() throws {
        for (_, _, source) in Self.cleanCopies() {
            let bytes = [UInt8](try Data(contentsOf: source))
            let pe = Int(StubWinebus.read32(bytes, 0x3c))
            #expect(WinebusPatcher.checksum(bytes, field: pe + 24 + 64) == StubWinebus.read32(bytes, pe + 24 + 64),
                    "\(source.path(percentEncoded: false))")
        }
    }

    @Test("Patching the shipped winebus.sys gives the pinned file")
    func patchesShippedCopy() throws {
        for (build, patch, source) in Self.cleanCopies() {
            let patched = try #require(try WinebusPatcher.patchedImage(patch, build: build, from: source))
            #expect(Digest.sha256(of: patched) == patch.patchedSHA256, "\(build.id) \(patch.arch.rawValue)")
        }
    }

    @Test("A winebus.sys that is not the pinned one is left alone")
    func skipsUnknownCopy() throws {
        let patch = try #require(WinebusPatcher.byBuild["27.0.0.41069"]?.first)
        let build = try #require(SupportedRunners.build(id: "27.0.0.41069"))
        let file = URL(filePath: NSTemporaryDirectory()).appending(path: "winebus-\(UUID().uuidString).sys")
        try StubWinebus.make().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try WinebusPatcher.patchedImage(patch, build: build, from: file) == nil)
    }

    @Test("An unpatched runner is reported, then patched by the install with the shipped copy kept")
    func installsIntoClone() throws {
        let candidates = RunnerStore.installedBuilds().compactMap { build -> (RunnerBuild, WinebusPatch)? in
            let root = SupportPaths.clonedRoot(forBuild: build.id)
            guard let patch = WinebusPatcher.patches(for: build).first(where: {
                Digest.sha256IfPresent(Clean.copy(of: WinebusPatcher.live(inRoot: root, arch: $0.arch))) == $0.cleanSHA256
            }) else { return nil }
            return (build, patch)
        }
        guard let (build, patch) = candidates.first else { return }

        let live = SupportPaths.clonedRoot(forBuild: build.id)
        let scratch = URL(filePath: NSTemporaryDirectory()).appending(path: "notproton-runner-\(UUID().uuidString)")
        let copied = try Shell.run("/bin/cp", [
            "-c", "-R", live.path(percentEncoded: false), scratch.path(percentEncoded: false),
        ])
        try #require(copied.status == 0)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Start from the shipped copy, as a runner set up before this patch existed has it.
        let winebus = WinebusPatcher.live(inRoot: scratch, arch: patch.arch)
        let backup = Clean.copy(of: winebus)
        if backup != winebus {
            try FileManager.default.removeItem(at: winebus)
            try FileManager.default.moveItem(at: backup, to: winebus)
        }

        let reported = "\(patch.arch.rawValue)/winebus.sys is not the patched copy"
        #expect(RunnerPatcher.verify(build: build, root: scratch).contains(reported))

        let outcome = try RunnerPatcher.install(build: build, root: scratch)
        #expect(outcome.winebus.contains(patch.arch))
        #expect(Digest.sha256IfPresent(winebus) == patch.patchedSHA256)
        #expect(Digest.sha256IfPresent(Clean.copy(of: winebus)) == patch.cleanSHA256)
        #expect(!RunnerPatcher.verify(build: build, root: scratch).contains(reported))

        #expect(try RunnerPatcher.install(build: build, root: scratch).winebus.isEmpty)
    }
}
