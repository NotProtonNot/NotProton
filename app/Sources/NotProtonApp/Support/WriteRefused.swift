// We couldn't write? Logic for that

import AppKit
import Foundation

struct WriteRefused: LocalizedError {
    let path: String

    var errorDescription: String? { L10n.tr("Could not write files.") }
}

extension WriteRefused {
    static func catching<T>(_ path: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw WriteRefused(path: path)
        }
    }

    static func catching<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        try catching(url.path(percentEncoded: false), body)
    }

    var remedy: Remedy { Remedy(forPath: path) }
}

// A write failure generally equals App Management permission error
// or bad folder ownership
enum Remedy: Hashable {
    case appManagement
    case otherAccount
    case ownership

    var advice: String {
        switch self {
        case .appManagement: L10n.tr("NotProton needs the App Management permission.")
        case .otherAccount:
            L10n.tr("Steam was installed by another account on this Mac. Only that account can modify it. Log in to macOS with that account to reinstall NotProton.")
        case .ownership: L10n.tr("Check permissions, make sure your user owns the folder.")
        }
    }

    static let settingsButton = L10n.tr("Open System Settings")

    private static let appManagementPane =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"

    var settingsPane: URL? {
        switch self {
        case .appManagement: URL(string: Self.appManagementPane)
        case .otherAccount, .ownership: nil
        }
    }

    @MainActor
    static func openSettings(_ pane: URL) {
        AppLog.note("opening App Management settings")
        NSWorkspace.shared.open(pane)
    }

    static func owner(of path: String) -> uid_t? {
        let files = FileManager.default
        let url = URL(filePath: path)
        for candidate in [url, url.deletingLastPathComponent()] {
            guard
                let attributes = try? files.attributesOfItem(
                    atPath: candidate.path(percentEncoded: false)
                ),
                let owner = attributes[.ownerAccountID] as? NSNumber
            else { continue }
            return uid_t(owner.uint32Value)
        }
        return nil
    }

    init(forPath path: String) {
        if let owner = Self.owner(of: path), owner != getuid() {
            self = .otherAccount
            return
        }

        let files = FileManager.default
        var directory = URL(filePath: path)
        while directory.pathComponents.count > 1 {
            let plist = directory.appending(path: "Contents/Info.plist")
            if files.fileExists(atPath: plist.path(percentEncoded: false)) {
                self = .appManagement
                return
            }
            directory = directory.deletingLastPathComponent()
        }
        self = .ownership
    }
}

struct FailureReport {
    let message: String
    let remedy: Remedy?

    var settingsPane: URL? { remedy?.settingsPane }

    init?(_ errors: [Error]) {
        guard !errors.isEmpty else { return nil }

        var seen = Set<String>()
        let reasons = errors.map(\.localizedDescription).filter { seen.insert($0).inserted }

        let refusals = errors.compactMap { $0 as? WriteRefused }
        let wanted = Set(refusals.map(\.remedy))
        remedy = refusals.count == errors.count && wanted.count == 1 ? wanted.first : nil

        var parts = reasons
        if let advice = remedy?.advice { parts.append(advice) }
        message = parts.joined(separator: " ")
    }
}
