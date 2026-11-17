"""Operator UI: the available programs and parameter definitions come from JSON."""
from __future__ import annotations

import copy
from pathlib import Path

from PySide6.QtCore import Qt, QTimer
from PySide6.QtGui import QColor
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QFormLayout, QFrame, QHBoxLayout, QLabel, QLineEdit,
    QMainWindow, QMessageBox, QPlainTextEdit, QPushButton, QScrollArea, QSpinBox,
    QSplitter, QTabWidget, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget,
)

from .config import ConfigStore, REPOSITORY, choices_for, launch_spec, parameter_value
from .processes import AlreadyRunning, ProcessManager


class LauncherWindow(QMainWindow):
    def __init__(self, store: ConfigStore, manager: ProcessManager | None = None,
                 repository: Path = REPOSITORY):
        super().__init__()
        self.store = store
        self.config = copy.deepcopy(store.data)
        self.manager = manager or ProcessManager()
        self.repository = repository
        self.selected_id: str | None = None
        self.editors: dict[str, QWidget] = {}
        self.rows: dict[str, QTreeWidgetItem] = {}
        self.setWindowTitle("生产 OCR 启动器")
        self.resize(1140, 760)
        self.setMinimumSize(850, 600)
        self.setStyleSheet("""
          QMainWindow, QWidget#page { background: #f3f5f8; }
          QLabel#heading { font-size: 25px; font-weight: 700; color: #17243b; }
          QLabel#muted { color: #64748b; }
          QLabel#inspectorTitle { font-size: 20px; font-weight: 600; color: #17243b; }
          QFrame#card { background: white; border: 1px solid #dbe1e9; border-radius: 8px; }
          QTreeWidget { border: 0; background: white; alternate-background-color: #f8fafc; }
          QTreeWidget::item { padding: 13px 5px; }
          QTreeWidget::item:selected { background: #e4efff; color: #183f78; }
          QHeaderView::section { background: #f8fafc; padding: 10px; border: 0; color: #64748b; }
          QLineEdit, QComboBox, QSpinBox { min-height: 32px; padding: 2px 7px; border: 1px solid #cbd5e1; border-radius: 4px; background: white; }
          QLineEdit:disabled, QComboBox:disabled, QSpinBox:disabled { background: #f1f5f9; color: #64748b; }
          QPushButton { padding: 9px 15px; border: 1px solid #cbd5e1; border-radius: 5px; background: white; color: #26344a; }
          QPushButton:hover { background: #edf3fc; }
          QPushButton#launch { background: #2463d3; color: white; border: 0; font-weight: 600; }
          QPushButton#launch:disabled { background: #dce4f0; color: #718096; }
          QPushButton:disabled { color: #94a3b8; background: #f1f5f9; }
          QPlainTextEdit { background: #152033; color: #e4eaf2; border: 0; padding: 10px; }
        """)
        page = QWidget(objectName="page")
        self.setCentralWidget(page)
        layout = QVBoxLayout(page)
        layout.setContentsMargins(24, 22, 24, 18)
        layout.setSpacing(16)
        title = QLabel("生产 OCR 启动器", objectName="heading")
        layout.addWidget(title)
        subtitle = QLabel("选择检测程序，确认相机和控制器参数后启动。每个程序仅允许运行一个实例。", objectName="muted")
        subtitle.setWordWrap(True)
        layout.addWidget(subtitle)
        toolbar = QHBoxLayout()
        self.config_path = QLabel(str(store.path), objectName="muted")
        self.config_path.setWordWrap(True)
        self.config_path.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.config_path.setToolTip("可用程序、相机名称和参数定义均由此配置文件管理")
        toolbar.addWidget(self.config_path, 1)
        self.reload_button = QPushButton("重新读取配置")
        self.reload_button.setObjectName("reloadConfig")
        self.reload_button.clicked.connect(self.reload_config)
        toolbar.addWidget(self.reload_button)
        layout.addLayout(toolbar)
        splitter = QSplitter(Qt.Orientation.Horizontal)
        layout.addWidget(splitter, 1)
        left = QFrame(objectName="card")
        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(12, 14, 12, 12)
        left_layout.addWidget(QLabel("可用程序"))
        self.program_list = QTreeWidget()
        self.program_list.setObjectName("programList")
        self.program_list.setColumnCount(2)
        self.program_list.setHeaderLabels(["检测程序", "状态"])
        self.program_list.setRootIsDecorated(False)
        self.program_list.setAlternatingRowColors(True)
        self.program_list.setColumnWidth(0, 255)
        self.program_list.currentItemChanged.connect(self.select_program)
        left_layout.addWidget(self.program_list, 1)
        hint = QLabel("程序列表由配置文件管理。\n修改配置文件后，点击「重新读取配置」。", objectName="muted")
        hint.setWordWrap(True)
        left_layout.addWidget(hint)
        splitter.addWidget(left)
        right = QFrame(objectName="card")
        right_layout = QVBoxLayout(right)
        right_layout.setContentsMargins(22, 20, 22, 20)
        self.inspector_title = QLabel("参数检查器", objectName="inspectorTitle")
        right_layout.addWidget(self.inspector_title)
        self.identity_label = QLabel("", objectName="muted")
        self.identity_label.setWordWrap(True)
        right_layout.addWidget(self.identity_label)
        self.status_label = QLabel("请选择一个程序")
        self.status_label.setWordWrap(True)
        right_layout.addWidget(self.status_label)
        self.tabs = QTabWidget()
        right_layout.addWidget(self.tabs, 1)
        self.parameter_scroll = QScrollArea()
        self.parameter_scroll.setWidgetResizable(True)
        self.parameter_scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.tabs.addTab(self.parameter_scroll, "运行参数")
        self.log_view = QPlainTextEdit()
        self.log_view.setObjectName("programLog")
        self.log_view.setReadOnly(True)
        self.tabs.addTab(self.log_view, "运行日志")
        self.next_run_hint = QLabel("参数保存后用于下一次启动。运行时请在程序自己的窗口中退出。", objectName="muted")
        self.next_run_hint.setWordWrap(True)
        right_layout.addWidget(self.next_run_hint)
        actions = QHBoxLayout()
        self.save_button = QPushButton("保存参数")
        self.save_button.setObjectName("saveParameters")
        self.save_button.clicked.connect(self.save_parameters)
        actions.addWidget(self.save_button)
        actions.addStretch()
        self.launch_button = QPushButton("启动程序", objectName="launch")
        self.launch_button.clicked.connect(self.launch_selected)
        actions.addWidget(self.launch_button)
        right_layout.addLayout(actions)
        splitter.addWidget(right)
        splitter.setSizes([400, 650])
        self.footer = QLabel("关闭启动器不会关闭已启动的生产程序。重新打开后仍会显示运行状态。", objectName="muted")
        self.footer.setWordWrap(True)
        layout.addWidget(self.footer)
        self.populate_programs()
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.refresh_status)
        self.timer.start(750)
        self.refresh_status()

    def program(self) -> dict | None:
        return next((p for p in self.config["programs"] if p["id"] == self.selected_id), None)

    def capture_values(self) -> None:
        program = self.program()
        if program is None:
            return
        values = program.setdefault("values", {})
        for key, editor in self.editors.items():
            if isinstance(editor, QComboBox):
                values[key] = editor.currentText()
            elif isinstance(editor, QSpinBox):
                values[key] = editor.value()
            elif isinstance(editor, QCheckBox):
                values[key] = editor.isChecked()
            else:
                values[key] = editor.text()

    def populate_programs(self, selected: str | None = None) -> None:
        self.program_list.blockSignals(True)
        self.program_list.clear()
        self.rows.clear()
        self.selected_id = None
        self.editors.clear()
        for program in self.config["programs"]:
            row = QTreeWidgetItem([program["name"], "就绪"])
            row.setData(0, Qt.ItemDataRole.UserRole, program["id"])
            row.setToolTip(0, program["id"])
            self.program_list.addTopLevelItem(row)
            self.rows[program["id"]] = row
        self.program_list.blockSignals(False)
        target = self.rows.get(selected) or self.program_list.topLevelItem(0)
        self.program_list.setCurrentItem(target)
        if target is None:
            self.select_program(None, None)

    def select_program(self, current, previous) -> None:
        self.capture_values()
        self.selected_id = current.data(0, Qt.ItemDataRole.UserRole) if current else None
        self.editors.clear()
        panel = QWidget()
        panel.setStyleSheet("background: white;")
        form = QFormLayout(panel)
        form.setContentsMargins(2, 22, 12, 20)
        form.setVerticalSpacing(18)
        form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.ExpandingFieldsGrow)
        program = self.program()
        if program:
            self.inspector_title.setText(program["name"])
            self.identity_label.setText(program["id"])
            for key, variable in program.get("parameters", {}).items():
                definition = self.config["parameters"][key]
                value = parameter_value(self.config, program, key)
                kind = definition["type"]
                if kind == "choice":
                    editor = QComboBox()
                    editor.addItems(choices_for(self.config, definition))
                    editor.setCurrentText(value)
                elif kind == "integer":
                    editor = QSpinBox()
                    editor.setRange(definition.get("minimum", -2147483648), definition.get("maximum", 2147483647))
                    editor.setValue(value)
                elif kind == "boolean":
                    editor = QCheckBox("启用")
                    editor.setChecked(value)
                else:
                    editor = QLineEdit(value)
                editor.setObjectName("parameter_" + key)
                editor.setToolTip(definition.get("description", "") + (f"\n环境变量: {variable}" if variable else ""))
                form.addRow(definition["label"], editor)
                self.editors[key] = editor
            if not self.editors:
                form.addRow(QLabel("该程序未配置可编辑参数。"))
        else:
            self.inspector_title.setText("参数检查器")
            self.identity_label.setText("没有可用程序；请在配置文件的 programs 列表中添加。")
        self.parameter_scroll.setWidget(panel)
        self.log_view.clear()
        self.refresh_status()

    def report_error(self, error: Exception) -> None:
        QMessageBox.warning(self, "无法完成操作", str(error))

    def save_parameters(self) -> bool:
        self.capture_values()
        try:
            self.store.update(self.config)
        except (OSError, ValueError) as error:
            self.report_error(error)
            return False
        self.footer.setText("参数已保存：" + str(self.store.path))
        return True

    def launch_selected(self) -> None:
        program = self.program()
        if program is None:
            return
        try:
            if self.manager.status(program.get("instance_key", program["id"]))["running"]:
                raise AlreadyRunning("该程序已经运行，请先关闭它的窗口。")
            if not self.save_parameters():
                return
            spec = launch_spec(self.config, program, self.repository)
            self.manager.launch(program.get("instance_key", program["id"]), spec)
            self.footer.setText("已提交启动请求。请查看运行状态和日志。")
        except (OSError, ValueError, AlreadyRunning) as error:
            self.report_error(error)
        self.refresh_status()

    def dirty_decision(self) -> bool:
        self.capture_values()
        if self.config == self.store.data:
            return True
        answer = QMessageBox.question(self, "未保存的参数", "是否保存尚未保存的参数？",
                                      QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel,
                                      QMessageBox.StandardButton.Save)
        if answer == QMessageBox.StandardButton.Cancel:
            return False
        return self.save_parameters() if answer == QMessageBox.StandardButton.Save else True

    def reload_config(self) -> None:
        if not self.dirty_decision():
            return
        selected = self.selected_id
        try:
            candidate = ConfigStore(self.store.path)
            candidate.load()
        except (OSError, ValueError, TypeError, KeyError) as error:
            self.report_error(error)
            return
        self.store = candidate
        self.config = copy.deepcopy(candidate.data)
        self.populate_programs(selected)
        self.footer.setText("已重新读取配置。已启动程序继续使用启动时的参数。")

    @staticmethod
    def state_text(state: dict) -> str:
        if state["running"]:
            return "启动中" if state["state"] == "starting" else "运行中"
        if state["state"] == "failed":
            return "启动失败"
        if state["state"] == "exited":
            return "已关闭" if state.get("exit_code") == 0 else "异常退出"
        return "已关闭" if state["state"] == "stopped" else "就绪"

    def refresh_status(self) -> None:
        program = self.program()
        for item in self.config["programs"]:
            key = item.get("instance_key", item["id"])
            state = self.manager.status(key)
            row = self.rows.get(item["id"])
            if row:
                row.setText(1, self.state_text(state))
                color = "#16815d" if state["running"] else ("#c23a3a" if state["state"] == "failed" or state.get("exit_code", 0) != 0 else "#64748b")
                row.setForeground(1, QColor(color))
        state = self.manager.status(program.get("instance_key", program["id"])) if program else None
        busy = bool(state and state["running"])
        self.launch_button.setEnabled(program is not None and not busy)
        self.launch_button.setText("程序运行中" if busy else "启动程序")
        self.save_button.setEnabled(program is not None and not busy)
        for editor in self.editors.values():
            editor.setEnabled(not busy)
        if state:
            text = self.state_text(state)
            if busy and state.get("pid"):
                text += f"  ·  PID {state['pid']}"
            if not busy and "exit_code" in state:
                text += f"  ·  退出码 {state['exit_code']}"
            if state.get("message"):
                text += "\n" + state["message"]
            self.status_label.setText(text)
            log = self.manager.log_tail(program.get("instance_key", program["id"]))
            if self.log_view.toPlainText() != log:
                scroll = self.log_view.verticalScrollBar()
                at_end = scroll.value() >= scroll.maximum() - 2
                old_position = scroll.value()
                self.log_view.setPlainText(log)
                scroll.setValue(scroll.maximum() if at_end else old_position)
        else:
            self.status_label.setText("请选择一个程序")

    def closeEvent(self, event) -> None:
        if self.dirty_decision():
            self.timer.stop()
            event.accept()
        else:
            event.ignore()
