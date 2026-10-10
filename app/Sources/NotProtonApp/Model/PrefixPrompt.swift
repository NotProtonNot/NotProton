// Strings for the delete/recreate confirmation prompts. Kept out of the view so
// they can be tested. Dumb development artifact, basically.

import Foundation

enum PrefixPrompt {

    static func deleteTitle(_ targets: [WinePrefix]) -> String {
        switch targets.count {
        case 0: L10n.tr("Delete prefix?")
        case 1: L10n.tr("Delete the prefix for \(targets[0].title)?")
        default: L10n.tr("Delete \(targets.count) prefixes?")
        }
    }

    static func deleteButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? L10n.tr("Delete \(targets.count) Prefixes") : L10n.tr("Delete Prefix")
    }

    static func deleteMessage(_ targets: [WinePrefix]) -> String {
        guard targets.count > 1 else {
            return sentences([
                L10n.tr("This will DELETE the game's prefix."),
                L10n.tr("The game SAVE DATA inside the prefix WILL BE LOST."),
                L10n.tr("Are you sure you want to do this?"),
            ])
        }
        return sentences([
            L10n.tr("This will DELETE the prefixes for \(targets.count) games."),
            L10n.tr("The game SAVE DATA inside them WILL BE LOST."),
            L10n.tr("Are you sure you want to do this?"),
        ])
    }

    static func rebuildTitle(_ targets: [WinePrefix], for tool: InstalledTool? = nil) -> String {
        let with = tool.map { L10n.tr(" with \($0.display)") } ?? ""
        switch targets.count {
        case 0: return L10n.tr("Rebuild prefix\(with)?")
        case 1: return L10n.tr("Rebuild the prefix for \(targets[0].title)\(with)?")
        default: return L10n.tr("Rebuild \(targets.count) prefixes\(with)?")
        }
    }

    static func rebuildButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? L10n.tr("Rebuild \(targets.count) Prefixes") : L10n.tr("Rebuild Prefix")
    }

    static func rebuildWithBackupButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1
            ? L10n.tr("Back Up and Rebuild \(targets.count) Prefixes") : L10n.tr("Back Up and Rebuild")
    }

    static func rebuildWithoutBackupButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1
            ? L10n.tr("Rebuild \(targets.count) Prefixes Without Backing Up")
            : L10n.tr("Rebuild Without Backing Up")
    }

    static func backUpTitle(_ targets: [WinePrefix]) -> String {
        switch targets.count {
        case 0: L10n.tr("Back up prefix?")
        case 1: L10n.tr("Back up the prefix for \(targets[0].title)?")
        default: L10n.tr("Back up \(targets.count) prefixes?")
        }
    }

    static func backUpButton(_ targets: [WinePrefix]) -> String {
        targets.count > 1 ? L10n.tr("Back Up \(targets.count) Prefixes") : L10n.tr("Back Up Prefix")
    }

    static func backUpMessage(_ targets: [WinePrefix] = []) -> String {
        targets.count > 1
            ? L10n.tr("Are you sure you want to back up these prefixes?")
            : L10n.tr("Are you sure you want to back up this prefix?")
    }

    static func rebuildMessage() -> String {
        sentences([
            L10n.tr("This tool is intended to repair a prefix after switching between Rosetta/FEX CrossOver."),
            L10n.tr("It will replace the DLLs used by CrossOver with ones that match your compatibility tool."),
            L10n.tr("This can also fix issues where a game previously started/worked and does not work now, even if you did not switch CrossOver types."),
            L10n.tr("You will not lose saves by using this tool."),
        ])
    }

    static func deleteBackupsTitle(_ targets: [PrefixBackup]) -> String {
        switch targets.count {
        case 0: L10n.tr("Delete backup?")
        case 1: L10n.tr("Delete the backup for \(targets[0].title)?")
        default: L10n.tr("Delete \(targets.count) backups?")
        }
    }

    static func deleteBackupsButton(_ targets: [PrefixBackup]) -> String {
        targets.count > 1 ? L10n.tr("Delete \(targets.count) Backups") : L10n.tr("Delete Backup")
    }

    static func deleteBackupsMessage(_ targets: [PrefixBackup] = []) -> String {
        guard targets.count > 1 else {
            return sentences([
                L10n.tr("Are you sure you want to delete this backup?"),
                L10n.tr("Any data in it will be lost."),
            ])
        }
        return sentences([
            L10n.tr("Are you sure you want to delete these \(targets.count) backups?"),
            L10n.tr("Any data in them will be lost."),
        ])
    }

    private static func sentences(_ parts: [String]) -> String {
        parts.joined(separator: " ")
    }
}
