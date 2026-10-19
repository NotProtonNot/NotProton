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

    static var signatures: URL {
        support.appending(path: "signatures/macos.arm64")
    }

    static var fonts: URL { support.appending(path: "fonts") }
    static var overlayShim: URL { support.appending(path: "overlay-shim.dylib") }
    static var iconmaker: URL { support.appending(path: "iconmaker") }
    static var appinfo: URL { support.appending(path: "appinfo") }

    static var packageDownloads: URL {
        home.appending(path: "Library/Caches/\(supportDirName)/valve-packages")
    }

    static var winetricksDownloads: URL {
        home.appending(path: "Library/Caches/\(supportDirName)/winetricks")
    }

    static var deployedVersion: URL { support.appending(path: "dylib.version") }

    // Read by the dylib at Steam launch, in np_compat_load_tool_list.
    static var toolList: URL { support.appending(path: "tools") }

    // Where Whisky and WhiskyPreview keep the runtimes they download. Each entry
    // under Runtimes is a runtime root, and Libraries is one itself.
    static var whiskyRuntimeFolders: [URL] {
        [
            "com.dappermint.WhiskyPreview",
            "com.isaacmarovitz.Whisky",
            "com.franke.Whisky",
        ].map { applicationSupport.appending(path: "\($0)/Runtimes") }
    }

    static var whiskyLibraries: [URL] {
        [
            "com.dappermint.WhiskyPreview",
            "com.isaacmarovitz.Whisky",
            "com.franke.Whisky",
        ].map { applicationSupport.appending(path: "\($0)/Libraries") }
    }

    static func isWhiskyBuild(_ id: String) -> Bool {
        id.wholeMatch(of: #/[A-Za-z][A-Za-z0-9.-]*-[0-9]+\.[0-9]+\.[0-9]+/#) != nil
            && !id.hasPrefix("crossover-")
    }

    static func runnerRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runners.appending(path: isWhiskyBuild(build) ? build : "crossover-\(build)")
    }

    static func crossOverRoot(inBundle bundle: URL) -> URL {
        bundle.appending(path: "Contents/SharedSupport/CrossOver")
    }

    static func clonedRoot(forBuild build: String, runners: URL = SupportPaths.runners) -> URL {
        runnerRoot(forBuild: build, runners: runners).appending(path: isWhiskyBuild(build) ? "Wine" : "CrossOver")
    }

    static func prefixTemplates(forBuild build: String, in library: SteamLibrary) -> [URL] {
        CompatTool.Flavor.allCases.map { prefixTemplate(forBuild: build, flavor: $0, in: library) }
    }

    static func prefixTemplate(forBuild build: String, flavor: CompatTool.Flavor, in library: SteamLibrary) -> URL {
        library.compatdata.appending(path: prefixTemplateFolder).appending(path: "crossover-\(build)-\(flavor.unixDir)")
    }

    static let prefixTemplateFolder = "notproton-template"
    static let bridgeCacheFolder = "bridge"

    enum Steam {
        static let defaultApp = URL(filePath: "/Applications/Steam.app")
        static let appPathKey = "steamAppPath"

        static var app: URL {
            UserDefaults.standard.string(forKey: appPathKey).map { URL(filePath: $0) } ?? defaultApp
        }
        static func isUnreachable(_ bundle: URL = app) -> Bool {
            !FileManager.default.fileExists(atPath: bundle.deletingLastPathComponent().path(percentEncoded: false))
        }
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

        static var compatTools: URL { userData.appending(path: "compatibilitytools.d") }

        static func notprotonTools(in directory: URL = compatTools) -> [URL] {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            return entries.filter { $0.lastPathComponent.hasPrefix("notproton") }
        }

        static var libraryFoldersVDF: URL { userData.appending(path: "steamapps/libraryfolders.vdf") }
    }
}

// The WhiskyWine layout inside a runtime root
enum RuntimeLayout {

    static func wine(in root: URL) -> URL { root.appending(path: "Wine") }

    static func libWine(in root: URL) -> URL { wine(in: root).appending(path: "lib/wine") }

    static func unixDir(in root: URL) -> URL { libWine(in: root).appending(path: "x86_64-unix") }

    // lib/wine's loader is the one the launcher bundle stages beside its unix
    // libraries, and bin/wine64 is the same binary.
    static func loader(in root: URL) -> URL {
        let unixLoader = unixDir(in: root).appending(path: "wine")
        if FileManager.default.isExecutableFile(atPath: unixLoader.path(percentEncoded: false)) {
            return unixLoader
        }
        return wine(in: root).appending(path: "bin/wine64")
    }

    static func server(in root: URL) -> URL { wine(in: root).appending(path: "bin/wineserver") }

    static func ntdll(in root: URL, arch: WineArch) -> URL {
        libWine(in: root).appending(path: "\(arch.rawValue)/ntdll.dll")
    }

    static func versionPlist(in root: URL) -> URL { root.appending(path: "WhiskyWineVersion.plist") }

    static func manifest(in root: URL) -> URL { root.appending(path: "RuntimeManifest.json") }

    static func gptkDeployment(in root: URL) -> URL { root.appending(path: "GPTKDeployment.plist") }

    static func hasWine(in root: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: libWine(in: root).path(percentEncoded: false))
            && fm.isExecutableFile(atPath: server(in: root).path(percentEncoded: false))
            && fm.isExecutableFile(atPath: wine(in: root).appending(path: "bin/wine64").path(percentEncoded: false))
    }
}
