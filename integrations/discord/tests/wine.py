"""Run the bridge and Windows clients in a disposable prefix with an explicit Wine runtime."""
import concurrent.futures
import contextlib
import os
from pathlib import Path
import selectors
import socket
import subprocess
import sys
import tempfile
import threading
import time

output = Path(sys.argv[1]).resolve()
wine = os.environ.get("DISCORD_TEST_WINE")
wineserver = os.environ.get("DISCORD_TEST_WINESERVER")
if not wine or not wineserver:
    sys.exit("Set DISCORD_TEST_WINE and DISCORD_TEST_WINESERVER to the matching runtime executables")

with tempfile.TemporaryDirectory(prefix="np-discord-wine-") as directory:
    tmp = Path(directory)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "DSB_", "NOTPROTON_"))}
    env.update(WINEPREFIX=str(tmp / "prefix"), WINESERVER=wineserver, WINEDEBUG="-all")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(tmp / "discord-ipc-0"))
    server.listen()
    server.settimeout(0.1)
    closed = threading.Event()
    peers, workers = [], []

    def echo(peer):
        with peer:
            try:
                while data := peer.recv(1009):
                    peer.sendall(data)
            except OSError:
                pass

    def accept():
        while not closed.is_set():
            try:
                peer, _ = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            peers.append(peer)
            worker = threading.Thread(target=echo, args=(peer,))
            workers.append(worker)
            worker.start()

    thread = threading.Thread(target=accept)
    thread.start()
    host = None
    try:
        subprocess.run([wine, "wineboot", "-u"], env=env, check=True, timeout=90,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        host = subprocess.Popen(
            [str(output / "host"), wine, str(output / "notproton-discord.exe")],
            env=dict(env, NOTPROTON_DISCORD_SOCKET_DIR=str(tmp)),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        with selectors.DefaultSelector() as selector:
            selector.register(host.stdout, selectors.EVENT_READ)
            assert selector.select(15), "Wine bridge readiness timed out"
        ready = host.stdout.readline()
        assert ready == b"ready\n", f"unexpected readiness output: {ready!r}"

        def thread_count():
            result = subprocess.run([wine, str(output / "test-client.exe"), "threads"],
                                    env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == 0, (result.stdout, result.stderr)
            return int(result.stdout.strip())

        idle_threads = thread_count()
        assert idle_threads <= 4, f"idle pipe server uses {idle_threads} threads"
        print(f"  ok    idle pipe server uses {idle_threads} thread(s)")

        def wait_for_idle():
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if thread_count() == idle_threads:
                    return
                time.sleep(0.05)
            raise AssertionError("pipe server did not release its connection threads")

        def client(seed, executable="test-client.exe"):
            result = subprocess.run([wine, str(output / executable), "echo", "1048576", str(seed)],
                                    env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, (result.stdout, result.stderr)
            print(result.stdout.rstrip())

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(client, range(4)))
        for seed in range(4, 10):
            client(seed)
        client(32, "test-client32.exe")
        # The first-instance guard must leave the existing server untouched.
        duplicate = subprocess.run(
            [str(output / "host"), wine, str(output / "notproton-discord.exe")],
            env=dict(env, NOTPROTON_DISCORD_SOCKET_DIR=str(tmp)),
            capture_output=True, timeout=15,
        )
        assert duplicate.returncode != 0 and b"ready" not in duplicate.stdout
        client(10)
        print("  ok    existing named pipe preserved when a second bridge starts")
        wait_for_idle()
        print("  ok    transfers and reconnects release their connection threads")
        pending = []
        try:
            for _ in range(16):
                process = subprocess.Popen([wine, str(output / "test-client.exe"), "wait", "0"],
                                           env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                pending.append(process)
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    assert selector.select(10), "concurrent client did not connect"
                assert process.stdout.readline().strip() == b"connected"
                assert all(p.poll() is None for p in pending), "concurrent pipe session closed early"
            assert thread_count() > idle_threads, "connection workers did not start"
        finally:
            for process in pending:
                if process.poll() is None:
                    process.terminate()
                process.communicate(timeout=5)
        wait_for_idle()
        client(11)
        print("  ok    sixteen concurrent sessions close and the pipe accepts new clients")
        waiting = subprocess.Popen([wine, str(output / "test-client.exe"), "wait", "0"],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(waiting.stdout, selectors.EVENT_READ)
                assert selector.select(10), "pending client did not connect"
            assert waiting.stdout.readline().strip() == b"connected"
            host.terminate()
            _, errors = host.communicate(timeout=8)
            waiting.communicate(timeout=8)
            assert waiting.returncode == 0, "blocked pipe read did not finish at shutdown"
        finally:
            if waiting.poll() is None:
                waiting.kill()
                waiting.wait(timeout=5)
        assert host.returncode == 0, errors.decode()
        print("  ok    Wine helper exits when its native host stops")
    finally:
        if host and host.poll() is None:
            host.terminate()
            host.wait(timeout=8)
        subprocess.run([wineserver, "-k"], env=env, timeout=10)
        subprocess.run([wineserver, "-w"], env=env, timeout=10)
        closed.set()
        server.close()
        thread.join(timeout=2)
        for peer in peers:
            with contextlib.suppress(OSError):
                peer.shutdown(socket.SHUT_RDWR)
        for worker in workers:
            worker.join(timeout=2)
print("==> Discord Wine: simultaneous clients, large transfers, reconnect and pipe ownership passed")
