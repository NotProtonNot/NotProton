// NotProton payload manifest stuff

import Foundation

enum PayloadOrigin: String, Sendable, CaseIterable {
    case built, patched, valve


    var isFetchable: Bool { self == .valve }
}

struct PayloadEntry: Sendable, Equatable, Identifiable {
    let origin: PayloadOrigin
    let path: String

    var id: String { path }
}

struct PayloadManifest: Sendable {
    let entries: [PayloadEntry]

    func paths(origin: PayloadOrigin) -> [String] {
        entries.filter { $0.origin == origin }.map(\.path)
    }

    static let resourceName = "payload"
    static let resourceExtension = "manifest"

    static func bundled() throws -> PayloadManifest {
        guard let url = AppResources.bundle.url(
            forResource: resourceName, withExtension: resourceExtension
        ) else {
            throw StepFailure(
                step: L10n.tr("Read the component list"),
                detail: L10n.tr("\(resourceName).\(resourceExtension) is missing from the app's resources.")
            )
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> PayloadManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StepFailure(
                step: L10n.tr("Read the component list"),
                detail: L10n.tr("\(url.path(percentEncoded: false)) could not be read. \(error.localizedDescription)")
            )
        }
        return try parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) throws -> PayloadManifest {
        var entries: [PayloadEntry] = []
        var seen = Set<String>()

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            let number = index + 1
            guard fields.count == 2 else {
                throw StepFailure(
                    step: L10n.tr("Read the component list"),
                    detail: L10n.tr("Line \(number) is not an origin and a path: \(line)")
                )
            }
            guard let origin = PayloadOrigin(rawValue: String(fields[0])) else {
                throw StepFailure(
                    step: L10n.tr("Read the component list"),
                    detail: L10n.tr("Line \(number) has an unknown origin \(fields[0]). Known: \(PayloadOrigin.allCases.map(\.rawValue).joined(separator: ", ")).")
                )
            }

            let path = String(fields[1])
            guard seen.insert(path).inserted else {
                throw StepFailure(
                    step: L10n.tr("Read the component list"),
                    detail: L10n.tr("Line \(number) repeats \(path).")
                )
            }

            entries.append(PayloadEntry(origin: origin, path: path))
        }

        guard !entries.isEmpty else {
            throw StepFailure(step: L10n.tr("Read the component list"), detail: L10n.tr("The component list has no entries."))
        }

        return PayloadManifest(entries: entries)
    }
}
