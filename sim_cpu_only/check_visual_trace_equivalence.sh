#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
image=${1:-"$REPO_DIR/vivado/tests/build/t08_load_use.coe"}
if [[ "$image" != /* ]]; then image="$PWD/$image"; fi

on_log="$SCRIPT_DIR/build/equivalence-trace-on.log"
off_log="$SCRIPT_DIR/build/equivalence-trace-off.log"
raw="$SCRIPT_DIR/build/equivalence.raw.jsonl"
common=(IROM_COE="$image" EXPECTED_LED=C0DEC0DE PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF STOP_NS=10000000 PROGRESS_NS=0 QUIET=1)

make -C "$SCRIPT_DIR" visual-trace "${common[@]}" VISUAL_TRACE_OUT="$raw" VISUAL_SIM_LOG="$on_log"
make -C "$SCRIPT_DIR" visual-trace-disabled "${common[@]}" VISUAL_DISABLED_LOG="$off_log"
node "$REPO_DIR/tools/cpu_visualizer/compare_sim_logs.mjs" "$on_log" "$off_log"
