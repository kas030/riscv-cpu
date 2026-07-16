#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

printf '[info] legacy regression entry redirected to verification/\n'
exec make -C "$ROOT_DIR/verification" regression
