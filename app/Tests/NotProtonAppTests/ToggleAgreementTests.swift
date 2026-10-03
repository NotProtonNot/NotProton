import Foundation
import Testing

@testable import NotProtonApp

@Suite("Toggle agreement")
struct ToggleAgreementTests {

    private static func source(_ path: String) throws -> String {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repo.appending(path: path), encoding: .utf8)
    }

    // The three shapes a setting name appears in: read, toggle, and write.
    static func toggleNames(in webpatch: String) throws -> Set<String> {
        var names: Set<String> = []
        for pattern in [
            #"g\(\\"([A-Z0-9_]+)\\"\)"#,
            #"T\(\[\\"([A-Z0-9_]+)\\""#,
            #"\[\\"([A-Z0-9_]+)\\","#,
        ] {
            for match in webpatch.matches(of: try Regex(pattern)) {
                names.insert(String(match[1].substring ?? ""))
            }
        }
        return names
    }

    static let ownedNames: Set<String> = ["WINEPREFIX", "WINELOADER", "WINESERVER", "PATH"]

    @Test("Every Compatibility page toggle reaches the game as an environment variable")
    func togglesAreNamespaced() throws {
        let webpatch = try Self.source("dylib/feats/webpatch.c")
        let names = try Self.toggleNames(in: webpatch)

        #expect(names.count >= 8, "found \(names.count) toggles, the parse looks wrong")

        #expect(
            webpatch.contains(#"rest=\"%command%\""#),
            "webpatch.c no longer writes %command%, so the toggles would reach the game as arguments"
        )

        for name in names.sorted() {
            #expect(
                !Self.ownedNames.contains(name),
                "\(name) is set by compat_run.sh, so the panel would write a value it overwrites")
            #expect(
                name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") },
                "\(name) is not a name sh can export, so it would reach the game as an argument")
        }
    }
}
