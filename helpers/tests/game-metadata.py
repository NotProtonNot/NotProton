"""Validate identity, signing and hardlink isolation on a synthetic Wine loader."""

import os
import pathlib
import platform
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile


def signing_flags(path):
    result = subprocess.run(
        ["codesign", "-d", "--verbose=1", str(path)],
        capture_output=True, text=True, check=True,
    )
    match = re.search(r"flags=(0x[0-9a-f]+)", result.stderr)
    assert match, "codesign did not report signature flags"
    return int(match[1], 16)


def signing_entitlements(path):
    data = subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", str(path)])
    return plistlib.loads(data) if data else {}


def loaded_metadata(path):
    return plistlib.loads(subprocess.check_output(
        [str(path)], env=dict(os.environ, NP_METADATA_PROBE="1"),
    ))


tool = pathlib.Path(sys.argv[1]).resolve()
architecture = sys.argv[2] if len(sys.argv) > 2 else platform.machine()
with tempfile.TemporaryDirectory(prefix="np-game-metadata-") as folder:
    root = pathlib.Path(folder)
    old = {
        "CFBundleIdentifier": "com.codeweavers.CrossOver.wineloader",
        "CFBundleName": "Wine",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleDevelopmentRegion": "English",
        "CFBundleAllowMixedLocalizations": True,
        "LSUIElement": "1",
    }
    embedded = root / "embedded.plist"
    embedded.write_bytes(plistlib.dumps(old).ljust(1074, b" "))
    c = root / "fixture.c"
    c.write_text('''#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    if (getenv("NP_METADATA_PROBE")) {
        CFDictionaryRef info = CFBundleGetInfoDictionary(CFBundleGetMainBundle());
        CFDataRef data = CFPropertyListCreateData(NULL, info, kCFPropertyListXMLFormat_v1_0, 0, NULL);
        if (!data) return 1;
        fwrite(CFDataGetBytePtr(data), 1, CFDataGetLength(data), stdout);
        CFRelease(data);
        return 0;
    }
    return getenv("NP_INJECTION_PROBE") ? 0 : 42;
}
''')
    runner = root / "runner"
    subprocess.run(
        [
            "clang",
            "-arch", architecture,
            str(c),
            "-framework", "CoreFoundation",
            "-Wl,-sectcreate,__TEXT,__info_plist," + str(embedded),
            "-o",
            str(runner),
        ],
        check=True,
    )
    subprocess.run(["codesign", "-s", "-", str(runner)], check=True)
    wine = root / "Game.app/Contents/MacOS/wine"
    wine.parent.mkdir(parents=True)
    os.link(runner, wine)
    before = runner.read_bytes()
    info = wine.parent.parent / "Info.plist"
    app = {
        "CFBundleIdentifier": "com.notproton.launcher.999",
        "CFBundleName": "Example Game — Extended Edition",
        "CFBundleExecutable": "launcher",
        "NSMicrophoneUsageDescription": "This game would like to access your microphone.",
        "NSCameraUsageDescription": "This game would like to access your camera.",
        "NSLocalNetworkUsageDescription": "This game would like to access devices on your local network.",
    }
    info.write_bytes(plistlib.dumps(app))
    subprocess.run([str(tool), str(wine), str(info)], check=True)
    assert runner.read_bytes() == before, "shared runner inode was modified"
    assert runner.stat().st_ino != wine.stat().st_ino
    subprocess.run(["codesign", "--verify", "--strict", str(wine)], check=True)
    assert not signing_flags(wine) & 0x10000, "plain loader acquired hardened runtime"
    blob = wine.read_bytes()
    expected = dict(app, CFBundleExecutable="wine", LSUIElement="1", LSSupportsGameMode=True)
    actual = loaded_metadata(wine)
    for key, value in expected.items():
        assert actual.get(key) == value, (key, actual.get(key), value)
    subprocess.run([str(tool), str(wine), str(info)], check=True)
    assert wine.read_bytes() == blob, "second preparation is not idempotent"
    info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "unrelated.app", "CFBundleName": "Bad"}))
    assert subprocess.run([str(tool), str(wine), str(info)], capture_output=True).returncode != 0
    assert wine.read_bytes() == blob
    info.write_bytes(plistlib.dumps(app))

    for attempt in range(3):
        fresh = root / str(attempt) / "wine"
        fresh.parent.mkdir()
        os.link(runner, fresh)
        subprocess.run([str(tool), str(fresh), str(info)], check=True)
        assert fresh.read_bytes() == blob, "unchanged launcher must be reusable across preparations"

    injection = root / "injection.c"
    injection.write_text(
        '''#include <stdlib.h>
__attribute__((constructor)) static void load(void) {
    setenv("NP_INJECTION_PROBE", "1", 1);
}
'''
    )
    library = root / "injection.dylib"
    subprocess.run([
        "clang", "-arch", architecture, "-dynamiclib", str(injection), "-o", str(library),
    ], check=True)
    subprocess.run(["codesign", "-f", "-s", "-", str(library)], check=True)
    permissions = {
        "com.apple.security.cs.allow-dyld-environment-variables": True,
        "com.apple.security.cs.disable-library-validation": True,
    }
    entitlements = root / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps(permissions))
    for mode in ("plain", "entitled", "hardened", "unsigned"):
        folder = root / mode
        folder.mkdir()
        source = folder / "runner"
        target = folder / "wine"
        shutil.copy2(runner, source)
        has_entitlements = mode in ("entitled", "hardened")
        if has_entitlements:
            command = ["codesign", "-f", "-s", "-", "--entitlements", str(entitlements)]
            if mode == "hardened":
                command += ["--options", "runtime"]
            subprocess.run(command + [str(source)], check=True)
        elif mode == "unsigned":
            subprocess.run(["codesign", "--remove-signature", str(source)], check=True)
        original = source.read_bytes()
        os.link(source, target)
        subprocess.run([str(tool), str(target), str(info)], check=True)
        assert source.read_bytes() == original, mode + " runner was modified"
        subprocess.run(["codesign", "--verify", "--strict", str(target)], check=True)
        assert bool(signing_flags(target) & 0x10000) == (mode == "hardened"), mode
        assert signing_entitlements(target) == (permissions if has_entitlements else {})
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(library))
        env.pop("NP_INJECTION_PROBE", None)
        result = subprocess.run([str(target)], env=env)
        assert result.returncode == 0, mode + " loader did not load the injected library"
        prepared = target.read_bytes()
        subprocess.run([str(tool), str(target), str(info)], check=True)
        assert target.read_bytes() == prepared, mode + " preparation is not idempotent"
    command_offset = 32
    plist_section = None
    for _ in range(struct.unpack_from("<I", before, 16)[0]):
        command, size = struct.unpack_from("<II", before, command_offset)
        if command == 0x19:
            for index in range(struct.unpack_from("<I", before, command_offset + 64)[0]):
                section = command_offset + 72 + index * 80
                if before[section : section + 16].rstrip(b"\0") == b"__info_plist":
                    plist_section = section
        command_offset += size
    assert plist_section is not None

    def reject(label, data):
        wine.write_bytes(data)
        result = subprocess.run([str(tool), str(wine), str(info)], capture_output=True)
        assert result.returncode != 0, label
        assert wine.read_bytes() == data, "failed parse must not modify " + label

    reject("non Mach-O", b"not a Mach-O")
    for label, offset, value in (
        ("commands beyond file", 20, len(before) + 4096),
        ("command count mismatch", 16, struct.unpack_from("<I", before, 16)[0] + 1),
        ("short segment", 36, 8),
        ("section overlaps header", plist_section + 48, 8),
        ("section outside file", plist_section + 48, len(before) + 1),
    ):
        malformed = bytearray(before)
        struct.pack_into("<I", malformed, offset, value)
        reject(label, malformed)
    print(
        f"==> game metadata ({architecture}): runtime identity and permissions, signing modes, DYLD injection, "
        "hardlink isolation, deterministic staging, idempotency, invalid input rejection"
    )
