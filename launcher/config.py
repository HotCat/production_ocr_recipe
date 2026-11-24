"""Versioned configuration and extensible, environment-backed parameters."""
from __future__ import annotations

import copy
import ipaddress
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

REPOSITORY = Path(__file__).resolve().parents[1]
IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
ENVIRONMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
TYPES = {"string", "choice", "integer", "boolean"}
LEGACY_OCR_PROGRAMS = {
    "Barcode+Sequence", "Barcode+Sequence+Barcode",
    "Barcode+Sequence+Engraving", "Engraving+Sequence",
}


def atomic_json(path: Path, data: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def default_config_path() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "production-ocr-launcher/config.json"


def choices_for(config: dict, definition: dict) -> list[str]:
    return config["cameras"] if definition.get("choices_from") == "cameras" else definition.get("choices", [])


def parameter_value(config: dict, program: dict, key: str):
    return program.get("values", {}).get(key, config["parameters"][key].get("default", ""))


def validate_value(config: dict, key: str, value):
    definition = config["parameters"][key]
    label = definition["label"]
    kind = definition["type"]
    if kind == "boolean":
        if type(value) is not bool:
            raise ValueError(f"{label} 必须是开关值")
    elif kind == "integer":
        if type(value) is not int or not definition.get("minimum", -2147483648) <= value <= definition.get("maximum", 2147483647):
            raise ValueError(f"{label} 超出允许范围")
    else:
        if not isinstance(value, str) or "\0" in value or (definition.get("required", True) and not value.strip()):
            raise ValueError(f"请填写 {label}")
        if kind == "choice" and value not in choices_for(config, definition):
            raise ValueError(f"{label} 的值不在下拉列表中")
        if definition.get("format") == "ipv4":
            try:
                ipaddress.IPv4Address(value)
            except ipaddress.AddressValueError as error:
                raise ValueError(f"{label} 必须是有效的 IPv4 地址") from error
    return value


def validate_config(config: dict) -> None:
    if not isinstance(config, dict) or config.get("schema_version") != 1:
        raise ValueError("不支持的配置文件版本")
    if type(config.get("debug_mode", False)) is not bool:
        raise ValueError("debug_mode 必须是 true 或 false")
    cameras = config.get("cameras")
    if not isinstance(cameras, list) or not cameras or any(not isinstance(c, str) or not c.strip() or "\0" in c for c in cameras) or len(set(cameras)) != len(cameras):
        raise ValueError("相机名称列表不能为空，且不能重复")
    parameters = config.get("parameters")
    if not isinstance(parameters, dict):
        raise ValueError("parameters 必须是参数定义对象")
    for key, definition in parameters.items():
        if not IDENTIFIER.fullmatch(key) or not isinstance(definition, dict) or definition.get("type") not in TYPES or not definition.get("label"):
            raise ValueError(f"无效的参数定义: {key}")
        if definition.get("choices_from") not in (None, "cameras"):
            raise ValueError(f"未知的选项来源: {key}")
        if definition["type"] == "choice":
            choices = choices_for(config, definition)
            if not isinstance(choices, list) or not choices or any(not isinstance(v, str) or not v for v in choices) or len(set(choices)) != len(choices):
                raise ValueError(f"{key} 需要不重复的选项")
        if definition["type"] == "integer":
            low, high = definition.get("minimum", -2147483648), definition.get("maximum", 2147483647)
            if type(low) is not int or type(high) is not int or low < -2147483648 or high > 2147483647 or low > high:
                raise ValueError(f"{key} 的整数范围无效")
        validate_value(config, key, definition.get("default", ""))
    programs = config.get("programs")
    if not isinstance(programs, list):
        raise ValueError("programs 必须是程序列表")
    identities = set()
    for program in programs:
        if not isinstance(program, dict):
            raise ValueError("无效的程序定义")
        identity = program.get("id")
        if not isinstance(identity, str) or not re.fullmatch(r"[A-Za-z0-9_+.-]+", identity) or identity in identities:
            raise ValueError("程序 ID 不能为空或重复")
        identities.add(identity)
        if type(program.get("use_angle_cls", False)) is not bool:
            raise ValueError(f"{identity}: use_angle_cls 必须是 true 或 false")
        if not isinstance(program.get("name"), str) or not program["name"].strip():
            raise ValueError(f"{identity}: 程序名称不能为空")
        command = program.get("command")
        if not isinstance(command, list) or not command or any(not isinstance(v, str) or not v or "\0" in v for v in command):
            raise ValueError(f"{identity}: command 必须是非空字符串数组")
        if not isinstance(program.get("cwd"), str) or not program["cwd"] or "\0" in program["cwd"]:
            raise ValueError(f"{identity}: 请设置工作目录")
        if not isinstance(program.get("instance_key", identity), str) or not program.get("instance_key", identity):
            raise ValueError(f"{identity}: 无效的实例标识")
        bindings = program.get("parameters", {})
        if not isinstance(bindings, dict) or not isinstance(program.get("values", {}), dict):
            raise ValueError(f"{identity}: 参数映射和值必须是对象")
        env_names = []
        for key, variable in bindings.items():
            if key not in parameters or not isinstance(variable, str) or (variable and not ENVIRONMENT.fullmatch(variable)):
                raise ValueError(f"{identity}: 无效的参数/环境变量映射 {key}")
            if variable:
                env_names.append(variable)
            validate_value(config, key, parameter_value(config, program, key))
        if len(set(env_names)) != len(env_names):
            raise ValueError(f"{identity}: 多个参数不能写入同一环境变量")
        environment = program.get("environment", {})
        if not isinstance(environment, dict) or any(not ENVIRONMENT.fullmatch(k) or not isinstance(v, str) or "\0" in v for k, v in environment.items()):
            raise ValueError(f"{identity}: 无效的额外环境变量")


class ConfigStore:
    def __init__(self, path: Path | None = None):
        self.path = (path or default_config_path()).expanduser().resolve()
        self.data: dict = {}
        self._digest = None

    def load(self) -> dict:
        if self.path.exists():
            contents = self.path.read_bytes()
            self.data = json.loads(contents)
            self._digest = hashlib.sha256(contents).hexdigest()
            validate_config(self.data)
        else:
            self.data = json.loads((Path(__file__).with_name("defaults.json")).read_text(encoding="utf-8"))
            self.save()
        return self.data

    def save(self) -> None:
        validate_config(self.data)
        atomic_json(self.path, self.data)
        self._digest = hashlib.sha256(self.path.read_bytes()).hexdigest()

    def update(self, data: dict) -> None:
        validate_config(data)
        if not self.path.exists() or hashlib.sha256(self.path.read_bytes()).hexdigest() != self._digest:
            raise ValueError("配置文件已被外部修改，请先重新读取配置，以免覆盖程序列表。")
        atomic_json(self.path, data)
        self._digest = hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.data = copy.deepcopy(data)


def launch_spec(config: dict, program: dict, repository: Path = REPOSITORY) -> dict:
    """Expand each argv token separately; no shell interprets parameter values."""
    substitutions = {"repo": str(repository.resolve())}
    environment = {}
    bound_values = {}
    for key, variable in program.get("parameters", {}).items():
        value = validate_value(config, key, parameter_value(config, program, key))
        text = ("1" if value else "0") if isinstance(value, bool) else str(value)
        substitutions[key] = text
        if variable:
            bound_values[variable] = text
    def expand(value: str) -> str:
        try:
            return value.format_map(substitutions)
        except (KeyError, ValueError, IndexError, AttributeError) as error:
            raise ValueError(f"命令模板无效: {value}") from error
    # Environment entries may contain paths based on the repository, too.
    environment = {key: expand(value) for key, value in program.get("environment", {}).items()}
    environment.update(bound_values)
    # Configuration is authoritative even if the parent shell/extra environment
    # contains OCR_DEBUG_MODE. No operator UI control can change this flag.
    enabled = config.get("debug_mode", False)
    if type(enabled) is not bool:
        raise ValueError("debug_mode 必须是 true 或 false")
    environment["OCR_DEBUG_MODE"] = "1" if enabled else "0"
    # JSON-only OCR setting, deliberately outside the inspector's parameters.
    # Send an explicit false for older configs so ambient shell variables cannot
    # silently enable extra inference. Identify aliases through their instance key.
    if program.get("instance_key", program["id"]) in LEGACY_OCR_PROGRAMS:
        angle_cls = program.get("use_angle_cls", False)
        if type(angle_cls) is not bool:
            raise ValueError("use_angle_cls 必须是 true 或 false")
        environment["PADDLEOCR_USE_ANGLE_CLS"] = "1" if angle_cls else "0"
    command = [expand(token) for token in program["command"]]
    directory = Path(expand(program["cwd"])).expanduser()
    if not directory.is_absolute():
        directory = repository / directory
    return {"name": program["name"], "command": command, "cwd": str(directory.resolve()), "environment": environment}
