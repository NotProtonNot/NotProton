"""Offline routing/security checks; --hardware is a bounded silent soak."""

import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

root = Path(os.environ["DSB_TEST_BUILD"]).resolve()
wire = struct.Struct("<II16sIIdff64s")
token = bytes.fromhex("56" * 16)


def packet(seq, report, kind=3, secret=token):
    return wire.pack(0x31425344, kind, secret, 1234, seq, time.time() - 978307200, 0, 0, report)


if "--hardware" not in sys.argv:
    for arch in ("arm64", "x86_64"):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", 0))
        sock.settimeout(0.3)
        env = dict(
            os.environ,
            DSB_PORT=str(sock.getsockname()[1]),
            DSB_TOKEN=token.hex(),
            DSB_RAW="1:pcm",
            DYLD_INSERT_LIBRARIES=str(root / "bridge.dylib"),
        )
        env.pop("DSB_PCM", None)  # Exercise the environment field forwarded by NotProton.
        result = subprocess.run(
            [str(root / ("audio-test-" + arch))], env=env, capture_output=True, text=True, timeout=5
        )
        assert result.returncode == 0, result.stderr
        chunks = []
        while True:
            try:
                chunks.append(wire.unpack(sock.recv(1024)))
            except socket.timeout:
                break
        assert len(chunks) > 5 and all(p[1] == 3 and p[2] == token for p in chunks)
        assert chunks[-1][-1][0] == 0
        # Speaker channels are .75 but haptic channels are -.125/.5. Verify
        # the signed samples at steady state.
        for p in chunks[2:-1]:
            assert p[-1][0] == 30
            assert all(
                abs(a + 16) <= 1 and abs(b - 64) <= 1
                for a, b in struct.iter_unpack("bb", p[-1][4:])
            )
        print(arch, "PASS: PCM routing, speaker isolation, stop, legacy-env forwarding", flush=True)

hardware = "--hardware" in sys.argv
seconds = int(os.environ.get("PCM_SOAK_SECONDS", "60")) if hardware else 3
dest = root / ("pcm-soak-status.json" if hardware else "pcm-dry-status.json")
log = (root / ("pcm-soak.log" if hardware else "pcm-dry.log")).open("w")
args = [
    str(root / "broker"),
    "--pcm",
    "--token",
    token.hex(),
    "--seconds",
    str(seconds + 2),
    "--status",
    str(dest),
] + ([] if hardware else ["--dry-run"])
p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=log, text=True)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
tick_stop = threading.Event()
tick_thread = None
try:
    line = p.stdout.readline()
    assert line, line
    ready = json.loads(line)
    p.pid = ready["pid"]
    addr = ("127.0.0.1", ready["port"])
    if not hardware and os.environ.get("DSB_TEST_DEFER_TIMERS"):
        # Hardware also supplies ~133 HID input events/s, including after an
        # effect ends. Authenticated no-op controls reproduce those extra
        # notifications in the dry transport.
        def ticks():
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as ticker:
                sequence = 0
                due = time.monotonic()
                while not tick_stop.is_set():
                    sequence += 1
                    ticker.sendto(
                        wire.pack(
                            0x31425344,
                            2,
                            token,
                            4321,
                            sequence,
                            time.time() - 978307200,
                            0,
                            0,
                            bytes([2]) + bytes(63),
                        ),
                        addr,
                    )
                    due += 0.0075
                    tick_stop.wait(max(0, due - time.monotonic()))

        tick_thread = threading.Thread(target=ticks)
        tick_thread.start()
    report = bytes([30, 1, 0, 0]) + (bytes(60) if hardware else bytes([16, 240]) * 30)
    epoch = time.monotonic()
    seq = 0
    if not hardware:
        sock.sendto(packet(seq, report, secret=bytes(16)), addr)
        sock.sendto(packet(seq, report) + b"extra", addr)
    for i in range(seconds * 100):
        seq += 1
        sock.sendto(packet(seq, report), addr)
        if not hardware and i % 10 == 0:
            # Exercise serialized simultaneous trigger/LED commands offline.
            seq += 1
            b = bytearray(64)
            b[0] = 2
            b[1] = 4
            b[2] = 4
            b[11:22] = bytes([0x21, 0xFE, 3, 0, 0x90, 0x44, 0x1A, 0, 0, 0, 0])
            b[45] = i % 256
            sock.sendto(packet(seq, b, kind=2), addr)
        remaining = epoch + (i + 1) * 0.01 - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        if i % 100 == 99:
            state = json.loads(dest.read_text())
            assert not state["hidStalled"] and not state["hidErrors"], state
            if hardware:
                print("silent soak", i // 100 + 1, "s", state["pcm"], flush=True)
    seq += 1
    sock.sendto(packet(seq, bytes([0, 1, 0, 0]) + bytes(60)), addr)
    p.wait(timeout=5)
    assert p.returncode == 0, p.returncode
    state = json.loads(dest.read_text())
    assert not state["hidStalled"], state
    assert (
        state["pcm"]["reports"] == 0 if hardware else state["pcm"]["reports"] > seconds * 40
    ), state
    assert state["pcm"]["discardedFrames"] == 0, state
    if not hardware:
        assert state["dropped"] == 2 and state["outputCommands"] > 0, state
    print(
        "PASS",
        (
            "hardware idle silence emits no PCM"
            if hardware
            else "dry transport + authentication + trigger interleave"
        ),
        state["pcm"],
    )
finally:
    tick_stop.set()
    if tick_thread:
        tick_thread.join(timeout=1)
    if p.poll() is None:
        p.terminate()
        p.wait(timeout=3)
    log.close()
    sock.close()
