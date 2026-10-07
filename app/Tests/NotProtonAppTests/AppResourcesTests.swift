import Foundation
import Testing

@testable import NotProtonApp

@Suite("Packaged resources")
struct AppResourcesTests {
    @Test("Resources resolve inside a moved app with either SwiftPM bundle layout",
          arguments: [false, true])
    func packagedResources(structured: Bool) throws {
        let files = FileManager.default
        let root = URL.temporaryDirectory.appendingPathComponent("np-resources-\(UUID().uuidString).app")
        defer { try? files.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        let resourceBundle = contents.appendingPathComponent(
            "Resources/NotProtonApp_NotProtonApp.bundle")
        let resources = structured
            ? resourceBundle.appendingPathComponent("Contents/Resources") : resourceBundle
        try files.createDirectory(
            at: resources.appendingPathComponent("payload"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.notproton.resources-test.\(UUID().uuidString)",
            "CFBundleName": "Resource Fixture",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if structured {
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "com.notproton.resource-bundle.\(UUID().uuidString)",
                "CFBundlePackageType": "BNDL",
            ], format: .xml, options: 0)
                .write(to: resourceBundle.appendingPathComponent("Contents/Info.plist"))
        }
        try Data([1, 2, 3]).write(to: resources.appendingPathComponent("detour.bin"))
        let app = try #require(Bundle(url: root))
        let bundle = try #require(AppResources.packaged(in: app))
        let detour = try #require(bundle.url(forResource: "detour", withExtension: "bin"))
        #expect(try Data(contentsOf: detour) == Data([1, 2, 3]))
        #expect(try InstallPayload.root(in: bundle).standardizedFileURL
                == resources.appendingPathComponent("payload").standardizedFileURL)
    }
}
