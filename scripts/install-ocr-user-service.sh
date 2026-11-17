#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
service_unit=${1:-paddleocr.service}
case "$service_unit" in
  paddleocr.service|production-paddleocr.service) ;;
  *) echo 'Usage: scripts/install-ocr-user-service.sh [paddleocr.service|production-paddleocr.service]' >&2; exit 2 ;;
esac
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$unit_dir"
temporary_unit=$(mktemp "$unit_dir/.paddleocr-unit.XXXXXX")
trap 'rm -f -- "$temporary_unit"' EXIT HUP INT TERM
cat > "$temporary_unit" <<UNIT
[Unit]
Description=Shared production PaddleOCR ZeroMQ service
After=network.target

[Service]
Type=exec
WorkingDirectory=$repo_dir
ExecStart="$repo_dir/services/paddleocr_service/run.sh"
Environment=PADDLEOCR_BIND=tcp://127.0.0.1:5555
Environment=PADDLEOCR_DEVICE=cpu
Restart=on-failure
RestartSec=5
TimeoutStopSec=20

[Install]
WantedBy=default.target
UNIT
if [ -f "$unit_dir/$service_unit" ] && ! cmp -s "$temporary_unit" "$unit_dir/$service_unit"; then
  backup_dir="${XDG_STATE_HOME:-$HOME/.local/state}/production-ocr-service/unit-backups"
  mkdir -p "$backup_dir"
  backup_file="$backup_dir/$service_unit.$(date +%Y%m%d-%H%M%S)"
  cp -p "$unit_dir/$service_unit" "$backup_file"
  printf 'Previous unit saved: %s\n' "$backup_file"
fi
install -m 644 "$temporary_unit" "$unit_dir/$service_unit"
systemctl --user daemon-reload
printf 'Installed %s. This does not start or restart it.\n' "$service_unit"
printf 'To activate after checking endpoint availability: systemctl --user enable --now %s\n' "$service_unit"
printf 'To apply changes to an already running unit: systemctl --user restart %s\n' "$service_unit"
