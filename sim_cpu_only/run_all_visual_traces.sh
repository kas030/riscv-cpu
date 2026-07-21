#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TRACE_ROOT="$REPO_DIR/site/public/generated/cpu-visualizer/traces"

make -C "$REPO_DIR/vivado/tests" t03_branch t05_load_store t08_load_use t09_branch_hazard t18_m_ext_basic t19_zicsr_trap visualizer_microarchitecture
node "$REPO_DIR/vivado/tests/visualizer/build_images.mjs"
node "$REPO_DIR/vivado/tests/visualizer/build_lane1_memory.mjs"

for scenario in t03_branch t05_load_store t08_load_use t09_branch_hazard t18_m_ext_basic t19_zicsr_trap visualizer_isa_coverage visualizer_lane1_memory visualizer_microarchitecture; do
    "$SCRIPT_DIR/run_visual_trace.sh" \
        "$REPO_DIR/vivado/tests/build/${scenario}.coe" \
        "$TRACE_ROOT/$scenario"
done

node "$REPO_DIR/tools/cpu_visualizer/validate_manifest.mjs"
node "$REPO_DIR/site/scripts/sync-visualizer-data.mjs"
echo "published 9 PASS visual traces to $TRACE_ROOT"
