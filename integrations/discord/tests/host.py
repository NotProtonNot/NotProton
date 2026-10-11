"""Exercise the native relay against local socket peers, without Wine or Discord."""
import concurrent.futures
import contextlib
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import sys
import tempfile
import threading

host_binary = Path(sys.argv[1]).resolve()


def receive(peer, size):
    data = bytearray()
    while len(data) < size:
        chunk = peer.recv(size - len(data))
        if not chunk:
            raise EOFError("peer closed before all bytes arrived")
        data.extend(chunk)
    return bytes(data)


class EchoServer:
    def __init__(self, directory, index=0):
        self.path = str(Path(directory) / f"discord-ipc-{index}")
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.closed = threading.Event()
        self.connections = []
        self.workers = []
        self.thread = threading.Thread(target=self.accept)
        self.thread.start()

    def accept(self):
        while not self.closed.is_set():
            try:
                peer, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            self.connections.append(peer)
            worker = threading.Thread(target=self.echo, args=(peer,))
            self.workers.append(worker)
            worker.start()

    def echo(self, peer):
        with peer:
            try:
                while not self.closed.is_set():
                    data = peer.recv(317)
                    if not data:
                        return
                    peer.sendall(data)
            except OSError:
                pass

    def close(self):
        self.closed.set()
        self.listener.close()
        self.thread.join(timeout=2)
        for peer in self.connections:
            with contextlib.suppress(OSError):
                peer.shutdown(socket.SHUT_RDWR)
        for worker in self.workers:
            worker.join(timeout=2)
            assert not worker.is_alive(), "echo peer did not stop"
        Path(self.path).unlink(missing_ok=True)


def start_host(tmp, mode="ready"):
    endpoint = tmp / "endpoint.json"
    fixture = tmp / "wine"
    fixture.write_text(f'''#!{sys.executable}
import json
import os
import socket
import sys
from pathlib import Path
port = int(os.environ["NOTPROTON_DISCORD_PORT"])
token = os.environ["NOTPROTON_DISCORD_TOKEN"]
Path(sys.argv[1]).write_text(json.dumps({{"port": port, "token": token, "pid": os.getpid()}}))
if os.environ.get("FIXTURE_MODE") == "exit":
    sys.exit(7)
with socket.create_connection(("127.0.0.1", port)) as control:
    control.sendall(token.encode() + bytes([0]))
    control.recv(1)
''')
    fixture.chmod(0o755)
    endpoint.unlink(missing_ok=True)
    env = dict(os.environ, NOTPROTON_DISCORD_SOCKET_DIR=str(tmp), FIXTURE_MODE=mode)
    process = subprocess.Popen(
        [str(host_binary), str(fixture), str(endpoint)], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if mode == "ready":
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(5), "host readiness timed out"
        ready = process.stdout.readline()
        assert ready == b"ready\n", f"unexpected readiness output: {ready!r}"
    return process, endpoint


def connect(endpoint, token=None, fragmented=False):
    config = json.loads(endpoint.read_text())
    peer = socket.create_connection(("127.0.0.1", config["port"]), timeout=5)
    hello = (token or config["token"]).encode() + bytes([1])
    if fragmented:
        for byte in hello:
            peer.sendall(bytes([byte]))
    else:
        peer.sendall(hello)
    return peer


def stop_host(process):
    process.terminate()
    _, errors = process.communicate(timeout=6)
    assert process.returncode == 0, errors.decode()


with tempfile.TemporaryDirectory(prefix="np-discord-") as directory:
    tmp = Path(directory)
    process, endpoint = start_host(tmp)
    server = None
    try:
        with connect(endpoint) as peer:
            assert peer.recv(1) == b"", "absent Discord must close the connection"
        server = EchoServer(tmp, index=3)
        with connect(endpoint, token="0" * 64) as peer:
            assert peer.recv(1) == b"", "unauthenticated client reached Discord"
        print("  ok    absent Discord and invalid authentication close only their clients")

        def round_trip(seed):
            payload = bytes((i * 31 + seed) % 256 for i in range(200003))
            with connect(endpoint, fragmented=True) as peer:
                peer.sendall(payload)
                assert receive(peer, len(payload)) == payload

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(round_trip, range(8)))
        print("  ok    concurrent, fragmented, binary streams survive backpressure")

        with connect(endpoint) as peer:
            peer.sendall(b"connected")
            assert receive(peer, 9) == b"connected"
            server.close()
            server = None
            assert peer.recv(1) == b"", "Discord closure was not forwarded"
        server = EchoServer(tmp)
        round_trip(9)
        print("  ok    late startup, socket selection and Discord restart")

        for _ in range(40):
            with connect(endpoint) as peer:
                peer.sendall(b"reconnect")
                assert receive(peer, 9) == b"reconnect"
        print("  ok    pipe clients can reconnect repeatedly")

        peer = connect(endpoint)
        peer.sendall(b"pending")
        assert receive(peer, 7) == b"pending"
        config = json.loads(endpoint.read_text())
        stop_host(process)
        assert peer.recv(1) == b""
        peer.close()
        try:
            os.kill(config["pid"], 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("helper survived the host")
        print("  ok    shutdown closes active sessions and reaps the helper")
    finally:
        if process.poll() is None:
            stop_host(process)
        if server:
            server.close()

    process, _ = start_host(tmp, mode="exit")
    output, errors = process.communicate(timeout=6)
    assert process.returncode != 0 and b"ready" not in output, errors.decode()
    print("  ok    failed helper does not report readiness")

print("==> Discord host: transport, authentication, reconnect and lifetime checks passed")
