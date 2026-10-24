import Foundation
import Testing

@testable import NotProtonApp

@Suite("WinetricksCatalog")
struct WinetricksCatalogTests {

    // A slice of the real script's shapes: backslash-continued headers, shell
    // path variables, | alternatives, a verb name with =, doubled backslashes.
    static let script = #"""
        w_metadata vcrun2022 dlls \
            title="Visual C++ 2015-2022 libraries (msvcp140.dll)" \
            publisher="Microsoft" \
            year="2022" \
            media="download" \
            conflicts="vcrun2015 vcrun2019" \
            installed_file1="c:/windows/system32/msvcp140.dll"

        w_metadata d3dx9 dlls \
            title="d3dx9_43.dll and friends" \
            publisher="Microsoft" \
            year="2011" \
            media="download" \
            installed_file1="${W_SYSTEM32_DLLS_WIN}/d3dx9_43.dll|${W_SYSTEM32_DLLS_WIN}/d3dx10_43.dll"

        w_metadata atmlib dlls \
            title="Adobe Type Manager" \
            publisher="Adobe" \
            year="2012" \
            media="manual_download" \
            installed_file1="${W_PROGRAMS_X86_WIN}/atmlib.dll"

        w_metadata 7zip apps \
            title="7-Zip" \
            publisher="Igor Pavlov" \
            year="2024" \
            media="download" \
            installed_exe1="C:\\Program Files\\7-Zip\\7zFM.exe"

        w_metadata corefonts fonts \
            title="MS Arial, Courier, Times fonts" \
            publisher="Microsoft" \
            year="2008" \
            media="download" \
            installed_file1="${W_FONTSDIR_WIN}/Arial.ttf"

        w_metadata csmt=on settings \
            title="Enable Command Stream Multithreading (default)"

        # a comment is not metadata
        load_vcrun2022()
        {
            w_try "$WINE" VC_redist.x64.exe /q
        }
        """#

    private func verbs() -> [WinetricksVerb] {
        WinetricksCatalog.verbs(in: Self.script)
    }

    @Test("The w_metadata blocks are read, junk between them is not")
    func parsesBlocks() {
        let found = verbs()
        #expect(found.map(\.name) == [
            "vcrun2022", "d3dx9", "atmlib", "7zip", "corefonts", "csmt=on"
        ])
        #expect(found.map(\.category) == ["dlls", "dlls", "dlls", "apps", "fonts", "settings"])
    }

    @Test("Fields come out with quotes stripped and lists split")
    func parsesFields() {
        let vcrun = verbs()[0]
        #expect(vcrun.title == "Visual C++ 2015-2022 libraries (msvcp140.dll)")
        #expect(vcrun.publisher == "Microsoft")
        #expect(vcrun.year == "2022")
        #expect(vcrun.media == "download")
        #expect(vcrun.conflicts == ["vcrun2015", "vcrun2019"])
        #expect(vcrun.installedFiles == ["c:/windows/system32/msvcp140.dll"])
        #expect(!vcrun.isManualDownload)

        let atmlib = verbs()[2]
        #expect(atmlib.isManualDownload)

        let d3dx9 = verbs()[1]
        #expect(d3dx9.installedFiles.count == 2)

        let csmt = verbs()[5]
        #expect(csmt.installedFiles.isEmpty)
        #expect(csmt.title == "Enable Command Stream Multithreading (default)")
    }

    @Test("Winetricks path variables and doubled backslashes resolve under drive_c")
    func resolvesPaths() throws {
        let prefix = try prefixWithLog(ran: [])
        // The prefix has no ntdll to read the arch from, so win64 is assumed.
        #expect(WinetricksCatalog.driveCFile(
            "c:/windows/system32/msvcp140.dll", in: prefix)?
            .standardizedFileURL.path(percentEncoded: false)
            .hasSuffix("drive_c/windows/system32/msvcp140.dll") == true)
        #expect(WinetricksCatalog.driveCFile(
            "C:\\Program Files\\7-Zip\\7zFM.exe", in: prefix)?
            .standardizedFileURL.path(percentEncoded: false)
            .hasSuffix("drive_c/Program Files/7-Zip/7zFM.exe") == true)
        #expect(WinetricksCatalog.driveCFile(
            "${W_SYSTEM32_DLLS_WIN}/d3dx9_43.dll", in: prefix)?
            .standardizedFileURL.path(percentEncoded: false)
            .hasSuffix("drive_c/windows/syswow64/d3dx9_43.dll") == true)
        #expect(WinetricksCatalog.driveCFile(
            "${W_PROGRAMS_X86_WIN}/atmlib.dll", in: prefix)?
            .standardizedFileURL.path(percentEncoded: false)
            .hasSuffix("drive_c/Program Files (x86)/atmlib.dll") == true)

        // A drive the launcher never maps, and a file path the prefix cannot
        // know, do not resolve.
        #expect(WinetricksCatalog.driveCFile("d:/data/setup.exe", in: prefix) == nil)
        #expect(WinetricksCatalog.driveCFile("/tmp/thing.exe", in: prefix) == nil)
    }

    @Test("Installed means the verb ran and its file is present and real")
    func installedNeedsLogAndFile() throws {
        let prefix = try prefixWithLog(ran: ["vcrun2022", "d3dx9", "atmlib", "csmt=on"])
        let found = verbs()

        func make(_ path: String, _ bytes: String) throws {
            let url = prefix.pfx.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes.utf8).write(to: url)
        }
        try make("drive_c/windows/system32/msvcp140.dll", "MZ real dll")
        try make("drive_c/windows/syswow64/d3dx9_43.dll", "MZ real dll")
        // atmlib's file is a Wine placeholder, so it does not count.
        try make("drive_c/Program Files (x86)/atmlib.dll", "Wine placeholder DLL")

        let installed = WinetricksCatalog.installedVerbs(among: found, in: prefix)
        #expect(installed.contains("vcrun2022"))
        // Only one of the | alternatives needs to exist.
        #expect(installed.contains("d3dx9"))
        #expect(!installed.contains("atmlib"))
        // Settings verbs name no file, so they are never installed, the same
        // verdict winetricks_is_installed returns.
        #expect(!installed.contains("csmt=on"))
        // Verbs that never ran are not installed even with the file present.
        #expect(!installed.contains("corefonts"))
    }

    @Test("Linux-only, overridden and prefix-breaking settings are left out of the list")
    func hidesUselessSettings() {
        func offered(_ name: String, _ category: String = "settings") -> Bool {
            WinetricksCatalog.isOffered(WinetricksVerb(
                name: name, category: category, title: "", publisher: "", year: "",
                media: "", conflicts: [], installedFiles: []))
        }
        for name in ["graphics=x11", "graphics=mac", "sound=alsa", "sound=pulse", "sound=oss",
                     "usetakefocus=y", "grabfullscreen=y", "nocrashdialog",
                     "autostart_winedbg=enabled", "isolate_home", "sandbox", "bad", "good",
                     "set_userpath", "set_mididevice", "vd=1024x768", "vd=off"] {
            #expect(!offered(name), "\(name) should be hidden")
        }
        for name in ["win10", "fontsmooth=rgb", "mackeyremap=both", "sound=coreaudio",
                     "sound=disabled", "renderer=gl", "csmt=off"] {
            #expect(offered(name), "\(name) should be listed")
        }
        // Only the three menus winetricks shows for a shared prefix.
        #expect(offered("vcrun2022", "dlls"))
        #expect(offered("corefonts", "fonts"))
        #expect(!offered("7zip", "apps"))
        #expect(!offered("3dmark2000", "benchmarks"))
    }

    @Test("Verbs that refuse a 64-bit prefix are hidden unless the prefix is 32-bit")
    func hidesWin32Only() {
        let script = """
            w_metadata win98 settings \\
                title="Set Windows version to Windows 98"
            load_win98()
            {
                w_package_unsupported_win64
                w_set_winver win98
            }

