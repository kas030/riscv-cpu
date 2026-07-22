#!/usr/bin/env python3
import os
import sys
import re
from pathlib import Path


def q(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"')


def u64_literal(v: str, name: str) -> str:
    digits = v.replace("_", "")
    if not digits or not digits.isdecimal():
        raise ValueError(f"{name} must be a non-negative decimal ns value, got {v!r}")
    return f"64'd{v}"


def real_literal(v: str, name: str) -> str:
    digits = v.strip().replace("_", "")
    if not digits:
        raise ValueError(f"{name} must be a positive decimal value, got {v!r}")
    try:
        value = float(digits)
    except ValueError as exc:
        raise ValueError(f"{name} must be a positive decimal value, got {v!r}") from exc
    if not value > 0.0:
        raise ValueError(f"{name} must be greater than 0, got {v!r}")
    return f"{value:.12g}"


def hex32_literal(v: str, name: str) -> str:
    digits = v.strip().replace("_", "")
    if digits.lower().startswith("0x"):
        digits = digits[2:]
    if not digits or len(digits) > 8 or not re.fullmatch(r"[0-9a-fA-F]+", digits):
        raise ValueError(f"{name} must be a 32-bit hex value, got {v!r}")
    return f"32'h{digits.zfill(8)}"


def main() -> int:
    out = sys.argv[1]
    expected_led = os.environ.get("EXPECTED_LED", "").strip()
    pass_led = os.environ.get("PASS_LED", "078B7323").strip()
    fail_led = os.environ.get("FAIL_LED", "24181824").strip()
    trace = os.environ.get("TRACE", "0").strip()
    cpu_freq_mhz = os.environ.get("CPU_FREQ_MHZ", "240.0").strip()
    stop_ns = os.environ.get("STOP_NS", "400000000").strip()
    progress_ns = os.environ.get("PROGRESS_NS", "10000000").strip()
    trace_file = os.environ.get("TRACE_FILE", "build/wave.fst").strip()

    has_expected = "1" if expected_led else "0"
    expected_value = hex32_literal(expected_led, "EXPECTED_LED") if expected_led else "32'h0"
    trace_value = "1" if trace == "1" else "0"

    text = f"""`define SIM_HAS_EXPECTED_LED {has_expected}
`define SIM_EXPECTED_LED {expected_value}
`define SIM_PASS_LED {hex32_literal(pass_led, "PASS_LED")}
`define SIM_FAIL_LED {hex32_literal(fail_led, "FAIL_LED")}
`define SIM_TRACE {trace_value}
`define SIM_CPU_FREQ_MHZ {real_literal(cpu_freq_mhz, "CPU_FREQ_MHZ")}
`define SIM_STOP_NS {u64_literal(stop_ns, "STOP_NS")}
`define SIM_PROGRESS_NS {u64_literal(progress_ns, "PROGRESS_NS")}
`define SIM_TRACE_FILE "{q(trace_file)}"
"""
    out_path = Path(out)
    if out_path.exists() and out_path.read_text(encoding="ascii") == text:
        return 0
    out_path.write_text(text, encoding="ascii")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
