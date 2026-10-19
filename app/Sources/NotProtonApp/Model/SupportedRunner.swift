// Allow list of runtime builds the runner clones from. The ntdll hook sites
// are hardcoded RVAs, so a build not pinned here would be patched at the wrong
// offsets. New builds go in after running ntdll-patch/resolve.py and pinning
// the hashes.

import Foundation

enum WineArch: String, Sendable, CaseIterable {
    case x86_64Windows = "x86_64-windows"
    case i386Windows = "i386-windows"
    case aarch64Windows = "aarch64-windows"
}

enum RuntimeProvider: Sendable {
    case crossOver
    case whisky
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

    var rebuilds: [RunnerRebuild] = []

    var runtimeName: String? = nil

    var provider: RuntimeProvider { runtimeName == nil ? .crossOver : .whisky }
    var name: String { runtimeName ?? "CrossOver" }
    var version: String { releaseVersion }
    var patchesNtdll: Bool { !patchedNtdll.isEmpty }

    static func whisky(name: String, version: String,
                       cleanNtdll: [WineArch: String] = [:],
                       patchedNtdll: [WineArch: String] = [:]) -> RunnerBuild {
        let id = "\(name)-\(version)"
        return RunnerBuild(
            bundleVersion: id, releaseVersion: version, flavor: nil, loaderSHA256: "",
            cleanNtdll: cleanNtdll, patchedNtdll: patchedNtdll,
            tools: [CompatTool(name: "notproton-whisky-\(id)", flavor: .rosetta,
                               display: "\(name) \(version) (Whisky)")], runtimeName: name)
    }

    static func native(name: String, version: String) -> RunnerBuild {
        whisky(name: name, version: version)
    }

    var id: String { flavor.map { "\(bundleVersion)-\($0)" } ?? bundleVersion }

    func matching(loaderSHA256 hash: String) -> RunnerBuild? {
        if hash == loaderSHA256 { return self }
        guard let rebuild = rebuilds.first(where: { $0.loaderSHA256 == hash }) else { return nil }
        return RunnerBuild(
            bundleVersion: bundleVersion, releaseVersion: releaseVersion, flavor: flavor,
            loaderSHA256: rebuild.loaderSHA256, cleanNtdll: rebuild.cleanNtdll,
            patchedNtdll: rebuild.patchedNtdll, tools: tools, rebuilds: rebuilds
        )
    }

    var flavorName: String { flavor?.uppercased() ?? "Rosetta" }

    var displayVersion: String { provider == .whisky ? "\(name) \(version)" : "\(releaseVersion) \(flavorName)" }
}

// The version of CrossOver offered in China has different hashes but is identical in the ways that matter
struct RunnerRebuild: Sendable, Equatable {
    let loaderSHA256: String
    let cleanNtdll: [WineArch: String]
    let patchedNtdll: [WineArch: String]
}

struct CompatTool: Sendable, Hashable, Identifiable {
    enum Flavor: String, Sendable, CaseIterable {
        case rosetta
        case fex

        var name: String { self == .fex ? "FEX" : "Rosetta" }
        var unixDir: String { self == .fex ? "aarch64-unix" : "x86_64-unix" }

        // CrossOver's FEX build needs Tahoe. Its Rosetta tool runs on Sequoia.
        static let fexAvailable = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
    }

    let name: String
    let flavor: Flavor
    let display: String

    var id: String { name }

    var prefixArch: PrefixArch { flavor == .fex ? .arm64 : .x86_64 }
}

struct InstalledTool: Sendable, Hashable, Identifiable {
    let tool: CompatTool
    let build: String

    var id: String { tool.name }
    var name: String { tool.name }
    var display: String { tool.display }
}

enum SupportedRunners {

    // First entry is what windows-only games get when Steam has no mapping.
    static let toolPreference = [
        legacyToolName, "notproton-fex", "notproton-fex-rosetta", "notproton-preview",
        "notproton-fex-41069", "notproton-fex-rosetta-41069", "notproton-preview-41069",
        "notproton-fex-41073", "notproton-fex-rosetta-41073", "notproton-preview-41073", "notproton-26.3",
    ]

