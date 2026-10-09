import Foundation

enum AppResources {
    /// SwiftPM toolchains disagree on where an executable's resource bundle
    /// lives. Packaged apps must not fall back to the developer's .build path.
    static func packaged(in app: Bundle) -> Bundle? {
        guard let resources = app.resourceURL else { return nil }
        return Bundle(url: resources.appendingPathComponent("NotProtonApp_NotProtonApp.bundle"))
    }

    static let bundle: Bundle = packaged(in: .main) ?? .module
}
