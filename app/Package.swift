// swift-tools-version: 6.2
import Foundation
import PackageDescription
let testsPath = "Tests/NotProtonAppTests"
let payloadPath = "Sources/NotProtonApp/Resources/payload"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hasTests = FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent(testsPath).path)

// make app-payload stages the payload, so a checkout that has not been built does
// not have it. A declared resource that is missing is a build error, while an app
// missing the payload is a condition InstallPayload already reports.
let hasPayload = FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent(payloadPath).path)
let package = Package(
    name: "NotProtonApp",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "NotProtonApp",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/NotProtonApp",
            resources: (hasPayload ? [.copy("Resources/payload")] : []) + [
                .process("Resources/en.lproj"),
                .copy("Resources/payload.manifest"),
                .copy("Resources/valve-packages.manifest"),
                .copy("Resources/detour2.bin"),
                .copy("Resources/detour2-fex.bin"),
                .copy("Resources/detour32.bin"),
                .copy("Resources/detour32-fex.bin"),
                .copy("Resources/detour64-fex.bin"),
                .copy("Resources/detour2-cx26.bin"),
                .copy("Resources/detour32-cx26.bin"),
                .copy("Resources/detour2-41069.bin"),
                .copy("Resources/detour32-41069.bin"),
                .copy("Resources/detour2-fex-41069.bin"),
                .copy("Resources/detour32-fex-41069.bin"),
                .copy("Resources/detour64-fex-41069.bin"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ] + (hasTests ? [
        .testTarget(
            name: "NotProtonAppTests",
            dependencies: ["NotProtonApp"],
            path: testsPath
        ),
    ] : [])
)