    static let legacyToolName = "notproton"

    // The only builds that can own the 'notproton' tool name.
    static let legacyHolders = ["27.0.0.40921-fex", "27.0.0.40921", "27.0.0.41069-fex", "27.0.0.41069"]

    enum LegacyHolder: Equatable, Sendable {
        case build(String)
        case nobody
    }

    static func tools(
        for builds: [RunnerBuild], legacy: LegacyHolder = .nobody,
        fexAvailable: Bool = CompatTool.Flavor.fexAvailable, keeping kept: Set<String> = []
    ) -> [InstalledTool] {
        let installed = Set(builds.map(\.id))
        let holder: String? = switch legacy {
        case .build(let id): id
        case .nobody: nil
        }
        let catalog = all.filter { installed.contains($0.id) }
            + builds.filter { candidate in !all.contains(where: { $0.id == candidate.id }) }
        let served = catalog.flatMap { build in
            build.tools.enumerated().map { index, tool in
                let name = build.id == holder && index == 0 ? legacyToolName : tool.name
                return InstalledTool(
                    tool: CompatTool(name: name, flavor: tool.flavor, display: tool.display), build: build.id
                )
            }
        }.filter { $0.tool.flavor != .fex || fexAvailable || kept.contains($0.name) }
        func rank(_ tool: InstalledTool) -> Int {
            if builds.first(where: { $0.id == tool.build })?.provider == .whisky { return -1 }
            return toolPreference.firstIndex(of: tool.name) ?? toolPreference.count
        }
        return served.enumerated()
            .sorted {
                let a = rank($0.element), b = rank($1.element)
                if a != b { return a < b }
                if a == -1 {
                    let aid = $0.element.build, bid = $1.element.build
                    let av = builds.first { $0.id == aid }?.version ?? ""
                    let bv = builds.first { $0.id == bid }?.version ?? ""
                    if av != bv { return av.compare(bv, options: .numeric) == .orderedDescending }
                    return $0.element.build < $1.element.build
                }
                return $0.offset < $1.offset
            }
            .map(\.element)
    }

    static let all: [RunnerBuild] = crossOver + whisky

    static let whisky: [RunnerBuild] = [
        RunnerBuild.whisky(
            name: "winecx-gptk",
            version: "4.7.54",
            cleanNtdll: [
                .x86_64Windows: "5e4a782ef6c5e79f70cda10083b786fda89f1364c1e4c1de00654ff61d4ea762",
                .i386Windows: "0540c0e79b0316a4ecbe884fa88b438ae63a2dcf0b246081a0e9fc0a9a09eb26",
            ],
            patchedNtdll: [
                .x86_64Windows: "db7f5204da7490afa0bbf3cdcf0f9f988b903a542219abbe3d310a6d3d8c70bb",
                .i386Windows: "c2e13f7a9bacf0ead8579fa02dd3481094be29308847f6a4c762a700b4e0e1f2",
            ]
        ),
    ]

