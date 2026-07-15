#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("lock", type=Path)
    parser.add_argument("--sources", type=Path)
    args = parser.parse_args()
    document = json.loads(args.lock.read_text(encoding="utf-8"))
    if document.get("schema") != 1:
        raise SystemExit("unsupported upstream lock schema")
    names = set()
    for source in document.get("sources", []):
        name = source.get("name", "")
        commit = source.get("commit", "")
        if not name or name in names:
            raise SystemExit(f"invalid or duplicate source name: {name!r}")
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise SystemExit(f"{name}: commit must be a full SHA-1")
        if not source.get("url", "").startswith("https://github.com/"):
            raise SystemExit(f"{name}: unexpected source URL")
        names.add(name)
        if args.sources:
            checkout = args.sources / name
            if not checkout.is_dir():
                raise SystemExit(f"missing checkout: {checkout}")
            actual = subprocess.check_output(
                ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
            ).strip()
            if actual != commit:
                raise SystemExit(f"{name}: expected {commit}, got {actual}")
    print(f"validated {len(names)} pinned upstream sources")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
