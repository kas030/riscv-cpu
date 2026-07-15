#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--only", action="append")
    args = parser.parse_args()
    root = args.root.resolve()
    build = args.build.resolve()
    manifest = json.loads((build / "manifest.json").read_text(encoding="utf-8"))
    selected = set(args.only or [item["id"] for item in manifest])
    unknown = selected - {item["id"] for item in manifest}
    if unknown:
        raise SystemExit("unknown test ids: " + ", ".join(sorted(unknown)))

    results = []
    for item in manifest:
        test_id = item["id"]
        if test_id not in selected:
            continue
        command = [
            str(root / "sim_cpu_only" / "run_verilator.sh"),
            f"IROM_COE={(build / f'{test_id}.irom.coe').resolve()}",
            f"BRAM_COE={(build / f'{test_id}.bram.coe').resolve()}",
            "PASS_LED=C0DEC0DE", "FAIL_LED=DEADBEEF", "EXPECTED_LED=C0DEC0DE",
            "STOP_NS=20000000", "PROGRESS_NS=0", "TRACE=0",
        ]
        print(f"[RUN] {test_id}", flush=True)
        completed = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)
        passed = completed.returncode == 0 and ">>> [PASS]" in completed.stdout
        results.append({"id": test_id, "status": "PASS" if passed else "FAIL"})
        print(f"[{'PASS' if passed else 'FAIL'}] {test_id}", flush=True)
        if not passed:
            sys.stdout.write(completed.stdout)
    (build / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    failures = [item["id"] for item in results if item["status"] != "PASS"]
    if failures:
        print("failed upstream tests: " + ", ".join(failures), file=sys.stderr)
        return 1
    print(f"passed {len(results)} pinned upstream tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
