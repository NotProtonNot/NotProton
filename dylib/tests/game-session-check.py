#!/usr/bin/env python3
"""Check bundle staging and native session shutdown without Wine or Steam."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else ROOT / 'dylib/feats/compat_run.sh').read_text()
RECIPE = re.search(r'(cat > "\$loader_macos/launcher" <<LAUNCHER\n.*?)\n\nbundle_listing\(\)', SOURCE, re.S)[1]


class GameSession(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='np-game-session-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / 'Example Game.app'
        self.macos = self.bundle / 'Contents/MacOS'
        self.macos.mkdir(parents=True)
        self.env = os.environ.copy()
        for key in ('DYLD_INSERT_LIBRARIES', 'NOTPROTON_GAME_CHANNEL', 'NOTPROTON_FEATURE_DYLIBS',
                    'STEAM_DYLD_INSERT_LIBRARIES', 'NOTPROTON_GAME_CWD'):
            self.env.pop(key, None)
        self.env.update(loader_macos=str(self.macos), loader_root=str(self.root),
                        WINELOADER=str(self.macos / 'wine'), np_game_host=str(ROOT / 'out/game-host'),
                        np_game_client=str(ROOT / 'out/game-client.dylib'))

    def stage(self, enabled):
        self.env['np_single_icon'] = str(int(enabled))
        subprocess.run(['sh', '-ec', RECIPE], env=self.env, check=True)

    def test_fallback_uses_existing_shell_entry(self):
        self.stage(False)
        self.assertTrue((self.macos / 'launcher').read_text().startswith('#!/bin/sh'))
        self.assertFalse((self.macos / 'wine-launch.sh').exists())

    def test_host_carries_both_architectures(self):
        self.stage(True)
        for name in ('launcher', 'game-client.dylib'):
            arches = subprocess.check_output(['lipo', '-archs', self.macos / name], text=True).split()
            self.assertEqual(set(arches), {'arm64', 'x86_64'})
        self.assertTrue((self.macos / 'wine-launch.sh').is_file())

    def test_quit_stops_only_the_requested_prefix_and_preserves_arguments(self):
        self.check_session(quit_from_host=True)

    def test_game_exit_removes_the_host_and_stops_the_prefix(self):
        self.check_session(quit_from_host=False)

    def test_game_exit_clears_a_lingering_bootstrap(self):
        self.check_session(quit_from_host=False, lingering_wrapper=True)

    def test_unrelated_window_exit_does_not_end_the_session(self):
        self.check_session(quit_from_host=False, lingering_wrapper=True, unrelated_window=True)

    def test_crash_before_appkit_clears_a_lingering_bootstrap(self):
        self.check_session(quit_from_host=False, lingering_wrapper=True, early_crash=True)

    def test_launcher_handoff_keeps_child_alive_until_it_exits(self):
        self.check_session(quit_from_host=False, lingering_wrapper=True, handoff=True)

    def check_session(self, quit_from_host, lingering_wrapper=False, unrelated_window=False,
                      early_crash=False, handoff=False):
        import plistlib
        self.stage(True)
        with (self.bundle / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleExecutable': 'launcher', 'CFBundleName': 'Example Game',
                          'CFBundlePackageType': 'APPL', 'CFBundleIdentifier': 'com.notproton.test.game'}, stream)
        fixture = ROOT / 'out/game-session-fixture'
        (self.macos / 'wine').write_bytes(fixture.read_bytes())
        (self.macos / 'wine').chmod(0o755)
        server = self.root / 'wineserver'
        server.write_text('#!/bin/sh\nprintf "%s\\n" "$WINEPREFIX" "$1" > "$NP_GAME_TEST_STOP"\n'
                          'kill "$(/usr/bin/plutil -extract pid raw -o - "$NP_GAME_TEST_STATE")"\n')
        server.chmod(0o755)
        state = self.root / 'state.json'
        stopped = self.root / 'stopped'
        self.env.update(WINESERVER=str(server), WINEPREFIX=str(self.root / 'prefix'),
                        NP_GAME_TEST_STATE=str(state), NP_GAME_TEST_STOP=str(stopped))
        arguments = ['argument with spaces', '-switch', 'literal$argument']
        if lingering_wrapper:
            child = self.macos / 'Game.exe'
            child.write_bytes(fixture.read_bytes())
            child.chmod(0o755)
            self.env.update(NP_GAME_TEST_CHILD=str(child), NP_GAME_TEST_WINDOW='1')
            if early_crash:
                self.env['NP_GAME_TEST_EARLY_EXIT'] = '1'
            if handoff:
                worker = self.macos / 'Worker.exe'
                worker.write_bytes(fixture.read_bytes())
                worker.chmod(0o755)
                self.env['NP_GAME_TEST_HANDOFF'] = str(worker)
            arguments = [r'C:\Program Files (x86)\Steam\steam.exe',
                         str(self.macos / 'Other.exe') if unrelated_window else str(child), *arguments]
        host = subprocess.Popen([self.macos / 'launcher', *arguments], env=self.env)
        client_pid = None
        try:
            deadline = time.monotonic() + 15
            while not state.exists():
                self.assertIsNone(host.poll(), 'host exited before launching the client')
                if time.monotonic() >= deadline:
                    self.fail('client did not publish its state')
                time.sleep(0.05)
            data = json.loads(state.read_text())
            client_pid = data['pid']
            self.assertEqual(data['policy'], -1 if early_crash else 1)
            self.assertEqual(data['arguments'][1:], arguments)
            self.assertIn(str(self.macos / 'game-client.dylib'), data['libraries'])
            if lingering_wrapper:
                # Allow the real key-window notification to reach the host.
                time.sleep(0.5)
                self.assertIsNone(host.poll())
            if handoff:
                time.sleep(1.5)
                self.assertIsNone(host.poll(), 'launcher exit must not stop its live child')
            if quit_from_host:
                subprocess.run([fixture, '--quit', str(host.pid)], check=True)
            else:
                os.kill(client_pid, signal.SIGTERM)
            if unrelated_window:
                time.sleep(1.5)
                self.assertIsNone(host.poll(), 'an unrelated UI helper must not end the game')
                subprocess.run([fixture, '--quit', str(host.pid)], check=True)
            self.assertEqual(host.wait(timeout=15), 0)
            self.assertEqual(stopped.read_text().splitlines(), [self.env['WINEPREFIX'], '-k'])
        finally:
            if host.poll() is None:
                host.kill()
                host.wait()
            if client_pid:
                try:
                    os.kill(client_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


if __name__ == '__main__':
    unittest.main()
