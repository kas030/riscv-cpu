#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <image.coe|mif|mem> <output-dir> [make VAR=value ...]" >&2
    exit 2
fi

image=$1
output_dir=$2
shift 2
if [[ "$image" != /* ]]; then image="$PWD/$image"; fi
if [[ "$output_dir" != /* ]]; then output_dir="$PWD/$output_dir"; fi
mkdir -p "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
scenario_id=$(basename -- "$output_dir")
raw_path="$SCRIPT_DIR/build/${scenario_id}.raw.jsonl"
sim_log="$SCRIPT_DIR/build/${scenario_id}.visual-sim.log"
bram_image="$REPO_DIR/sim/coe/mext/dram.coe"
for argument in "$@"; do
    if [[ "$argument" == BRAM_COE=* ]]; then bram_image=${argument#BRAM_COE=}; fi
done
if [[ "$bram_image" != /* ]]; then bram_image="$SCRIPT_DIR/$bram_image"; fi

title=$scenario_id
category=directed
description="由当前 RTL 的 CPU-only Verilator 仿真生成。"
if [[ -f "$SCRIPT_DIR/visual_trace/scenarios.json" ]]; then
    mapfile -t scenario_fields < <(node - "$SCRIPT_DIR/visual_trace/scenarios.json" "$scenario_id" <<'NODE'
const fs = require("node:fs");
const [file, id] = process.argv.slice(2);
const item = JSON.parse(fs.readFileSync(file, "utf8")).scenarios.find((entry) => entry.id === id);
if (item) console.log([item.title, item.category, item.description].join("\n"));
NODE
    )
    if [[ ${#scenario_fields[@]} -ge 3 ]]; then
        title=${scenario_fields[0]}
        category=${scenario_fields[1]}
        description=${scenario_fields[2]}
    fi
fi

cd "$SCRIPT_DIR"
make visual-trace \
    IROM_COE="$image" \
    VISUAL_TRACE_OUT="$raw_path" \
    VISUAL_SIM_LOG="$sim_log" \
    EXPECTED_LED=C0DEC0DE PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF \
    STOP_NS=10000000 PROGRESS_NS=0 QUIET=1 "$@"

node "$REPO_DIR/tools/cpu_visualizer/build_trace_index.mjs" \
    --raw="$raw_path" \
    --out="$output_dir" \
    --image="$image" \
    --bram="$bram_image" \
    --sim-log="$sim_log" \
    --id="$scenario_id" \
    --title="$title" \
    --category="$category" \
    --description="$description"

node "$REPO_DIR/tools/cpu_visualizer/reference_compare.mjs" \
    --image="$image" \
    --bram="$bram_image" \
    --trace="$output_dir"
