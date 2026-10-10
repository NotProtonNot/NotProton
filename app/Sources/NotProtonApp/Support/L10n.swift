import Foundation

/// Explicit bundles also localize model strings (SwiftUI does not localize a
/// computed String). Follow the main app's language selection, including macOS
/// per-app language preferences. Tools without localized bundles fall back to
/// English; NOTPROTON_LANGUAGE is a process-local override for testing.
enum L10n {
    static let language = ProcessInfo.processInfo.environment["NOTPROTON_LANGUAGE"]
        ?? Bundle.main.preferredLocalizations.first
        ?? "en"

    static func isSimplifiedChinese(_ language: String) -> Bool {
        let parts = language.lowercased().replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
        guard parts.first == "zh" else { return false }
        if parts.contains("hant") { return false }
        if parts.contains("hans") { return true }
        return parts.count == 1 || parts == ["zh", "cn"] || parts == ["zh", "sg"]
    }

    static let chinese: Bundle? = {
        let resources = AppResources.bundle
        // SwiftPM normalizes this directory to zh-hans.lproj. Bundle's resource
        // lookup is case-sensitive even on a case-insensitive APFS volume.
        let name = resources.localizations.first { $0.lowercased() == "zh-hans" } ?? "zh-Hans"
        return resources.path(forResource: name, ofType: "lproj").flatMap { Bundle(path: $0) }
    }()

    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]

        init(stringLiteral value: String) {
            key = value
            arguments = []
        }

        init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }

        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []

            init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }

            mutating func appendLiteral(_ literal: String) { key += literal }

            mutating func appendInterpolation<T>(_ value: T) {
                key += "{\(arguments.count)}"
                arguments.append(String(describing: value))
            }
        }
    }

    static func tr(_ message: Message, language: String = language) -> String {
        let template = isSimplifiedChinese(language)
            ? chinese?.localizedString(forKey: message.key, value: message.key, table: nil) ?? message.key
            : message.key
        return render(template, arguments: message.arguments)
    }

    /// One pass, not repeated replacement: a game name containing "{1}" or "%"
    /// must stay literal, never become a second formatting instruction.
    static func render(_ template: String, arguments: [String]) -> String {
        let pattern = /\{([0-9]+)\}/
        var result = ""
        var position = template.startIndex
        for match in template.matches(of: pattern) {
            result += template[position..<match.range.lowerBound]
            if let index = Int(match.1), arguments.indices.contains(index) {
                result += arguments[index]
            } else {
                result += template[match.range]
            }
            position = match.range.upperBound
        }
        result += template[position...]
        return result
    }
}
