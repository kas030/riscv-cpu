#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_BIN=/home/mph/.local/micromamba/envs/hdl/bin

cd "$SCRIPT_DIR"

stop_ns=""
for arg in "$@"; do
    case "$arg" in
        STOP_NS=*)
            stop_ns=${arg#STOP_NS=}
            ;;
    esac
done

if [[ -z "$stop_ns" && -f config.mk ]]; then
    stop_ns=$(sed -n 's/^STOP_NS[[:space:]]*:=[[:space:]]*//p' config.mk | tail -n 1 | tr -d '[:space:]')
fi

if [[ -z "$stop_ns" ]]; then
    stop_ns=400000000
fi

exec 3>&1 4>&2
TIMEFORMAT='%3R %3U %3S'
time_output=$({
    time "$ENV_BIN/make" sim-verilator "$@" 1>&3 2>&4
} 2>&1)
exec 3>&- 4>&-

read -r wall_s user_s sys_s <<<"$time_output"

python3 - "$stop_ns" "$wall_s" "$user_s" "$sys_s" <<'PY'
import sys

stop_ns = int(sys.argv[1])
wall_s = float(sys.argv[2])
user_s = float(sys.argv[3])
sys_s = float(sys.argv[4])

cpu_s = user_s + sys_s
sim_ms = stop_ns / 1_000_000
speed = sim_ms / wall_s if wall_s > 0 else 0.0

print(f" wall_time_s       : {wall_s:.3f}")
print(f" cpu_time_s        : {cpu_s:.3f}")
print(f" sim_speed         : {speed:.3f} ms/s")
PY
