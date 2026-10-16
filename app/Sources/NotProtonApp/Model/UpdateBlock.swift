// Simple logic to block updates in the Steam client, if
// a user wants to.

import Foundation

enum UpdateBlock {
    static let step = String(localized: "Block client updates")

    static let key = "BootStrapperInhibitUpdateOnLaunch"
    static let contents = "\(key)=enable\n"

    static var paths: [URL] {
        [SupportPaths.Steam.configFile, SupportPaths.Steam.innerConfigFile]
    }

    static func isPresent(at urls: [URL] = paths) -> Bool {
        guard let required = urls.first, let text = try? read(required) else { return false }
        return setting(in: text) == "enable"
    }

    // Latin-1 maps every byte, so a file that is not UTF-8 is rewritten unchanged.
    private static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            let bytes = try Data(contentsOf: url)
            return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        } catch let error as NSError where error.code == NSFileReadNoPermissionError {
            throw WriteRefused(path: url.path(percentEncoded: false))
        }
    }

    private static func encoded(_ text: String) -> Data {
        Data(text.unicodeScalars.map { UInt8($0.value) })
    }

    // Split on the scalar: "\r\n" is one Character, so a CRLF file would read as one line.
    private static func lines(of text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    private static func setting(in text: String) -> String? {
        lines(of: text).compactMap(value(of:)).last
    }

    private static func value(of line: String) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { return nil }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blocked(_ text: String) -> String {
        let rows = lines(of: text)
        func line(endingLike row: String?) -> String {
            contents.trimmingCharacters(in: .newlines) + (row?.unicodeScalars.last == "\r" ? "\r" : "")
        }
        var seen = false
        var out: [String] = []
        for existing in rows {
            guard value(of: existing) != nil else {
                out.append(existing)
                continue
            }
            if !seen {
                out.append(line(endingLike: existing))
                seen = true
            }
        }
        guard !seen else { return out.joined(separator: "\n") }
        if out.last?.isEmpty == true { out.removeLast() }
        out.append(line(endingLike: rows.first))
        out.append("")
        return out.joined(separator: "\n")
    }

    private static func unblocked(_ text: String) -> String {
        lines(of: text).filter { value(of: $0) == nil }.joined(separator: "\n")
    }

    @discardableResult
    static func write(to urls: [URL] = paths) throws -> [String] {
        guard let required = urls.first else { return [] }

        do {
            try FileManager.default.createDirectory(
                at: required.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoded(blocked(read(required) ?? "")).write(to: required)
        } catch let refusal as WriteRefused {
            throw refusal
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw WriteRefused(path: required.path(percentEncoded: false))
        } catch {
            throw StepFailure(
                step: step,
                detail: String(localized: "\(required.path(percentEncoded: false)) could not be written. ")
                    + error.localizedDescription
            )
        }

        var written = [required.path(percentEncoded: false)]
        for url in urls.dropFirst() {
            let parent = url.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path(percentEncoded: false)) else { continue }
            guard let text = try? read(url) ?? "",
                (try? encoded(blocked(text)).write(to: url)) != nil else { continue }
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
            guard let text = try read(url) else { continue }
            let kept = unblocked(text)
            guard kept != text else { continue }
            try WriteRefused.catching(path) {
                if kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try files.removeItem(at: url)
                } else {
                    try encoded(kept).write(to: url)
                }
            }
            removed.append(path)
        }
        return removed
    }
}
