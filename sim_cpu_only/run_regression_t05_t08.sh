#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

printf '[info] legacy load/hazard entry redirected to trusted memory and pipeline tests\n'
make -C "$ROOT_DIR/verification" run TEST=memory
exec make -C "$ROOT_DIR/verification" run TEST=pipeline
