#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

FIELDS = {
    "cycles": int,
    "retired inst": int,
    "CPI": float,
    "dual issue packets": int,
    "front stall cycles": int,
    "load/use EX stalls": int,
    "load/use MEM stalls": int,
    "ex busy cycles": int,
    "L0 load hits": int,
    "BRAM loads": int,
    "L0 hit rate": str,
    "wall_time_s": float,
    "sim_speed": str,
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    verification = Path(__file__).resolve().parents[1]
    command = [
        str(root / "sim_cpu_only" / "run_verilator.sh"),
        f"IROM_COE={(root / 'sim/coe/mext/irom-v2.coe').resolve()}",
        f"BRAM_COE={(root / 'sim/coe/mext/dram.coe').resolve()}",
        "PASS_LED=078B7323", "FAIL_LED=24181824", "EXPECTED_LED=078B7323",
        "CPU_FREQ_MHZ=200.0", "STOP_NS=4000000000", "PROGRESS_NS=0", "TRACE=0",
    ]
    completed = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT)
    sys.stdout.write(completed.stdout)
    passed = completed.returncode == 0 and ">>> [PASS]" in completed.stdout
    metrics = {}
    for label, convert in FIELDS.items():
        match = re.search(rf"^\s*{re.escape(label)}\s*:\s*([^\s%]+%?)", completed.stdout, re.M)
        if match:
            raw = match.group(1)
            metrics[label] = convert(raw) if convert is not str else raw
    result = {
        "test": "irom-v2",
        "status": "PASS" if passed else "FAIL",
        "expected_led": "0x078b7323",
        "performance_gate": False,
        "metrics": metrics,
    }
    output = verification / "build" / "irom-v2-result.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
