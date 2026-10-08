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

    // A free WineHQ engine NotProton downloads itself rather than a CrossOver
    // install. It has no license to check.
    var isFree = false

    var id: String { flavor.map { "\(bundleVersion)-\($0)" } ?? bundleVersion }

    var flavorName: String { flavor?.uppercased() ?? "Rosetta" }

    var displayVersion: String { "\(releaseVersion) \(flavorName)" }
}

enum SupportedRunners {

    static let all: [RunnerBuild] = [
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
                .x86_64Windows: "b21f4bace5a7a0cfef0f74cef9b27561f6eb3ad38daf76f36b186ca0677c2b2c",
                .i386Windows: "25bfde1f50ee96485763968ef10b9d9ad35e38214232f17ebdc009b098af44a0",
            ]
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.40921",
            releaseVersion: "20260821",
            flavor: "fex",
            loaderSHA256: "7a6ea337c9caf2217454bec9537371e5d8ca302406bbed40b65316c1a636c4ab",
            cleanNtdll: [
                .i386Windows: "09474795d6f306163cebab6429819999fcff50e07dbc4b067a90ec4f74a3a7d7",
                .aarch64Windows: "7823d71fbce6c9947163bf8b96beb299eabb02878245bcaf6759f2a22e81f071",
            ],
            patchedNtdll: [
                .i386Windows: "e799ea02418294588ee353a90b967358be316a3044ff9515b28aa1ce07e63981",
                .aarch64Windows: "560939a0f6e58314fc9d79fe6f839dce2b181f829ae58dca195fa142fcf40f39",
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
                .x86_64Windows: "e744e9a24e4401acc5038b490ddd146e6e9485fccf74d3b113c56f3e5854a1e2",
                .i386Windows: "0d8e3ebb57b3173f675eef5e3a0950052c592efa10a7a10193b0beb811b55ea5",
            ]
        ),
        RunnerBuild(
            bundleVersion: "27.0.0.41069",
            releaseVersion: "20261006",
            flavor: "fex",
            loaderSHA256: "ef2b9a0ad185d8caa2960a97c135a75b8b85ca62425599e35cf672f787fba64c",
            cleanNtdll: [
                .i386Windows: "66b1a244a611795c59a93a9491d17f36c98cd8db9be495004a37864e0e5ed4a5",
                .aarch64Windows: "77ca83b2e1a3a1242f9d2d8868328262b2bcfc3f59bacf8b9389ea7e797ea852",
            ],
            patchedNtdll: [
                .i386Windows: "e16b0199db721a08201b1512476b9eff255624d2faf3696fa57ff74b1a54be5c",
                .aarch64Windows: "89e4c9e7f0a0a60462c0231ec393168f8bdb04bc8ea1dc22211f25bf3ff2c6b3",
            ]
        ),
        RunnerBuild(
            bundleVersion: "winehq-11.15",
            releaseVersion: "WineHQ 11.15",
            flavor: nil,
            loaderSHA256: "8aa25e55f28a0634a7df04c02dd719d4bc20de645cf42b9ba7d0e3b7d8f66a80",
            cleanNtdll: [
                .x86_64Windows: "682181234a55f5b7eed5b2ffa691fbdef1b488734337ef67ea7b5ce17adf43a2",
                .i386Windows: "49396e7ad804a5345b1b968d02fdb6697ddbb7428e61e20e62806c50c37589d1",
            ],
            patchedNtdll: [
                .x86_64Windows: "08a825e8236e79c909fae3934ca5e8a195a344d06f8affb6e13cdf1bd9ffa783",
                .i386Windows: "88f9a1d16dd7127100eab902156390ec2a5ec67770cfddd3fd3f1237c9965309",
            ],
            isFree: true
        ),
    ]

    static func build(loaderSHA256 hash: String) -> RunnerBuild? {
        all.first { $0.loaderSHA256 == hash }
    }

    static func build(id: String) -> RunnerBuild? {
        all.first { $0.id == id }
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
