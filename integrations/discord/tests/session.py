"""Exercise the run-script integration with a helper that records its environment."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[3]
source = (root / "dylib/feats/compat_run.sh").read_text()
start = source.index('discord_session="$np_support/integrations/discord/session.sh"')
end = source.index('\n# Fixes CrossOver window focus issues', start)
launch = source[start:end]
clean = {k: v for k, v in os.environ.items() if not k.startswith(("NOTPROTON_", "DYLD_", "STEAM_"))}
with tempfile.TemporaryDirectory(prefix="np discord session ") as directory:
    tmp = Path(directory)
    installed = tmp / "integrations/discord"
    installed.mkdir(parents=True)
    (installed / "session.sh").write_bytes((root / "integrations/discord/session.sh").read_bytes())
    (installed / "notproton-discord.exe").touch()
    host = installed / "host"
    host.write_text(f'''#!{sys.executable}
import json
import os
import signal
import sys
import time
from pathlib import Path
Path(os.environ["FIXTURE_REPORT"]).write_text(json.dumps({{"argv": sys.argv[1:], "env": dict(os.environ), "pid": os.getpid()}}))
if os.environ.get("FIXTURE_MODE") == "fail":
    sys.exit(1)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
if os.environ.get("FIXTURE_MODE") == "slow":
    time.sleep(4)
if os.environ.get("FIXTURE_MODE") != "hang":
    print("ready", flush=True)
while True:
    time.sleep(1)
''')
    host.chmod(0o755)
    report = tmp / "report.json"
    env = dict(clean, np_support=directory, WINELOADER="/wine path/wine", log=str(tmp / "run.log"),
               TMPDIR=str(tmp), FIXTURE_REPORT=str(report),
               STEAM_DYLD_INSERT_LIBRARIES="/unused-overlay.dylib", NOTPROTON_GAME_LOADER="/game-loader")

    def check_cleanup():
        assert not list(tmp.glob("notproton-discord.*")), "session directory was leaked"
        if report.exists():
            observed = json.loads(report.read_text())
            assert observed["argv"] == [env["WINELOADER"], str(installed / "notproton-discord.exe")]
            assert not any(k in observed["env"] for k in (
                "DYLD_INSERT_LIBRARIES", "STEAM_DYLD_INSERT_LIBRARIES", "NOTPROTON_GAME_LOADER"))
            try:
                os.kill(observed["pid"], 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError("helper survived the game session")

    for mode in ("default", "disabled", "invalid", "ready", "slow", "fail", "hang"):
        report.unlink(missing_ok=True)
        Path(env["log"]).unlink(missing_ok=True)
        settings = dict(env, FIXTURE_MODE=mode)
        if mode != "default":
            settings["NOTPROTON_DISCORD_BRIDGE"] = {"disabled": "0", "invalid": "true"}.get(mode, "1")
        enabled = mode in ("ready", "slow", "fail", "hang")
        result = subprocess.run(
            ["/bin/sh", "-ec", launch + '\nexit 23\n'],
            env=settings, timeout=18, capture_output=True, text=True,
        )
        assert result.returncode == 23, result.stderr
        assert report.exists() == enabled
        log = Path(env["log"]).read_text() if Path(env["log"]).exists() else ""
        assert ("Discord bridge ready" in log) == (mode in ("ready", "slow")), log
        check_cleanup()
        print(f"  ok    Discord session: {mode}, exit status preserved and helper stopped")

    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        report.unlink(missing_ok=True)
        process = subprocess.Popen(
            ["/bin/sh", "-ec", launch + '\nexit 23\n'],
            env=dict(env, NOTPROTON_DISCORD_BRIDGE="1", FIXTURE_MODE="hang"),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 5
            while not report.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            assert report.exists(), "session did not start its helper"
            process.send_signal(signum)
            _, errors = process.communicate(timeout=8)
            assert process.returncode == 128 + signum, errors.decode()
            check_cleanup()
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
        print(f"  ok    Discord session: {signum.name} during startup stops the helper")

    host.unlink()
    report.unlink(missing_ok=True)
    result = subprocess.run(["/bin/sh", "-ec", launch + '\nexit 23\n'],
                            env=dict(env, NOTPROTON_DISCORD_BRIDGE="1"),
                            timeout=5, capture_output=True, text=True)
    assert result.returncode == 23 and not report.exists(), result.stderr
    check_cleanup()
    print("  ok    Discord session: unavailable components do not prevent game launch")
print("==> Discord session: opt-in, startup, failure and signal cleanup passed")
