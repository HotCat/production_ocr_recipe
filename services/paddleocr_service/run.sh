#!/bin/sh
set -eu
service_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$(dirname -- "$service_dir")")
: "${PADDLE_PDX_CACHE_HOME:=$service_dir/.cache}"
export PADDLE_PDX_CACHE_HOME
: "${PADDLEOCR_LEGACY_MODEL_ROOT:=$PADDLE_PDX_CACHE_HOME/legacy_models}"
export PADDLEOCR_LEGACY_MODEL_ROOT
# Legacy weights are deliberately imported, never silently substituted with a
# different OCR release or fetched while a production application is starting.
for asset in ch_PP-OCRv3_det_infer/inference.pdmodel ch_PP-OCRv3_det_infer/inference.pdiparams en_PP-OCRv3_rec_infer/inference.pdmodel en_PP-OCRv3_rec_infer/inference.pdiparams en_dict.txt; do
  if [ ! -s "$PADDLEOCR_LEGACY_MODEL_ROOT/$asset" ]; then
    echo "Missing legacy OCR asset: $PADDLEOCR_LEGACY_MODEL_ROOT/$asset" >&2
    echo 'Prepare models with: python3 -m services.paddleocr_service.import_legacy_models MODEL_ROOT EN_DICT' >&2
    exit 1
  fi
done
# Prefer a complete local model set, including when starting from the desktop
# or systemd. Fresh installations can still prepare models in the usual way.
if [ -z "${PADDLEOCR_MODEL_ROOT:-}" ]; then
  model_directory="$PADDLE_PDX_CACHE_HOME/official_models"
  have_models=true
  for model in PP-LCNet_x1_0_doc_ori UVDoc PP-LCNet_x1_0_textline_ori PP-OCRv6_medium_det PP-OCRv6_medium_rec; do
    if [ ! -f "$model_directory/$model/inference.yml" ]; then have_models=false; fi
  done
  if "$have_models"; then
    export PADDLEOCR_MODEL_ROOT="$model_directory"
  fi
fi
if [ -n "${PADDLEOCR_MODEL_ROOT:-}" ]; then
  : "${PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK:=True}"
  export PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK
fi
cd "$project_dir"
exec "$service_dir/.venv/bin/python" -u -m services.paddleocr_service.server "$@"
