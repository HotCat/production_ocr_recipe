#!/bin/sh
# Real Haskell SQLite writes + launcher history/clock checks; no camera or PLC.
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d /tmp/production-log-tests.XXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
cd "$repo_dir/apps/Barcode+Sequence"
export STACK_YAML="$PWD/stack.yaml"
if [ -f stack.local.yaml ]; then export STACK_YAML="$PWD/stack.local.yaml"; fi
stack ghc -- -threaded -package sqlite-simple -package text -package containers \
  -package unix -package time -package directory -package filepath -package template-haskell \
  -i../../shared/production-log -outputdir "$test_dir" \
  ../../shared/production-log/tests/ProductionLogProbe.hs -o "$test_dir/probe"
cd "$repo_dir"
export PRODUCTION_LOG_PROBE="$test_dir/probe"
exec_python=${OCR_LAUNCHER_PYTHON:-"$repo_dir/launcher/.venv/bin/python"}
"$exec_python" -m unittest launcher.tests.test_production -v
