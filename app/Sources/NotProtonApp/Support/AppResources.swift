import Foundation

enum AppResources {
    // Swift 6.1's generated Bundle.module accessor looks beside the executable
    // and then in the build tree, not in an app's Contents/Resources directory.
    // Prefer the packaged bundle so moving the app never depends on that tree.
    static let bundle: Bundle = packaged(in: .main) ?? .module

    static func packaged(in app: Bundle) -> Bundle? {
        guard let url = app.url(forResource: "NotProtonApp_NotProtonApp", withExtension: "bundle")
        else { return nil }
        return Bundle(url: url)
    }
}
