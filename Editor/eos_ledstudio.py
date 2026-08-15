"""
eos_ledstudio — a visual WS2812 editor for the EOS Script mini-IDE.

Paint LEDs with a colour picker, build a sequence of frames, apply effect
generators, preview the animation, and emit a complete in-bounds .eos script
(GRB packing + budget handled by eos_ledgen). Opened from Tools -> LED Studio.
"""
from PySide6.QtCore import Qt, QTimer, Signal, QSize
from PySide6.QtGui import QColor, QPainter, QBrush, QPen
from PySide6.QtWidgets import (QDialog, QWidget, QVBoxLayout, QHBoxLayout, QLabel,
                               QSpinBox, QComboBox, QLineEdit, QSlider, QPushButton,
                               QListWidget, QColorDialog, QFrame, QGridLayout,
                               QMessageBox, QApplication, QListWidgetItem)

import eos_language as L
import eos_ledgen as G

BLACK = (0, 0, 0)
PALETTE = [(255, 0, 0), (255, 96, 0), (255, 200, 0), (0, 255, 0),
           (0, 200, 255), (0, 0, 255), (160, 0, 255), (255, 0, 160),
           (255, 255, 255), (0, 0, 0)]


class StripView(QWidget):
    """A single frame: a row of clickable LED cells (click/drag to paint)."""
    changed = Signal()

    def __init__(self):
        super().__init__()
        self.frame = [BLACK] * 8
        self.paint_color = (255, 0, 0)
        self.setMinimumHeight(46)
        self.setMouseTracking(False)

    def set_frame(self, frame):
        self.frame = list(frame); self.update()

    def sizeHint(self):
        return QSize(480, 46)

    def _index_at(self, x):
        n = max(1, len(self.frame))
        w = self.width() / n
        i = int(x // w)
        return min(max(i, 0), n - 1)

    def paintEvent(self, _):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor("#0d1216"))
        n = max(1, len(self.frame))
        w = self.width() / n
        for i, px in enumerate(self.frame):
            x = int(i * w)
            rect_w = int((i + 1) * w) - x - 2
            col = QColor(px[0], px[1], px[2])
            p.setBrush(QBrush(col))
            p.setPen(QPen(QColor("#263238")))
            p.drawRoundedRect(x + 1, 4, max(2, rect_w), self.height() - 8, 3, 3)

    def _paint_at(self, pos):
        i = self._index_at(pos.x())
        if 0 <= i < len(self.frame):
            self.frame[i] = self.paint_color
            self.update(); self.changed.emit()

    def mousePressEvent(self, e): self._paint_at(e.position())
    def mouseMoveEvent(self, e):
        if e.buttons() & Qt.LeftButton: self._paint_at(e.position())


