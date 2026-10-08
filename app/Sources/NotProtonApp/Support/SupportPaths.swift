// Path construction for the NotProton support directory and Steam

import Foundation

enum SupportPaths {

    static let supportDirName = "notproton"
    static let dylibName = "notproton.dylib"

    static var home: URL {
        URL(filePath: NSHomeDirectory())
    }

    static var applicationSupport: URL {
        home.appending(path: "Library/Application Support")
    }

    // ~/Library/Application Support/notproton
    static var support: URL {
        applicationSupport.appending(path: supportDirName)
    }

    static var bridge: URL { support.appending(path: "bridge") }
    static var runners: URL { support.appending(path: "runners") }
    static var backups: URL { support.appending(path: "backups") }
    static var launchers: URL { support.appending(path: "launchers") }
    // Free WineHQ engines NotProton downloaded, laid out like a CrossOver bundle.
    static var engines: URL { support.appending(path: "engines") }

    static var signatures: URL {
        support.appending(path: "signatures/macos.arm64")
    }

    static var overlayShim: URL { support.appending(path: "overlay-shim.dylib") }
    static var iconmaker: URL { support.appending(path: "iconmaker") }
    static var appinfo: URL { support.appending(path: "appinfo") }

    static var packageDownloads: URL {
        home.appending(path: "Library/Caches/\(supportDirName)/valve-packages")
    }

    static var deployedVersion: URL { support.appending(path: "dylib.version") }

    static var currentRunner: URL { runners.appending(path: "current") }

    static func runnerRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runners.appending(path: "crossover-\(build)")
    }

    static func crossOverRoot(inBundle bundle: URL) -> URL {
        bundle.appending(path: "Contents/SharedSupport/CrossOver")
    }

    static func clonedRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runnerRoot(forBuild: build, runners: runners).appending(path: "CrossOver")
    }

    enum Steam {
        static var app: URL { URL(filePath: "/Applications/Steam.app") }
        static var infoPlist: URL { infoPlist(inBundle: app) }
        static var executable: URL { app.appending(path: "Contents/MacOS/steam_osx") }
        static var deployedDylib: URL { deployedDylib(inBundle: app) }

        static func infoPlist(inBundle bundle: URL) -> URL {
            bundle.appending(path: "Contents/Info.plist")
        }

        static func deployedDylib(inBundle bundle: URL) -> URL {
            bundle.appending(path: "Contents/MacOS/\(dylibName)")
        }

        static var userData: URL {
            SupportPaths.applicationSupport.appending(path: "Steam")
        }

        static var configFile: URL { userData.appending(path: "steam.cfg") }

        static var innerApp: URL { userData.appending(path: "Steam.AppBundle/Steam") }
        static var innerInfoPlist: URL { innerApp.appending(path: "Contents/Info.plist") }

        static var innerClient: URL { innerApp.appending(path: "Contents/MacOS") }

        static var innerConfigFile: URL { innerClient.appending(path: "steam.cfg") }
        static var legacyCompat: URL { innerClient.appending(path: "legacycompat") }

        static var compatTool: URL {
            userData.appending(path: "compatibilitytools.d/notproton")
        }

        static var libraryFoldersVDF: URL { userData.appending(path: "steamapps/libraryfolders.vdf") }
    }
}
