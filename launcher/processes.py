"""Linux process supervision with kernel locks that outlive the launcher UI."""
from __future__ import annotations

import argparse
import codecs
import fcntl
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

from .config import atomic_json
from .production import ClockGuard, ClockError, production_directory


class AlreadyRunning(RuntimeError):
    pass


def default_state_directory() -> Path:
    override = os.environ.get("PRODUCTION_OCR_LAUNCHER_STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "production-ocr-launcher"


class ProcessManager:
    def __init__(self, directory: Path | None = None, production_dir: Path | None = None):
        self.directory = (directory or default_state_directory()).resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.children: list[subprocess.Popen] = []
        self.production_directory = (production_dir or production_directory()).resolve()
        self._clock = None

    def clock_status(self, persist: bool = False) -> dict:
        try:
            if self._clock is None:
                self._clock = ClockGuard(self.production_directory)
            return self._clock.check(persist=True) if persist else self._clock.observe()
        except (OSError, sqlite3.Error) as error:
            raise ClockError(f"无法保存生产时间，已禁止启动：{error}") from error

    def paths(self, key: str) -> tuple[Path, Path, Path]:
        digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
        return tuple(self.directory / (digest + suffix) for suffix in (".lock", ".json", ".log"))

    def status(self, key: str) -> dict:
        lock, record, log = self.paths(key)
        with lock.open("a+b") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                busy = False
            except BlockingIOError:
                busy = True
            try:
                state = json.loads(record.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                state = {}
        self.children = [child for child in self.children if child.poll() is None]
        state["running"] = busy
        state["log"] = str(log)
        if busy:
            if state.get("state") not in ("starting", "running"):
                state["state"] = "starting"
        elif state.get("state") in ("starting", "running"):
            state.update(state="stopped", message="进程已结束（监控进程意外退出）")
        else:
            state.setdefault("state", "ready")
        return state

    def launch(self, key: str, spec: dict) -> None:
        self.clock_status(persist=True)
        # Every managed child shares the same protected time database and log root.
        spec = dict(spec, environment=dict(spec.get("environment", {}),
                    OCR_PRODUCTION_LOG_DIR=str(self.production_directory)))
        lock, record, log = self.paths(key)
        descriptor = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        request = None
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise AlreadyRunning("该程序已经运行，请先关闭它的窗口。") from error
            directory = Path(spec["cwd"])
            if not directory.is_dir():
                raise ValueError(f"工作目录不存在: {directory}")
            executable = spec["command"][0]
            if "/" in executable:
                target = Path(executable) if Path(executable).is_absolute() else directory / executable
                if not target.is_file() or not os.access(target, os.X_OK):
                    raise ValueError(f"程序不存在或不可执行: {target}\n请先编译程序，或编辑程序路径。")
            elif shutil.which(executable, path=spec.get("environment", {}).get("PATH", os.environ.get("PATH"))) is None:
                raise ValueError(f"找不到命令: {executable}")
            initial = {"state": "starting", "name": spec["name"], "started_at": time.time(),
                       "command": spec["command"], "cwd": spec["cwd"]}
            # Keep the previous exit information if no new process can be created.
            atomic_json(record, initial)
            fd, filename = tempfile.mkstemp(prefix="request-", suffix=".json", dir=self.directory)
            request = Path(filename)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump({"spec": spec, "record": str(record), "log": str(log), "initial": initial}, stream)
            child = subprocess.Popen(
                [sys.executable, "-m", "launcher.processes", "--supervise", str(request), "--lock-fd", str(descriptor)],
                cwd=Path(__file__).resolve().parents[1], stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True, close_fds=True, pass_fds=(descriptor,),
            )
            self.children.append(child)
            # Keep ownership until the detached supervisor finishes, even when a
            # window/manager is discarded while its application is still running.
            threading.Thread(target=child.wait, daemon=True, name="ocr-supervisor-reaper").start()
        except AlreadyRunning:
            raise
        except Exception as error:
            if request is not None:
                request.unlink(missing_ok=True)
            if 'initial' in locals():
                atomic_json(record, dict(initial, state="failed", message=str(error)))
            raise
        finally:
            # Do not LOCK_UN here: supervisor and application inherit this open
            # file description. Closing only our copy preserves their lock.
            os.close(descriptor)

    def log_tail(self, key: str, maximum: int = 65536) -> str:
        log = self.paths(key)[2]
        try:
            with log.open("rb") as stream:
                stream.seek(0, os.SEEK_END)
                stream.seek(max(0, stream.tell() - maximum))
                return stream.read().decode("utf-8", errors="replace")
        except FileNotFoundError:
            return ""


def supervise(request: Path, descriptor: int) -> int:
    payload = json.loads(request.read_text(encoding="utf-8"))
    request.unlink(missing_ok=True)
    spec, initial = payload["spec"], payload["initial"]
    record, log_path = Path(payload["record"]), Path(payload["log"])
    handler = RotatingFileHandler(log_path, maxBytes=2 * 1024 * 1024, backupCount=2, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger = logging.getLogger("supervisor")
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)
    # Leave previous logs available, marking each run with its actual timestamp.
    logger.info("\n=== %s | %s ===", spec["name"], time.strftime("%Y-%m-%d %H:%M:%S"))
    try:
        ClockGuard(Path(spec["environment"]["OCR_PRODUCTION_LOG_DIR"])).check(persist=True)
        environment = dict(os.environ, **spec.get("environment", {}))
        child = subprocess.Popen(spec["command"], cwd=spec["cwd"], env=environment,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, bufsize=0, close_fds=True,
                                 pass_fds=(descriptor,))
        atomic_json(record, dict(initial, state="running", pid=child.pid, supervisor_pid=os.getpid(),
                                 environment=spec.get("environment", {})))
        def collect():
            decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
            while True:
                chunk = child.stdout.read(65536)
                if not chunk:
                    break
                logger.info("%s", decoder.decode(chunk))
            remaining = decoder.decode(b"", final=True)
            if remaining:
                logger.info("%s", remaining)
        reader = threading.Thread(target=collect, daemon=True)
        reader.start()
        exit_code = child.wait()
        reader.join(timeout=2)
        logger.info("=== 程序结束，退出码 %s ===", exit_code)
        atomic_json(record, dict(initial, state="exited", exit_code=exit_code, ended_at=time.time()))
        return 0
    except Exception as error:
        logger.exception("启动/监控失败")
        atomic_json(record, dict(initial, state="failed", message=str(error), ended_at=time.time()))
        return 1
    finally:
        handler.close()
        # A surviving application still owns its inherited copy after a monitor failure.
        os.close(descriptor)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--supervise", type=Path, required=True)
    parser.add_argument("--lock-fd", type=int, required=True)
    args = parser.parse_args()
    raise SystemExit(supervise(args.supervise, args.lock_fd))
