// Strings for the delete/recreate confirmation prompts. Kept out of the view so
// they can be tested. Dumb development artifact, basically.

import Foundation

enum PrefixPrompt {

    static func deleteTitle(_ targets: [WinePrefix]) -> String {
        switch targets.count {
        case 0: "Delete prefix?"
        case 1: "Delete the prefix for \(targets[0].title)?"
        default: "Delete \(targets.count) prefixes?"
        }
    }

    static func deleteButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? "Delete \(targets.count) Prefixes" : "Delete Prefix"
    }

    static func deleteMessage(_ targets: [WinePrefix]) -> String {
        guard targets.count > 1 else {
            return sentences([
                "This will DELETE the game's prefix.",
                "The game SAVE DATA inside the prefix WILL BE LOST.",
                "Are you sure you want to do this?",
            ])
        }
        return sentences([
            "This will DELETE the prefixes for \(targets.count) games.",
            "The game SAVE DATA inside them WILL BE LOST.",
            "Are you sure you want to do this?",
        ])
    }

    static func rebuildTitle(_ targets: [WinePrefix], for tool: InstalledTool? = nil) -> String {
        let with = tool.map { " with \($0.display)" } ?? ""
        switch targets.count {
        case 0: return "Rebuild prefix\(with)?"
        case 1: return "Rebuild the prefix for \(targets[0].title)\(with)?"
        default: return "Rebuild \(targets.count) prefixes\(with)?"
        }
    }

    static func rebuildButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? "Rebuild \(targets.count) Prefixes" : "Rebuild Prefix"
    }

    static func rebuildWithBackupButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1
            ? "Back Up and Rebuild \(targets.count) Prefixes" : "Back Up and Rebuild"
    }

    static func rebuildWithoutBackupButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1
            ? "Rebuild \(targets.count) Prefixes Without Backing Up"
            : "Rebuild Without Backing Up"
    }

    static func backUpTitle(_ targets: [WinePrefix]) -> String {
        switch targets.count {
        case 0: "Back up prefix?"
        case 1: "Back up the prefix for \(targets[0].title)?"
        default: "Back up \(targets.count) prefixes?"
        }
    }

    static func backUpButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? "Back Up \(targets.count) Prefixes" : "Back Up Prefix"
    }

    static func backUpMessage(_ targets: [WinePrefix] = []) -> String {
        targets.count > 1
            ? "Are you sure you want to back up these prefixes?"
            : "Are you sure you want to back up this prefix?"
    }

    static func backUpGameFilesTitle(_ prefix: WinePrefix?) -> String {
        guard let prefix else { return "Back up game files?" }
        return "Back up the game files for \(prefix.title)?"
    }

    static func backUpGameFilesMessage() -> String {
        sentences([
            "This copies the entire installed game folder to a NotProton snapshot in the same Steam library.",
            "It may require free space about as large as the installed game.",
            "The Wine prefix and data stored in it are not included. Quit the game before continuing.",
        ])
    }

    static func restoreGameFilesTitle(_ backup: GameFilesBackup?) -> String {
        guard let backup else { return "Restore game-file snapshot?" }
        let when = backup.taken?.formatted(date: .abbreviated, time: .shortened)
            ?? backup.url.lastPathComponent
        return "Restore the game files for \(backup.prefix.title) from \(when)?"
    }

    static func restoreGameFilesMessage() -> String {
        sentences([
            "The current game files will first be kept as another snapshot.",
            "This restores the game folder only; the Wine prefix and its data are unchanged.",
            "Steam may verify or update the game before its next launch.",
        ])
    }

    static func rebuildMessage() -> String {
        sentences([
            "This tool is intended to repair a prefix after switching between Rosetta/FEX CrossOver.",
            "It will replace the DLLs used by CrossOver with ones that match your compatibility tool.",
            "This can also fix issues where a game previously started/worked and does not work now, "
                + "even if you did not switch CrossOver types.",
            "You will not lose saves by using this tool.",
        ])
    }

    static func deleteBackupsTitle(_ targets: [PrefixBackup]) -> String {
        switch targets.count {
        case 0: "Delete backup?"
        case 1: "Delete the backup for \(targets[0].title)?"
        default: "Delete \(targets.count) backups?"
        }
    }

    static func deleteBackupsButton(_ targets: [PrefixBackup]) -> String {
        targets.count > 1 ? "Delete \(targets.count) Backups" : "Delete Backup"
    }

    static func deleteBackupsMessage(_ targets: [PrefixBackup] = []) -> String {
        guard targets.count > 1 else {
            return sentences([
                "Are you sure you want to delete this backup?",
                "Any data in it will be lost.",
            ])
        }
        return sentences([
            "Are you sure you want to delete these \(targets.count) backups?",
            "Any data in them will be lost.",
        ])
    }

    private static func sentences(_ parts: [String]) -> String {
        parts.joined(separator: " ")
    }
}
