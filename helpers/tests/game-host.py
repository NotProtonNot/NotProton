"""Game child identity must not spread to Wine/Ubisoft helper processes."""

from pathlib import Path
import os, subprocess, tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="dsb-host-") as tmp:
    t = Path(tmp)
    game = t / "Games" / "Example Game"
    game.mkdir(parents=True)
    sibling = t / "Games" / "Example Game Tools"
    sibling.mkdir()
    prefix = t / "prefix"
    (prefix / "dosdevices").mkdir(parents=True)
    (prefix / "drive_c/windows/system32").mkdir(parents=True)
    (prefix / "drive_c/Program Files/Ubisoft").mkdir(parents=True)
    (prefix / "dosdevices/s:").symlink_to(t / "Games", target_is_directory=True)
    (prefix / "dosdevices/c:").symlink_to("../drive_c", target_is_directory=True)
    (prefix / "dosdevices/z:").symlink_to("/", target_is_directory=True)
    loader = t / "Application Support/notproton/launchers/999/Game.app/Contents/MacOS/wine"
    loader.parent.mkdir(parents=True)
    loader.write_text("")
    loader.chmod(0o755)
    exe = game / "Binaries/Win64/game.exe"
    exe.parent.mkdir(parents=True)
    exe.touch()
    service = prefix / "drive_c/windows/system32/winedevice.exe"
    service.touch()
    launcher = prefix / "drive_c/Program Files/Ubisoft/upc.exe"
    launcher.touch()
    other = sibling / "tool.exe"
    other.touch()
    (game / "escape.exe").symlink_to(service)
    (t / "Steam").symlink_to(game, target_is_directory=True)
    probe = t / "probe.c"
    probe.write_text(
        '#define GAME_HOST_TEST\n#include "'
        + str(root / "game-host.c")
        + '"\nint main(int argc,char **argv){char *child[]={argv[1],argc>2?argv[2]:NULL,argc>3?argv[3]:NULL,NULL};puts(game_loader_for(argv[1],child)?"game":"original");}\n'
    )
    subprocess.run(
        [
            "clang",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Wno-unused-function",
            str(probe),
            "-o",
            str(t / "probe"),
        ],
        check=True,
    )
    env = dict(
        os.environ,
        NOTPROTON_GAME_LOADER=str(loader),
        WINEPREFIX=str(prefix),
        WINELOADERNOEXEC="1",
        STEAM_COMPAT_INSTALL_PATH=str(t / "Steam"),
    )
    temp_loader = os.environ["TMPDIR"].rstrip("/") + "/winetemp-123/game.exe"
    cases = [
        ("S:\\Example Game\\Binaries\\Win64\\game.exe", True),
        ("\\??\\s:\\Example Game\\Binaries\\Win64\\game.exe", True),
        ("\\\\?\\S:\\Example Game\\Binaries\\Win64\\game.exe", True),
        (str(exe), True),
        ("Binaries/Win64/game.exe", True),
        ("C:\\windows\\system32\\winedevice.exe", False),
        ("C:\\Program Files\\Ubisoft\\upc.exe", False),
        (str(other), False),
        (str(game / "escape.exe"), False),
        ("S:\\Example Game\\missing.exe", False),
        ("game.exe", False),
        ("", False),
    ]
    for argument, expected in cases:
        got = subprocess.check_output(
            [str(t / "probe"), temp_loader, argument], env=env, cwd=game, text=True
        ).strip()
        assert got == ("game" if expected else "original"), (argument, got)
    for args in (
        [str(t / "probe"), "/tmp/unrelated-wine", str(exe)],
        [str(t / "probe"), temp_loader, str(launcher), str(exe)],
        [str(t / "probe"), temp_loader],
    ):
        assert subprocess.check_output(args, env=env, text=True).strip() == "original"
    # A similarly named temporary directory or executable is not a Wine re-exec.
    temp_root = os.environ["TMPDIR"].rstrip("/")
    for candidate in (
        temp_root + "-other/winetemp-123/game.exe",
        temp_root + "/unrelated/winetemp-123/game.exe",
        temp_root + "//unrelated/winetemp-123/game.exe",
    ):
        assert (
            subprocess.check_output(
                [str(t / "probe"), candidate, str(exe)], env=env, text=True
            ).strip()
            == "original"
        )
    # CrossOver appends /winetemp to confstr's already slash-terminated directory.
    for separators in ("/", "//", "///"):
        candidate = temp_root + separators + "winetemp-123/game.exe"
        for temporary_root in (temp_root, temp_root + "/"):
            assert (
                subprocess.check_output(
                    [str(t / "probe"), candidate, str(exe)],
                    env=dict(env, TMPDIR=temporary_root),
                    text=True,
                ).strip()
                == "game"
            ), (candidate, temporary_root)
    other_loader = loader.with_name("wine-other")
    other_loader.touch()
    other_loader.chmod(0o755)
    assert (
        subprocess.check_output(
            [str(t / "probe"), temp_loader, str(exe)],
            env=dict(env, NOTPROTON_GAME_LOADER=str(other_loader)),
            text=True,
        ).strip()
        == "original"
    )
    print(
        "PASS: only actual game executables retain game identity; services, launcher, escapes and argument-only matches excluded"
    )
