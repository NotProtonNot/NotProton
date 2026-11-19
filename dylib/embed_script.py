#!/usr/bin/env python3
# Turns a shell script into a C string literal.
import sys
from pathlib import Path


def literal(text: str) -> str:
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    out = []
    for line in lines:
        body = line.replace("\\", "\\\\").replace('"', '\\"').replace("?", "\\?")
        out.append(f'    "{body}\\n"')
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write("usage: embed_script.py <input.sh> <output.h> <symbol>\n")
        return 2
    src, dst, symbol = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]

    text = src.read_text(encoding="ascii")
    guard = f"NOTPROTON_GENERATED_{symbol.upper()}_H"
    header = (
        f"// Generated from {src.as_posix()} by dylib/embed_script.py. Edit that file.\n"
        f"#ifndef {guard}\n"
        f"#define {guard}\n"
        f"\n"
        f"static const char {symbol}[] =\n"
        f"{literal(text)};\n"
        f"\n"
        f"#endif // {guard}\n"
    )
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(header, encoding="ascii")
    return 0


if __name__ == "__main__":
    sys.exit(main())
