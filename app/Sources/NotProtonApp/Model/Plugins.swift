import AppKit
import Foundation
import Observation

struct PluginRecord: Equatable, Sendable {
    let id: String
    var label: String?
    var apps: [String] = []
    var requires: [String] = []
}

struct PluginFile: Identifiable, Equatable, Sendable {
    let url: URL
    let records: [PluginRecord]

    var id: String { url.lastPathComponent }

    var title: String {
        records.first?.label ?? records.first?.id ?? url.deletingPathExtension().lastPathComponent
    }

    var apps: [String] { records.flatMap(\.apps) }
    var requires: [String] { records.flatMap(\.requires) }
}

enum PluginConf {
    static func parse(_ text: String) -> [PluginRecord] {
        var records: [PluginRecord] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard let close = line.lastIndex(of: "]") else { continue }
                let id = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                if !id.isEmpty { records.append(PluginRecord(id: id)) }
                continue
            }
            guard let eq = line.firstIndex(of: "="), !records.isEmpty else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let last = records.count - 1
            switch key {
            case "label": if records[last].label == nil { records[last].label = value }
            case "apps": records[last].apps.append(value)
            case "requires": records[last].requires.append(value)
            default: break
            }
        }
        return records
    }

    static func resolve(_ path: String, home: URL) -> URL {
        if path.hasPrefix("/") { return URL(filePath: path) }
        var rel = Substring(path)
        if rel.hasPrefix("~/") { rel = rel.dropFirst(2) } else if rel.hasPrefix("$HOME/") { rel = rel.dropFirst(6) }
        return home.appending(path: String(rel))
    }

    static func owned(by file: PluginFile, among all: [PluginFile], folder: URL, home: URL) -> [URL] {
        let root = folder.standardizedFileURL.path(percentEncoded: false)
        let inside = root.hasSuffix("/") ? root : root + "/"
        let others = Set(all.filter { $0.id != file.id }.flatMap(\.requires).map {
            resolve($0, home: home).standardizedFileURL.path(percentEncoded: false)
        })
        var seen = Set<String>()
        return file.requires.compactMap { rel in
            let url = resolve(rel, home: home).standardizedFileURL
            let path = url.path(percentEncoded: false)
            var isDir: ObjCBool = false
            guard path.hasPrefix(inside), !path.hasSuffix(".conf"), !others.contains(path),
                  seen.insert(path).inserted,
                  FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue
            else { return nil }
            return url
        }
    }
}

@MainActor
@Observable
final class PluginsModel {

    private(set) var plugins: [PluginFile] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var outcome: String?
    private(set) var failure: String?
    var pendingRemoval: PluginFile?

    let folder: URL
    let home: URL

    init(folder: URL = SupportPaths.plugins, home: URL = SupportPaths.home) {
        self.folder = folder
        self.home = home
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let folder = folder
        plugins = await Task.detached { Self.scan(folder) }.value
        hasLoaded = true
    }

    nonisolated static func scan(_ folder: URL) -> [PluginFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".conf") }.sorted().map { name in
            let url = folder.appending(path: name)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return PluginFile(url: url, records: PluginConf.parse(text))
        }
    }

    func missing(_ file: PluginFile) -> String? {
        let exists = { (rel: String) in
            FileManager.default.fileExists(atPath: PluginConf.resolve(rel, home: self.home).path(percentEncoded: false))
        }
        return file.records.first { !$0.requires.isEmpty && !$0.requires.contains(where: exists) }?.requires.first
    }

    func remove(_ file: PluginFile) async {
        outcome = nil
        failure = nil
        let urls = [file.url] + PluginConf.owned(by: file, among: plugins, folder: folder, home: home)
        do {
            for url in urls { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            outcome = String(localized: "Moved \(file.title) to the Trash.")
        } catch {
            failure = String(localized: "\(file.title) could not be moved to the Trash. \(error.localizedDescription)")
        }
        await load()
    }

    func reveal(_ file: PluginFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
