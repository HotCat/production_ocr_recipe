# Shared OCR service migration

Completed on 2026-11-17 (Asia/Shanghai). The canonical runtime is now:

```text
/home/hotcat/Downloads/production_ocr_recipe/services/paddleocr_service/
  server.py
  run.sh
  .venv/                    Relocated Python/PaddleOCR environment
  .cache/official_models/   All five tested models
```

The existing user unit `paddleocr.service` remains enabled, using this
repository as its working directory. The endpoint is unchanged at
`tcp://127.0.0.1:5555`; the launcher and five clients need no endpoint edits.
There is one shared model pipeline and requests are still processed serially.
No second permanent OCR service was created.

```sh
systemctl --user status paddleocr.service
systemctl --user restart paddleocr.service
journalctl --user -u paddleocr.service -f
```

The old checkout under `LearnOpenGL.hs/GettingStarted/Engraving+Sequence` was
retained as a backup. The launcher and migrated OCR service no longer depend
on that checkout. The original systemd unit was backed up under
`~/.local/state/production-ocr-service/unit-backups/`.

The Python base installation under `~/anaconda3` and externally installed
camera/motion SDKs remain external requirements. Moving the applications does
not move those system dependencies. The environment and model weights are
ignored by Git; only their source, requirements and setup instructions belong
in the source repository.

Validation completed:

- Repaired 33 virtualenv entry-point/configuration files; no active virtualenv
  paths point to the old application. No editable packages or model symlinks
  depended on that application.
- Verified SHA-256 matches for all 99 model files.
- Python imports and `pip check` passed; all four service unittest groups
  passed, including concurrent clients and serial engine access.
- Launched a temporary service with the entire old application hidden in a
  private mount namespace; health, Chinese text and simultaneous independent
  OCR clients passed. The host's old directory was unaffected.
- Systemd unit validation passed. After restart, the original enabled unit
  reported `active/running` with its executable and working directory in this
  repository. Health, Chinese text and concurrent OCR clients passed again at
  port 5555.
- The compiled `Engraving+Compare` Haskell client accepted the generated
  `客服电话：96008` label through the migrated service. Active process paths
  and mapped libraries contained no dependency on the old application.

The service runner prefers the complete local model set and skips remote model
host checks. Reinstall its unit with `scripts/install-ocr-user-service.sh`;
that helper backs up a changed unit and reloads systemd, but deliberately
leaves starting/restarting to the operator.
