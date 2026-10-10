import Foundation

// Which compatibility tool Steam runs a game with, read from Steam's
// config.vdf. Only read: Steam rewrites that file when it quits.
enum SteamCompatMapping {

    static var configVDF: URL { SupportPaths.Steam.userData.appending(path: "config/config.vdf") }

    static func tool(forApp appID: String, file: URL = configVDF) -> String? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap { tool(forApp: appID, in: $0) }
    }

    // The "name" of the app's entry inside the CompatToolMapping block.
    static func tool(forApp appID: String, in text: String) -> String? {
        guard let key = text.range(of: "\"CompatToolMapping\""),
              let open = text[key.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var end = text.endIndex
        for i in text[open...].indices {
            if text[i] == "{" { depth += 1 }
            if text[i] == "}" { depth -= 1; if depth == 0 { end = i; break } }
        }
        let block = String(text[open..<end])
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: appID))\"\\s*\\{[^}]*?\"name\"\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let name = Range(match.range(at: 1), in: block) else { return nil }
        return String(block[name])
    }
}
