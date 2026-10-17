// Caps the input report queue in CrossOver's winebus.sys.
//
// winebus queues every HID input report until hidclass reads it and never drops one, so
// a device that sends faster than Wine reads builds up input lag without bound. Steam's
// virtual gamepad sends a report for every stick jitter, about 830 a second, and under
// Rosetta winedevice.exe falls behind it within minutes. The detour in winebus-patch/cap.S
// keeps the 32 newest reports, as the native HID class ring buffer does.

import Foundation

struct WinebusPatch: Sendable {
    // Only x86_64 so far. The aarch64 winebus.sys a FEX build also ships is not patched.
    let arch: WineArch

    let cleanSHA256: String
    let patchedSHA256: String

    let payloadResource: String
    let payloadSHA256: String

    // The call to memcpy right after the inlined list_add_tail in bus_main_thread, which
    // the patch points at the cave instead.
    let hookRVA: Int
    let hookTargetRVA: Int

    // The padding after the code in .text, which the linker fills with cavePad.
    let caveRVA: Int
    var cavePad: UInt8 = 0x00
}

enum WinebusPatcher {

    static let step = String(localized: "Patch winebus")

    private static let machineAMD64: UInt16 = 0x8664
    private static let magicPE32Plus: UInt16 = 0x20b
    private static let callRel32: UInt8 = 0xe8

    // A FEX build's x86_64 winebus.sys, which its Rosetta tool loads, is a different binary
    // from the Rosetta build's, so it has its own pins.
    static let byBuild: [String: [WinebusPatch]] = [
        "26.3.0.39832": [
            WinebusPatch(
                arch: .x86_64Windows,
                cleanSHA256: "63fd9c2f064af697e28d8bd49cdff4579e44994ceecf52a836130227cf824c5a",
                patchedSHA256: "c7296f181486456c4ab8d3bac895bbc8472832cc0aeba883f8a32683bf67d791",
                payloadResource: "winebus-cap-cx26",
                payloadSHA256: "92d9d442398d5ad684acf68dcf427ec7531ace65e2315c06621676256ff525a5",
                hookRVA: 0x1f6a,
                hookTargetRVA: 0x1100,
                caveRVA: 0x6840
            ),
        ],
        "27.0.0.40921": [
            WinebusPatch(
                arch: .x86_64Windows,
                cleanSHA256: "6e983df1f54ac8f64c925c3e32f72ba019777cf8dfc58e45d2b19341db67128d",
                patchedSHA256: "80ff9102e38024ec07ac986713b4f59434e5553e1e38f7f20a3bae8481ac8901",
                payloadResource: "winebus-cap-40921",
                payloadSHA256: "f1b61669c9780969124cad88e490651634c7bb45f34e783b80bedaa5a1bf5942",
                hookRVA: 0x2110,
                hookTargetRVA: 0x1100,
                caveRVA: 0x6b40
            ),
        ],
        "27.0.0.40921-fex": [
            WinebusPatch(
                arch: .x86_64Windows,
                cleanSHA256: "f8bac65ceb1cab3930e7028a242a7c2684c65c2aabdb033325793f54d3b4fa3e",
                patchedSHA256: "13a505a45848e5cba2a6adbea66174f129c81b320e10194f827d1b1d5a0bc0e7",
                payloadResource: "winebus-cap-fex-40921",
                payloadSHA256: "095fccc33427852b7780216773fe0fd0868fb61b041e34663db7b8606f3fbf58",
                hookRVA: 0x432a,
                hookTargetRVA: 0x5be0,
                caveRVA: 0x5f00,
                cavePad: 0xcc
            ),
        ],
        "27.0.0.41069": [
            WinebusPatch(
                arch: .x86_64Windows,
                cleanSHA256: "fd60af0afdeac0d19c23e134d1d2f66d3376eebac1904d5e644e24500fc8b8ea",
                patchedSHA256: "57df15bc49f77d94578cde325953c84ea8d7d363a908323133374f52f3cb00f8",
                payloadResource: "winebus-cap-41069",
                payloadSHA256: "120620526ae5066285abea6b94f4bee35321732f538507c46503d0e3b1b5d6e4",
                hookRVA: 0x2110,
                hookTargetRVA: 0x1100,
                caveRVA: 0x6c20
            ),
        ],
        "27.0.0.41069-fex": [
            WinebusPatch(
                arch: .x86_64Windows,
                cleanSHA256: "09594bcc90bd55935f5f07a887efaee362ac800b3ba15ca7eb2809eb142ec1ce",
                patchedSHA256: "df89dc44d547f23dcba699f2d402af90902edf39f847c88f5c3e996a8839fae2",
                payloadResource: "winebus-cap-fex-41069",
                payloadSHA256: "cde2fa77b8739935cc5700f095a1a48c8a0b14d5d71946049dba1767fe0f58bb",
                hookRVA: 0x4473,
                hookTargetRVA: 0x5d00,
                caveRVA: 0x6020,
                cavePad: 0xcc
            ),
        ],
        // 41073 ships the very same winebus.sys as 41069, in both its builds.
        "27.0.0.41073": [
            WinebusPatch(
                arch: .x86_64Windows,
                cleanSHA256: "fd60af0afdeac0d19c23e134d1d2f66d3376eebac1904d5e644e24500fc8b8ea",
                patchedSHA256: "57df15bc49f77d94578cde325953c84ea8d7d363a908323133374f52f3cb00f8",
                payloadResource: "winebus-cap-41069",
                payloadSHA256: "120620526ae5066285abea6b94f4bee35321732f538507c46503d0e3b1b5d6e4",
                hookRVA: 0x2110,
                hookTargetRVA: 0x1100,
                caveRVA: 0x6c20
            ),
        ],
        "27.0.0.41073-fex": [
            WinebusPatch(
                arch: .x86_64Windows,
                cleanSHA256: "09594bcc90bd55935f5f07a887efaee362ac800b3ba15ca7eb2809eb142ec1ce",
                patchedSHA256: "df89dc44d547f23dcba699f2d402af90902edf39f847c88f5c3e996a8839fae2",
                payloadResource: "winebus-cap-fex-41069",
                payloadSHA256: "cde2fa77b8739935cc5700f095a1a48c8a0b14d5d71946049dba1767fe0f58bb",
                hookRVA: 0x4473,
                hookTargetRVA: 0x5d00,
                caveRVA: 0x6020,
                cavePad: 0xcc
            ),
        ],
    ]

