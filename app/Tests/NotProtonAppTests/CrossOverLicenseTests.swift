import Foundation
import Testing

@testable import NotProtonApp

// The check gates whether a runner may be cloned, so a wrong unlicensed verdict strands a user
// who holds a good license. Fixtures carry their own keypair, so it reads the same either way.
@Suite("CrossOver license")
struct CrossOverLicenseTests {

    // The tree hangs off a bundle so the layout check() is handed directly and the one
    // requireValid derives from a bundle are the same tree.
    private struct Fixture {
        let dir: URL
        let bundle: URL
        let local: URL
        let system: URL
        let key: URL

        var root: URL { SupportPaths.crossOverRoot(inBundle: bundle) }
        var publishedKey: URL { root.appending(path: "share/crossover/data/tie.pub") }
        var searchDirs: [URL] { [local, system] }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    private static let base = "com.codeweavers.CrossOver"

    private static let body = """
        [crossmac]
        customer=Test
        expires=2999/01/01
        [license]
        id=test

        """

    private static func fixture(withKey: Bool = true) throws -> Fixture {
        let fm = FileManager.default
        let dir = URL.temporaryDirectory.appending(path: "np-license-\(UUID().uuidString)")
        let fix = Fixture(
            dir: dir,
            bundle: dir.appending(path: "CrossOver.app"),
            local: dir.appending(path: "local"),
            system: dir.appending(path: "system"),
            key: dir.appending(path: "private.pem")
        )

        // The caller registers teardown on what it is handed, so a fixture that throws
        // half built has to take its own tree with it.
        do {
            for made in [
                fix.publishedKey.deletingLastPathComponent(), fix.local, fix.system,
            ] {
                try fm.createDirectory(at: made, withIntermediateDirectories: true)
            }
            try generate(key: fix.key, publishing: withKey ? fix.publishedKey : nil)
        } catch {
            fix.remove()
            throw error
        }
        return fix
    }

    // check, not run: openssl failing here leaves the fixture without the file the test
    // is about, and a test that then passes proves nothing.
    private static func generate(key: URL, publishing pub: URL?) throws {
        try Shell.check(
            CrossOverLicense.defaultOpenssl,
            ["genrsa", "-out", key.path(percentEncoded: false), "2048"]
        )
        guard let pub else { return }
        try Shell.check(CrossOverLicense.defaultOpenssl, [
            "rsa", "-in", key.path(percentEncoded: false),
            "-pubout", "-out", pub.path(percentEncoded: false),
        ])
    }

    @discardableResult
    private static func writeLicense(in dir: URL) throws -> URL {
        let license = dir.appending(path: "\(base).license")
        try body.write(to: license, atomically: true, encoding: .utf8)
        return license
    }

    private static func sign(
        _ license: URL, with key: URL, digest: String, sidecar: String
    ) throws {
        try Shell.check(CrossOverLicense.defaultOpenssl, [
            "dgst", digest, "-sign", key.path(percentEncoded: false),
            "-out", license.deletingLastPathComponent()
                .appending(path: "\(base).\(sidecar)").path(percentEncoded: false),
            license.path(percentEncoded: false),
        ])
    }

    @Test("A license signed by the bundle's key is accepted")
    func validLicenseIsAccepted() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(status.licensed)
    }

