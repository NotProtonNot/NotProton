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
token = bytes.fromhex("34" * 16)
curve = bytes([0x21, 0xFE, 3, 0, 0x90, 0x44, 0x1A, 0, 0, 0, 0])
off = bytes([5]) + bytes(10)
for pcm, grace in ((False, 75), (False, 0), (True, 0)):
    with tempfile.TemporaryDirectory() as tmp:
        status = Path(tmp) / "state.json"
        p = subprocess.Popen(
            [
                str(root / "broker"),
                "--dry-run",
                "--trigger-reset-grace-ms",
                str(grace),
                "--token",
                token.hex(),
                "--status",
                str(status),
                "--seconds",
                "5",
            ]
            + (["--pcm"] if pcm else []),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        addr = ("127.0.0.1", json.loads(p.stdout.readline())["port"])
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        seq = 0

        def send(effect):
            global seq
            seq += 1
            report = bytearray(64)
            report[0] = 2
            report[1] = 4
            report[11:22] = effect
            sock.sendto(
                wire.pack(0x31425344, 2, token, 1234, seq, time.time() - 978307200, 0, 0, report),
                addr,
            )

        end = time.monotonic() + 1.2
        while time.monotonic() < end:
            send(curve)
            send(off)
            time.sleep(0.01)
        d = json.loads(status.read_text())
        t = d["triggers"]
        if grace:
            assert bytes(t["r2"]) == curve and t["suppressedR2Resets"] > 50, t
            assert len(t["sentHistory"]) == 1 and bytes(t["sentHistory"][0]["r2"]) == curve, t
        else:
            assert t["suppressedR2Resets"] == 0, t
        stopped = time.time()
        time.sleep(1.1)
        t = json.loads(status.read_text())["triggers"]
        assert bytes(t["r2"]) == off, t
        if grace:
            assert (
                len(t["sentHistory"]) == 2 and 0 <= t["sentHistory"][-1]["at"] - stopped < 0.12
            ), t
        send(curve)
        time.sleep(0.06)
        p.terminate()
        _, err = p.communicate(timeout=3)
        assert p.returncode == 0, err
        final = json.loads(status.read_text())
        assert final["state"] == "stopped", final
        assert bytes(final["triggers"]["sentHistory"][-1]["r2"]) == off, final
        print(
            "PASS pcm="
            + str(pcm)
            + " grace="
            + str(grace)
            + ": exact curve preserved; reset bursts handled; genuine release delivered; no change to default behavior"
        )
