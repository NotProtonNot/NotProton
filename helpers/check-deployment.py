#!/usr/bin/env python3
"""Reject app bundles with native binaries requiring a newer macOS version."""

import argparse
import plistlib
import re
import subprocess
from pathlib import Path


MACHO_MAGIC = {
    bytes.fromhex(value)
    for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe",
                  "cafebabe", "bebafeca", "cafebabf", "bfbafeca")
}


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"invalid macOS version: {value!r}")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def minimum_versions(load_commands):
    versions = []
    # A fat binary must pass for every architecture, not merely have one
    # recognized deployment command somewhere in the combined otool output.
    slices = re.split(r"(?m)^.* \(architecture [^)]+\):\n", load_commands)
    for slice_commands in filter(str.strip, slices):
        minima = []
        for block in re.split(r"Load command \d+", slice_commands):
            if re.search(r"\bcmd LC_BUILD_VERSION\b", block):
                if not re.search(r"\bplatform (?:1|MACOS)\b", block):
                    raise ValueError("a native slice targets a platform other than macOS")
                field = re.search(r"\bminos ([\d.]+)", block)
            elif re.search(r"\bcmd LC_VERSION_MIN_MACOSX\b", block):
                field = re.search(r"\bversion ([\d.]+)", block)
            else:
                continue
            if field is None:
                raise ValueError("a native slice has no minimum OS version")
            minimum = field.group(1)
            version(minimum)
            minima.append(minimum)
        if len(minima) != 1:
            raise ValueError("a native slice must have exactly one macOS deployment target")
        versions.extend(minima)
    if not versions:
        raise ValueError("no native slices found")
    return versions


def check_bundle(bundle, maximum):
    maximum_version = version(maximum)
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        plist = plistlib.load(stream)
    minimum = plist["LSMinimumSystemVersion"]
    declared_version = version(minimum)
    if declared_version > maximum_version:
        raise ValueError(f"Info.plist requires macOS {minimum}")

    checked = 0
    for path in sorted(bundle.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in MACHO_MAGIC:
                continue
        commands = subprocess.check_output(
            ["otool", "-arch", "all", "-l", str(path)], text=True)
        try:
            for minimum in minimum_versions(commands):
                if version(minimum) > declared_version:
                    raise ValueError(f"requires macOS {minimum}, newer than LSMinimumSystemVersion")
        except ValueError as error:
            raise ValueError(f"{path.relative_to(bundle)}: {error}") from error
        checked += 1
    if not checked:
        raise ValueError("the bundle contains no native binaries")
    print(f"==> {checked} native binaries satisfy the bundle's declared macOS minimum")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("maximum", nargs="?", default="15.0")
    args = parser.parse_args()
    try:
        check_bundle(args.bundle, args.maximum)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"deployment check failed: {error}\n")