            w_metadata fontsmooth=rgb settings \\
                title="Enable subpixel font smoothing for LCD (RGB)"
            load_fontsmooth()
            {
                arg="$1"
            }

            w_metadata dotnet11 dlls \\
                title="MS .NET 1.1" \\
                media="download"
            load_dotnet11()
            {
                w_package_unsupported_win64
                w_call remove_mono internal
            }
            """
        let found = WinetricksCatalog.verbs(in: script)
        #expect(found.filter(\.win32Only).map(\.name) == ["win98", "dotnet11"])
        #expect(found.filter { WinetricksCatalog.isOffered($0) }.map(\.name) == ["fontsmooth=rgb"])
        #expect(found.filter { WinetricksCatalog.isOffered($0, prefixIs32Bit: true) }.count == 3)
    }

    @Test("Settings that only set wined3d's Direct3D keys are marked")
    func marksWined3dOnly() {
        let script = #"""
            w_metadata renderer=vulkan settings \
                title="Set renderer to Vulkan"
            load_renderer()
            {
                winetricks_set_wined3d_var renderer "$1"
            }

            w_metadata csmt=off settings \
                title="Disable Command Stream Multithreading"
            load_csmt()
            {
                cat > "${W_TMP}"/set-csmt.reg <<_EOF_
            REGEDIT4

            [HKEY_CURRENT_USER\\Software\\Wine\\Direct3D]
            "csmt"=dword:0
            _EOF_
            }

            w_metadata fontsmooth=rgb settings \
                title="Enable subpixel font smoothing for LCD (RGB)"
            load_fontsmooth()
            {
                cat > "${W_TMP}"/fontsmooth.reg <<_EOF_
            [HKEY_CURRENT_USER\\Control Panel\\Desktop]
            _EOF_
            }
            """#
        let found = WinetricksCatalog.verbs(in: script)
        #expect(found.filter(\.wined3dOnly).map(\.name) == ["renderer=vulkan", "csmt=off"])
    }

    @Test("Year ranges get an en dash and placeholders are dropped")
    func cleansYears() {
        #expect(WinetricksCatalog.displayYear("2022") == "2022")
        #expect(WinetricksCatalog.displayYear("1995-2009") == "1995\u{2013}2009")
        #expect(WinetricksCatalog.displayYear("FIXME") == "")
        #expect(WinetricksCatalog.displayYear("") == "")
    }

    @Test("A missing log means nothing is installed")
    func noLogInstallsNothing() throws {
        let dir = try scratchDirectory("winetricks-nolog")
        let prefix = WinePrefix(
            appID: "2075800", name: "Game", library: SteamLibrary(root: dir), lastUsed: nil)
        try FileManager.default.createDirectory(at: prefix.pfx, withIntermediateDirectories: true)
        #expect(WinetricksCatalog.installedVerbs(among: verbs(), in: prefix).isEmpty)
    }

    private func prefixWithLog(ran: [String]) throws -> WinePrefix {
        let dir = try scratchDirectory("winetricks-installed")
        let prefix = WinePrefix(
            appID: "2075800", name: "Game", library: SteamLibrary(root: dir), lastUsed: nil)
        try FileManager.default.createDirectory(
            at: prefix.pfx, withIntermediateDirectories: true)
        try ran.joined(separator: "\n").write(
            to: prefix.pfx.appending(path: "winetricks.log"), atomically: true, encoding: .utf8)
        return prefix
    }
}
