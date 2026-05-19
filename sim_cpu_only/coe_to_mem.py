#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {Path(sys.argv[0]).name} input.coe output.mem", file=sys.stderr)
        return 2

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    text = src.read_text(encoding="utf-8")

    radix_match = re.search(r"memory_initialization_radix\s*=\s*(\d+)\s*;", text, re.I)
    vector_match = re.search(r"memory_initialization_vector\s*=\s*(.*?);", text, re.I | re.S)
    if not radix_match or not vector_match:
        raise SystemExit(f"{src}: not a valid COE file")

    radix = int(radix_match.group(1))
    if radix not in (2, 10, 16):
        raise SystemExit(f"{src}: unsupported radix {radix}")

    words = []
    for token in re.split(r"[,\s]+", vector_match.group(1).strip()):
        if not token:
            continue
        words.append(f"{int(token, radix) & 0xffffffff:08x}")

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text("\n".join(words) + "\n", encoding="ascii")
    print(f"converted {src} -> {dst} ({len(words)} words)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
