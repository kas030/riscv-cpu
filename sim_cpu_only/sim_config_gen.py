#!/usr/bin/env python3
import os
import sys


def q(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"')


def u64_literal(v: str, name: str) -> str:
    digits = v.replace("_", "")
    if not digits or not digits.isdecimal():
        raise ValueError(f"{name} must be a non-negative decimal ns value, got {v!r}")
    return f"64'd{v}"


def main() -> int:
    out = sys.argv[1]
    expected_led = os.environ.get("EXPECTED_LED", "").strip()
    trace = os.environ.get("TRACE", "0").strip()
    stop_ns = os.environ.get("STOP_NS", "400000000").strip()
    progress_ns = os.environ.get("PROGRESS_NS", "10000000").strip()
    trace_file = os.environ.get("TRACE_FILE", "build/wave.fst").strip()

    has_expected = "1" if expected_led else "0"
    expected_value = f"32'h{expected_led}" if expected_led else "32'h0"
    trace_value = "1" if trace == "1" else "0"

    text = f"""`define SIM_HAS_EXPECTED_LED {has_expected}
`define SIM_EXPECTED_LED {expected_value}
`define SIM_TRACE {trace_value}
`define SIM_STOP_NS {u64_literal(stop_ns, "STOP_NS")}
`define SIM_PROGRESS_NS {u64_literal(progress_ns, "PROGRESS_NS")}
`define SIM_TRACE_FILE "{q(trace_file)}"
"""
    with open(out, "w", encoding="ascii") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
