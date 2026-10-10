import json
import os
import socket
import struct
import subprocess
import time
import tempfile
from pathlib import Path

root = Path(os.environ["DSB_TEST_BUILD"]).resolve()
packet = struct.Struct("<II16sIIdff64s")
token = bytes.fromhex("12" * 16)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 0))
s.settimeout(1)
env = dict(
    os.environ,
    DSB_PORT=str(s.getsockname()[1]),
    DSB_TOKEN=token.hex(),
    DSB_RAW="1",
    DYLD_INSERT_LIBRARIES=str(root / "bridge.dylib"),
)
for arch in ("arm64", "x86_64"):
    subprocess.run(
        [
            "lipo",
            str(root / "audio-test"),
            "-thin",
            arch,
            "-output",
            str(root / ("audio-test-" + arch)),
        ],
        check=True,
    )
    for sample_format, mode in (
        [(fmt, "normal") for fmt in ("f32", "s8", "u8", "s16", "u16", "s32", "u32")]
        + [("u8", "fail"), ("u32", "fail")]
        + [("f32", mode) for mode in ("volume", "mute", "silence", "short", "external")]
    ):
        p = subprocess.run(
            [str(root / ("audio-test-" + arch)), sample_format, mode],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert p.returncode == 0, p.stderr + p.stdout
        levels = []
        while True:
            try:
                v = packet.unpack(s.recv(1024))
                assert v[0] == 0x31425344 and v[2] == token
                levels.append((v[6], v[7]))
            except socket.timeout:
                break
        silent = mode in ("fail", "mute", "silence", "short")
        active = (0.03125, 0.25) if mode == "volume" else (0.125, 0.5)
        expected = ((0, 0),) if silent else (active, (0, 0))
        assert len(levels) >= 5 and all(x in expected for x in levels), levels
        if not silent:
            assert active in levels, levels
        assert levels[-1] == (0, 0)
        print(arch, "PASS 4-channel routing, levels, stop:", p.stdout.strip())
with tempfile.TemporaryDirectory() as tmp:
    status = Path(tmp) / "status.json"
    p = subprocess.Popen(
        [
            str(root / "broker"),
            "--dry-run",
            "--token",
            token.hex(),
            "--status",
            str(status),
            "--seconds",
            "3.5",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    ready = json.loads(p.stdout.readline())
    addr = ("127.0.0.1", ready["port"])

    def send(seq, secret=token, ago=0):
        s.sendto(
            packet.pack(
                0x31425344, 1, secret, 1234, seq, time.time() - 978307200 - ago, 0.3, 0.4, bytes(64)
            ),
            addr,
        )

    send(1)
    send(2, b"0" * 16)
    send(3, ago=1)
    send(1)
    time.sleep(1.3)
    v = json.loads(status.read_text())
    assert v["accepted"] == 1 and v["dropped"] == 3, v
    assert v["left"] == v["right"] == 0 and v["peakLeft"] > 0.29, v
    # An invalid kind must not advance the replay counter for a real source.
    s.sendto(
        packet.pack(0x31425344, 99, token, 1234, 100000, time.time() - 978307200, 0, 0, bytes(64)),
        addr,
    )
    sequence = 2
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:
        # Updating a color is independent of an already active rumble command.
        rumble = bytes([2, 3, 0, 64, 128]) + bytes(59)
        color = bytearray(64)
        color[0] = 2
        color[2] = 4
        color[45:48] = bytes([20, 30, 40])
        for report in (rumble, color):
            s.sendto(
                packet.pack(
                    0x31425344, 2, token, 1234, sequence, time.time() - 978307200, 0, 0, report
                ),
                addr,
            )
            sequence += 1
        time.sleep(0.02)
    active = json.loads(status.read_text())
    assert active["left"] > 0.49 and active["right"] > 0.24, active
    assert active["dropped"] == 4, active
    out, err = p.communicate(timeout=5)
    assert p.returncode == 0, err
    print("PASS token/replay/stale rejection and silence watchdog")
