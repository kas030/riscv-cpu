#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
BSP_DIR="$ROOT_DIR/rt-thread/bsp/mycpu"
BUILD_DIR="$SCRIPT_DIR/.build"
RUNNER="$ROOT_DIR/sim_cpu_only/run_verilator.sh"
TERMINAL_TEE="$ROOT_DIR/sim_cpu_only/terminal_tee.py"
ANALYZER="$SCRIPT_DIR/tools/analyze_coremark_run.py"
PROTECTED_MANIFEST="$SCRIPT_DIR/protected_sources.sha256"
FIXED_TEST="rt-thread/coremark-2k-performance"
TARGET_ITERATIONS=10000
DEFAULT_PROGRESS_NS=100000000

usage() {
    printf '%s\n' \
        '用法：' \
        '  ./coremark-perf/run_coremark_verilator.sh estimate [--tag TAG] [NAME=VALUE ...]' \
        '  ./coremark-perf/run_coremark_verilator.sh quick    [--tag TAG] [NAME=VALUE ...]' \
        '  ./coremark-perf/run_coremark_verilator.sh stage    [--tag TAG] [NAME=VALUE ...]' \
        '  ./coremark-perf/run_coremark_verilator.sh full     [--tag TAG] [NAME=VALUE ...]' \
        '' \
        'estimate=一次2次运行，以1/2观察点外推10000次；quick=1次；stage=16次；full=实跑10000次。' \
        'NAME=VALUE 传给 CPU-only Makefile；CROSS 请用环境变量设置。'
}

die() {
    printf '错误：%s\n' "$*" >&2
    exit 2
}

mode=${1:-}
if [[ -z "$mode" || "$mode" == -h || "$mode" == --help ]]; then
    usage
    exit 0
fi
shift

case "$mode" in
    estimate)
        iterations=2
        snapshot_low=1
        snapshot_high=2
        require_valid=0
        default_stop_ns=30000000
        ;;
    quick)
        iterations=1
        snapshot_low=1
        snapshot_high=1
        require_valid=0
        default_stop_ns=25000000
        ;;
    stage)
        iterations=16
        snapshot_low=8
        snapshot_high=16
        require_valid=0
        default_stop_ns=100000000
        ;;
    full)
        iterations=$TARGET_ITERATIONS
        snapshot_low=5000
        snapshot_high=$TARGET_ITERATIONS
        require_valid=1
        default_stop_ns=26000000000
        ;;
    *)
        die "未知模式 $mode"
        ;;
esac