    static let crossOver: [RunnerBuild] = [
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
            ],
            rebuilds: [
                // crossoverchina.com
                RunnerRebuild(
                    loaderSHA256: "35aeb1a75a48f3b053dbf2395deac33c530a0b0b7db0bc6357362348af9514ce",
                    cleanNtdll: [
                        .x86_64Windows: "1c4799bb3769ba1392c2298e4904ce0b080f040940b2a273f4eaa0906b231a93",
                        .i386Windows: "21e7d0a6d6868f1853489f5a9798e706509a20a65ee370f50b37ab7b1cdcaae3",
                    ],
                    patchedNtdll: [
                        .x86_64Windows: "3725117cc103acd9d2713535e41733563f340e27604e1abdea5afbdc2c2be65a",
                        .i386Windows: "6d9ef05089fea07d1f4cbebe27df1f9a92dbc8eb245033db9f5e40a943175d5b",
                    ]
                ),
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
                CompatTool(name: "notproton-preview", flavor: .rosetta, display: "CrossOver 2026 08 21-X86 - Rosetta"),
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
                CompatTool(name: "notproton-fex", flavor: .fex, display: "CrossOver 2026 08 21-ARM64 - FEX"),
                CompatTool(name: "notproton-fex-rosetta", flavor: .rosetta, display: "CrossOver 2026 08 21-ARM64 - Rosetta"),
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
                CompatTool(name: "notproton-preview-41069", flavor: .rosetta, display: "CrossOver 2026 10 06-X86 - Rosetta"),
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
                CompatTool(name: "notproton-fex-41069", flavor: .fex, display: "CrossOver 2026 10 06-ARM64 - FEX"),
                CompatTool(name: "notproton-fex-rosetta-41069", flavor: .rosetta, display: "CrossOver 2026 10 06-ARM64 - Rosetta"),
            ]
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.41073",
            releaseVersion: "20261015",
            flavor: nil,
            loaderSHA256: "57144ccad16e75a171d48ea4b20974183e76c1cd5f5022bfc4b8917016b126b5",
            cleanNtdll: [
                .x86_64Windows: "f489347e59d4e8b43c2b0d2abbff9ee31e2059d45fd75fc04e2f4c0d8b04464a",
                .i386Windows: "5249b95eea6df765257b2e5212831f511d8f66134abe3c231b8e73d8f5b4707e",
            ],
            patchedNtdll: [
                .x86_64Windows: "901bff9138707d90efecc592bd9bd3062075a350add4b3a283b089c1da635a61",
                .i386Windows: "7d3df0ee9dd61693293ba74a8d2c588b4dce26fb7f7a78c0c5ed5bdc58869e14",
            ],
            tools: [
                CompatTool(name: "notproton-preview-41073", flavor: .rosetta, display: "CrossOver 2026 10 15-X86 - Rosetta"),
            ]
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.41073",
            releaseVersion: "20261015",
            flavor: "fex",
            loaderSHA256: "f4cedebfb30efc1e91e46ee25296abeb526fe7d814041d7cc6ca693bd4b8cb7b",
            cleanNtdll: [
                .x86_64Windows: "3d24426735defd222fd9518b094b738dc1c12afd13efc41a855013ed0f825129",
                .i386Windows: "3ee764335e50709285361e2542731385f0b06e593a76aa84a3c328c278164c4f",
                .aarch64Windows: "a6678f9d0818e1cdb325e1ce8a07a540433f544b6f756c52a6ab1cfd3f632408",
            ],
            patchedNtdll: [
                .x86_64Windows: "2b47ed8c19d1d15d0f82519d39d64bf34113b285c4ada325bb64c5e587326d33",
                .i386Windows: "3f4b0d9589c1f374e3c2fd135263f2bf3c8300e09dd010fd778936dd71e894ad",
                .aarch64Windows: "2efb13f3303adc2c8ee61b93e027e4e94730a2e6b0162c7e6aebd4104200f07c",
            ],
            tools: [
                CompatTool(name: "notproton-fex-41073", flavor: .fex, display: "CrossOver 2026 10 15-ARM64 - FEX"),
                CompatTool(name: "notproton-fex-rosetta-41073", flavor: .rosetta, display: "CrossOver 2026 10 15-ARM64 - Rosetta"),
            ]
        ),
    ]

    static func build(cleanNtdllSHA256 hash: String) -> RunnerBuild? {
        whisky.first { $0.cleanNtdll[.x86_64Windows] == hash }
    }

    static func build(loaderSHA256 hash: String) -> RunnerBuild? {
        crossOver.lazy.compactMap { $0.matching(loaderSHA256: hash) }.first
    }

    static func build(id: String) -> RunnerBuild? {
        all.first { $0.id == id }
    }

    static func displayVersion(forID id: String) -> String {
        build(id: id)?.displayVersion ?? id
    }

    static var versionList: String {
        var seen = Set<String>()
        return crossOver.map(\.releaseVersion)
            .filter { seen.insert($0).inserted }
            .joined(separator: ", ")
    }
}
