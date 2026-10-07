// Patches CrossOver's ntdll.dll so that lsteamclient is loaded.

import Foundation

// jump site
struct NtdllHook: Sendable {
    let rva: Int

    // The bytes that are supposed to be at `rva`.
    let stolen: [UInt8]
}

enum CavePlacement: Sendable {
    case padding
    case section
}

struct NtdllPatch: Sendable {
    let arch: WineArch

    let payloadResource: String
    let payloadSHA256: String

    // cave
    let caveRVA: Int
    let payloadRVA: Int

    let hooks: [NtdllHook]


    let caveSize: Int
    let cavePad: UInt8

    let machine: UInt16
    let magic: UInt16
    let imageBase: UInt64

    var placement: CavePlacement = .padding
}

enum NtdllPatcher {

    static let step = "Patch ntdll"

    private static let magicPE32Plus: UInt16 = 0x20b
    // SECTION_NAME, SECTION_SIZE and SECTION_FLAGS in resolve.py.
    private static let sectionName: [UInt8] = Array(".npdet".utf8) + [0, 0]
    private static let sectionSize = 0x1000
    private static let sectionFlags: UInt32 = 0x6000_0020
    private static let machineARM64: UInt16 = 0xaa64


    static let byBuild: [String: [NtdllPatch]] = [
        "27.0.0.40921": [
            NtdllPatch(
                arch: .x86_64Windows,
                payloadResource: "detour2",
                payloadSHA256: "4ce2ddc11c433fe15f78633fc5c1fda8b27fa642426cb26378f7d7d7b54a79f8",
                caveRVA: 0x80be0,
                payloadRVA: 0x80be0,
                hooks: [
                    NtdllHook(rva: 0x51f15,
                              stolen: [0x48, 0x83, 0xbc, 0x24, 0xf0, 0x00, 0x00, 0x00, 0x00]),
                ],
                caveSize: 1056,
                cavePad: 0x00,
                machine: 0x8664,
                magic: 0x20b,
                imageBase: 0x1_7000_0000
            ),
            NtdllPatch(
                arch: .i386Windows,
                payloadResource: "detour32",
                payloadSHA256: "2758d4f6783c853c460187f83f4fb9b1105380d194126ef83fc85e2596d3036a",
                caveRVA: 0x7c830,
                payloadRVA: 0x7c830,
                hooks: [
                    NtdllHook(rva: 0x4d828, stolen: [0xf6, 0x45, 0xbc, 0x02, 0x75, 0x26]),
                ],
                caveSize: 2000,
                cavePad: 0x00,
                machine: 0x14c,
                magic: 0x10b,
                imageBase: 0x7bc0_0000
            ),
        ],
        // FEX patches
        "27.0.0.40921-fex": [
            NtdllPatch(
                arch: .i386Windows,
                payloadResource: "detour32-fex",
                payloadSHA256: "b4c697ba396ecb59125c505666ad3465d1208b8a1e3e53a0c457657b341376b9",
                caveRVA: 0x6b2fe,
                payloadRVA: 0x6b300,
                hooks: [
                    NtdllHook(rva: 0x2ee12, stolen: [0x8b, 0x45, 0x14, 0xa8, 0x02]),
                ],
                caveSize: 3330,
                cavePad: 0xcc,
                machine: 0x14c,
                magic: 0x10b,
                imageBase: 0x7bc0_0000
            ),
            NtdllPatch(
                arch: .aarch64Windows,
                payloadResource: "detour64-fex",
                payloadSHA256: "bee4ee13c235bd5de3cb6ce840b9695effd5623132f6dc0d137496d6a5330f5e",
                caveRVA: 0xf1185,
                payloadRVA: 0xf1190,
                hooks: [
                    NtdllHook(rva: 0x48004, stolen: [0x1f, 0x20, 0x03, 0xd5]),
                    NtdllHook(rva: 0xa71bc, stolen: [0x1f, 0x20, 0x03, 0xd5]),
                ],
                caveSize: 61051,
                cavePad: 0xcc,
                machine: 0xaa64,
                magic: 0x20b,
                imageBase: 0x1_8000_0000
            ),
        ],
        "27.0.0.41069": [
            NtdllPatch(
                arch: .x86_64Windows,
                payloadResource: "detour2-41069",
                payloadSHA256: "67b70667387ff5bf89743b2d0a995a94543812678d4558dc884e6cebb46e7750",
                caveRVA: 0x815e0,
                payloadRVA: 0x815e0,
                hooks: [
                    NtdllHook(rva: 0x52055,
                              stolen: [0x48, 0x83, 0xbc, 0x24, 0xf0, 0x00, 0x00, 0x00, 0x00]),
                ],
                caveSize: 2592,
                cavePad: 0x00,
                machine: 0x8664,
                magic: 0x20b,
                imageBase: 0x1_7000_0000
            ),
            NtdllPatch(
                arch: .i386Windows,
                payloadResource: "detour32-41069",
                payloadSHA256: "3eaa5021add0c8e30e324d6b1a6392a32720f5f73596418a2086b7f8081eb1bd",
                caveRVA: 0x7d1f0,
                payloadRVA: 0x7d1f0,
                hooks: [
                    NtdllHook(rva: 0x4d848, stolen: [0xf6, 0x45, 0xbc, 0x02, 0x75, 0x26]),
                ],
                caveSize: 3600,
                cavePad: 0x00,
                machine: 0x14c,
                magic: 0x10b,
                imageBase: 0x7bc0_0000
            ),
        ],
        "27.0.0.41069-fex": [
            fexI38641069,
            NtdllPatch(
                arch: .aarch64Windows,
                payloadResource: "detour64-fex-41069",
                payloadSHA256: "c6060b07f2c2f25636fcb1489ddd6729c277666167e9a090f55a1b711f0d5979",
                caveRVA: 0xf3185,
                payloadRVA: 0xf3190,
                hooks: [
                    NtdllHook(rva: 0x48738, stolen: [0x1f, 0x20, 0x03, 0xd5]),
                    NtdllHook(rva: 0xa883c, stolen: [0x1f, 0x20, 0x03, 0xd5]),
                ],
                caveSize: 52859,
                cavePad: 0xcc,
                machine: 0xaa64,
                magic: 0x20b,
                imageBase: 0x1_8000_0000
            ),
        ],
        "27.0.0.41069-bundled-rosetta": [bundledRosetta41069, fexI38641069],
    ]

