import Foundation
import Testing

@testable import NotProtonApp

// The dylib picks the signature database itself, in newest_sigdb_in_dir. What the app reports
// has to be the file the dylib will load, or the status describes a different install.
@Suite("Signature database selection")
struct SignatureDatabaseSelectionTests {

    private func directory(_ names: [String]) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "np-sigs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names {
            try Data("{}".utf8).write(to: url.appending(path: name))
        }
        return url
    }

    @Test("The highest numbered database wins, whatever order the directory lists")
    func picksTheHighestNumber() throws {
        let dir = try directory(["1788400362.json", "1700000000.json", "1788400361.json"])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PayloadInspector.newestSignatureDatabase(in: dir) == "1788400362.json")
    }

    @Test("Numbers are compared as numbers, not as text")
    func comparesNumerically() throws {
        // Lexically "9" sorts above "10", so a string comparison would pick the older one.
        let dir = try directory(["9.json", "10.json"])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PayloadInspector.newestSignatureDatabase(in: dir) == "10.json")
    }

    @Test("A directory with no database reports none")
    func reportsNoneWhenEmpty() throws {
        let dir = try directory([])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PayloadInspector.newestSignatureDatabase(in: dir) == nil)
    }

    @Test("A directory that is not there reports none rather than throwing")
    func reportsNoneWhenAbsent() {
        let absent = URL.temporaryDirectory.appending(path: "np-sigs-absent-\(UUID().uuidString)")
        #expect(PayloadInspector.newestSignatureDatabase(in: absent) == nil)
    }

    @Test("Files that are not databases are ignored")
    func ignoresOtherFiles() throws {
        let dir = try directory(["1788400362.json", "notes.txt", "README"])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PayloadInspector.newestSignatureDatabase(in: dir) == "1788400362.json")
    }

    // newest_sigdb_in_dir requires the whole stem to be digits, so strtoull has to consume every
    // character before ".json". A name the dylib skips cannot be reported as the one it loads.
    @Test("A name that is not all digits is not a database the dylib would load")
    func refusesNonNumericNames() throws {
        let dir = try directory(["notes.json"])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PayloadInspector.newestSignatureDatabase(in: dir) == nil)
    }

    @Test("Trailing text after the number is not a database either")
    func refusesTrailingText() throws {
        // What duplicating the file in Finder produces.
        let dir = try directory(["1788400362 copy.json"])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PayloadInspector.newestSignatureDatabase(in: dir) == nil)
    }

    // The dylib treats a parsed value of zero as no database, so "0.json" is skipped.
    @Test("Zero is not a client build")
    func refusesZero() throws {
        let dir = try directory(["0.json"])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PayloadInspector.newestSignatureDatabase(in: dir) == nil)
    }

    @Test("A real database is still found next to names the dylib skips")
    func picksTheRealOneAmongstJunk() throws {
        let dir = try directory(["notes.json", "0.json", "1788400362.json", "old copy.json"])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PayloadInspector.newestSignatureDatabase(in: dir) == "1788400362.json")
    }
}

@Suite("Payload completeness")
struct PayloadStateTests {

    private func state(
        missing: [PayloadEntry] = [],
        overlay: Bool = true,
        signatures: String? = "1788400362.json",
        problem: String? = nil
    ) -> PayloadState {
        PayloadState(
            expected: 18,
            present: 18 - missing.count,
            missing: missing,
            overlayShimPresent: overlay,
            iconmakerPresent: true,
            appinfoPresent: true,
            signatureDatabase: signatures,
            legacyCompatPresent: 6,
            legacyCompatExpected: 6,
            manifestProblem: problem
        )
    }

    @Test("Everything staged is complete")
    func completeWhenNothingIsWrong() {
        #expect(state().isComplete)
    }

    @Test("Each thing that can be wrong on its own makes the payload incomplete")
    func incompleteForEachCause() {
        let entry = PayloadEntry(origin: .valve, path: "steamclient64.dll")

        #expect(!state(missing: [entry]).isComplete)
        #expect(!state(overlay: false).isComplete)
        #expect(!state(signatures: nil).isComplete)
        #expect(!state(problem: "the manifest will not parse").isComplete)
    }

    // A manifest that will not parse leaves expected at zero and missing empty, which looks
    // exactly like a complete install. Only the problem separates them, so it has to decide.
    @Test("An unreadable manifest is not mistaken for a complete install")
    func unreadableManifestIsNotComplete() {
        let broken = PayloadState(
            expected: 0, present: 0, missing: [],
            overlayShimPresent: true,
            iconmakerPresent: true,
            appinfoPresent: true,
            signatureDatabase: "1788400362.json",
            legacyCompatPresent: 6,
            legacyCompatExpected: 6,
            manifestProblem: "payload.tsv is missing from the app's resources."
        )
        #expect(!broken.isComplete)
    }

    @Test("Missing entries are reported per origin")
    func splitsMissingByOrigin() {
        let built = PayloadEntry(origin: .built, path: "x86_64-unix/lsteamclient.so")
        let valve = PayloadEntry(origin: .valve, path: "steamclient64.dll")
        let patched = PayloadEntry(origin: .patched, path: "wine/i386-windows/ntdll.dll")
        let payload = state(missing: [built, valve, patched])

        #expect(payload.missing(origin: .built) == [built])
        #expect(payload.missing(origin: .valve) == [valve])
        #expect(payload.missing(origin: .patched) == [patched])
    }

    @Test("Issue 39: an installed Steam remains complete before runner setup")
    func steamDoesNotRequireRunnerFiles() {
        let runnerFiles = [PayloadEntry(origin: .patched, path: "wine/i386-windows/ntdll.dll"),
                           PayloadEntry(origin: .valve, path: "steamclient.dll")]
        #expect(state(missing: runnerFiles).isSteamComplete)
        #expect(!state(missing: runnerFiles).isComplete)
        #expect(!state(missing: [PayloadEntry(origin: .built, path: "steam.exe")]).isSteamComplete)
        #expect(!state(overlay: false).isSteamComplete)
        #expect(!state(signatures: nil).isSteamComplete)
        #expect(!state(problem: "Invalid manifest").isSteamComplete)
    }

    @Test("Repair text names missing files and clarifies macOS user")
    func actionableRepairText() {
        let payload = state(missing: [PayloadEntry(origin: .built, path: "steam.exe")], overlay: false)
        #expect(payload.steamRepairDetail.contains("steam.exe"))
        #expect(payload.steamRepairDetail.contains("overlay-shim.dylib"))
        #expect(payload.steamRepairDetail.contains("macOS user"))
        #expect(state(problem: "Invalid manifest").steamRepairDetail == "Invalid manifest")
    }

    @Test("An origin with nothing missing reports nothing")
    func emptyOriginIsEmpty() {
        let payload = state(missing: [PayloadEntry(origin: .valve, path: "steamclient64.dll")])
        #expect(payload.missing(origin: .built).isEmpty)
    }
}
