#!/usr/bin/env python3
"""Validate UTF-8 string tables without requiring macOS or third-party packages."""
import collections
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "app/Sources/NotProtonApp/Resources/Localization"
ENTRY = re.compile(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");')
PLACEHOLDERS = re.compile(r"\{\d+\}")


def read_table(language):
    result = {}
    for number, line in enumerate(
        (RESOURCES / f"{language}.lproj/Localizable.strings").read_text().splitlines(), 1
    ):
        if not line.strip() or line.startswith("//"):
            continue
        match = ENTRY.fullmatch(line)
        assert match, f"{language}:{number}: invalid .strings entry"
        key, value = map(json.loads, match.groups())
        assert key not in result, f"{language}:{number}: duplicate key {key}"
        assert value, f"{language}:{number}: empty translation"
        result[key] = value
    return result


def main():
    english, chinese = read_table("en"), read_table("zh-Hans")
    assert english and english.keys() == chinese.keys(), "Language tables differ"
    for key, value in chinese.items():
        assert english[key] == key, f"English fallback changed: {key}"
        assert collections.Counter(PLACEHOLDERS.findall(key)) == collections.Counter(
            PLACEHOLDERS.findall(value)
        ), f"Interpolation values differ: {key}"
        assert re.search(r"[\u3400-\u9fff]", value) or key == "The {0}", f"Not translated: {key}"
    print(f"PASS: {len(chinese)} Chinese translations, English fallbacks and interpolation values")


if __name__ == "__main__":
    main()
