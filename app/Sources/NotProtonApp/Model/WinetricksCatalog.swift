import Foundation

struct WinetricksVerb: Identifiable, Sendable, Equatable {
    let name: String
    let category: String
    let title: String
    let publisher: String
    let year: String
    let media: String
    let conflicts: [String]
    let installedFiles: [String]
    var win32Only = false
    var win64Only = false
    // Trying to avoid confusing the user with regards to if these settings are applied to DXMT/DXVK/D3DMetal or not (they are not).
    var wined3dOnly = false

    var id: String { name }
    var isManualDownload: Bool { media == "manual_download" }
}

enum WinetricksCatalog {

    static let categories = ["dlls", "fonts", "settings"]

    private static let hiddenFamilies: Set<String> = [
        "graphics",
        "windowmanagerdecorated", "windowmanagermanaged", "usetakefocus", "useegl",
        "grabfullscreen",
        "autostart_winedbg", "nocrashdialog",
        "set_userpath", "set_mididevice",
        "bad", "good",
        "vd",
        "isolate_home", "sandbox",
    ]
    private static let hiddenVerbs: Set<String> = ["sound=alsa", "sound=oss", "sound=pulse"]

    static func isOffered(_ verb: WinetricksVerb, prefixIs32Bit: Bool = false) -> Bool {
        guard categories.contains(verb.category) else { return false }
        if verb.win32Only && !prefixIs32Bit { return false }
        if verb.win64Only && prefixIs32Bit { return false }
        let family = String(verb.name.prefix { $0 != "=" })
        return !hiddenFamilies.contains(family) && !hiddenVerbs.contains(verb.name)
    }