    // Both runtime profiles in the combined distribution use this i386 DLL.
    private static let fexI38641069 = NtdllPatch(
        arch: .i386Windows,
        payloadResource: "detour32-fex-41069",
        payloadSHA256: "6ff6c7289e639c4caad85c2670bfa849d9f36baa24152b6979896caede5e249b",
        caveRVA: 0xa4000,
        payloadRVA: 0xa4000,
        hooks: [NtdllHook(rva: 0x2ede2, stolen: [0x8b, 0x45, 0x14, 0xa8, 0x02])],
        caveSize: 0x1000,
        cavePad: 0x00,
        machine: 0x14c,
        magic: 0x10b,
        imageBase: 0x7bc0_0000,
        placement: .section
    )

    private static let bundledRosetta41069 = NtdllPatch(
        arch: .x86_64Windows,
        payloadResource: "detour2-bundled-41069",
        payloadSHA256: "41a397d176aefdbbe1b795f25ab0bd891804e40c43fa44d25aeb3df45fa01a4a",
        caveRVA: 0xb5000,
        payloadRVA: 0xb5000,
        hooks: [
            NtdllHook(rva: 0x34aae,
                      stolen: [0x48, 0x8b, 0x84, 0x24, 0x10, 0x01, 0x00, 0x00]),
        ],
        caveSize: 0x1000,
        cavePad: 0x00,
        machine: 0x8664,
        magic: 0x20b,
        imageBase: 0x1_7000_0000,
        placement: .section
    )

    static func patches(for build: RunnerBuild) -> [NtdllPatch] {
        byBuild[build.id] ?? []
    }

    static func patch(for arch: WineArch, in build: RunnerBuild) -> NtdllPatch? {
        patches(for: build).first { $0.arch == arch }
    }

