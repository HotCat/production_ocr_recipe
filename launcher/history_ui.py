"""Calendar distribution, date-range queries and full production event details."""
from __future__ import annotations

import sqlite3
from PySide6.QtCore import QDate, Qt, QLocale
from PySide6.QtGui import QColor, QFont, QTextCharFormat
from PySide6.QtWidgets import (
    QAbstractItemView, QCalendarWidget, QComboBox, QDateEdit, QDialog, QHBoxLayout,
    QHeaderView, QLabel, QLineEdit, QPlainTextEdit, QPushButton, QSplitter,
    QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget,
)

from .production import ProductionHistory

COLUMNS = [('timestamp_local','完整时间（含时区）'),('result','结果'),('barcode','产品条码'),
           ('packaging_barcode','包装条码'),('serial_number','序列号'),('detected_text','识别文字'),
           ('preset_text','预设文字'),('bank','银行'),('integrity_guard','产品印字校验'),
           ('reverse','Reverse'),('packaging_integrity_guard','包装印字校验'),
           ('reason','说明')]
BOOLEAN_COLUMNS = {'integrity_guard','reverse','packaging_integrity_guard'}
APP_COLUMNS = {
    'Barcode+Sequence': {'barcode', 'integrity_guard', 'reverse'},
    'Barcode+Sequence+Barcode': {'barcode', 'packaging_barcode', 'integrity_guard', 'packaging_integrity_guard', 'reverse'},
    'Barcode+Sequence+Engraving': {'barcode', 'serial_number', 'detected_text', 'bank', 'integrity_guard', 'reverse'},
    'Engraving+Sequence': {'serial_number', 'detected_text', 'reverse'},
    'Engraving+Compare': {'detected_text', 'preset_text'},
}


def format_cell(key, value):
    if value is None:
        return '—'
    if key in BOOLEAN_COLUMNS:
        return '开启' if value else '关闭'
    return str(value)