    static func patches(for build: RunnerBuild) -> [WinebusPatch] {
        byBuild[build.id] ?? []
    }

    static func live(inRoot root: URL, arch: WineArch) -> URL {
        root.appending(path: "lib/wine/\(arch.rawValue)/winebus.sys")
    }

    // The patched image of `source`, or nil when `source` is not the stock winebus.sys the
    // patch was pinned against, such as a rebuild's own copy.
    static func patchedImage(_ patch: WinebusPatch, build: RunnerBuild, from source: URL) throws -> Data? {
        guard Digest.sha256IfPresent(source) == patch.cleanSHA256 else { return nil }

        let image: Data
        do {
            image = try Data(contentsOf: source)
        } catch {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(source.path(percentEncoded: false)) could not be read. \(error.localizedDescription)")
            )
        }

        let patched = try apply(patch, to: image, payload: try payload(for: patch))
        let hash = Digest.sha256(of: patched)
        guard hash == patch.patchedSHA256 else {
            throw StepFailure(
                step: step,
                detail: String(localized: "The patched winebus.sys hashes \(String(hash.prefix(16))) and build \(build.bundleVersion) expects \(String(patch.patchedSHA256.prefix(16))). Nothing was written.")
            )
        }
        return patched
    }

    static func apply(_ patch: WinebusPatch, to image: Data, payload: Data) throws -> Data {
        var bytes = [UInt8](image)

        guard let pe = u32(bytes, 0x3c).map(Int.init), u32(bytes, pe) == 0x0000_4550,
              u16(bytes, pe + 4) == machineAMD64, u16(bytes, pe + 24) == magicPE32Plus,
              let sections = u16(bytes, pe + 6).map(Int.init),
              let optionalSize = u16(bytes, pe + 20).map(Int.init)
        else {
            throw StepFailure(step: step, detail: String(localized: "winebus.sys is not an x86_64 PE image."))
        }

        let optional = pe + 24
        let table = optional + optionalSize
        guard let header = (0 ..< sections).map({ table + $0 * 40 }).first(where: { entry in
            guard let virtualAddress = u32(bytes, entry + 12).map(Int.init),
                  let rawSize = u32(bytes, entry + 16).map(Int.init) else { return false }
            return patch.hookRVA >= virtualAddress && patch.hookRVA + 5 <= virtualAddress + rawSize
        }), let virtualSize = u32(bytes, header + 8).map(Int.init),
              let virtualAddress = u32(bytes, header + 12).map(Int.init),
              let rawSize = u32(bytes, header + 16).map(Int.init),
              let rawOffset = u32(bytes, header + 20).map(Int.init),
              rawOffset + rawSize <= bytes.count
        else {
            throw StepFailure(step: step, detail: String(localized: "winebus.sys is not an x86_64 PE image."))
        }

        func offset(_ rva: Int) -> Int { rawOffset + rva - virtualAddress }

        let expected = [callRel32] + rel32(from: patch.hookRVA, to: patch.hookTargetRVA)
        let present = Array(bytes[offset(patch.hookRVA) ..< offset(patch.hookRVA) + expected.count])
        guard present == expected else {
            throw StepFailure(
                step: step,
                detail: String(localized: "The winebus.sys hook site at \(hex(patch.hookRVA)) holds \(hex(present)) instead of \(hex(expected)), so the offsets do not belong to this build.")
            )
        }

        // The cave has to start past the code and fit in the section's file-backed padding.
        let caveEnd = patch.caveRVA + payload.count
        guard patch.caveRVA >= virtualAddress + virtualSize, caveEnd <= virtualAddress + rawSize,
              bytes[offset(patch.caveRVA) ..< offset(caveEnd)].allSatisfy({ $0 == patch.cavePad })
        else {
            throw StepFailure(
                step: step,
                detail: String(localized: "The winebus.sys cave at \(hex(patch.caveRVA)) is not empty padding after the code, so writing the detour could overwrite live code.")
            )
        }

        bytes.replaceSubrange(offset(patch.caveRVA) ..< offset(caveEnd), with: payload)
        bytes.replaceSubrange(offset(patch.hookRVA) ..< offset(patch.hookRVA) + expected.count,
                              with: [callRel32] + rel32(from: patch.hookRVA, to: patch.caveRVA))
        put32(UInt32(caveEnd - virtualAddress), at: header + 8, in: &bytes)
        put32(checksum(bytes, field: optional + 64), at: optional + 64, in: &bytes)

        return Data(bytes)
    }

    // The PE image checksum, which skips its own field.
    static func checksum(_ bytes: [UInt8], field: Int) -> UInt32 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            if index != field && index != field + 2 {
                sum += UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
                sum = (sum & 0xffff) + (sum >> 16)
            }
            index += 2
        }
        if bytes.count % 2 == 1 { sum += UInt32(bytes[bytes.count - 1]) }
        sum = (sum & 0xffff) + (sum >> 16)
        return (sum & 0xffff) + UInt32(bytes.count)
    }

    private static func rel32(from callRVA: Int, to targetRVA: Int) -> [UInt8] {
        withUnsafeBytes(of: Int32(truncatingIfNeeded: targetRVA - (callRVA + 5)).littleEndian, Array.init)
    }

    private static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0 ..< 4 { bytes[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xff) }
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (0 ..< 4).reversed().reduce(0) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    private static func hex(_ value: Int) -> String { "0x" + String(value, radix: 16) }
    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // Resources

    static func payload(for patch: WinebusPatch) throws -> Data {
        guard let url = Bundle.module.url(forResource: patch.payloadResource, withExtension: "bin") else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(patch.payloadResource).bin is missing from the app's resources.")
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(patch.payloadResource).bin could not be read. \(error.localizedDescription)")
            )
        }

        let hash = Digest.sha256(of: data)
        guard hash == patch.payloadSHA256 else {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(patch.payloadResource).bin hashes \(String(hash.prefix(16))) and should hash \(String(patch.payloadSHA256.prefix(16))), so the shipped detour is not the one that was built.")
            )
        }
        return data
    }
}
