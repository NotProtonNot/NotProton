import Sparkle

@MainActor
final class AppUpdater {

    private let controller: SPUStandardUpdaterController

    init() {
        #if DEBUG || NOTPROTON_LOCAL_TEST
        let scheduling = false
        #else
        let scheduling = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: scheduling,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func check() {
        #if !DEBUG && !NOTPROTON_LOCAL_TEST
        controller.checkForUpdates(nil)
        #endif
    }
}
