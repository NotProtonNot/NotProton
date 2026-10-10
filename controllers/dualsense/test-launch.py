"""Native launcher lifecycle, using a fake broker; never opens a controller."""

import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

build = Path(os.environ["DSB_TEST_BUILD"]).resolve()
with tempfile.TemporaryDirectory(prefix="notproton dualsense ") as tmp:
    root = Path(tmp)
    shutil.copy2(build / "launch", root / "launch")
    (root / "bridge.dylib").touch()
    broker = root / "broker"
    broker.write_text(
        "#!"
        + sys.executable
        + "\n"
        + """
import json, os, signal, sys, time
if '--probe' in sys.argv:
    usb = int(os.environ.get('TEST_USB', '0'))
    print(json.dumps(dict(bluetooth=0 if usb else 1, usb=usb, eligible=not usb)), flush=True)
    sys.exit()
if os.environ.get('TEST_BAD_READY'):
    print('{}', flush=True)
else:
    print(json.dumps(dict(ready=True, port=54565, pid=os.getpid())), flush=True)
if os.environ.get('TEST_REMOVE_ONCE'):
    from pathlib import Path
    marker = Path(__file__).with_name('removed-once')
    if not marker.exists():
        marker.touch()
        time.sleep(.2)
        sys.exit(10)
signal.signal(signal.SIGTERM, lambda *_: sys.exit())
while True: time.sleep(.02)
"""
    )
    broker.chmod(0o755)
    child = root / "child.py"
    child.write_text(
        """import json, os, sys, time
keys = ('DSB_RAW', 'DSB_PCM', 'DSB_LIBRARY', 'DSB_SESSION')
print(json.dumps({k: os.environ.get(k) for k in keys}), flush=True)
time.sleep(float(os.environ.get('TEST_CHILD_SLEEP', '0')))
sys.exit(int(os.environ.get('TEST_CHILD_EXIT', '0')))
"""
    )
    args = [str(root / "launch"), sys.executable, str(child)]
    clean = {k: v for k, v in os.environ.items() if not k.startswith("DSB_")}
    clean.update(STEAM_COMPAT_APP_ID="999999", STEAM_COMPAT_DATA_PATH=str(root / "prefix"))
    for route, raw, usb, disabled in [
        ("steam-input", "0", "0", "0"),
        ("original-usb", "1", "1", "0"),
        ("disabled", "1", "0", "1"),
        ("pcm", "1", "0", "0"),
    ]:
        env = dict(clean, NOTPROTON_RAW_CONTROLLERS=raw, TEST_USB=usb, DSB_DISABLED=disabled)
        result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=12)
        assert result.returncode == 0, (route, result.stderr)
        observed = json.loads(result.stdout.splitlines()[-1])
        assert observed["DSB_SESSION"] == "1"
        if route == "pcm":
            assert observed["DSB_RAW"] == "1:pcm" and observed["DSB_PCM"] == "1", observed
            assert observed["DSB_LIBRARY"] == str(root / "bridge.dylib")
        else:
            assert observed["DSB_RAW"] is None and observed["DSB_LIBRARY"] is None
            assert json.loads((root / "sessions/999999-status.json").read_text())["route"] == route
        assert not (root / "sessions/999999.json").exists()
        print("PASS native launcher:", route, flush=True)

    env = dict(clean, NOTPROTON_RAW_CONTROLLERS="1")
    result = subprocess.run(
        args, env=dict(env, TEST_CHILD_EXIT="23"), capture_output=True, timeout=12
    )
    assert result.returncode == 23
    result = subprocess.run(
        args, env=dict(env, TEST_BAD_READY="1"), capture_output=True, timeout=12
    )
    assert result.returncode == 70 and not (root / "sessions/999999.json").exists()
    print("PASS child exit status and failed initialization cleanup", flush=True)

    resumed = subprocess.Popen(
        args,
        env=dict(env, TEST_REMOVE_ONCE="1", TEST_CHILD_SLEEP="3"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    record = root / "sessions/999999.json"
    observed = []
    deadline = time.monotonic() + 10
    while resumed.poll() is None and time.monotonic() < deadline:
        if record.exists():
            doc = json.loads(record.read_text())
            observed.append(
                (doc["brokerPid"], doc["environment"]["DSB_PORT"], doc["environment"]["DSB_TOKEN"])
            )
        time.sleep(0.025)
    out, err = resumed.communicate(timeout=3)
    assert resumed.returncode == 0, err
    assert len({x[0] for x in observed}) == 2, "physical removal should restart broker once"
    assert len({x[1:] for x in observed}) == 1, "reconnect must retain port and session credentials"
    assert not record.exists()
    print("PASS bounded physical reconnect retains session and port", flush=True)

    owner = subprocess.Popen(
        args, env=dict(env, TEST_CHILD_SLEEP="30"), stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    record = root / "sessions/999999.json"
    try:
        deadline = time.monotonic() + 10
        while not record.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert record.exists()
        assert stat.S_IMODE(record.stat().st_mode) == 0o600
        assert stat.S_IMODE(record.parent.stat().st_mode) == 0o700
        info = json.loads(record.read_text())
        assert len(info["environment"]["DSB_TOKEN"]) == 32
        rival = subprocess.run(args, env=env, capture_output=True, timeout=10)
        assert rival.returncode == 70 and b"owns the wireless bridge" in rival.stderr
        assert record.exists(), "rival must not remove the owning session"
        owner.send_signal(signal.SIGTERM)
        owner.communicate(timeout=8)
        assert owner.returncode == 143, owner.returncode
        assert not record.exists()
        try:
            os.kill(info["brokerPid"], 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("broker survived launcher termination")
        print("PASS credentials, single owner, signal forwarding and broker cleanup", flush=True)
    finally:
        if owner.poll() is None:
            owner.kill()
            owner.communicate()