    @Test("A bundle carrying no verification key is named in the diagnostic")
    func missingKeyIsNamed() throws {
        let fix = try Self.fixture(withKey: false)
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic == "no verification key in the CrossOver bundle")
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // Both read the same to the user, so the log is the only thing left that can tell an
    // install that never had a license from one whose license was refused.
    @Test("No license file reads apart from a license that fails")
    func absentLicenseReadsApartFromInvalid() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }

        let absent = CrossOverLicense.check(
            crossOverRoot: fix.root, searchDirs: fix.searchDirs, trialStart: { nil }
        )
        #expect(!absent.licensed)
        #expect(absent.diagnostic.hasPrefix("no CrossOver license file found"))
        #expect(absent.detail == CrossOverLicense.notActivated)

        let license = try Self.writeLicense(in: fix.local)
        let other = fix.local.appending(path: "other.pem")
        try Self.generate(key: other, publishing: nil)
        try Self.sign(license, with: other, digest: "-sha256", sidecar: "sha256")

        let wrong = CrossOverLicense.check(
            crossOverRoot: fix.root, searchDirs: fix.searchDirs, trialStart: { nil }
        )
        #expect(!wrong.licensed)
        #expect(wrong.diagnostic.contains("verified against this bundle"))
        #expect(wrong.diagnostic != absent.diagnostic)
        #expect(wrong.detail == CrossOverLicense.notActivated)
    }

    @Test("A license with no signature beside it is named as such")
    func unsignedLicenseIsNamed() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        try Self.writeLicense(in: fix.local)

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("has no signature beside it"))
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // The sidecar that verifies is not always the first one present, and taking only
    // the first turned a good license into an invalid one.
    @Test("A stale .sha256 does not condemn a license the .sig verifies")
    func staleSidecarDoesNotCondemnTheLicense() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha1", sidecar: "sig")
        try Data(repeating: 0x41, count: 256).write(
            to: fix.local.appending(path: "\(Self.base).sha256")
        )

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(status.licensed)
    }

    @Test("A license kept only in the system directory is found")
    func systemDirectoryIsSearched() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.system)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(status.licensed)
        #expect(status.diagnostic.contains(fix.system.path(percentEncoded: false)))
    }

    // Without the tool there is no verdict, and the user is told the same thing either way, so
    // the log is the only place a missing openssl reads apart from a CrossOver never activated.
    @Test("A missing openssl reads apart from an unactivated CrossOver in the log")
    func missingToolIsNotReportedAsUnlicensed() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(
            crossOverRoot: fix.root,
            searchDirs: fix.searchDirs,
            openssl: "/usr/bin/notproton-no-such-openssl"
        )
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("could not run"))
        #expect(status.diagnostic.contains("notproton-no-such-openssl"))
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // The reason reaches the user only through the thrown failure. requireValid searches the
    // machine's own directories, so only the two agreeing is fixed, not the text itself.
    @Test("The refusal carries the reason the check found and nothing else")
    func refusalCarriesTheReason() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let install = CrossOverInstall(
            bundle: fix.bundle, releaseVersion: nil, support: .unreadable
        )

        // A key generated for this fixture verifies no license on this machine, and a
        // machine with no license has nothing to find either. The trial is held absent
        // so a trial on the machine running the tests does not answer for it.
        let expected = CrossOverLicense.check(
            crossOverRoot: install.crossOverRoot, trialStart: { nil }
        )
        #expect(!expected.licensed)

        do {
            try CrossOverLicense.requireValid(for: install, trialStart: { nil })
            Issue.record("requireValid accepted a bundle whose key verifies nothing")
        } catch let failure as StepFailure {
            #expect(failure.detail == expected.detail)
        }
    }

    // An unreadable key exits the same status as a signature that does not match, which
    // leaves the log as the only place the two are told apart.
    @Test("An unreadable verification key reads apart from a license that fails in the log")
    func unreadableKeyReadsApartFromInvalid() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")
        try Data("not a key".utf8).write(to: fix.publishedKey)

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic == "the verification key in the CrossOver bundle could not be read")
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // Same exit status again, and the license here is the one thing known to be good.
    @Test("A signature openssl cannot read is not called an invalid license")
    func unreadableSidecarIsNotCalledInvalid() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: fix.local.appending(path: "\(Self.base).sha256")
                .path(percentEncoded: false)
        )

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("could not be checked"))
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // MARK: Trial

    // A fixed clock, so no test reads the machine's own trial or date.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 86400

    private static func check(
        _ fix: Fixture, trialStart: Date?
    ) -> CrossOverLicense.Status {
        CrossOverLicense.check(
            crossOverRoot: fix.root, searchDirs: fix.searchDirs,
            trialStart: { trialStart }, now: now
        )
    }

    @Test("A paid license is accepted whatever the trial says")
    func paidLicenseIgnoresTrial() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        for start in [nil, Self.now - 400 * Self.day, Self.now + Self.day] {
            let status = Self.check(fix, trialStart: start)
            #expect(status.licensed)
            #expect(status.diagnostic.contains("valid license"))
        }
    }

    @Test("An active trial is accepted and says how long it has left")
    func activeTrialIsAccepted() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }

        let status = Self.check(fix, trialStart: Self.now - 3 * Self.day)
        #expect(status.licensed)
        #expect(status.detail == "CrossOver trial is active, 11 days left.")
        #expect(status.diagnostic.contains("trial active"))

        let lastDay = Self.check(fix, trialStart: Self.now - 13.5 * Self.day)
        #expect(lastDay.licensed)
        #expect(lastDay.detail == "CrossOver trial is active, 1 day left.")
    }

    @Test("An ended trial is refused and points to purchase")
    func expiredTrialIsRefused() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }

        for start in [Self.now - CrossOverLicense.trialLength, Self.now - 15 * Self.day,
                      Self.now - 400 * Self.day] {
            let status = Self.check(fix, trialStart: start)
            #expect(!status.licensed)
            #expect(status.detail == CrossOverLicense.trialEnded)
            #expect(status.detail.contains("codeweavers.com/store"))
            #expect(status.diagnostic.contains("trial has ended"))
        }
    }

    @Test("No recorded trial start is refused as not activated")
    func missingTrialIsRefused() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }

        let status = Self.check(fix, trialStart: nil)
        #expect(!status.licensed)
        #expect(status.detail == CrossOverLicense.notActivated)
        #expect(status.diagnostic.contains("no trial start recorded"))
    }

    // A first run in the future means the clock went back or the record was moved,
    // and either way the trial cannot be measured.
    @Test("A trial start in the future is refused as not activated")
    func futureTrialIsRefused() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }

        let status = Self.check(fix, trialStart: Self.now + 60)
        #expect(!status.licensed)
        #expect(status.detail == CrossOverLicense.notActivated)
        #expect(status.diagnostic.contains("in the future"))
    }

    @Test("A license that fails is not rescued by an active trial")
    func failingLicenseIsNotRescuedByTrial() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        try Self.writeLicense(in: fix.local)

        let status = Self.check(fix, trialStart: Self.now - Self.day)
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("has no signature beside it"))
    }

    @Test("A bundle with no verification key is refused even during a trial")
    func trialStillNeedsTheBundleKey() throws {
        let fix = try Self.fixture(withKey: false)
        defer { fix.remove() }

        let status = Self.check(fix, trialStart: Self.now - Self.day)
        #expect(!status.licensed)
        #expect(status.diagnostic == "no verification key in the CrossOver bundle")
    }
}
