#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPORT_DIR=${REPORT_DIR:-"$SCRIPT_DIR/build/regression"}
REPORT_FILE=${REPORT_FILE:-"$REPORT_DIR/report.md"}

DEFAULT_STOP_NS=${DEFAULT_STOP_NS:-1000000000}
TEST_STOP_NS=${TEST_STOP_NS:-20000000}
PERF_STOP_NS=${PERF_STOP_NS:-200000000}
PROGRESS_NS=${PROGRESS_NS:-0}

PASS_LED=${PASS_LED:-C0DEC0DE}
FAIL_LED=${FAIL_LED:-DEADBEEF}
EXPECTED_LED=${EXPECTED_LED:-C0DEC0DE}
BRAM_COE=${BRAM_COE:-../sim/coe/bram.coe}

mkdir -p "$REPORT_DIR"

names=(
    default
    t03_branch
    t09_branch_hazard
    t19_zicsr_trap
    perf_test
)

iroms=(
    ../sim/coe/irom.coe
    ../vivado/tests/build/t03_branch.coe
    ../vivado/tests/build/t09_branch_hazard.coe
    ../vivado/tests/build/t19_zicsr_trap.coe
    ../vivado/tests/build/perf_test.coe
)

stop_times=(
    "$DEFAULT_STOP_NS"
    "$TEST_STOP_NS"
    "$TEST_STOP_NS"
    "$TEST_STOP_NS"
    "$PERF_STOP_NS"
)

expected_args=(
    ""
    "EXPECTED_LED=$EXPECTED_LED"
    "EXPECTED_LED=$EXPECTED_LED"
    "EXPECTED_LED=$EXPECTED_LED"
    "EXPECTED_LED=$EXPECTED_LED"
)

extract_value() {
    local key=$1
    local log_file=$2
    awk -F: -v key="$key" '
        $1 ~ key {
            sub(/^[[:space:]]+/, "", $2)
            sub(/[[:space:]]+$/, "", $2)
            print $2
            exit
        }
    ' "$log_file"
}

extract_status() {
    local log_file=$1
    if grep -q '>>> \[PASS\]' "$log_file"; then
        printf 'PASS'
    elif grep -q '>>> \[FAIL\]' "$log_file"; then
        printf 'FAIL'
    else
        printf 'ERROR'
    fi
}

{
    printf '# Verilator Regression Report\n\n'
    printf -- '- generated_at: `%s`\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf -- '- default_stop_ns: `%s`\n' "$DEFAULT_STOP_NS"
    printf -- '- test_stop_ns: `%s`\n' "$TEST_STOP_NS"
    printf -- '- perf_stop_ns: `%s`\n\n' "$PERF_STOP_NS"
    printf '| test | result | stop_reason | virtual_led | cycles | pc | sim_time_ns | log |\n'
    printf '| --- | --- | --- | --- | ---: | --- | ---: | --- |\n'
} > "$REPORT_FILE"

overall=0

for idx in "${!names[@]}"; do
    name=${names[$idx]}
    irom=${iroms[$idx]}
    stop_ns=${stop_times[$idx]}
    expected_arg=${expected_args[$idx]}
    log_file="$REPORT_DIR/$name.log"
    raw_log_file="$REPORT_DIR/$name.raw.log"

    printf '[run] %s\n' "$name"

    if [[ ! -f "$SCRIPT_DIR/$irom" ]]; then
        printf '[skip] missing image: %s\n' "$irom" | tee "$log_file"
        printf '| `%s` | SKIP | missing image | - | - | - | - | [%s](%s) |\n' \
            "$name" "$(basename "$log_file")" "regression/$(basename "$log_file")" >> "$REPORT_FILE"
        overall=1
        continue
    fi

    cmd=(
        "$SCRIPT_DIR/run_verilator.sh"
        "IROM_COE=$irom"
        "BRAM_COE=$BRAM_COE"
        "STOP_NS=$stop_ns"
        "PROGRESS_NS=$PROGRESS_NS"
    )

    if [[ "$name" != "default" ]]; then
        cmd+=("PASS_LED=$PASS_LED" "FAIL_LED=$FAIL_LED")
    fi

    if [[ -n "$expected_arg" ]]; then
        cmd+=("$expected_arg")
    fi

    if ! "${cmd[@]}" > "$raw_log_file" 2>&1; then
        tr -d '\000' < "$raw_log_file" > "$log_file"
        status=ERROR
        overall=1
    else
        tr -d '\000' < "$raw_log_file" > "$log_file"
        status=$(extract_status "$log_file")
        if [[ "$status" != "PASS" ]]; then
            overall=1
        fi
    fi
    rm -f "$raw_log_file"

    stop_reason=$(extract_value 'stop_reason' "$log_file")
    virtual_led=$(extract_value 'virtual_led' "$log_file" | awk '{print $1}')
    cycles=$(extract_value 'cycles' "$log_file")
    pc=$(extract_value 'pc' "$log_file")
    sim_time_ns=$(extract_value 'sim_time_ns' "$log_file")

    stop_reason=${stop_reason:--}
    virtual_led=${virtual_led:--}
    cycles=${cycles:--}
    pc=${pc:--}
    sim_time_ns=${sim_time_ns:--}

    printf '| `%s` | %s | `%s` | `%s` | %s | `%s` | %s | [%s](%s) |\n' \
        "$name" "$status" "$stop_reason" "$virtual_led" "$cycles" "$pc" "$sim_time_ns" \
        "$(basename "$log_file")" "regression/$(basename "$log_file")" >> "$REPORT_FILE"
done

printf '\nReport: %s\n' "$REPORT_FILE"
exit "$overall"
