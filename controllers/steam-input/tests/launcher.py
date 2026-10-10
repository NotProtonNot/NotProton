"""Exercise launch gating with real shell expansion; no Steam or hardware needed."""

import os
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
with tempfile.TemporaryDirectory(prefix="notproton rumble ") as tmp:
    library = Path(tmp) / "controllers/steam-input/rumble.dylib"
    library.parent.mkdir(parents=True)
    library.touch()
    for verb, raw, setting, expected in [
        ("waitforexitandrun", "0", "", True),
        ("waitforexitandrun", "1", "", False),
        ("waitforexitandrun", "0", "0", False),
        ("run", "0", "", False),
        ("waitforexitandrun", "", "1", True),
    ]:
        env = dict(
            os.environ,
            np_support=tmp,
            verb=verb,
            NOTPROTON_RAW_CONTROLLERS=raw,
            NOTPROTON_STEAM_RUMBLE=setting,
        )
        for overlay in ("", "overlay"):
            command = (
                f"DYLD_INSERT_LIBRARIES={overlay}\n"
                + block
                + '\nprintf "%s|%s" "$NOTPROTON_RUMBLE_LIBRARY" "$DYLD_INSERT_LIBRARIES"'
            )
            result = subprocess.check_output(["/bin/sh", "-c", command], env=env, text=True)
            libraries = str(library) + (f":{overlay}" if overlay else "")
            assert result == (f"{library}|{libraries}" if expected else f"|{overlay}"), result
    library.unlink()
    env.update(verb="waitforexitandrun")
    assert subprocess.check_output(["/bin/sh", "-c", command], env=env, text=True) == "|overlay"
for name in ("NOTPROTON_RUMBLE_LIBRARY", "NOTPROTON_STEAM_RUMBLE", "NOTPROTON_RAW_CONTROLLERS"):
    assert f"--env {name}=" in source
assert "\\$NOTPROTON_RUMBLE_LIBRARY\\${DYLD_INSERT_LIBRARIES:+" in source
print(
    "steam-input: game/helper/raw/disabled/missing-library launch gating and environment forwarding passed"
)
