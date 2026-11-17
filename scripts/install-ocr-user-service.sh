#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$unit_dir"
# Use a distinct unit name; do not replace another client's service.
cat > "$unit_dir/production-paddleocr.service" <<UNIT
[Unit]
Description=Production OCR shared PaddleOCR service
After=network.target
[Service]
Type=exec
WorkingDirectory="$repo_dir"
ExecStart="$repo_dir/services/paddleocr_service/run.sh"
Environment=PADDLEOCR_BIND=tcp://127.0.0.1:5555
Environment=PADDLEOCR_DEVICE=cpu
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
printf '%s\n' 'Unit installed. Ensure port 5555 is free before enabling production-paddleocr.service.'
