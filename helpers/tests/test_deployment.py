import importlib.util
import io
import plistlib
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "deployment", Path(__file__).resolve().parents[1] / "check-deployment.py")
deployment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deployment)

MODERN = "Load command 1\n cmd LC_BUILD_VERSION\n platform 1\n minos 15.0\n sdk 26.0\n"
LEGACY = "Load command 1\n cmd LC_VERSION_MIN_MACOSX\n version 10.13\n sdk 15.5\n"


class DeploymentTests(unittest.TestCase):
    def test_normalizes_versions(self):
        self.assertEqual(deployment.version("15"), deployment.version("15.0.0"))
        for value in ("", "15.", "15.0.0.1", "-1", "15.x", 15):
            with self.subTest(value=value), self.assertRaises(ValueError):
                deployment.version(value)

    def test_reads_modern_and_legacy_commands(self):
        self.assertEqual(deployment.minimum_versions(MODERN), ["15.0"])
        self.assertEqual(deployment.minimum_versions(LEGACY), ["10.13"])

    def test_checks_every_fat_slice(self):
        output = ("app (architecture x86_64):\n" + LEGACY
                  + "app (architecture arm64):\n" + MODERN)
        self.assertEqual(deployment.minimum_versions(output), ["10.13", "15.0"])
        with self.assertRaises(ValueError):
            deployment.minimum_versions(output.replace(MODERN, "Load command 0\n cmd LC_SEGMENT_64\n"))

    def test_refuses_missing_duplicate_and_non_macos_commands(self):
        for output in ("", "Load command 0\n cmd LC_SEGMENT_64\n", MODERN + MODERN,
                       MODERN.replace("platform 1", "platform 2"),
                       MODERN.replace("minos 15.0", "")):
            with self.subTest(output=output), self.assertRaises(ValueError):
                deployment.minimum_versions(output)

    def test_bundle_checks_declared_minima_not_sdk_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "App.app"
            contents = bundle / "Contents"
            contents.mkdir(parents=True)
            with (contents / "Info.plist").open("wb") as stream:
                plistlib.dump({"LSMinimumSystemVersion": "15.0"}, stream)
            binary = contents / "App"
            binary.write_bytes(bytes.fromhex("cffaedfe"))
            with patch.object(deployment.subprocess, "check_output", return_value=MODERN):
                with redirect_stdout(io.StringIO()):
                    deployment.check_bundle(bundle, "15.0")
                with self.assertRaisesRegex(ValueError, "Info.plist"):
                    deployment.check_bundle(bundle, "14.0")
            with patch.object(deployment.subprocess, "check_output",
                              return_value=MODERN.replace("minos 15.0", "minos 26.0")):
                with self.assertRaisesRegex(ValueError, "Contents/App.*26.0"):
                    deployment.check_bundle(bundle, "15.0")
                # A relaxed build-time limit must not let a bundle promise
                # macOS 15 while shipping a required macOS 26 binary.
                with self.assertRaisesRegex(ValueError, "LSMinimumSystemVersion"):
                    deployment.check_bundle(bundle, "26.0")
            binary.unlink()
            with self.assertRaisesRegex(ValueError, "no native binaries"):
                deployment.check_bundle(bundle, "15.0")


if __name__ == "__main__":
    unittest.main()
