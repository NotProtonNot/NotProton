// Download one hash pinned file from a list of CDN hosts

import Foundation

enum PinnedDownload {

    enum Progress: Sendable {
        case reusing
        case fetching(host: String)

        var label: String {
            switch self {
            case .reusing: L10n.tr("Preparing")
            case .fetching(let host): L10n.tr("Downloading from \(host)")
            }
        }
    }

    static func obtain(
        file: String,
        sha256: String,
        bases: [URL],
        into downloads: URL,
        step: String,
        report: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> URL {
        let archive = downloads.appending(path: file)
        if Digest.sha256IfPresent(archive) == sha256 {
            report(.reusing)
            return archive
        }

        var refusals: [String] = []
        var kinds: Set<Refusal> = []
        for base in bases {
            let host = base.host() ?? base.absoluteString
            report(.fetching(host: host))
            do {
                let (body, response) = try await URLSession.shared.download(from: base.appending(path: file))
                defer { try? FileManager.default.removeItem(at: body) }

                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    refusals.append("\(host) answered \(http.statusCode)")
                    kinds.insert(.answered)
                    continue
                }

                let got = try Digest.sha256(of: body)
                guard got == sha256 else {
                    refusals.append("\(host) served \(got.prefix(16)) rather than \(sha256.prefix(16))")
                    kinds.insert(.mismatch)
                    continue
                }

                try FileManager.default.createDirectory(
                    at: downloads, withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: archive)
                try FileManager.default.moveItem(at: body, to: archive)
                return archive
            } catch {
                refusals.append("\(host): \(error.localizedDescription)")
                kinds.insert(.unreachable)
            }
        }

        AppLog.note("\(file) refused by all \(bases.count) hosts: \(refusals.joined(separator: ". "))")
        throw StepFailure(step: step, detail: reason(kinds))
    }

    private enum Refusal {
        case unreachable
        case mismatch
        case answered
    }

    private static func reason(_ kinds: Set<Refusal>) -> String {
        if kinds == [.mismatch] {
            return L10n.tr("Something is wrong with the downloaded files. Please check for a NotProton update.")
        }
        if kinds == [.unreachable] {
            return L10n.tr("NotProton could not reach Valve's servers. Please check your internet connection and try again.")
        }
        return L10n.tr("NotProton could not download the files it needs from Valve. Please try again later.")
    }
}
