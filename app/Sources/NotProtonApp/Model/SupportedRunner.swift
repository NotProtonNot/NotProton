// Allow list of CrossOver builds the runner clones from. The ntdll hook sites
// are hardcoded RVAs, so a build not pinned here would be patched at the wrong
// offsets. New builds go in after running ntdll-patch/resolve.py and pinning
// the hashes.

import Foundation

enum WineArch: String, Sendable, CaseIterable {
    case x86_64Windows = "x86_64-windows"
    case i386Windows = "i386-windows"
    case aarch64Windows = "aarch64-windows"
}

struct RunnerBuild: Sendable, Equatable, Identifiable {
    // CFBundleVersion, which also names the directory under runners/ and keys
    // the ntdll hash tables. Changing it orphans an installed runner.
    let bundleVersion: String

    // CFBundleShortVersionString. CrossOver inverts the usual pair and sets this
    // to the build date, so it is the string the download page shows. Display
    // only, never identity.
    let releaseVersion: String

    let flavor: String?

    let loaderSHA256: String

    let cleanNtdll: [WineArch: String]
    let patchedNtdll: [WineArch: String]

    var tools: [CompatTool] = []

    // Set when the runner comes from a modified copy of this build. The copy has
    // the same loader and ntdll, so it is checked and patched the same way, but it
    // gets its own runner directory and tools.
    var variant: String? = nil

    var baseID: String { flavor.map { "\(bundleVersion)-\($0)" } ?? bundleVersion }

    var id: String { variant.map { "\(baseID)-\($0)" } ?? baseID }

    var flavorName: String { flavor?.uppercased() ?? "Rosetta" }

    var displayVersion: String {
        let version = "\(releaseVersion) \(flavorName)"
        return variant.map { "\(version) · \(RunnerVariant.label($0))" } ?? version
    }

    func withVariant(_ variant: String?) -> RunnerBuild {
        guard let variant else { return self }
        var copy = self
        copy.variant = variant
        let label = RunnerVariant.label(variant)
        copy.tools = tools.map {
            CompatTool(name: "\($0.name)-\(variant)", flavor: $0.flavor,
                       display: "\($0.display) · \(label)", short: $0.short.map { "\($0) · \(label)" })
        }
        return copy
    }
}

enum RunnerVariant {
    // A copy names itself with this file at the root of its CrossOver directory.
    static let markerName = "notproton-variant"

    // The dylib skips a tools line whose name, build or display outgrows its
    // fields (compat.c), so a long name would drop the tool from Steam.
    static let maxLength = 16

    // GPTK Patcher leaves this receipt in the CrossOver tree it changed.
    static let patcherReceipt = "gptkpatcher-receipt.json"

    // A marker names the copy. Without one, a copy GPTK Patcher changed is named
    // after what it put in, so it gets its own runner beside the stock build.
    static func declared(crossOverRoot root: URL) -> String? {
        marked(crossOverRoot: root) ?? patched(crossOverRoot: root)
    }

    // The first line of the marker as an id: lower-case letters and digits.
    static func marked(crossOverRoot root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appending(path: markerName), encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        let id = String(line.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(maxLength))
        // "fex" would read as the FEX build's id.
        return id.isEmpty || id == "fex" ? nil : id
    }

    private struct Receipt: Decodable {
        let gptkD3DMetalVersion: String?
        let dxmtVersion: String?
    }

