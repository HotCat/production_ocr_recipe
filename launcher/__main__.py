"""Run with python -m launcher from the repository root."""
import argparse
from pathlib import Path
import sys

from .config import ConfigStore, REPOSITORY, default_config_path


def main() -> int:
    parser = argparse.ArgumentParser(description="生产 OCR 启动器 / Production OCR launcher")
    parser.add_argument("--config", type=Path, default=default_config_path())
    parser.add_argument("--repo", type=Path, default=REPOSITORY, help="Application repository root")
    parser.add_argument("--check-config", action="store_true", help="Validate configuration without opening a window")
    args = parser.parse_args()
    if args.check_config:
        try:
            store = ConfigStore(args.config)
            store.load()
        except (OSError, ValueError, TypeError, KeyError) as error:
            print(f"Configuration error: {error}", file=sys.stderr)
            return 1
        print(f"OK: {len(store.data['programs'])} programs; {store.path}")
        return 0
    from PySide6.QtCore import QLockFile
    from PySide6.QtGui import QFont, QFontDatabase
    from PySide6.QtWidgets import QApplication, QMessageBox
    from .ui import LauncherWindow
    app = QApplication(sys.argv[:1])
    app.setApplicationName("Production OCR Launcher")
    app.setOrganizationName("ProductionOCR")
    config_path = args.config.expanduser().resolve()
    try:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        lock = QLockFile(str(config_path) + ".ui.lock")
        lock.setStaleLockTime(0)
        if not lock.tryLock(0):
            QMessageBox.information(None, "启动器已打开", "该配置的启动器已经打开。请使用现有窗口。")
            return 0
        store = ConfigStore(config_path)
        store.load()
    except (OSError, ValueError, TypeError, KeyError) as error:
        QMessageBox.critical(None, "配置文件错误", f"{config_path}\n\n{error}\n\n配置文件已保留，请修正后重新启动。")
        return 1
    font = args.repo / "assets/font/msyhl.ttc"
    if font.is_file():
        font_id = QFontDatabase.addApplicationFont(str(font))
        families = QFontDatabase.applicationFontFamilies(font_id)
        if families:
            app.setFont(QFont(families[0], 11))
    window = LauncherWindow(store, repository=args.repo.resolve())
    window.show()
    result = app.exec()
    lock.unlock()
    return result


if __name__ == "__main__":
    raise SystemExit(main())
