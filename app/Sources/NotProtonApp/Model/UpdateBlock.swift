// Simple logic to block updates in the Steam client, if
// a user wants to.

import Foundation

enum UpdateBlock {
    static let step = L10n.tr("Block client updates")

    static let key = "BootStrapperInhibitUpdateOnLaunch"
    static let contents = "\(key)=enable\n"

    static var paths: [URL] {
        [SupportPaths.Steam.configFile, SupportPaths.Steam.innerConfigFile]
    }

    static func isPresent(at urls: [URL] = paths) -> Bool {
        guard let required = urls.first else { return false }
        guard let text = try? String(contentsOf: required, encoding: .utf8) else { return false }
        return setting(in: text) == "enable"
    }

    private static func setting(in text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap(value(of:)).last
    }

    private static func value(of line: Substring) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    private static func blocked(_ text: String) -> String {
        var seen = false
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard value(of: line) != nil else {
                out.append(String(line))
                continue
            }
            if !seen {
                out.append(contents.trimmingCharacters(in: .newlines))
                seen = true
            }
        }
        guard !seen else { return out.joined(separator: "\n") }
        if out.last?.isEmpty == true { out.removeLast() }
        out.append(contents.trimmingCharacters(in: .newlines))
        out.append("")
        return out.joined(separator: "\n")
    }

    private static func unblocked(_ text: String) -> String {
        let out = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { value(of: $0) == nil }
        return out.joined(separator: "\n")
    }

    @discardableResult
    static func write(to urls: [URL] = paths) throws -> [String] {
        guard let required = urls.first else { return [] }

        func existing(at url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        do {
            try FileManager.default.createDirectory(
                at: required.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(blocked(existing(at: required)).utf8).write(to: required)
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw WriteRefused(path: required.path(percentEncoded: false))
        } catch {
            throw StepFailure(
                step: step,
                detail: L10n.tr("\(required.path(percentEncoded: false)) could not be written. ")
                    + error.localizedDescription
            )
        }

        var written = [required.path(percentEncoded: false)]
        for url in urls.dropFirst() {
            let parent = url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)) else { continue }
            guard (try? Data(blocked(existing(at: url)).utf8).write(to: url)) != nil else { continue }
            written.append(url.path(percentEncoded: false))
        }
        return written
    }

    @discardableResult
    static func remove(from urls: [URL] = paths) throws -> [String] {
        let files = FileManager.default
        var removed: [String] = []
        for url in urls {
            let path = url.path(percentEncoded: false)
            guard files.fileExists(atPath: path) else { continue }
            let text = try? String(contentsOf: url, encoding: .utf8)
            let kept = text.map(unblocked) ?? ""
            guard text == nil || kept != text else { continue }
            try WriteRefused.catching(path) {
                if kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try files.removeItem(at: url)
                } else {
                    try Data(kept.utf8).write(to: url)
                }
            }
            removed.append(path)
        }
        return removed
    }
}
