#!/usr/bin/env bash
# Generate specs with the local model and validate them with Syzkaller.
# Usage: ./run.sh [NUM_SPECS]   (default 1; the paper used 1000)
# Results: spec-gen/eval-output/return.txt lists "<spec>,<returncode>";
# 0 means the spec compiled in Syzkaller. Valid specs are copied to
# spec-gen/eval-output/correct-spec/.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NUM=${1:-1}
PY="$ROOT/.venv/bin/python"
# Kernel 6.7 does not build with gcc 15 (Ubuntu's default); use gcc-14.
export KERNEL_CC=gcc-14

cd "$ROOT/spec-gen"
"$PY" gen_spec.py -d analyzer/processed_handlers.json -o spec-output -n "$NUM"
"$PY" eval_spec.py -u -s spec-output/_generated --output-name debug -o eval-output
