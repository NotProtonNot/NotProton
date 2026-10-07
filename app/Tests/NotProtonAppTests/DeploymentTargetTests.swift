import Foundation
import Testing

@Suite("macOS deployment target")
struct DeploymentTargetTests {
    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Launch Services allows the app to open on macOS 15")
    func bundleMinimum() throws {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["LSMinimumSystemVersion"] as? String == "15.0")
        #expect(plist["CFBundleIconFile"] as? String == "NotProton")
    }
}
