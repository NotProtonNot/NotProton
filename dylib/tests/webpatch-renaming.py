#!/usr/bin/env python3
"""Minifier drift: rename local bindings, preserving strings and property APIs."""
import pathlib
import random
import re
import subprocess
import sys
import tempfile

gatecheck = pathlib.Path(sys.argv[1]).resolve()
fixtures = pathlib.Path(__file__).parent / "webpatch-fixtures"
token = re.compile(r'''("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|//[^\n]*|/\*[\s\S]*?\*/)|([A-Za-z_$][\w$]*)''')
reserved = set("var let const if else return function true false new get null try for of in this void typeof".split())


def renamed(source, seed):
    rng = random.Random(seed)
    names = {}
    # Include names used inside the injected panel to catch accidental shadowing.
    candidates = rng.sample(["t", "g", "s", "b", "o", "c", "np", "$R", "_UI"], 9)

    def replace(match):
        name = match[2]
        if not name or name in reserved or len(name) > 3:
            return match[0]
        before = source[:match.start()].rstrip()
        after = source[match.end():].lstrip()
        if (before.endswith(".") and not before.endswith("...")) or after.startswith(":"):
            return name
        if name not in names:
            # Suffixes avoid capturing unrelated bindings in the source fixture.
            names[name] = candidates.pop() if candidates else f"$binding_{seed}_{len(names)}"
        return names[name]

    return token.sub(replace, source)


with tempfile.TemporaryDirectory(prefix="np-webpatch-renaming-") as work:
    work = pathlib.Path(work)
    count = 0
    for fixture in sorted(fixtures.glob("gates.*.js")):
        source = fixture.read_text()
        for seed in range(30):
            candidate = renamed(source, seed) + '\nconst locale="de-DE", text="Kompatibilität";\n'
            path = work / "input.js"
            path.write_text(candidate)
            result = subprocess.run([str(gatecheck), str(path)], capture_output=True, text=True, check=True)
            assert "APPLIED" in result.stdout and "WRONG" not in result.stdout, result.stdout + result.stderr
            # Ambiguity and structural changes must still refuse the complete patch.
            for broken in (candidate + candidate, candidate.replace("SpecifyCompatTool", "ChangedCompatAPI")):
                # The selecttool fixtures do not contain that particular API.
                if broken == candidate:
                    broken = candidate.replace("most_available_per_client_data", "changed_client_data", 1)
                path.write_text(broken)
                result = subprocess.run([str(gatecheck), str(path)], capture_output=True, text=True, check=True)
                assert "REJECTED" in result.stdout, result.stdout + result.stderr
            count += 1
    print(f"{count} identifier-renamed/localization variants applied; ambiguous and changed APIs refused")
