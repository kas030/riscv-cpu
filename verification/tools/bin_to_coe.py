#!/usr/bin/env python3
import argparse
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description="Convert a little-endian binary to 32-bit COE")
    parser.add_argument("--max-words", type=int, required=True)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    data = args.input.read_bytes()
    if len(data) % 4:
        data += bytes(4 - len(data) % 4)
    words = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
    if not words:
        words = [0]
    if len(words) > args.max_words:
        raise SystemExit(f"{args.input}: {len(words)} words exceeds limit {args.max_words}")

    body = ",\n".join(f"{word:08x}" for word in words)
    args.output.write_text(
        "memory_initialization_radix=16;\n"
        "memory_initialization_vector=\n" + body + ";\n",
        encoding="ascii",
    )
    print(f"generated {args.output} ({len(words)} words)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
