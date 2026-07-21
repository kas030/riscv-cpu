#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
image=${1:-"$REPO_DIR/vivado/tests/build/t08_load_use.coe"}
if [[ "$image" != /* ]]; then image="$PWD/$image"; fi
work_dir=$(mktemp -d /tmp/cpu-visual-trace-determinism.XXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT

"$SCRIPT_DIR/run_visual_trace.sh" "$image" "$work_dir/run-a"
"$SCRIPT_DIR/run_visual_trace.sh" "$image" "$work_dir/run-b"
hash_a=$(node -p "require('$work_dir/run-a/metadata.json').functionalSha256")
hash_b=$(node -p "require('$work_dir/run-b/metadata.json').functionalSha256")
if [[ "$hash_a" != "$hash_b" ]]; then
    echo "visual trace is not deterministic: $hash_a != $hash_b" >&2
    exit 1
fi
echo "visual trace deterministic functional sha256: $hash_a"