tag=''
overrides=()
has_stop=0
has_progress=0
while (($# > 0)); do
    case "$1" in
        --tag)
            (($# >= 2)) || die '--tag 缺少参数'
            tag=$2
            shift 2
            ;;
        *=*)
            [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || die "无效覆盖参数 $1"
            [[ "$1" == STOP_NS=* ]] && has_stop=1
            [[ "$1" == PROGRESS_NS=* ]] && has_progress=1
            case "$1" in
                COREMARK_PERF=*|COREMARK_ITERATIONS=*|COREMARK_SNAPSHOT_LOW=*|COREMARK_SNAPSHOT_HIGH=*|COREMARK_ENTRY_PC=*|COREMARK_REQUIRE_VALID=*)
                    die "参数 $1 由运行模式固定，不能覆盖"
                    ;;
            esac
            overrides+=("$1")
            shift
            ;;
        *)
            die "未知参数 $1"
            ;;
    esac
done

if [[ -z "$tag" ]]; then
    tag=$(date '+%Y%m%d-%H%M%S')
fi
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die 'TAG 只能包含字母、数字、点、下划线和连字符'
((has_stop)) || overrides+=("STOP_NS=$default_stop_ns")
((has_progress)) || overrides+=("PROGRESS_NS=$DEFAULT_PROGRESS_NS")

if [[ -n "${CROSS:-}" ]]; then
    cross=$CROSS
elif command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then
    cross=riscv32-unknown-elf-
elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
    cross=riscv64-unknown-elf-
else
    die '未找到 RISC-V bare-metal GCC；请设置 CROSS 环境变量'
fi
command -v "${cross}gcc" >/dev/null 2>&1 || die "找不到 ${cross}gcc"
command -v "${cross}nm" >/dev/null 2>&1 || die "找不到 ${cross}nm"
command -v "${cross}objdump" >/dev/null 2>&1 || die "找不到 ${cross}objdump"

printf '检查 CoreMark 核心文件保护清单...\n'
(cd "$ROOT_DIR" && sha256sum --check --strict "$PROTECTED_MANIFEST")

printf '构建 RT-Thread/CoreMark 固件（报告目标迭代数=%s）...\n' "$TARGET_ITERATIONS"
make -C "$BSP_DIR" BUILD="$BUILD_DIR" CROSS="$cross" \
    COREMARK_ITERATIONS="$TARGET_ITERATIONS" COREMARK_AUTORUN=1 \
    COREMARK_RUN_ITERATIONS="$iterations" all

elf="$BUILD_DIR/rtthread.elf"
irom="$BUILD_DIR/rtthread.irom.coe"
bram="$BUILD_DIR/rtthread.bram.coe"
[[ -f "$elf" && -f "$irom" && -f "$bram" ]] || die 'RT-Thread 构建产物不完整'

mapfile -t symbol_rows < <("${cross}nm" -n "$elf" | awk '$2 ~ /^[Tt]$/ && $3 == "core_bench_list" {print $1}')
((${#symbol_rows[@]} == 1)) || die "core_bench_list 符号数量异常：${#symbol_rows[@]}"
entry_hex=${symbol_rows[0]#0x}
[[ "$entry_hex" =~ ^[0-9A-Fa-f]{8}$ ]] || die "core_bench_list 地址格式异常：$entry_hex"
entry_value=$((16#$entry_hex))
((entry_value >= 16#80000000 && entry_value < 16#80010000 && (entry_value & 3) == 0)) || \
    die "core_bench_list 不在有效 IROM 中：0x$entry_hex"

run_dir="$SCRIPT_DIR/results/$tag-$mode"
case "$run_dir" in
    "$SCRIPT_DIR/results/"*"-$mode") ;;
    *) die "拒绝清理非预期结果目录：$run_dir" ;;
esac
if [[ -e "$run_dir" ]]; then
    printf '覆盖旧结果：%s\n' "$run_dir"
    rm -rf -- "$run_dir"
fi
mkdir -p "$run_dir/firmware"

cp -- "$elf" "$run_dir/firmware/rtthread.elf"
cp -- "$irom" "$run_dir/firmware/rtthread.irom.coe"
cp -- "$bram" "$run_dir/firmware/rtthread.bram.coe"
cp -- "$PROTECTED_MANIFEST" "$run_dir/protected_sources.sha256"
"${cross}objdump" -d "$elf" > "$run_dir/firmware/rtthread.disasm"

printf 'fixed_test=%s\nmode=%s\ntag=%s\ntarget_iterations=%s\niterations=%s\nsnapshot_low=%s\nsnapshot_high=%s\nrequire_valid=%s\ncoremark_entry_pc=0x%s\ncross=%s\n' \
    "$FIXED_TEST" "$mode" "$tag" "$TARGET_ITERATIONS" "$iterations" \
    "$snapshot_low" "$snapshot_high" "$require_valid" "$entry_hex" "$cross" \
    > "$run_dir/run.meta"
for override in "${overrides[@]}"; do
    printf 'override=%s\n' "$override" >> "$run_dir/run.meta"
done

(cd "$ROOT_DIR" && sha256sum --check --strict "$PROTECTED_MANIFEST")
find "$ROOT_DIR/rtl" -type f \( -name '*.v' -o -name '*.sv' \) -print0 |
    LC_ALL=C sort -z |
    xargs -0 sha256sum > "$run_dir/rtl.sha256"
sha256sum "$BSP_DIR/coremark/core_portme.c" \
          "$BSP_DIR/coremark/core_portme.h" \
          "$BSP_DIR/coremark_cmd.c" \
          "$BSP_DIR/main.c" \
          "$BSP_DIR/Makefile" > "$run_dir/port.sha256"
sha256sum "$run_dir/firmware/"* > "$run_dir/firmware.sha256"

log="$run_dir/verilator_i${iterations}.log"
printf '结果目录：%s\n' "$run_dir"
printf 'core_bench_list：0x%s\n' "$entry_hex"
printf '\n=== Verilator: CoreMark iterations=%s ===\n' "$iterations"
set +e
"$RUNNER" \
    "IROM_COE=$run_dir/firmware/rtthread.irom.coe" \
    "BRAM_COE=$run_dir/firmware/rtthread.bram.coe" \
    PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF \
    CPU_FREQ_MHZ=200.0 TRACE=0 COREMARK_PERF=1 \
    "COREMARK_ITERATIONS=$iterations" \
    "COREMARK_SNAPSHOT_LOW=$snapshot_low" \
    "COREMARK_SNAPSHOT_HIGH=$snapshot_high" \
    "COREMARK_ENTRY_PC=$entry_hex" \
    "COREMARK_REQUIRE_VALID=$require_valid" \
    "${overrides[@]}" 2>&1 | python3 "$TERMINAL_TEE" "$log"
runner_status=${PIPESTATUS[0]}
set -e

if ((runner_status != 0)) || ! grep -Fq '>>> [PASS]' "$log"; then
    printf 'CoreMark 仿真失败，日志：%s\n' "$log" >&2
    exit 1
fi
grep -Fq '>>> [COREMARK_CRC] crclist=e714 crcmatrix=1fd7 crcstate=8e3a' "$log" || \
    die '日志缺少三项 CRC 通过标记'
grep -Fq ">>> [COREMARK_SNAPSHOT] iterations=$snapshot_low" "$log" || \
    die "日志缺少第 $snapshot_low 次观察点"
grep -Fq ">>> [COREMARK_SNAPSHOT] iterations=$snapshot_high" "$log" || \
    die "日志缺少第 $snapshot_high 次观察点"

if [[ "$mode" == estimate || "$mode" == stage || "$mode" == full ]]; then
    python3 "$ANALYZER" "$run_dir"
fi

printf '结果目录：%s\n' "$run_dir"
