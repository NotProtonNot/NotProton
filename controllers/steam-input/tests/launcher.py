"""Exercise launch gating and the environment delivered to a Wine fixture."""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[3]
source = (root / "dylib/feats/compat_run.sh").read_text()
start = source.index('steam_rumble="$np_support/controllers/steam-input/rumble.dylib"')
end = source.index("export NOTPROTON_RUMBLE_LIBRARY", start) + len(
    "export NOTPROTON_RUMBLE_LIBRARY"
)
block = source[start:end]
start = source.index('cat > "$loader_macos/launcher" <<LAUNCHER\n')
end = source.index("\nLAUNCHER\n", start) + len("\nLAUNCHER\n")
launcher = source[start:end]
start = source.index('set -- --args "$shim_exe" "$@"')
end = source.index('\nlsregister=', start)
forwarding = source[start:end]

# Run the same shell fragments as compat_run without starting LaunchServices or Steam.
clean = {
    key: value for key, value in os.environ.items()
    if not key.startswith(("DSB_", "NOTPROTON_", "DYLD_", "STEAM_", "Steam"))
}
with tempfile.TemporaryDirectory(prefix="notproton rumble ") as tmp:
    library = Path(tmp) / "controllers/steam-input/rumble.dylib"
    library.parent.mkdir(parents=True)
    fixture = Path(tmp) / "fixture.c"
    fixture.write_text('''#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    const char *keys[] = {
        "NOTPROTON_RUMBLE_LIBRARY", "NOTPROTON_STEAM_RUMBLE",
        "NOTPROTON_RAW_CONTROLLERS", "DYLD_INSERT_LIBRARIES"
    };
    for (unsigned i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        const char *value = getenv(keys[i]);
        puts(value ? value : "");
    }
    for (int i = 1; i < argc; i++) puts(argv[i]);
    return 23;
}
''')
    wine = Path(tmp) / "wine"
    subprocess.run(["clang", str(fixture), "-o", str(wine)], check=True)
    stub = Path(tmp) / "stub.c"
    stub.write_text("void fixture(void) {}\n")
    subprocess.run(["clang", "-dynamiclib", str(stub), "-o", str(library)], check=True)
    overlay = Path(tmp) / "overlay.dylib"
    shutil.copy2(library, overlay)
    game_args = ["--test", "argument with spaces", "player's name"]
    for verb, raw, setting, expected in [
        ("waitforexitandrun", "0", "", True),
        ("waitforexitandrun", "1", "", False),
        ("waitforexitandrun", "0", "0", False),
        ("run", "0", "", False),
        ("waitforexitandrun", "", "1", True),
    ]:
        env = dict(
            clean,
            np_support=tmp,
            verb=verb,
            NOTPROTON_RAW_CONTROLLERS=raw,
            NOTPROTON_STEAM_RUMBLE=setting,
        )
        for renderer in ("", str(overlay)):
            command = (
                'DYLD_INSERT_LIBRARIES="$STEAM_DYLD_INSERT_LIBRARIES"\n'
                + block
                + '\nprintf "%s|%s" "$NOTPROTON_RUMBLE_LIBRARY" "$DYLD_INSERT_LIBRARIES"'
            )
            env.update(STEAM_DYLD_INSERT_LIBRARIES=renderer)
            result = subprocess.check_output(["/bin/sh", "-c", command], env=env, text=True)
            libraries = str(library) + (f":{renderer}" if renderer else "")
            assert result == (f"{library}|{libraries}" if expected else f"|{renderer}"), result
            if renderer:
                continue

            # The generated wrapper runs a fixture with no desktop overlay attached.
            env.update(
                loader_macos=tmp, loader_root=tmp, WINELOADER=str(wine),
                game_host="", shim_exe="game.exe", game_cwd=tmp,
            )
            command = block + "\n" + launcher + forwarding + '\nprintf "%s\\0" "$@"'
            result = subprocess.check_output(
                ["/bin/sh", "-c", command, "launcher-test", *game_args], env=env,
            )
            arguments = result.decode().split("\0")[:-1]
            child_env = dict(clean)
            while arguments and arguments[0] == "--env":
                key, value = arguments[1].split("=", 1)
                child_env[key] = value
                arguments = arguments[2:]
            assert arguments == ["--args", "game.exe", *game_args], arguments
            result = subprocess.run(
                ["/bin/sh", str(Path(tmp) / "launcher"), *arguments[1:]],
                env=child_env, capture_output=True, text=True, timeout=5,
            )
            assert result.returncode == 23, result.stderr
            observed = (Path(tmp) / "notproton-wine.log").read_text().splitlines()
            assert observed == [
                str(library) if expected else "",
                "1" if expected else setting,
                raw,
                libraries if expected else renderer,
                "game.exe", *game_args,
            ], (verb, raw, setting, renderer, observed)
            print(f"  ok    rumble launcher: {verb}, raw={raw!r}, setting={setting!r}")
    library.unlink()
    command = block + '\nprintf "%s" "$NOTPROTON_RUMBLE_LIBRARY"'
    assert subprocess.check_output(["/bin/sh", "-c", command], env=env, text=True) == ""
print("==> rumble launcher: launch gating, environment, arguments and exit status hold")
