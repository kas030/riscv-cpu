#!/usr/bin/env python3
"""Analyze a short or full RT-Thread CoreMark run."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


TARGET_ITERATIONS = 10_000
FIXED_TEST = "rt-thread/coremark-2k-performance"
COREMARK_TICKS_PER_SECOND = 1_000
INTEGER_METRICS = {
    "cnt_ms": "cnt_ms",
    "cycles": "cycles",
    "writeback": "writeback (reg_file)",
    "slot1_writeback": "slot1 writeback",
    "stores": "stores",
    "taken_branches": "taken branches",
    "dual_issue_packets": "dual issue packets",
    "front_stall_cycles": "front stall cycles",
    "load_use_stalls": "load/use stalls",
    "load_use_ex_stalls": "load/use EX stalls",
    "load_use_mem_stalls": "load/use MEM stalls",
    "hazard_ex_busy": "hazard+EX busy",
    "ex_busy_cycles": "ex busy cycles",
    "l0_load_hits": "L0 load hits",
    "bram_loads": "BRAM loads",
    "retired_inst": "retired inst",
}


def read_meta(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            if key != "override":
                result[key] = value
    required = {
        "fixed_test",
        "mode",
        "iterations",
        "snapshot_low",
        "snapshot_high",
        "target_iterations",
    }
    missing = sorted(required - result.keys())
    if missing:
        raise ValueError(f"{path}: missing fields: {', '.join(missing)}")
    if result["fixed_test"] != FIXED_TEST:
        raise ValueError(
            f"{path}: fixed_test is {result['fixed_test']!r}, expected {FIXED_TEST!r}"
        )
    if int(result["target_iterations"]) != TARGET_ITERATIONS:
        raise ValueError(f"{path}: target_iterations must be {TARGET_ITERATIONS}")
    return result


def parse_metrics(section: str, source: Path, context: str) -> dict[str, int]:
    values: dict[str, int] = {}
    for key, label in INTEGER_METRICS.items():
        matches = re.findall(
            rf"^\s*{re.escape(label)}\s*:\s*(\d+)\s*$", section, re.MULTILINE
        )
        if not matches:
            raise ValueError(f"{source}: {context} missing metric {label!r}")
        values[key] = int(matches[-1])
    return values


def parse_snapshot(path: Path, iterations: int) -> dict[str, int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    marker = rf">>> \[COREMARK_SNAPSHOT\] iterations={iterations}[^\S\r\n]*\r?$"
    match = re.search(
        marker + r"(.*?)(?=>>> \[COREMARK_SNAPSHOT\]|>>> \[COREMARK_CRC\]|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise ValueError(f"{path}: missing CoreMark snapshot {iterations}")
    return parse_metrics(match.group(1), path, f"snapshot {iterations}")


def parse_log(path: Path, iterations: int) -> dict[str, object]:
    text = path.read_text(encoding="utf-8", errors="replace")
    run_marker = re.search(
        r">>> \[COREMARK_RUN\] iterations=(\d+) validity=\s*(\S+)", text
    )
    result: dict[str, object] = {
        "pass": ">>> [PASS]" in text,
        "crc_validated": (
            ">>> [COREMARK_CRC] crclist=e714 crcmatrix=1fd7 crcstate=8e3a" in text
        ),
        "validity": run_marker.group(2) if run_marker else "missing",
    }
    if not run_marker or int(run_marker.group(1)) != iterations:
        raise ValueError(f"{path}: missing or inconsistent COREMARK_RUN marker")
    result.update(parse_metrics(text, path, "final report"))
    freq = re.findall(r"^\s*cpu_freq_mhz\s*:\s*([0-9.]+)\s*$", text, re.MULTILINE)
    if not freq:
        raise ValueError(f"{path}: missing cpu_freq_mhz")
    result["cpu_freq_mhz"] = float(freq[-1])
    total_ticks = re.findall(
        r"^\s*Total ticks\s*:\s*(\d+)\s*$", text, re.MULTILINE
    )
    total_time = re.findall(
        r"^\s*Total time \(secs\)\s*:\s*([0-9.]+)\s*$", text, re.MULTILINE
    )
    if not total_ticks or not total_time:
        raise ValueError(f"{path}: missing CoreMark Total ticks/time")
    result["coremark_total_ticks"] = int(total_ticks[-1])
    result["coremark_total_time_sec"] = float(total_time[-1])
    expected_time = int(total_ticks[-1]) / COREMARK_TICKS_PER_SECOND
    if abs(float(total_time[-1]) - expected_time) > 0.5 / COREMARK_TICKS_PER_SECOND:
        raise ValueError(f"{path}: inconsistent CoreMark Total ticks/time")
    return result


def parse_timing_report(path: Path) -> dict[str, float | str | bool]:
    text = path.read_text(encoding="utf-8", errors="replace")
    timing: dict[str, float | str | bool] = {
        "path": str(path.resolve()),
        "constraints_met": "All user specified timing constraints are met" in text,
    }
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if "WNS(ns)" not in line or "TNS(ns)" not in line:
            continue
        for candidate in lines[index + 1 : index + 7]:
            values = re.findall(r"[-+]?\d+(?:\.\d+)?", candidate)
            if len(values) >= 2:
                timing["wns_ns"] = float(values[0])
                timing["tns_ns"] = float(values[1])
                break
        if "wns_ns" in timing:
            break
    setup_paths = re.findall(
        r"Slack \((?:VIOLATED|MET)\)\s*:\s*([-+]?\d+(?:\.\d+)?)ns"
        r"\s*\(required time - arrival time\)(.*?)"
        r"Requirement:\s*([0-9.]+)ns",
        text,
        re.IGNORECASE | re.DOTALL,
    )
    if setup_paths:
        _, _, period = min(setup_paths, key=lambda item: float(item[0]))
        timing["target_period_ns"] = float(period)
    if "wns_ns" in timing and "target_period_ns" in timing:
        estimated_period = float(timing["target_period_ns"]) - float(timing["wns_ns"])
        if estimated_period > 0:
            timing["estimated_fmax_mhz"] = 1000.0 / estimated_period
    return timing


def fmt_int(value: float) -> str:
    return f"{round(value):,}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--timing-report", type=Path)
    args = parser.parse_args()

    meta = read_meta(args.run_dir / "run.meta")
    mode = meta["mode"]
    source_iterations = int(meta["iterations"])
    low_iterations = int(meta["snapshot_low"])
    high_iterations = int(meta["snapshot_high"])
    if not 1 <= low_iterations < high_iterations <= source_iterations:
        raise ValueError("snapshot points must satisfy 1 <= low < high <= iterations")

    log_path = args.run_dir / f"verilator_i{source_iterations}.log"
    final = parse_log(log_path, source_iterations)
    low = parse_snapshot(log_path, low_iterations)
    high = parse_snapshot(log_path, high_iterations)
    if not final["pass"] or not final["crc_validated"]:
        raise ValueError(f"{log_path}: PASS and all three CRC checks are required")

    per_iteration: dict[str, float] = {}
    for key in INTEGER_METRICS:
        per_iteration[key] = (high[key] - low[key]) / (
            high_iterations - low_iterations
        )

    freq_mhz = float(final["cpu_freq_mhz"])
    steady_cycles = per_iteration["cycles"]
    steady_retired = per_iteration["retired_inst"]
    if steady_cycles <= 0 or steady_retired <= 0 or per_iteration["bram_loads"] <= 0:
        raise ValueError("snapshot deltas must contain positive work")

    tick_ms = 1000.0 / COREMARK_TICKS_PER_SECOND
    source_steady_time_ms = (
        source_iterations * steady_cycles / (freq_mhz * 1000.0)
    )
    coremark_counter_time_ms = float(final["coremark_total_ticks"]) * tick_ms
    timer_error_ms = source_steady_time_ms - coremark_counter_time_ms
    timer_error_pct = 100.0 * timer_error_ms / source_steady_time_ms
    # CoreMark reads a 1 ms free-running counter at each end of the timed section.
    # The difference may differ from the exact elapsed time by less than one tick.
    # Two ticks leave margin for the few instructions outside the repeated body.
    timer_tolerance_ms = max(2.0 * tick_ms, 0.02 * source_steady_time_ms)
    if source_iterations >= 8 and abs(timer_error_ms) > timer_tolerance_ms:
        raise ValueError(
            "snapshot/CoreMark timer mismatch: "
            f"{source_steady_time_ms:.3f} ms from snapshots versus "
            f"{coremark_counter_time_ms:.3f} ms from Total ticks "
            f"(allowed {timer_tolerance_ms:.3f} ms); snapshot detection is unreliable"
        )

    counter_scale = TARGET_ITERATIONS / source_iterations
    derived: dict[str, float] = {
        "coremark_iterations_per_sec": freq_mhz * 1_000_000.0 / steady_cycles,
        "benchmark_time_ms": TARGET_ITERATIONS * steady_cycles / (freq_mhz * 1000.0),
        "source_steady_time_ms": source_steady_time_ms,
        "coremark_counter_time_ms": coremark_counter_time_ms,
        "snapshot_timer_error_ms": timer_error_ms,
        "snapshot_timer_error_pct": timer_error_pct,
        "counter_extrapolated_time_ms": coremark_counter_time_ms * counter_scale,
        "counter_extrapolated_lower_ms": max(
            0.0, coremark_counter_time_ms - tick_ms
        )
        * counter_scale,
        "counter_extrapolated_upper_ms": (
            coremark_counter_time_ms + tick_ms
        )
        * counter_scale,
        "steady_cpi": steady_cycles / steady_retired,
        "steady_mips": freq_mhz * steady_retired / steady_cycles,
        "steady_l0_hit_rate_pct": (
            100.0 * per_iteration["l0_load_hits"] / per_iteration["bram_loads"]
        ),
    }

    output: dict[str, object] = {
        "fixed_test": FIXED_TEST,
        "mode": mode,
        "target_iterations": TARGET_ITERATIONS,
        "source_iterations": source_iterations,
        "snapshot_iterations": [low_iterations, high_iterations],
        "source_pass": bool(final["pass"]),
        "crc_validated": bool(final["crc_validated"]),
        "source_validity": final["validity"],
        "per_iteration": per_iteration,
        "derived_10000": derived,
    }

    if mode == "full":
        if source_iterations != TARGET_ITERATIONS:
            raise ValueError("full mode must execute exactly 10000 iterations")
        if final["validity"] != "official-valid":
            raise ValueError("full mode did not satisfy the official validity gate")
        actual = {key: int(final[key]) for key in INTEGER_METRICS}
        actual["cpi"] = actual["cycles"] / actual["retired_inst"]
        actual["mips"] = freq_mhz * actual["retired_inst"] / actual["cycles"]
        actual["end_to_end_ms"] = actual["cycles"] / (freq_mhz * 1000.0)
        actual["coremark_reported_time_ms"] = coremark_counter_time_ms
        output["actual_10000"] = actual
        report_stem = "actual_10000"
        title = "CoreMark 10000 次正式回归"
    else:
        estimated: dict[str, float] = {}
        for key in INTEGER_METRICS:
            estimated[key] = float(final[key]) + (
                TARGET_ITERATIONS - source_iterations
            ) * per_iteration[key]
        estimated["cnt_ms"] = estimated["cycles"] / (freq_mhz * 1000.0)
        estimated["cpi"] = estimated["cycles"] / estimated["retired_inst"]
        estimated["mips"] = freq_mhz * estimated["retired_inst"] / estimated["cycles"]
        estimated["end_to_end_ms"] = estimated["cycles"] / (freq_mhz * 1000.0)
        estimated["l0_hit_rate_pct"] = (
            100.0 * estimated["l0_load_hits"] / estimated["bram_loads"]
        )
        output["estimated_10000"] = estimated
        report_stem = "estimate_10000"
        title = "CoreMark 10000 次外推"

    if args.timing_report:
        timing = parse_timing_report(args.timing_report)
        output["vivado_timing"] = timing
        if "estimated_fmax_mhz" in timing:
            derived["coremark_iterations_per_sec_at_estimated_fmax"] = (
                float(timing["estimated_fmax_mhz"]) * 1_000_000.0 / steady_cycles
            )

    json_path = args.run_dir / f"{report_stem}.json"
    json_path.write_text(
        json.dumps(output, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    rows = [
        ("稳态 cycles/iteration", f"{steady_cycles:,.3f}"),
        ("稳态 retired/iteration", f"{steady_retired:,.3f}"),
        ("稳态 CPI", f"{derived['steady_cpi']:.4f}"),
        ("CoreMark iterations/s", f"{derived['coremark_iterations_per_sec']:.3f}"),
        ("10000 次稳态时间", f"{derived['benchmark_time_ms']:,.3f} ms"),
        (
            f"{source_iterations} 次 CoreMark 计时",
            f"{derived['coremark_counter_time_ms']:,.3f} ms",
        ),
        (
            "观察点/计时误差",
            f"{derived['snapshot_timer_error_ms']:+,.3f} ms "
            f"({derived['snapshot_timer_error_pct']:+.3f}%)",
        ),
        (
            "计时器外推区间",
            f"{derived['counter_extrapolated_lower_ms']:,.3f}–"
            f"{derived['counter_extrapolated_upper_ms']:,.3f} ms",
        ),
        ("稳态 L0 命中率", f"{derived['steady_l0_hit_rate_pct']:.3f}%"),
    ]
    if mode == "full":
        total = output["actual_10000"]
        assert isinstance(total, dict)
        rows.append(("实跑端到端 cycles", fmt_int(float(total["cycles"]))))
        rows.append(
            ("CoreMark 实际计时", f"{float(total['coremark_reported_time_ms']):,.3f} ms")
        )
        rows.append(("实跑端到端时间", f"{float(total['end_to_end_ms']):,.3f} ms"))
    else:
        total = output["estimated_10000"]
        assert isinstance(total, dict)
        rows.append(("外推端到端 cycles", fmt_int(float(total["cycles"]))))
        rows.append(("外推端到端时间", f"{float(total['end_to_end_ms']):,.3f} ms"))

    md = [
        f"# {title}",
        "",
        f"- 固定负载：`{FIXED_TEST}`",
        f"- 输入：同一次 {source_iterations} 次运行的第 {low_iterations}/{high_iterations} 次观察点",
        "- CRC：`e714 / 1fd7 / 8e3a`，PASS",
        f"- 有效性：`{final['validity']}`",
        "",
        "| 指标 | 结果 |",
        "|---|---:|",
    ]
    md.extend(f"| {label} | {value} |" for label, value in rows)
    if args.timing_report:
        timing = output["vivado_timing"]
        assert isinstance(timing, dict)
        md.extend(["", "## Vivado 时序", "", f"- 报告：`{timing['path']}`"])
        md.append(
            "- 时序约束："
            + ("满足" if bool(timing["constraints_met"]) else "未满足")
        )
        if "wns_ns" in timing:
            md.append(f"- WNS：{float(timing['wns_ns']):.3f} ns")
        if "tns_ns" in timing:
            md.append(f"- TNS：{float(timing['tns_ns']):.3f} ns")
        if "target_period_ns" in timing:
            md.append(f"- 目标周期：{float(timing['target_period_ns']):.3f} ns")
        if "estimated_fmax_mhz" in timing:
            md.append(f"- 近似 Fmax：{float(timing['estimated_fmax_mhz']):.3f} MHz")
    if mode != "full":
        md.extend(
            [
                "",
                "> 短测通过三项官方 CRC，但因不足 10 秒不是正式 CoreMark 成绩；",
                "> 本报告是 16 次短测外推，不宣称为 10000 次实跑或官方 CoreMark 成绩。",
            ]
        )
    md.append("")
    md_path = args.run_dir / f"{report_stem}.md"
    md_path.write_text("\n".join(md), encoding="utf-8")
    print(md_path.read_text(encoding="utf-8"))
    print(f"JSON: {json_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
