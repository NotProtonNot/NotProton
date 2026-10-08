import Foundation

struct HelpTopic: Identifiable, Sendable {
    let id: String
    let title: String
    let body: String
    let url: URL?

    func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let searchable = [title, body, GuideCopy.text(title), GuideCopy.text(body)].joined(separator: " ")
        return words.allSatisfy { searchable.localizedStandardContains(String($0)) }
    }

    static let all: [HelpTopic] = [
        .init(id: "first-game", title: "Where do I choose NotProton?",
              body: "Use the macOS Steam app. In Library, open the game's Properties → Compatibility and choose the installed NotProton / CrossOver tool. Restart Steam after adding a runtime. You do not need Windows Steam in a separate bottle.",
              url: URL(string: "https://github.com/NotProtonNot/NotProton")),
        .init(id: "builds", title: "Why is my CrossOver version unsupported?",
              body: "Stable and Preview are release channels, not compatibility guarantees. NotProton patches specific Wine binaries. Each exact build needs verified hashes and hook locations. Compare the build number in Status with the supported profiles. Do not rename an app to force support.", url: URL(string: "https://github.com/NotProtonNot/NotProton/issues/40")),
        .init(id: "black-screen", title: "The game opens to a black screen",
              body: "Allow the first launch to finish creating its game environment. If it stays black, quit the game normally and try again. Check the selected tool and change only one graphics option at a time in Steam's Compatibility page. A game-specific renderer or launcher problem may remain. Reinstalling NotProton is not a general fix for game compatibility.", url: URL(string: "https://github.com/NotProtonNot/NotProton/issues")),
        .init(id: "controller", title: "My controller or keyboard does not work",
              body: "Check the controller in macOS and in Steam's controller settings first. NotProton's Compatibility page includes game input options. Some games need different Steam Input settings. If Steam's macOS permission was denied, use Reset controller permission in Status, then restart Steam. Change one option at a time; no controller fix works for every game.", url: URL(string: "https://github.com/NotProtonNot/NotProton/issues/34")),
        .init(id: "saves", title: "What is a prefix, and where are my saves?",
              body: "A prefix is a game's Windows environment: registry, installed components and possibly save files. It appears in Game environments after the first Windows game launch. Back it up before rebuilding or experimenting. A prefix backup is not a backup of downloaded games or a guarantee of Steam Cloud sync. Existing CrossOver bottles cannot be migrated just by moving their folders.", url: nil),
        .init(id: "updates", title: "Steam updated and compatibility disappeared",
              body: "Refresh Status to inspect the integration. Use an updated NotProton build when Steam changes its interface. Blocking Steam client updates is optional and also delays Steam fixes; it does not stop game updates. An older app cannot safely repair a newer NotProton installation. Keep your own save backups.", url: nil),
        .init(id: "dependencies", title: "VCRuntime is missing or a launcher opens",
              body: "Additional Windows components belong in the affected game's environment. Use Game environments → Tools → Run Program to run a trusted component installer in that prefix. Avoid random DLL download sites. Ubisoft and other third-party launchers can still have compatibility issues; do not install a second Steam client as a blanket workaround.", url: URL(string: "https://github.com/NotProtonNot/NotProton/issues/42")),
        .init(id: "anticheat", title: "Will online games and anti-cheat work?",
              body: "NotProton does not make every anti-cheat system compatible with Wine. VAC is not supported by this integration; a game opening does not prove protected multiplayer works. Check the game's requirements and current reports before buying it for this setup.", url: URL(string: "https://github.com/NotProtonNot/NotProton/issues/43")),
        .init(id: "mods", title: "Can I run a custom EXE or install mods?",
              body: "Select the game's environment and use Tools → Run Program to run a trusted EXE there. This does not replace Steam's default Play executable. Custom launch options and mods are game-specific; back up the prefix before changing its components.", url: URL(string: "https://github.com/NotProtonNot/NotProton/issues/17")),
    ]
}