class LedStudioDialog(QDialog):
    def __init__(self, parent=None, target="NOHD"):
        super().__init__(parent)
        self.parent_win = parent
        self.target = target
        self.setWindowTitle("LED Studio")
        self.resize(720, 560)
        self.color = (255, 0, 0)
        self.frames = [[BLACK] * 8]     # list of frames
        self.delays = [120]             # ms per frame
        self.play_idx = 0

        root = QVBoxLayout(self)

        # ---- top row: strip setup ----
        top = QHBoxLayout()
        top.addWidget(QLabel("LEDs"))
        self.sp_count = QSpinBox(); self.sp_count.setRange(1, L.LIMITS["WS_MAX_COUNT"])
        self.sp_count.setValue(8); self.sp_count.valueChanged.connect(self.on_count)
        top.addWidget(self.sp_count)
        top.addWidget(QLabel("Pin"))
        self.cb_pin = QComboBox(); self.cb_pin.addItems(["EXP4", "EXP5", "EXP6", "EXP7", "EXP8"])
        top.addWidget(self.cb_pin)
        top.addWidget(QLabel("Name"))
        self.ed_name = QLineEdit("anim"); self.ed_name.setMaxLength(12)
        self.ed_name.setFixedWidth(90); top.addWidget(self.ed_name)
        top.addStretch(1)
        top.addWidget(QLabel("Brightness"))
        self.sl_bri = QSlider(Qt.Horizontal); self.sl_bri.setRange(1, 255)
        self.sl_bri.setValue(255); self.sl_bri.setFixedWidth(120)
        self.sl_bri.valueChanged.connect(lambda _: self.strip.update())
        top.addWidget(self.sl_bri)
        root.addLayout(top)

        # ---- the strip canvas ----
        self.strip = StripView(); self.strip.set_frame(self.frames[0])
        self.strip.paint_color = self.color
        self.strip.changed.connect(self.on_strip_changed)
        root.addWidget(self.strip)

        # ---- colour + palette ----
        crow = QHBoxLayout()
        self.btn_color = QPushButton("Pick colour")
        self.btn_color.clicked.connect(self.pick_color)
        crow.addWidget(self.btn_color)
        self.sw_current = QFrame(); self.sw_current.setFixedSize(28, 24)
        self._set_swatch()
        crow.addWidget(self.sw_current)
        crow.addWidget(QLabel("  Quick:"))
        for col in PALETTE:
            b = QFrame(); b.setFixedSize(22, 22)
            b.setStyleSheet(f"background:rgb{col};border:1px solid #37474f;")
            b.mousePressEvent = (lambda e, c=col: self.set_color(c))
            crow.addWidget(b)
        crow.addStretch(1)
        root.addLayout(crow)

        # ---- middle: frames list + effects ----
        mid = QHBoxLayout()
        left = QVBoxLayout()
        left.addWidget(QLabel("<b>Frames</b>"))
        self.lst = QListWidget(); self.lst.currentRowChanged.connect(self.on_select_frame)
        self.lst.setFixedWidth(180)
        left.addWidget(self.lst)
        drow = QHBoxLayout()
        drow.addWidget(QLabel("Delay ms"))
        self.sp_delay = QSpinBox(); self.sp_delay.setRange(0, L.LIMITS["DELAY_MAX"])
        self.sp_delay.setValue(120); self.sp_delay.valueChanged.connect(self.on_delay)
        drow.addWidget(self.sp_delay); left.addLayout(drow)
        ops = QGridLayout()
        for i, (label, fn) in enumerate([
                ("Add", self.add_frame), ("Duplicate", self.dup_frame),
                ("Delete", self.del_frame), ("Clear", self.clear_frame),
                ("Up", lambda: self.move_frame(-1)), ("Down", lambda: self.move_frame(1))]):
            b = QPushButton(label); b.clicked.connect(fn)
            ops.addWidget(b, i // 2, i % 2)
        left.addLayout(ops)
        mid.addLayout(left)

        right = QVBoxLayout()
        right.addWidget(QLabel("<b>Effect generators</b> (replace all frames)"))
        for ename in G.EFFECTS:
            b = QPushButton(ename)
            b.clicked.connect(lambda checked=False, n=ename: self.apply_effect(n))
            right.addWidget(b)
        right.addStretch(1)
        self.lbl_budget = QLabel(""); self.lbl_budget.setWordWrap(True)
        right.addWidget(self.lbl_budget)
        mid.addLayout(right)
        root.addLayout(mid)

        # ---- bottom: playback + export ----
        bot = QHBoxLayout()
        self.btn_play = QPushButton("\u25b6 Play"); self.btn_play.clicked.connect(self.toggle_play)
        bot.addWidget(self.btn_play)
        bot.addStretch(1)
        b_copy = QPushButton("Copy code"); b_copy.clicked.connect(self.copy_code)
        b_new = QPushButton("Open as new tab"); b_new.clicked.connect(self.open_new)
        b_close = QPushButton("Close"); b_close.clicked.connect(self.reject)
        for b in (b_copy, b_new, b_close): bot.addWidget(b)
        root.addLayout(bot)

        self.timer = QTimer(self); self.timer.timeout.connect(self._tick)
        self._apply_theme()
        self.refresh_list(); self.lst.setCurrentRow(0); self.update_budget()

    # ---- colour ----
    def _set_swatch(self):
        self.sw_current.setStyleSheet(
            f"background:rgb{self.color};border:1px solid #78909c;")
    def set_color(self, col):
        self.color = tuple(col); self.strip.paint_color = self.color; self._set_swatch()
    def pick_color(self):
        c = QColorDialog.getColor(QColor(*self.color), self, "Pick LED colour")
        if c.isValid(): self.set_color((c.red(), c.green(), c.blue()))

    # ---- count ----
    def on_count(self, n):
        for k in range(len(self.frames)):
            f = self.frames[k]
            if n < len(f): self.frames[k] = f[:n]
            else: self.frames[k] = f + [BLACK] * (n - len(f))
        self.strip.set_frame(self.frames[self.cur()])
        self.update_budget()

    # ---- frame selection / list ----
    def cur(self):
        return max(0, self.lst.currentRow())
    def refresh_list(self):
        self.lst.blockSignals(True); self.lst.clear()
        for i in range(len(self.frames)):
            self.lst.addItem(QListWidgetItem(f"Frame {i}   ({self.delays[i]} ms)"))
        self.lst.blockSignals(False)
    def on_select_frame(self, row):
        if 0 <= row < len(self.frames):
            self.strip.set_frame(self.frames[row])
            self.sp_delay.blockSignals(True); self.sp_delay.setValue(self.delays[row])
            self.sp_delay.blockSignals(False)
    def on_strip_changed(self):
        self.frames[self.cur()] = list(self.strip.frame)
    def on_delay(self, v):
        self.delays[self.cur()] = v; self.refresh_list()
        self.lst.setCurrentRow(self.cur())

    # ---- frame ops ----
    def add_frame(self):
        n = len(self.frames[0]); self.frames.insert(self.cur() + 1, [BLACK] * n)
        self.delays.insert(self.cur() + 1, 120)
        self.refresh_list(); self.lst.setCurrentRow(self.cur() + 1); self.update_budget()
    def dup_frame(self):
        i = self.cur(); self.frames.insert(i + 1, list(self.frames[i]))
        self.delays.insert(i + 1, self.delays[i])
        self.refresh_list(); self.lst.setCurrentRow(i + 1); self.update_budget()
    def del_frame(self):
        if len(self.frames) <= 1: return
        i = self.cur(); self.frames.pop(i); self.delays.pop(i)
        self.refresh_list(); self.lst.setCurrentRow(min(i, len(self.frames) - 1))
        self.update_budget()
    def clear_frame(self):
        n = len(self.frames[0]); self.frames[self.cur()] = [BLACK] * n
        self.strip.set_frame(self.frames[self.cur()])
    def move_frame(self, d):
        i = self.cur(); j = i + d
        if 0 <= j < len(self.frames):
            self.frames[i], self.frames[j] = self.frames[j], self.frames[i]
            self.delays[i], self.delays[j] = self.delays[j], self.delays[i]
            self.refresh_list(); self.lst.setCurrentRow(j)

    # ---- effects ----
    def apply_effect(self, name):
        count = self.sp_count.value()
        needs, fn = G.EFFECTS[name]
        frames = fn(count, self.color)
        self.frames = [list(f) for f in frames]
        self.delays = [120] * len(frames)
        self.refresh_list(); self.lst.setCurrentRow(0)
        self.strip.set_frame(self.frames[0]); self.update_budget()

    # ---- budget ----
    def update_budget(self):
        probs = G.check_budget(self.sp_count.value(), len(self.frames))
        total = self.sp_count.value() * 3 * len(self.frames)
        if probs:
            self.lbl_budget.setText("\u26a0 " + " ".join(probs))
            self.lbl_budget.setStyleSheet("color:#ff8a80;")
        else:
            self.lbl_budget.setText(
                f"\u2713 {len(self.frames)} frame(s), {total} B of data \u2014 in bounds.")
            self.lbl_budget.setStyleSheet("color:#66bb6a;")

    # ---- playback ----
    def toggle_play(self):
        if self.timer.isActive():
            self.timer.stop(); self.btn_play.setText("\u25b6 Play")
        else:
            self.play_idx = self.cur(); self.btn_play.setText("\u25a0 Stop")
            self._tick()
    def _tick(self):
        self.strip.set_frame(self.frames[self.play_idx])
        d = max(10, self.delays[self.play_idx])
        self.play_idx = (self.play_idx + 1) % len(self.frames)
        self.timer.start(d)

    # ---- export ----
    def _code(self):
        return G.generate_script(self.cb_pin.currentText(),
                                 self.ed_name.text() or "anim",
                                 self.frames, self.delays,
                                 brightness=self.sl_bri.value(),
                                 target=self.target)
    def copy_code(self):
        if self._blocked(): return
        QApplication.clipboard().setText(self._code())
        QMessageBox.information(self, "Copied", "Script copied to the clipboard.")
    def open_new(self):
        if self._blocked(): return
        code = self._code()
        if self.parent_win and hasattr(self.parent_win, "add_tab"):
            self.parent_win.add_tab(code)
            if hasattr(self.parent_win, "run_lint"): self.parent_win.run_lint()
            self.accept()
        else:
            QApplication.clipboard().setText(code)
            QMessageBox.information(self, "Copied",
                                   "No editor to open into — copied to clipboard instead.")
    def _blocked(self):
        probs = G.check_budget(self.sp_count.value(), len(self.frames))
        if probs:
            QMessageBox.warning(self, "Out of bounds",
                                "Fix these first:\n\n- " + "\n- ".join(probs))
            return True
        return False

    def _apply_theme(self):
        self.setStyleSheet("""
            QDialog, QWidget { background:#10161c; color:#cfd8dc; }
            QListWidget { background:#141b22; border:1px solid #263238; }
            QLineEdit, QSpinBox, QComboBox { background:#1b2027; border:1px solid #37474f;
                                             padding:3px; border-radius:3px; }
            QPushButton { background:#263238; border:1px solid #37474f; padding:5px 9px;
                          border-radius:3px; }
            QPushButton:hover { background:#37474f; }
        """)