    // "gptk40b2-dxmt080" for D3DMetal 4.0b2 and DXMT 0.80.
    static func patched(crossOverRoot root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appending(path: patcherReceipt)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return nil }
        func segment(_ prefix: String, _ version: String?) -> String? {
            let digits = String((version ?? "").lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
            return digits.isEmpty ? nil : prefix + digits
        }
        let id = [segment("gptk", receipt.gptkD3DMetalVersion), segment("dxmt", receipt.dxmtVersion)]
            .compactMap { $0 }.joined(separator: "-")
        let capped = String(id.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return capped.isEmpty ? nil : capped
    }

    // A copy's own name, a patcher's two parts, and a toolkit runner's D3DMetal.
    static func isVariant(_ suffix: String) -> Bool {
        suffix.wholeMatch(of: #/[a-z0-9]+(-[a-z0-9]+){0,2}/#) != nil
    }

    static func label(_ variant: String) -> String {
        // The dot goes back after the major, so "40b2" reads 4.0b2 and "080" reads 0.80.
        func dotted(_ digits: Substring) -> String {
            guard digits.count > 1, digits.first?.isNumber == true,
                  digits.dropFirst().first?.isNumber == true else { return String(digits) }
            return "\(digits.prefix(1)).\(digits.dropFirst())"
        }
        return variant.split(separator: "-").map { part in
            for (prefix, name) in [("d3dm", "D3DMetal"), ("gptk", "GPTK"), ("dxmt", "DXMT")]
            where part.hasPrefix(prefix) && part.dropFirst(prefix.count).first?.isNumber == true {
                let rest = part.dropFirst(prefix.count)
                return "\(name) \(prefix == "d3dm" ? String(rest) : dotted(rest))"
            }
            return String(part)
        }.joined(separator: " · ")
    }

    // The D3DMetal major a toolkit runner was set up with: 3 for "<build>-d3dm3".
    static func d3dmetal(of build: RunnerBuild) -> String? {
        guard let last = build.variant?.split(separator: "-").last, last.hasPrefix("d3dm") else { return nil }
        return String(last.dropFirst(4))
    }

    static func d3dmetalMajor(_ toolkit: URL) -> String? {
        let plist = toolkit.appending(path: "external/D3DMetal.framework/Versions/A/Resources/Info.plist")
        let version = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
        return version?.split(separator: ".").first.map(String.init)
    }

    // The D3DMetal major in apple_gptk, the one CrossOver loads: lib64 in
    // CrossOver 25 and 26, lib in CrossOver 27.
    static func activeMajor(crossOverRoot root: URL) -> String? {
        d3dmetalMajor(root.appending(path: "lib64/apple_gptk")) ?? d3dmetalMajor(root.appending(path: "lib/apple_gptk"))
    }

    // Toolkit directories beside lib64/apple_gptk (apple_gptk_3, apple_gptk_4, ...),
    // one per D3DMetal major that apple_gptk does not already have. Only lib64,
    // where CrossOver 26 keeps its toolkit: CrossOver 27 (lib/) already picks a
    // D3DMetal per game with CX_GRAPHICS_BACKEND_VERSION.
    static func otherToolkits(crossOverRoot root: URL) -> [(path: String, major: String)] {
        let dir = root.appending(path: "lib64")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
        else { return [] }
        var seen = Set([activeMajor(crossOverRoot: root)].compactMap { $0 })
        var found: [(path: String, major: String)] = []
        for name in names.sorted() where name.hasPrefix("apple_gptk") && name != "apple_gptk" {
            guard let major = d3dmetalMajor(dir.appending(path: name)), seen.insert(major).inserted else { continue }
            found.append(("lib64/\(name)", major))
        }
        return found
    }
}

struct CompatTool: Sendable, Hashable, Identifiable {
    enum Flavor: String, Sendable, CaseIterable {
        case rosetta
        case fex

        var name: String { self == .fex ? "FEX" : "Rosetta" }
        var unixDir: String { self == .fex ? "aarch64-unix" : "x86_64-unix" }
    }

    let name: String
    let flavor: Flavor
    let display: String
    var short: String? = nil

    var id: String { name }
    var shortDisplay: String { short ?? display }

    var prefixArch: PrefixArch { flavor == .fex ? .arm64 : .x86_64 }
}

struct InstalledTool: Sendable, Hashable, Identifiable {
    let tool: CompatTool
    let build: String

    var id: String { tool.name }
    var name: String { tool.name }
    var display: String { tool.display }
    var shortDisplay: String { tool.shortDisplay }
}

enum SupportedRunners {

    // First entry is what windows-only games get when Steam has no mapping.
    static let toolPreference = [
        legacyToolName, "notproton-fex", "notproton-fex-rosetta", "notproton-preview",
        "notproton-fex-41069", "notproton-fex-rosetta-41069", "notproton-preview-41069", "notproton-26.3",
    ]

    static let legacyToolName = "notproton"

    // The only builds that can own the 'notproton' tool name.
    static let legacyHolders = ["27.0.0.40921-fex", "27.0.0.40921", "27.0.0.41069-fex", "27.0.0.41069"]

    enum LegacyHolder: Equatable, Sendable {
        case build(String)
        case nobody
    }

    // d3dmetal gives the D3DMetal major a build's copy runs, named on tools that do
    // not already carry it in their variant.
    static func tools(
        for builds: [RunnerBuild], legacy: LegacyHolder = .nobody, d3dmetal: (RunnerBuild) -> String? = { _ in nil }
    ) -> [InstalledTool] {
        let holder: String? = switch legacy {
        case .build(let id): id
        case .nobody: nil
        }
        // The builds given, not `all`: variants are installed but never pinned.
        let pinned = Set(all.map(\.id))
        let served = builds.filter { pinned.contains($0.baseID) }.flatMap { build in
            let label = RunnerVariant.d3dmetal(of: build) == nil ? d3dmetal(build).map { " · D3DMetal \($0)" } : nil
            return build.tools.enumerated().map { index, tool in
                let name = build.id == holder && index == 0 ? legacyToolName : tool.name
                return InstalledTool(
                    tool: CompatTool(name: name, flavor: tool.flavor, display: tool.display + (label ?? ""),
                                     short: tool.short.map { $0 + (label ?? "") }),
                    build: build.id
                )
            }
        }
        func rank(_ tool: InstalledTool) -> Int {
            toolPreference.firstIndex(of: tool.name) ?? toolPreference.count
        }
        return served.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    static let all: [RunnerBuild] = [
        RunnerBuild(
            bundleVersion: "26.3.0.39832",
            releaseVersion: "26.3",
            flavor: nil,
            loaderSHA256: "b5edb0444b5b25ba0aa5091be1cba11680130895c338cc8044101bce98802a63",
            cleanNtdll: [
                .x86_64Windows: "6dff64c00793ce92124f1316985c63783f539f26b392975c70f57637458d2387",
                .i386Windows: "2c60ee6b00dd13b7f6cb11017778a041ba6a321eaea194f1fa0dca7eab8403e2",
            ],
            patchedNtdll: [
                .x86_64Windows: "c0e21a9a5250f0a97c08d3c3e1798566255387213e2553b1e555264fb9ded97e",
                .i386Windows: "e641d7b2e81ee13877823494679ba2d87e0d61b8a87e8a1ce92b4fe73631ae74",
            ],
            tools: [
                CompatTool(name: "notproton-26.3", flavor: .rosetta, display: "CrossOver 26.3"),
            ]
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.40921",
            releaseVersion: "20260821",
            flavor: nil,
            loaderSHA256: "b59d5fdccb62d425230a4e4d157c50c25b63ff586832c60cc5b12b4d6053ab80",
            cleanNtdll: [
                .x86_64Windows: "04c7200b6645decb7c2d1ba6b0195abc9af83257072558d11aa72cc067ac3377",
                .i386Windows: "94cc7c14c1e9dcf58ef501015c115f8405c73b2a65cefe31faa5d9e47f36e58b",
            ],
            patchedNtdll: [
                .x86_64Windows: "b6a98622fb8f7e6a998bc038f442b17d257da3df5e9e135f0c35f7bbc46ea5d6",
                .i386Windows: "25bfde1f50ee96485763968ef10b9d9ad35e38214232f17ebdc009b098af44a0",
            ],
            tools: [
                CompatTool(name: "notproton-preview", flavor: .rosetta, display: "CrossOver 20260821 (X86) - Rosetta", short: "20260821 (X86) - Rosetta"),
            ]
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.40921",
            releaseVersion: "20260821",
            flavor: "fex",
            loaderSHA256: "7a6ea337c9caf2217454bec9537371e5d8ca302406bbed40b65316c1a636c4ab",
            cleanNtdll: [
                .x86_64Windows: "f4fa556a3dc20f6e966a803f5de554359227a61a24cd5b5a2ad88a427ceeec58",
                .i386Windows: "09474795d6f306163cebab6429819999fcff50e07dbc4b067a90ec4f74a3a7d7",
                .aarch64Windows: "7823d71fbce6c9947163bf8b96beb299eabb02878245bcaf6759f2a22e81f071",
            ],
            patchedNtdll: [
                .x86_64Windows: "fa8cd8fe7c4c19effade92d55b00fa946b630ab13cbb6721076848238c1dcf6a",
                .i386Windows: "e799ea02418294588ee353a90b967358be316a3044ff9515b28aa1ce07e63981",
                .aarch64Windows: "f40810193a5ef2520774288f354a8604f5ba91828315f643b3ee6688b873dc3f",
            ],
            tools: [
                CompatTool(name: "notproton-fex", flavor: .fex, display: "CrossOver 20260821 (ARM64) - FEX", short: "20260821 (ARM64) - FEX"),
                CompatTool(name: "notproton-fex-rosetta", flavor: .rosetta, display: "CrossOver 20260821 (ARM64) - Rosetta", short: "20260821 (ARM64) - Rosetta"),
            ]
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.41069",
            releaseVersion: "20261006",
            flavor: nil,
            loaderSHA256: "8286bfd0c6d2ae337e11784926d371a9f7ed7e8da870bd2f435c2bce8eb3c148",
            cleanNtdll: [
                .x86_64Windows: "5b388fd48823e905616432fba627eb48f68dc14383963bb213d55db3f691b1b9",
                .i386Windows: "e7da2a712870222942ef27a80b3bf4fa70fc8545dd1a64bdc7f2fa24a38debc3",
            ],
            patchedNtdll: [
                .x86_64Windows: "9569625387cf179d306b004c556273e2ec15811b2cfd51f21d078e2a0aa06f7f",
                .i386Windows: "0d8e3ebb57b3173f675eef5e3a0950052c592efa10a7a10193b0beb811b55ea5",
            ],
            tools: [
                CompatTool(name: "notproton-preview-41069", flavor: .rosetta, display: "CrossOver 20261006 (X86) - Rosetta", short: "20261006 (X86) - Rosetta"),
            ]
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.41069",
            releaseVersion: "20261006",
            flavor: "fex",
            loaderSHA256: "ef2b9a0ad185d8caa2960a97c135a75b8b85ca62425599e35cf672f787fba64c",
            cleanNtdll: [
                .x86_64Windows: "1b02dcf6ad9d9490870f1127a421c4c0d1471c65ec1574e1e84c05d69801ac7e",
                .i386Windows: "66b1a244a611795c59a93a9491d17f36c98cd8db9be495004a37864e0e5ed4a5",
                .aarch64Windows: "77ca83b2e1a3a1242f9d2d8868328262b2bcfc3f59bacf8b9389ea7e797ea852",
            ],
            patchedNtdll: [
                .x86_64Windows: "7548abd874656f6a6455e7fac659020ed755d92f4e1929a33097bbde964699f5",
                .i386Windows: "e16b0199db721a08201b1512476b9eff255624d2faf3696fa57ff74b1a54be5c",
                .aarch64Windows: "7623c0b33350f511b431d39c7ec0c0d4f5def4183acef0eee5d4a5c694898956",
            ],
            tools: [
                CompatTool(name: "notproton-fex-41069", flavor: .fex, display: "CrossOver 20261006 (ARM64) - FEX", short: "20261006 (ARM64) - FEX"),
                CompatTool(name: "notproton-fex-rosetta-41069", flavor: .rosetta, display: "CrossOver 20261006 (ARM64) - Rosetta", short: "20261006 (ARM64) - Rosetta"),
            ]
        ),
    ]

    static func build(loaderSHA256 hash: String) -> RunnerBuild? {
        all.first { $0.loaderSHA256 == hash }
    }

    static func build(id: String) -> RunnerBuild? {
        if let exact = all.first(where: { $0.id == id }) { return exact }
        // "<pinned id>-<variant>". The longest match wins, so a FEX variant stays FEX.
        guard let base = all.filter({ id.hasPrefix($0.id + "-") }).max(by: { $0.id.count < $1.id.count })
        else { return nil }
        let variant = String(id.dropFirst(base.id.count + 1))
        return RunnerVariant.isVariant(variant) ? base.withVariant(variant) : nil
    }

    static func displayVersion(forID id: String) -> String {
        build(id: id)?.displayVersion ?? id
    }

    static var versionList: String {
        var seen = Set<String>()
        return all.map(\.releaseVersion)
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }
}
