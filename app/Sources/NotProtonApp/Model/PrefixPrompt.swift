// Strings for the delete/recreate confirmation prompts. Kept out of the view so
// they can be tested. Dumb development artifact, basically.

import Foundation

enum PrefixPrompt {

    static func deleteTitle(_ targets: [WinePrefix]) -> String {
        switch targets.count {
        case 0: String(localized: "Delete prefix?")
        case 1: String(localized: "Delete the prefix for \(targets[0].title)?")
        default: String(localized: "Delete \(targets.count) prefixes?")
        }
    }

    static func deleteButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? String(localized: "Delete \(targets.count) Prefixes") : String(localized: "Delete Prefix")
    }

    static func deleteMessage(_ targets: [WinePrefix]) -> String {
        guard targets.count > 1 else {
            return sentences([
                String(localized: "This will DELETE the game's prefix."),
                String(localized: "The game SAVE DATA inside the prefix WILL BE LOST."),
                String(localized: "Are you sure you want to do this?"),
            ])
        }
        return sentences([
            String(localized: "This will DELETE the prefixes for \(targets.count) games."),
            String(localized: "The game SAVE DATA inside them WILL BE LOST."),
            String(localized: "Are you sure you want to do this?"),
        ])
    }

    static func rebuildTitle(_ targets: [WinePrefix], for tool: InstalledTool? = nil) -> String {
        let with = tool.map { String(localized: " with \($0.display)") } ?? ""
        switch targets.count {
        case 0: return String(localized: "Rebuild prefix\(with)?")
        case 1: return String(localized: "Rebuild the prefix for \(targets[0].title)\(with)?")
        default: return String(localized: "Rebuild \(targets.count) prefixes\(with)?")
        }
    }

    static func rebuildButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? String(localized: "Rebuild \(targets.count) Prefixes") : String(localized: "Rebuild Prefix")
    }

    static func rebuildWithBackupButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1
            ? String(localized: "Back Up and Rebuild \(targets.count) Prefixes") : String(localized: "Back Up and Rebuild")
    }

    static func rebuildWithoutBackupButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1
            ? String(localized: "Rebuild \(targets.count) Prefixes Without Backing Up")
            : String(localized: "Rebuild Without Backing Up")
    }

    static func backUpTitle(_ targets: [WinePrefix]) -> String {
        switch targets.count {
        case 0: String(localized: "Back up prefix?")
        case 1: String(localized: "Back up the prefix for \(targets[0].title)?")
        default: String(localized: "Back up \(targets.count) prefixes?")
        }
    }

    static func backUpButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? String(localized: "Back Up \(targets.count) Prefixes") : String(localized: "Back Up Prefix")
    }

    static func backUpMessage(_ targets: [WinePrefix] = []) -> String {
        targets.count > 1
            ? String(localized: "Are you sure you want to back up these prefixes?")
            : String(localized: "Are you sure you want to back up this prefix?")
    }

    static func rebuildMessage() -> String {
        sentences([
            String(localized: "This tool repairs a prefix after switching between Whisky or CrossOver compatibility tools."),
            String(localized: "It will replace the Wine DLLs with ones that match your compatibility tool."),
            String(localized: "This can also fix a game that previously worked, even if you did not switch compatibility tools."),
            String(localized: "You will not lose saves by using this tool."),
        ])
    }

    static func deleteBackupsTitle(_ targets: [PrefixBackup]) -> String {
        switch targets.count {
        case 0: String(localized: "Delete backup?")
        case 1: String(localized: "Delete the backup for \(targets[0].title)?")
        default: String(localized: "Delete \(targets.count) backups?")
        }
    }

    static func deleteBackupsButton(_ targets: [PrefixBackup]) -> String {
        targets.count > 1 ? String(localized: "Delete \(targets.count) Backups") : String(localized: "Delete Backup")
    }

    static func deleteBackupsMessage(_ targets: [PrefixBackup] = []) -> String {
        guard targets.count > 1 else {
            return sentences([
                String(localized: "Are you sure you want to delete this backup?"),
                String(localized: "Any data in it will be lost."),
            ])
        }
        return sentences([
            String(localized: "Are you sure you want to delete these \(targets.count) backups?"),
            String(localized: "Any data in them will be lost."),
        ])
    }

    private static func sentences(_ parts: [String]) -> String {
        parts.joined(separator: " ")
    }
}