class ProductionCalendar(QCalendarWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setLocale(QLocale(QLocale.Language.Chinese, QLocale.Country.China))
        self.counts = {}
        self.setGridVisible(True)
        self.setVerticalHeaderFormat(QCalendarWidget.VerticalHeaderFormat.NoVerticalHeader)
        self.setMinimumSize(410, 330)

    def set_distribution(self, counts):
        self.counts = counts
        self.setDateTextFormat(QDate(), QTextCharFormat())
        for date, row in counts.items():
            style = QTextCharFormat()
            style.setBackground(QColor('#ffe5e5' if row['ng'] else '#e2f4ed'))
            style.setFontWeight(QFont.Weight.Bold)
            self.setDateTextFormat(QDate.fromString(date, 'yyyy-MM-dd'), style)
        self.updateCells()

    def paintCell(self, painter, rectangle, date):
        super().paintCell(painter, rectangle, date)
        row = self.counts.get(date.toString('yyyy-MM-dd'))
        if row:
            painter.save()
            painter.setPen(QColor('#b62929' if row['ng'] else '#16704b'))
            font = painter.font()
            font.setPointSize(max(7, font.pointSize()-2))
            painter.setFont(font)
            painter.setBrush(QColor('#b62929' if row['ng'] else '#16704b'))
            painter.drawEllipse(rectangle.right()-8, rectangle.top()+3, 5, 5)
            painter.drawText(rectangle.adjusted(1, 0, -1, -1), Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignBottom, str(row['total']) + ' 件')
            painter.restore()


class ProductionHistoryWindow(QDialog):
    def __init__(self, history: ProductionHistory, title: str, parent=None):
        super().__init__(parent)
        self.history = history
        visible = APP_COLUMNS[history.app] | {'timestamp_local', 'result', 'reason'}
        self.columns = [(key, label) for key, label in COLUMNS if key in visible]
        self.offset = 0
        self.page_size = 200
        self.rows = []
        self.setWindowTitle(title + ' · 生产记录')
        self.resize(1320, 780)
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel('生产记录 · ' + title))
        path = QLabel(str(history.path))
        path.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        layout.addWidget(path)
        splitter = QSplitter()
        layout.addWidget(splitter, 1)
        left = QWidget()
        left_layout = QVBoxLayout(left)
        self.calendar = ProductionCalendar()
        self.calendar.currentPageChanged.connect(self.update_calendar)
        self.calendar.clicked.connect(self.choose_day)
        left_layout.addWidget(self.calendar)
        legend = QLabel('绿色：全部 OK  ·  红色：含 NG\n日期下方显示当天总产量。点击日期查询当天记录。')
        legend.setWordWrap(True)
        left_layout.addWidget(legend)
        self.day_summary = QLabel()
        left_layout.addWidget(self.day_summary)
        left_layout.addStretch()
        splitter.addWidget(left)
        right = QWidget()
        right_layout = QVBoxLayout(right)
        filters = QHBoxLayout()
        self.start = QDateEdit(QDate.currentDate()); self.start.setCalendarPopup(True)
        self.end = QDateEdit(QDate.currentDate()); self.end.setCalendarPopup(True)
        for editor in [self.start, self.end]:editor.setDisplayFormat('yyyy-MM-dd')
        filters.addWidget(QLabel('从')); filters.addWidget(self.start)
        filters.addWidget(QLabel('到')); filters.addWidget(self.end)
        self.result_filter = QComboBox(); self.result_filter.addItems(['全部','OK','NG'])
        filters.addWidget(self.result_filter)
        self.search = QLineEdit(); self.search.setPlaceholderText('条码 / 序列号 / 文字 / 银行')
        self.search.returnPressed.connect(self.query)
        filters.addWidget(self.search, 1)
        refresh = QPushButton('查询 / 刷新'); refresh.clicked.connect(self.query)
        filters.addWidget(refresh)
        right_layout.addLayout(filters)
        self.summary = QLabel(); right_layout.addWidget(self.summary)
        self.table = QTableWidget(0, len(self.columns))
        self.table.setHorizontalHeaderLabels([title for _,title in self.columns])
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Interactive)
        self.table.setColumnWidth(0, 250)
        for i, (key, _) in enumerate(self.columns[1:], 1):
            self.table.setColumnWidth(i, 90 if key == 'result' else 115 if key in BOOLEAN_COLUMNS else 220)
        self.table.cellDoubleClicked.connect(self.details)
        right_layout.addWidget(self.table,1)
        pagination = QHBoxLayout()
        self.previous = QPushButton('上一页'); self.previous.clicked.connect(lambda: self.page(-1))
        self.next = QPushButton('下一页'); self.next.clicked.connect(lambda: self.page(1))
        self.page_label = QLabel()
        pagination.addWidget(self.previous);pagination.addWidget(self.page_label);pagination.addWidget(self.next)
        pagination.addStretch();pagination.addWidget(QLabel('双击一条记录查看完整内容'))
        right_layout.addLayout(pagination)
        splitter.addWidget(right);splitter.setSizes([420,900])
        self.update_calendar()
        self.query()

    def update_calendar(self, *args):
        first = QDate(self.calendar.yearShown(), self.calendar.monthShown(), 1)
        last = first.addMonths(1).addDays(-1)
        try:
            counts = self.history.distribution(first.toString('yyyy-MM-dd'),last.toString('yyyy-MM-dd'))
            self.calendar.set_distribution(counts)
            self.update_day_summary()
        except (OSError,sqlite3.Error) as error:
            self.summary.setText('无法读取记录：'+str(error))

    def update_day_summary(self):
        day = self.calendar.selectedDate().toString('yyyy-MM-dd')
        count = self.calendar.counts.get(day, {'total':0,'ok':0,'ng':0})
        self.day_summary.setText(f"{day}  ·  总计 {count['total']}  ·  OK {count['ok']}  ·  NG {count['ng']}")

    def choose_day(self, date):
        self.start.setDate(date);self.end.setDate(date)
        self.update_day_summary();self.query()

    def page(self, direction):
        self.offset=max(0,self.offset+direction*self.page_size)
        self.query(reset=False)

    def query(self, *args, reset=True):
        if reset:self.offset=0
        if self.start.date()>self.end.date():
            self.summary.setText('开始日期不能晚于结束日期');return
        try:
            data=self.history.query(self.start.date().toString('yyyy-MM-dd'),self.end.date().toString('yyyy-MM-dd'),
                '' if self.result_filter.currentIndex()==0 else self.result_filter.currentText(),self.search.text(),self.offset,self.page_size)
            self.rows=data['rows']
            self.table.setRowCount(len(self.rows))
            for i,row in enumerate(self.rows):
                for j,(key,_) in enumerate(self.columns):
                    item=QTableWidgetItem(format_cell(key,row[key]));item.setToolTip(item.text())
                    if key=='result':item.setForeground(QColor('#16815d' if row[key]=='OK' else '#c23a3a'))
                    self.table.setItem(i,j,item)
            self.summary.setText(f"总计 {data['total']}  ·  OK {data['ok']}  ·  NG {data['ng']}"+('  ·  尚无生产记录' if not self.history.path.exists() else ''))
            self.previous.setEnabled(self.offset>0)
            self.next.setEnabled(self.offset+len(self.rows)<data['total'])
            self.page_label.setText(f"第 {self.offset//self.page_size+1} 页")
            self.update_calendar()
        except (OSError,sqlite3.Error,ValueError) as error:
            self.summary.setText('无法查询记录：'+str(error))

    def details(self, row, column):
        data=self.rows[row]
        dialog=QDialog(self);dialog.setWindowTitle('完整生产记录');dialog.resize(780,650)
        layout=QVBoxLayout(dialog)
        text=QPlainTextEdit();text.setReadOnly(True)
        labels=dict(COLUMNS)
        text.setPlainText('\n\n'.join(labels.get(key,key)+'：\n'+format_cell(key,value) for key,value in data.items()))
        layout.addWidget(text);dialog.exec()
