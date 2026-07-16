#!/usr/bin/env python3
import argparse
import json
import subprocess
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--dest", type=Path, required=True)
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    args.dest.mkdir(parents=True, exist_ok=True)
    for source in lock["sources"]:
        target = args.dest / source["name"]
        if not target.exists():
            subprocess.run(["git", "clone", "--no-checkout", source["url"], str(target)], check=True)
        subprocess.run(["git", "-C", str(target), "fetch", "--depth=1", "origin", source["commit"]], check=True)
        subprocess.run(["git", "-C", str(target), "checkout", "--detach", source["commit"]], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
