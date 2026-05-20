#!/usr/bin/env python3
import re
import sys
from pathlib import Path


def parse_words(src: Path) -> list[str]:
    text = src.read_text(encoding="utf-8")

    radix_match = re.search(r"memory_initialization_radix\s*=\s*(\d+)\s*;", text, re.I)
    vector_match = re.search(r"memory_initialization_vector\s*=\s*(.*?);", text, re.I | re.S)
    if radix_match and vector_match:
        radix = int(radix_match.group(1))
        if radix not in (2, 10, 16):
            raise SystemExit(f"{src}: unsupported COE radix {radix}")
        tokens = re.split(r"[,\s]+", vector_match.group(1).strip())
        return [f"{int(token, radix) & 0xffffffff:08x}" for token in tokens if token]

    content_match = re.search(r"CONTENT\s+BEGIN(.*?)END\s*;", text, re.I | re.S)
    if content_match:
        words = []
        for _, value in re.findall(r"([0-9a-fA-F]+)\s*:\s*([0-9a-fA-F]+)\s*;", content_match.group(1)):
            words.append(f"{int(value, 16) & 0xffffffff:08x}")
        return words

    words = []
    for line in text.splitlines():
        token = line.strip().rstrip(",;")
        if not token or token.startswith("#") or token.startswith("//"):
            continue
        if re.fullmatch(r"[01]{32}", token):
            words.append(f"{int(token, 2) & 0xffffffff:08x}")
        elif re.fullmatch(r"[0-9a-fA-F]{1,8}", token):
            words.append(f"{int(token, 16) & 0xffffffff:08x}")
        else:
            raise SystemExit(f"{src}: unsupported memory line {line!r}")
    return words


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {Path(sys.argv[0]).name} input.coe|mif|mem output.mem", file=sys.stderr)
        return 2

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    words = parse_words(src)

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text("\n".join(words) + "\n", encoding="ascii")
    print(f"converted {src} -> {dst} ({len(words)} words)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
