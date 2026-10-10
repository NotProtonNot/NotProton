"""Validate identity, signing and hardlink isolation on a synthetic Wine loader."""

import os, pathlib, plistlib, struct, subprocess, sys, tempfile

tool = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="np-game-metadata-") as folder:
    root = pathlib.Path(folder)
    old = {
        "CFBundleIdentifier": "com.codeweavers.CrossOver.wineloader",
        "CFBundleName": "Wine",
        "CFBundleVersion": "1",
    }
    embedded = root / "embedded.plist"
    embedded.write_bytes(plistlib.dumps(old).ljust(4096, b" "))
    c = root / "fixture.c"
    c.write_text("int main(void) { return 0; }\n")
    runner = root / "runner"
    subprocess.run(
        [
            "clang",
            str(c),
            "-Wl,-sectcreate,__TEXT,__info_plist," + str(embedded),
            "-o",
            str(runner),
        ],
        check=True,
    )
    subprocess.run(["codesign", "-s", "-", str(runner)], check=True)
    wine = root / "wine"
    os.link(runner, wine)
    before = runner.read_bytes()
    info = root / "Info.plist"
    info.write_bytes(
        plistlib.dumps(
            {"CFBundleIdentifier": "com.notproton.launcher.999", "CFBundleName": "Example Game"}
        )
    )
    subprocess.run([str(tool), str(wine), str(info)], check=True)
    assert runner.read_bytes() == before, "shared runner inode was modified"
    assert runner.stat().st_ino != wine.stat().st_ino
    subprocess.run(["codesign", "--verify", "--strict", str(wine)], check=True)
    blob = wine.read_bytes()
    assert b"com.notproton.launcher.999" in blob and b"LSSupportsGameMode" in blob
    subprocess.run([str(tool), str(wine), str(info)], check=True)
    assert wine.read_bytes() == blob, "second preparation is not idempotent"
    info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "unrelated.app", "CFBundleName": "Bad"}))
    assert subprocess.run([str(tool), str(wine), str(info)], capture_output=True).returncode != 0
    assert wine.read_bytes() == blob
    info.write_bytes(
        plistlib.dumps(
            {"CFBundleIdentifier": "com.notproton.launcher.999", "CFBundleName": "Example Game"}
        )
    )
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
        "PASS metadata: scoped identity, valid signature, unchanged runner, idempotency, invalid input rejection"
    )
