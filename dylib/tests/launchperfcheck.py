#!/usr/bin/env python3
"""Exercise launcher fast paths without Wine, Steam, or a real prefix."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(sys.argv.pop(1) if len(sys.argv) > 1 else Path(__file__).parents[1] / 'feats/compat_run.sh').read_text()


def embedded(marker):
    return re.search(r"<<'" + marker + r"'\n(.*?)\n" + marker, SOURCE, re.S)[1]


class LaunchFastPaths(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_code(self, marker, *args):
        return subprocess.run([sys.executable, '-I', '-c', embedded(marker), *map(str, args)], capture_output=True, text=True)

    def install_fixture(self, completed=True, action='run process'):
        script = self.root / 'script.vdf'
        script.write_text('"evaluatorscript" { "0" { "appid" "228980" "mode" "1" '
            '"compat_installscript" { "' + action + '" { "dxsetup" { '
            '"hasrunkey" "HKEY_LOCAL_MACHINE\\\\Software\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\DirectX\\\\Jun2010" '
            '"process 1" "%INSTALLDIR%\\\\_CommonRedist\\\\DirectX\\\\Jun2010\\\\DXSETUP.exe" '
            '"command 1" "/silent" "nocleanup" "1" } } } } }')
        (self.root / 'system.reg').write_text('[Software\\\\Wow6432Node\\\\Valve\\\\Steam\\\\Apps\\\\CommonRedist\\\\DirectX\\\\Jun2010]\n'
            '"dxsetup"=dword:0000000' + ('1' if completed else '0') + '\n')
        return script

    def test_completed_install_check(self):
        self.assertEqual(self.run_code('NP_COMPLETED_REDIST', self.install_fixture(), self.root).returncode, 0)

    def test_incomplete_install_requires_evaluator(self):
        self.assertNotEqual(self.run_code('NP_COMPLETED_REDIST', self.install_fixture(False), self.root).returncode, 0)

    def test_unknown_action_requires_evaluator(self):
        self.assertNotEqual(self.run_code('NP_COMPLETED_REDIST', self.install_fixture(action='registry'), self.root).returncode, 0)

    def test_malformed_script_requires_evaluator(self):
        script = self.install_fixture()
        script.write_text('broken')
        self.assertNotEqual(self.run_code('NP_COMPLETED_REDIST', script, self.root).returncode, 0)

    def test_cache_dependency_changes(self):
        cache = self.root / 'cache.json'
        dependency = self.root / 'bridge.dll'
        dependency.write_text('original')
        args = (cache, 'environment', 'WINELOADER=/runner/wine', dependency)
        self.assertEqual(self.run_code('NP_METADATA_CACHE', 'write', *args).returncode, 0)
        self.assertEqual(self.run_code('NP_METADATA_CACHE', 'read', *args).returncode, 0)
        dependency.write_text('changed')
        self.assertNotEqual(self.run_code('NP_METADATA_CACHE', 'read', *args).returncode, 0)
        dependency.unlink()
        self.assertNotEqual(self.run_code('NP_METADATA_CACHE', 'read', *args).returncode, 0)

    def test_bundle_detects_symlink_change(self):
        bundle = self.root / 'Game.app'
        bundle.mkdir()
        link = bundle / 'library.dylib'
        link.symlink_to('/one')
        before = self.run_code('NP_BUNDLE_CHECK', bundle)
        link.unlink()
        link.symlink_to('/two')
        after = self.run_code('NP_BUNDLE_CHECK', bundle)
        self.assertEqual(before.returncode, 0)
        self.assertEqual(after.returncode, 0)
        self.assertNotEqual(before.stdout, after.stdout)


if __name__ == '__main__':
    unittest.main()
