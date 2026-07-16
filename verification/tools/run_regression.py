#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


def run_one(root: Path, verification: Path, name: str) -> dict:
    irom = (verification / "build" / f"{name}.irom.coe").resolve()
    bram = (verification / "build" / f"{name}.bram.coe").resolve()
    command = [
        str(root / "sim_cpu_only" / "run_verilator.sh"),
        f"IROM_COE={irom}",
        f"BRAM_COE={bram}",
        "PASS_LED=C0DEC0DE",
        "FAIL_LED=DEADBEEF",
        "EXPECTED_LED=C0DEC0DE",
        "STOP_NS=20000000",
        "PROGRESS_NS=0",
        "TRACE=0",
    ]
    print(f"[RUN] {name}", flush=True)
    result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    sys.stdout.write(result.stdout)
    passed = result.returncode == 0 and ">>> [PASS]" in result.stdout
    metrics = {}
    for label, converter in (("cycles", int), ("retired inst", int), ("CPI", float),
                             ("dual issue packets", int), ("front stall cycles", int),
                             ("load/use EX stalls", int), ("load/use MEM stalls", int),
                             ("ex busy cycles", int), ("L0 load hits", int),
                             ("BRAM loads", int)):
        match = re.search(rf"^\s*{re.escape(label)}\s*:\s*([^\s]+)", result.stdout, re.M)
        if match:
            metrics[label] = converter(match.group(1))
    cycles = metrics.get("cycles", "-")
    print(f"[{'PASS' if passed else 'FAIL'}] {name} cycles={cycles}", flush=True)
    return {"test": name, "status": "PASS" if passed else "FAIL", "metrics": metrics}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--test", action="append", required=True)
    args = parser.parse_args()
    verification = Path(__file__).resolve().parents[1]
    root = args.root.resolve()
    results = [run_one(root, verification, name) for name in args.test]
    output = verification / "build" / "local-results.json"
    output.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    failures = [item["test"] for item in results if item["status"] != "PASS"]
    if failures:
        print("failed tests: " + ", ".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
