// Checks whether the user's CrossOver install is licensed.
// CodeWeavers, I hope this doesn't bother you. You don't validate
// license when the Wine binary itself is invoked, so I wanted to
// do something to prevent skids from doing really trivial piracy.

import Foundation

enum CrossOverLicense {

    struct Status: Sendable {
        let licensed: Bool
        let detail: String
        // The real reason, for the log.
        let diagnostic: String
    }

    static let defaultSearchDirs: [URL] = {
        let home = URL(filePath: NSHomeDirectory())
        return [
            home.appending(path: "Library/Preferences"),
            URL(filePath: "/Library/Preferences"),
        ]
    }()

    private static let licenseBase = "com.codeweavers.CrossOver"

    static let notActivatedTitle = "CrossOver does not appear to be activated."
    static let notActivatedAdvice = "Please run CrossOver and try again."
    static var notActivated: String { "\(notActivatedTitle) \(notActivatedAdvice)" }

    static let trialEndedTitle = "Your CrossOver trial has ended."
    static let trialEndedAdvice = "Buy CrossOver at https://www.codeweavers.com/store, then try again."
    static var trialEnded: String { "\(trialEndedTitle) \(trialEndedAdvice)" }

    // CodeWeavers' published trial: 14 days from the first launch, which CrossOver
    // records as FirstRunDate in its own preferences. It writes no license file until
    // it is bought, so a missing license with a recent first run is a trial.
    static let trialLength: TimeInterval = 14 * 24 * 60 * 60
    private static let trialStartKey = "FirstRunDate"

    static func recordedTrialStart() -> Date? {
        UserDefaults(suiteName: licenseBase)?.object(forKey: trialStartKey) as? Date
    }

    static let defaultOpenssl = "/usr/bin/openssl"

    static func check(
        crossOverRoot: URL,
        searchDirs: [URL] = defaultSearchDirs,
        openssl: String = defaultOpenssl,
        trialStart: () -> Date? = recordedTrialStart,
        now: Date = Date()
    ) -> Status {
        let status = evaluate(
            crossOverRoot: crossOverRoot, searchDirs: searchDirs, openssl: openssl,
            trialStart: trialStart, now: now
        )
        AppLog.note("license: \(status.diagnostic)")
        return status
    }

    // Only reached when no license file exists at all: a license that is present but
    // fails is refused as before, never rescued by a trial.
    static func trial(startedAt start: Date?, now: Date) -> Status {
        guard let start else {
            return Status(
                licensed: false,
                detail: notActivated,
                diagnostic: "no CrossOver license file found and no trial start recorded"
            )
        }
        // A first run after now means the clock or the record moved, so the trial
        // cannot be measured.
        guard start <= now else {
            return Status(
                licensed: false,
                detail: notActivated,
                diagnostic: "no CrossOver license file found and the recorded trial start is in the future"
            )
        }
        let remaining = start.addingTimeInterval(trialLength).timeIntervalSince(now)
        guard remaining > 0 else {
            return Status(
                licensed: false,
                detail: trialEnded,
                diagnostic: "no CrossOver license file found and the trial has ended"
            )
        }
        let days = Int((remaining / 86400).rounded(.up))
        return Status(
            licensed: true,
            detail: "CrossOver trial is active, \(days) day\(days == 1 ? "" : "s") left.",
            diagnostic: "no CrossOver license file found, trial active with \(days) day(s) left"
        )
    }

    private static func evaluate(
        crossOverRoot: URL,
        searchDirs: [URL],
        openssl: String,
        trialStart: () -> Date?,
        now: Date
    ) -> Status {
        let keyFile = crossOverRoot.appending(
            path: "share/crossover/data/tie.pub"
        ).path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: keyFile) else {
            return Status(
                licensed: false,
                detail: notActivated,
                diagnostic: "no verification key in the CrossOver bundle"
            )
        }

        var rejection: String?

        for dir in searchDirs {
            let label = dir.path(percentEncoded: false)
            let license = dir.appending(path: "\(licenseBase).license")
                .path(percentEncoded: false)

            guard FileManager.default.fileExists(atPath: license) else { continue }

            let signatures = sidecars(in: dir)
            guard !signatures.isEmpty else {
                rejection = "the license in \(label) has no signature beside it"
                continue
            }

            var unchecked: String?

            for signature in signatures {
                let result: CommandResult
                do {
                    result = try Shell.run(openssl, [
                        "dgst", signature.digest, "-verify", keyFile,
                        "-signature", signature.path, license,
                    ])
                } catch {
                    return Status(
                        licensed: false,
                        detail: notActivated,
                        diagnostic: "could not run \(openssl) to verify the license"
                    )
                }

                if result.succeeded {
                    return Status(
                        licensed: true,
                        detail: "CrossOver is activated.",
                        diagnostic: "valid license in \(label)"
                    )
                }

                let trouble = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trouble.isEmpty {
                    if trouble.localizedCaseInsensitiveContains("unable to load key") {
                        return Status(
                            licensed: false,
                            detail: notActivated,
                            diagnostic: "the verification key in the CrossOver bundle could not be read"
                        )
                    }
                    unchecked = "the license in \(label) could not be checked"
                }
            }

            rejection = unchecked
                ?? "no signature beside the license in \(label) verified against this bundle"
        }

        guard let rejection else { return trial(startedAt: trialStart(), now: now) }
        return Status(licensed: false, detail: notActivated, diagnostic: rejection)
    }

    static func requireValid(
        for install: CrossOverInstall,
        trialStart: () -> Date? = recordedTrialStart,
        now: Date = Date()
    ) throws {
        let status = check(crossOverRoot: install.crossOverRoot, trialStart: trialStart, now: now)
        guard status.licensed else {
            throw StepFailure(
                step: "Verify CrossOver license",
                detail: status.detail
            )
        }
    }

    private static func sidecars(in dir: URL) -> [(path: String, digest: String)] {
        let candidates: [(path: String, digest: String)] = [
            (dir.appending(path: "\(licenseBase).sha256").path(percentEncoded: false), "-sha256"),
            (dir.appending(path: "\(licenseBase).sig").path(percentEncoded: false), "-sha1"),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
