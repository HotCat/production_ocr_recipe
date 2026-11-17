#!/bin/sh
set -eu
service_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$(dirname -- "$service_dir")")
: "${PADDLE_PDX_CACHE_HOME:=$service_dir/.cache}"
export PADDLE_PDX_CACHE_HOME
cd "$project_dir"
exec "$service_dir/.venv/bin/python" -u -m services.paddleocr_service.server "$@"