    static func verbs(in script: String) -> [WinetricksVerb] {
        var found: [WinetricksVerb] = []
        var open: (name: String, category: String, fields: [String: String])?
        func close() {
            if let block = open {
                found.append(verb(name: block.name, category: block.category, fields: block.fields))
            }
            open = nil
        }
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            if let head = header(of: line) {
                close()
                open = (head.name, head.category, [:])
            } else if open != nil, let field = field(of: line) {
                open?.fields[field.key] = field.value
            } else {
                close()
            }
        }
        close()
        let win32Only = loaders(in: script) { $0 == "w_package_unsupported_win64" }
        let win64Only = loaders(in: script) { $0 == "w_package_unsupported_win32" }
        let wined3dOnly = loaders(in: script) {
            $0.hasPrefix("winetricks_set_wined3d_var ") || $0 == #"[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]"#
        }
        for index in found.indices {
            let family = String(found[index].name.prefix { $0 != "=" })
            found[index].win32Only = win32Only.contains(family)
            found[index].win64Only = win64Only.contains(family)
            found[index].wined3dOnly = wined3dOnly.contains(family)
        }
        return found
    }

    private static func loaders(in script: String, where matches: (String) -> Bool) -> Set<String> {
        var names: Set<String> = []
        var current: String?
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("load_"), line.hasSuffix("()") {
                current = String(line.dropFirst("load_".count).dropLast(2))
            } else if line == "}" {
                current = nil
            } else if let name = current, matches(line.trimmingCharacters(in: .whitespaces)) {
                names.insert(name)
            }
        }
        return names
    }

    private static func header(of line: Substring) -> (name: String, category: String)? {
        guard line.hasPrefix("w_metadata ") else { return nil }
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return nil }
        return (name: String(words[1]), category: String(words[2]))
    }

    private static func field(of line: Substring) -> (key: String, value: String)? {
        guard let equals = line.range(of: "=\"") else { return nil }
        let key = line[..<equals.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        let rest = line[equals.upperBound...]
        guard let closing = rest.lastIndex(of: "\"") else { return nil }
        var value = String(rest[..<closing])
        var after = rest[rest.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        if after.last == "\\" { after.removeLast() }
        after = after.trimmingCharacters(in: .whitespaces)
        if after.hasPrefix("/") {
            value += after
            after = ""
        }
        guard after.isEmpty else { return nil }
        return (key, value)
    }

    private static func verb(
        name: String, category: String, fields: [String: String]
    ) -> WinetricksVerb {
        // file1..file6 name cached downloads and not installed files.
        let probed = [fields["installed_file1"], fields["installed_exe1"]]
            .compactMap { $0 }
            .flatMap { $0.split(separator: "|").map(String.init) }
        return WinetricksVerb(
            name: name,
            category: category,
            title: fields["title"] ?? "",
            publisher: fields["publisher"] ?? "",
            year: displayYear(fields["year"] ?? ""),
            media: fields["media"] ?? "",
            conflicts: (fields["conflicts"] ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init),
            installedFiles: probed
        )
    }

    static func displayYear(_ raw: String) -> String {
        guard raw.first?.isNumber == true else { return "" }
        return raw.replacingOccurrences(of: "-", with: "\u{2013}")
    }

    static func installedVerbs(among verbs: [WinetricksVerb], in prefix: WinePrefix) -> Set<String> {
        let ran = ranVerbs(in: prefix)
        var installed: Set<String> = []
        for verb in verbs where ran.contains(verb.name) && !verb.installedFiles.isEmpty {
            if verb.installedFiles.contains(where: { isRealFile($0, in: prefix) }) {
                installed.insert(verb.name)
            }
        }
        return installed
    }

    // w_conflicts checks this log even if the installed file is gone.
    static func ranVerbs(in prefix: WinePrefix) -> Set<String> {
        let log = prefix.pfx.appending(path: "winetricks.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    static func clash(
        among verbs: [WinetricksVerb], checked: Set<String>, ran: Set<String>
    ) -> (verb: String, with: String)? {
        for verb in verbs where checked.contains(verb.name) {
            if let other = verb.conflicts.first(where: {
                $0 != verb.name && (ran.contains($0) || checked.contains($0))
            }) {
                return (verb.name, other)
            }
        }
        return nil
    }

    private static func isRealFile(_ path: String, in prefix: WinePrefix) -> Bool {
        guard let url = driveCFile(path, in: prefix) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url),
            let head = try? handle.read(upToCount: 128 * 1024)
        else { return false }
        try? handle.close()
        return !String(decoding: head, as: UTF8.self).contains("Wine placeholder DLL")
    }

    static func driveCFile(_ path: String, in prefix: WinePrefix) -> URL? {
        let arch = PrefixStore.arch(of: prefix)
        var windows = winetricksWindowsPath(path, arch: arch)
        windows = windows.replacingOccurrences(of: "\\", with: "/")
        while windows.contains("//") {
            windows = windows.replacingOccurrences(of: "//", with: "/")
        }
        guard let colon = windows.firstIndex(of: ":"), windows.distance(
            from: windows.startIndex, to: colon) == 1
        else { return nil }
        guard windows[windows.startIndex].lowercased() == "c" else { return nil }
        return prefix.pfx
            .appending(path: "drive_c")
            .appending(path: String(windows[windows.index(after: colon)...]))
    }

    static func winetricksWindowsPath(_ path: String, arch: PrefixArch?) -> String {
        let win64 = arch != .i386
        let variables: [String: String] = [
            "W_WINDIR_WIN": "C:/windows",
            "W_FONTSDIR_WIN": "C:/windows/Fonts",
            "W_PROGRAMS_WIN": "C:/Program Files",
            "W_PROGRAMS_X86_WIN": win64 ? "C:/Program Files (x86)" : "C:/Program Files",
            "W_COMMONFILES_WIN": "C:/Program Files/Common Files",
            "W_COMMONFILES_X86_WIN": win64
                ? "C:/Program Files (x86)/Common Files" : "C:/Program Files/Common Files",
            "W_SYSTEM32_DLLS_WIN": win64 ? "C:/windows/syswow64" : "C:/windows/system32",
            "W_SYSTEM64_DLLS_WIN64": win64 ? "C:/windows/system32" : "C:/does-not-exist-on-win32",
            "W_SYSTEM64_DLLS_WIN64:-does_not_exist": win64
                ? "C:/windows/system32" : "C:/does-not-exist",
        ]
        var expanded = path
        for (name, value) in variables {
            expanded = expanded.replacingOccurrences(of: "${\(name)}", with: value)
        }
        return expanded
    }
}
