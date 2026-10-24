// The package list the Winetricks window shows, parsed out of the winetricks
// script itself so it always matches the release PrefixTools pins.

import Foundation

struct WinetricksVerb: Identifiable, Sendable, Equatable {
    let name: String
    let category: String
    let title: String
    let publisher: String
    let year: String
    let media: String
    let conflicts: [String]
    // installed_file1 and installed_exe1, winetricks-style c: paths. A single
    // entry may name alternatives separated by |.
    let installedFiles: [String]
    // The verb calls w_package_unsupported_win64, which exits 32 on any prefix
    // but a 32-bit one.
    var win32Only = false
    // The verb only sets wined3d's Direct3D keys. Games on D3DMetal, DXMT or
    // DXVK never read them.
    var wined3dOnly = false

    var id: String { name }
    var isManualDownload: Bool { media == "manual_download" }
}

enum WinetricksCatalog {

    // The menus winetricks itself offers for a shared prefix. ProtonTricks
    // users only ever see these three.
    static let categories = ["dlls", "fonts", "settings"]

    // Settings with no place in the list. Families are matched by the part
    // before the =, so graphics covers graphics=x11, graphics=mac and so on.
    private static let hiddenFamilies: Set<String> = [
        // Driver choices for Linux. The Mac driver and CoreAudio are the only
        // ones that work, and they are already the default.
        "graphics",
        // X11 Driver keys, which the Mac driver never reads.
        "windowmanagerdecorated", "windowmanagermanaged", "usetakefocus", "useegl",
        "grabfullscreen",
        // compat_run.sh sets AeDebug Auto=0 and hides the crash dialog on
        // every launch, so these are either already done or undone.
        "autostart_winedbg", "nocrashdialog",
        // Read their value from WINEPATH and MIDI_DEVICE, which nothing in the
        // window can set.
        "set_userpath", "set_mididevice",
        // Winetricks' own test verbs.
        "bad", "good",
        // Wine starts explorer /desktop for it, but the Mac driver opens no
        // desktop window and the game's windows stay as they were.
        "vd",
        // Both write "disable" to .update-timestamp, which PrefixTools.lastBuild
        // reads to name the prefix's build, and sandbox removes the z: drive
        // games outside the prefix run from.
        "isolate_home", "sandbox",
    ]
    private static let hiddenVerbs: Set<String> = ["sound=alsa", "sound=oss", "sound=pulse"]

    static func isOffered(_ verb: WinetricksVerb, prefixIs32Bit: Bool = false) -> Bool {
        guard categories.contains(verb.category) else { return false }
        if verb.win32Only && !prefixIs32Bit { return false }
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
                // Anything else ends the block: a blank line, a comment, the
                // w_try that follows the metadata.
                close()
            }
        }
        close()
        let win32Only = loaders(in: script) { $0 == "w_package_unsupported_win64" }
        let wined3dOnly = loaders(in: script) {
            $0.hasPrefix("winetricks_set_wined3d_var ") || $0 == #"[HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]"#
        }
        for index in found.indices {
            let family = String(found[index].name.prefix { $0 != "=" })
            found[index].win32Only = win32Only.contains(family)
            found[index].wined3dOnly = wined3dOnly.contains(family)
        }
        return found
    }

    // Names of the load_ functions with a line in their body that matches. A
    // verb like csmt=off runs load_csmt, so the family name is what matches.
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

    // A line like `    title="MS Arial, Courier, Times fonts" \`, the trailing
    // backslash only when another field follows.
    private static func field(of line: Substring) -> (key: String, value: String)? {
        guard let equals = line.range(of: "=\"") else { return nil }
        let key = line[..<equals.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }
        let rest = line[equals.upperBound...]
        guard let closing = rest.lastIndex(of: "\"") else { return nil }
        let value = String(rest[..<closing])
        let after = rest[rest.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after == "\\" else { return nil }
        return (key, value)
    }

    private static func verb(
        name: String, category: String, fields: [String: String]
    ) -> WinetricksVerb {
        // Only installed_file1 and installed_exe1 are probed; file1..file6 are
        // archive names for winetricks' download cache, not installed markers.
        let probed = [fields["installed_file1"], fields["installed_exe1"]]
            .compactMap { $0 }
            .flatMap { $0.split(separator: "|").map(String.init) }
        return WinetricksVerb(
            name: name,
            category: category,
            title: fields["title"] ?? "",
            publisher: fields["publisher"] ?? "",
            year: fields["year"] ?? "",
            media: fields["media"] ?? "",
            conflicts: (fields["conflicts"] ?? "")
                .split(whereSeparator: \.isWhitespace).map(String.init),
            installedFiles: probed
        )
    }

    // The same test winetricks_is_installed makes: the verb must have been run,
    // which winetricks records in the prefix's own winetricks.log, and when it
    // names a file to look for, that file must exist and not be one of the
    // placeholder DLLs Wine writes during prefix setup.
    static func installedVerbs(among verbs: [WinetricksVerb], in prefix: WinePrefix) -> Set<String> {
        let log = prefix.pfx.appending(path: "winetricks.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        let ran = Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
        var installed: Set<String> = []
        for verb in verbs where ran.contains(verb.name) && !verb.installedFiles.isEmpty {
            if verb.installedFiles.contains(where: { isRealFile($0, in: prefix) }) {
                installed.insert(verb.name)
            }
        }
        return installed
    }

    private static func isRealFile(_ path: String, in prefix: WinePrefix) -> Bool {
        // Paths winetricks cannot express as a drive_c path, such as a d: or
        // z: path, are trusted on the strength of the log alone.
        guard let url = driveCFile(path, in: prefix) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url),
            let head = try? handle.read(upToCount: 128 * 1024)
        else { return false }
        try? handle.close()
        return !String(decoding: head, as: UTF8.self).contains("Wine placeholder DLL")
    }

    // Resolves a winetricks installed-file path against the prefix: expand the
    // winetricks path variables, then map the c: drive onto drive_c. Raw
    // script text also carries backslashes doubled for the shell, so both
    // spellings are normalized here.
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

    // The drive_c locations of the winetricks path variables that installed
    // files are named with. winetricks keeps a 32-bit prefix in the win32
    // column and everything else in win64.
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
        ]
        var expanded = path
        for (name, value) in variables {
            expanded = expanded.replacingOccurrences(of: "${\(name)}", with: value)
        }
        return expanded
    }
}
