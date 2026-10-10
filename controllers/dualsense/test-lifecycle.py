"""Offline: idle audio, silence tail, restart, and trigger/rumble coexistence."""

import json
import os
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(os.environ["DSB_TEST_BUILD"]).resolve()
wire = struct.Struct("<II16sIIdff64s")
token = bytes.fromhex("78" * 16)
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "status.json"
    p = subprocess.Popen(
        [str(root / "broker"), "--pcm", "--dry-run", "--token", token.hex(), "--status", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    address = ("127.0.0.1", json.loads(p.stdout.readline())["port"])
    seq = 0

    def pump(seconds, active):
        global seq
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            seq += 1
            samples = bytes([40, 216]) * 30 if active else bytes(60)
            report = bytes([30, 1, 0, 0]) + samples
            s.sendto(
                wire.pack(0x31425344, 3, token, 1234, seq, time.time() - 978307200, 0, 0, report),
                address,
            )
            time.sleep(0.01)
        return json.loads(path.read_text())

    try:
        state = pump(1.2, False)
        assert state["pcm"]["reports"] == 0, state
        pump(0.6, True)
        state = pump(1.3, False)
        count = state["pcm"]["reports"]
        assert count > 10, state
        state = pump(1.1, False)
        assert state["pcm"]["reports"] == count, state
        pump(0.6, True)
        state = pump(1.3, False)
        assert state["pcm"]["reports"] > count + 10, state
        assert not state["hidErrors"] and not state["hidStalled"], state
        p.terminate()
        p.communicate(timeout=3)
        assert p.returncode == 0
        assert json.loads(path.read_text())["state"] == "stopped"
        print("PASS: open silent audio produces no PCM; waveform starts/stops/restarts; clean exit")
    finally:
        if p.poll() is None:
            p.kill()
            p.wait()
        s.close()