    // Patch
    static func apply(_ patch: NtdllPatch, to image: Data, payload: Data) throws -> Data {
        var bytes = [UInt8](image)
        try validateHeaders(patch, bytes)
        if patch.placement == .section {
            try appendSection(patch, to: &bytes)
        }

        let caveOffset = try fileOffset(of: patch.caveRVA, in: bytes, describing: "cave", patch: patch)
        let payloadOffset = try fileOffset(of: patch.payloadRVA, in: bytes, describing: "payload", patch: patch)

        let intoCave = patch.payloadRVA - patch.caveRVA
        guard intoCave >= 0 else {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) detour goes to \(hex(patch.payloadRVA)), below its "
                    + "cave at \(hex(patch.caveRVA)), so writing it would land in live code."
            )
        }

        let room = patch.caveSize - intoCave
        if payload.count > room {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) detour is \(payload.count) bytes and the cave holds "
                    + "\(room), so writing it would overrun into live code."
            )
        }

        try requireRange(caveOffset, patch.caveSize, in: bytes, describing: "The cave")
        guard bytes[caveOffset ..< caveOffset + patch.caveSize].allSatisfy({ $0 == patch.cavePad }) else {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) cave at \(hex(patch.caveRVA)) is not empty. "
                    + "This ntdll is either already patched or not the build its hash claimed."
            )
        }

        // check files
        var branches: [(offset: Int, code: [UInt8])] = []
        for hook in patch.hooks {
            let offset = try fileOffset(of: hook.rva, in: bytes, describing: "hook site", patch: patch)
            try requireRange(offset, hook.stolen.count, in: bytes, describing: "The hook site")
            let present = Array(bytes[offset ..< offset + hook.stolen.count])
            guard present == hook.stolen else {
                throw StepFailure(
                    step: step,
                    detail: "The \(patch.arch.rawValue) hook site at \(hex(hook.rva)) holds \(hex(present)) "
                        + "instead of \(hex(hook.stolen)), so the offsets do not belong to this ntdll."
                )
            }
            branches.append(
                (offset, try branch(patch, from: hook.rva, filling: hook.stolen.count))
            )
        }

        bytes.replaceSubrange(payloadOffset ..< payloadOffset + payload.count, with: payload)
        for branch in branches {
            bytes.replaceSubrange(branch.offset ..< branch.offset + branch.code.count, with: branch.code)
        }

        return Data(bytes)
    }

    private static func branch(_ patch: NtdllPatch, from hookRVA: Int, filling width: Int) throws -> [UInt8] {
        patch.machine == machineARM64
            ? try branchLink(from: hookRVA, to: patch.payloadRVA, filling: width)
            : try relativeJump(from: hookRVA, to: patch.payloadRVA, filling: width)
    }

    private static func branchLink(from hookRVA: Int, to payloadRVA: Int, filling width: Int) throws -> [UInt8] {
        guard width == 4 else {
            throw StepFailure(
                step: step, detail: "A hook site of \(width) bytes cannot hold a branch and link."
            )
        }

        let delta = payloadRVA - hookRVA
        guard delta % 4 == 0, (-0x800_0000 ..< 0x800_0000).contains(delta) else {
            throw StepFailure(
                step: step,
                detail: "The detour is \(delta) bytes from the hook site, which a branch and link "
                    + "cannot reach."
            )
        }

        let encoded = UInt32(0x9400_0000) | (UInt32(bitPattern: Int32(delta) >> 2) & 0x03ff_ffff)
        return withUnsafeBytes(of: encoded.littleEndian, Array.init)
    }


    private static func relativeJump(from hookRVA: Int, to caveRVA: Int, filling width: Int) throws -> [UInt8] {
        guard width >= 5 else {
            throw StepFailure(
                step: step, detail: "A hook site of \(width) bytes cannot hold a relative jump."
            )
        }

        let delta = caveRVA - (hookRVA + 5)
        guard let displacement = Int32(exactly: delta) else {
            throw StepFailure(
                step: step,
                detail: "The cave is \(delta) bytes from the hook site, which a relative jump cannot reach."
            )
        }

        var jump: [UInt8] = [0xe9]
        withUnsafeBytes(of: displacement.littleEndian) { jump.append(contentsOf: $0) }
        jump.append(contentsOf: repeatElement(0xcc, count: width - 5))
        return jump
    }


    private static func appendSection(_ patch: NtdllPatch, to bytes: inout [UInt8]) throws {
        let pe = Int(try u32(bytes, 0x3c))
        let sections = Int(try u16(bytes, pe + 6))
        let optional = pe + 24
        let table = optional + Int(try u16(bytes, pe + 20))
        let header = table + sections * 40
        let fileAlignment = Int(try u32(bytes, optional + 36))
        let imageSize = Int(try u32(bytes, optional + 56))
        let headersSize = Int(try u32(bytes, optional + 60))

        guard patch.caveSize == sectionSize, imageSize == patch.caveRVA else {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) ntdll image ends at \(hex(imageSize)), and the detour "
                    + "section was pinned at \(hex(patch.caveRVA))."
            )
        }
        guard header + 40 <= headersSize, bytes[header ..< header + 40].allSatisfy({ $0 == 0 }) else {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) ntdll has no free section header slot for the detour."
            )
        }
        guard fileAlignment > 0, fileAlignment & (fileAlignment - 1) == 0 else {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) ntdll file alignment \(hex(fileAlignment)) is not a power of two."
            )
        }

        let rawOffset = (bytes.count + fileAlignment - 1) & ~(fileAlignment - 1)
        // The last zero is NumberOfRelocations and NumberOfLinenumbers (two bytes each).
        var entry = sectionName
        for field in [UInt32(sectionSize), UInt32(patch.caveRVA), UInt32(sectionSize), UInt32(rawOffset),
                      0, 0, 0, sectionFlags] {
            withUnsafeBytes(of: field.littleEndian) { entry.append(contentsOf: $0) }
        }
        bytes.replaceSubrange(header ..< header + 40, with: entry)

        put16(UInt16(sections + 1), at: pe + 6, in: &bytes)
        put32(UInt32(imageSize + sectionSize), at: optional + 56, in: &bytes)
        bytes.append(contentsOf: repeatElement(0, count: rawOffset + sectionSize - bytes.count))
    }

    private static func put16(_ value: UInt16, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(value & 0xff)
        bytes[offset + 1] = UInt8(value >> 8)
    }

    private static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0 ..< 4 { bytes[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xff) }
    }

    private static func validateHeaders(_ patch: NtdllPatch, _ bytes: [UInt8]) throws {
        let pe = Int(try u32(bytes, 0x3c))
        guard try u32(bytes, pe) == 0x0000_4550 else {
            throw StepFailure(
                step: step, detail: "The \(patch.arch.rawValue) ntdll has no PE header where its DOS stub points."
            )
        }

        let machine = try u16(bytes, pe + 4)
        guard machine == patch.machine else {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) ntdll is machine \(hex(Int(machine))), "
                    + "expected \(hex(Int(patch.machine)))."
            )
        }

        let magic = try u16(bytes, pe + 24)
        guard magic == patch.magic else {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) ntdll optional header is \(hex(Int(magic))), "
                    + "expected \(hex(Int(patch.magic)))."
            )
        }

        let imageBase = magic == magicPE32Plus
            ? try u64(bytes, pe + 24 + 24)
            : UInt64(try u32(bytes, pe + 24 + 28))
        guard imageBase == patch.imageBase else {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) ntdll is based at \(hex(imageBase)), "
                    + "and the detour was linked against \(hex(patch.imageBase))."
            )
        }
    }

    private static func fileOffset(
        of rva: Int, in bytes: [UInt8], describing what: String, patch: NtdllPatch
    ) throws -> Int {
        let pe = Int(try u32(bytes, 0x3c))
        let sections = Int(try u16(bytes, pe + 6))
        let optionalSize = Int(try u16(bytes, pe + 20))
        let table = pe + 24 + optionalSize

        for index in 0 ..< sections {
            let entry = table + index * 40
            let virtualSize = Int(try u32(bytes, entry + 8))
            let virtualAddress = Int(try u32(bytes, entry + 12))
            let rawSize = Int(try u32(bytes, entry + 16))
            let rawOffset = Int(try u32(bytes, entry + 20))

            if rawSize == 0 || rawOffset == 0 { continue }

            let span = max(virtualSize, rawSize)
            guard rva >= virtualAddress, rva < virtualAddress + span else { continue }

            let offset = rawOffset + (rva - virtualAddress)
            try requireRange(offset, 1, in: bytes, describing: "The \(what)")
            return offset
        }

        throw StepFailure(
            step: step,
            detail: "RVA \(hex(rva)) falls in no mapped section of the \(patch.arch.rawValue) ntdll, "
                + "so the \(what) cannot be located."
        )
    }

    private static func requireRange(
        _ offset: Int, _ length: Int, in bytes: [UInt8], describing what: String
    ) throws {
        guard offset >= 0, length >= 0, offset <= bytes.count - length else {
            throw StepFailure(
                step: step,
                detail: "\(what) at \(hex(offset)) spans \(length) bytes, past the end of a "
                    + "\(bytes.count) byte file."
            )
        }
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        try requireRange(offset, 2, in: bytes, describing: "A header field")
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        try requireRange(offset, 4, in: bytes, describing: "A header field")
        var value: UInt32 = 0
        for index in (0 ..< 4).reversed() { value = value << 8 | UInt32(bytes[offset + index]) }
        return value
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) throws -> UInt64 {
        try requireRange(offset, 8, in: bytes, describing: "A header field")
        var value: UInt64 = 0
        for index in (0 ..< 8).reversed() { value = value << 8 | UInt64(bytes[offset + index]) }
        return value
    }

    private static func hex(_ value: Int) -> String { "0x" + String(value, radix: 16) }
    private static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // Resources

    static func payload(for patch: NtdllPatch) throws -> Data {
        guard let url = AppResources.bundle.url(forResource: patch.payloadResource, withExtension: "bin") else {
            throw StepFailure(
                step: step,
                detail: "\(patch.payloadResource).bin is missing from the app's resources."
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StepFailure(
                step: step,
                detail: "\(patch.payloadResource).bin could not be read. \(error.localizedDescription)"
            )
        }

        let hash = Digest.sha256(of: data)
        guard hash == patch.payloadSHA256 else {
            throw StepFailure(
                step: step,
                detail: "\(patch.payloadResource).bin hashes \(hash.prefix(16)) and should hash "
                    + "\(patch.payloadSHA256.prefix(16)), so the shipped detour is not the one that was built."
            )
        }
        return data
    }

    static func cleanSource(inRoot root: URL, arch: WineArch) -> URL {
        Clean.copy(of: root.appending(path: "lib/wine/\(arch.rawValue)/ntdll.dll"))
    }

    @discardableResult
    static func write(
        _ patch: NtdllPatch, build: RunnerBuild, from source: URL, to destination: URL
    ) throws -> String {
        guard let expectedInput = build.cleanNtdll[patch.arch],
              let expectedOutput = build.patchedNtdll[patch.arch]
        else {
            throw StepFailure(
                step: step,
                detail: "Build \(build.bundleVersion) records no \(patch.arch.rawValue) ntdll hashes."
            )
        }

        guard let inputHash = Digest.sha256IfPresent(source) else {
            throw StepFailure(
                step: step, detail: "There is no ntdll to patch at \(source.path(percentEncoded: false))."
            )
        }
        guard inputHash == expectedInput else {
            throw StepFailure(
                step: step,
                detail: "The \(patch.arch.rawValue) ntdll at \(source.path(percentEncoded: false)) hashes "
                    + "\(inputHash.prefix(16)) and build \(build.bundleVersion) expects "
                    + "\(expectedInput.prefix(16)). It is already patched, or from another CrossOver build."
            )
        }

        let image: Data
        do {
            image = try Data(contentsOf: source)
        } catch {
            throw StepFailure(
                step: step,
                detail: "\(source.path(percentEncoded: false)) could not be read. \(error.localizedDescription)"
            )
        }

        let patched = try apply(patch, to: image, payload: try payload(for: patch))

        let outputHash = Digest.sha256(of: patched)
        guard outputHash == expectedOutput else {
            throw StepFailure(
                step: step,
                detail: "The patched \(patch.arch.rawValue) ntdll hashes \(outputHash.prefix(16)) and build "
                    + "\(build.bundleVersion) expects \(expectedOutput.prefix(16)). Nothing was written."
            )
        }

        try atomicReplace(destination, with: patched, step: step)
        return outputHash
    }

    @discardableResult
    static func stage(
        build: RunnerBuild, runnerRoot: URL, bridge: URL = SupportPaths.bridge
    ) throws -> [WineArch] {
        var written: [WineArch] = []

        for patch in patches(for: build) {
            let destination = bridge.appending(path: "wine/\(patch.arch.rawValue)/ntdll.dll")

            if Digest.sha256IfPresent(destination) == build.patchedNtdll[patch.arch] { continue }

            try write(patch, build: build, from: cleanSource(inRoot: runnerRoot, arch: patch.arch),
                      to: destination)
            written.append(patch.arch)
        }

        prune(keeping: patches(for: build).map(\.arch), in: bridge)

        return written
    }

    private static func prune(keeping arches: [WineArch], in bridge: URL) {
        let fm = FileManager.default

        for arch in WineArch.allCases where !arches.contains(arch) {
            let directory = bridge.appending(path: "wine/\(arch.rawValue)")
            try? fm.removeItem(at: directory.appending(path: "ntdll.dll"))

            let path = directory.path(percentEncoded: false)
            if let left = try? fm.contentsOfDirectory(atPath: path), left.isEmpty {
                try? fm.removeItem(at: directory)
            }
        }
    }

}
