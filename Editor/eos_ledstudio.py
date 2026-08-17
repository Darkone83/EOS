"""EOS LED Studio 2.0 — effect-first WS2812 designer.

The Studio renders rich effects on the PC and exports ordinary EOS WS/DATA
scripts, keeping the FPGA expansion engine unchanged.
"""
from __future__ import annotations

from PySide6.QtCore import Qt, QTimer, Signal, QSize, QRectF
from PySide6.QtGui import QColor, QPainter, QBrush, QPen
from PySide6.QtWidgets import (
    QDialog, QWidget, QVBoxLayout, QHBoxLayout, QLabel, QSpinBox, QComboBox,
    QLineEdit, QSlider, QPushButton, QListWidget, QColorDialog, QFrame,
    QGridLayout, QMessageBox, QApplication, QListWidgetItem, QTabWidget,
    QGroupBox, QSplitter, QPlainTextEdit, QProgressBar, QFormLayout
)

import eos_language as L
import eos_ledgen as G

BLACK = (0, 0, 0)


class LedPreview(QWidget):
    """Animated linear/ring preview. Editable only when `editable` is True."""
    changed = Signal()

    def __init__(self):
        super().__init__()
        self.frame = [BLACK] * 8
        self.paint_color = (255, 0, 0)
        self.layout_mode = "Strip"
        self.editable = False
        self.preview_brightness = 255
        self.setMinimumHeight(220)
        self.setMouseTracking(False)

    def set_frame(self, frame):
        self.frame = list(frame)
        self.update()

    def sizeHint(self):
        return QSize(620, 260)

    def _shown(self, px):
        return G.scale_pixel(px, self.preview_brightness)

    def paintEvent(self, _):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.fillRect(self.rect(), QColor("#0b1015"))
        n = max(1, len(self.frame))

        if self.layout_mode == "Ring" and n <= 240:
            cx, cy = self.width() / 2.0, self.height() / 2.0
            radius = max(35.0, min(self.width(), self.height()) * 0.34)
            led_r = max(3.0, min(11.0, (2.0 * 3.14159 * radius / n) * 0.34))
            for i, px in enumerate(self.frame):
                ang = -3.14159 / 2 + 2 * 3.14159 * i / n
                x = cx + radius * __import__('math').cos(ang)
                y = cy + radius * __import__('math').sin(ang)
                c = self._shown(px)
                p.setBrush(QBrush(QColor(*c)))
                p.setPen(QPen(QColor("#34424c")))
                p.drawEllipse(QRectF(x-led_r, y-led_r, led_r*2, led_r*2))
        else:
            cols = min(n, 50)
            rows = (n + cols - 1) // cols
            gap = 3
            cell_w = max(4.0, (self.width() - gap * (cols + 1)) / cols)
            cell_h = max(8.0, min(24.0, (self.height() - gap * (rows + 1)) / max(1, rows)))
            total_h = rows * cell_h + (rows - 1) * gap
            y0 = (self.height() - total_h) / 2.0
            for i, px in enumerate(self.frame):
                r, cidx = divmod(i, cols)
                x = gap + cidx * (cell_w + gap)
                y = y0 + r * (cell_h + gap)
                c = self._shown(px)
                p.setBrush(QBrush(QColor(*c)))
                p.setPen(QPen(QColor("#34424c")))
                p.drawRoundedRect(QRectF(x, y, cell_w, cell_h), 3, 3)

        p.setPen(QColor("#607d8b"))
        p.drawText(10, 18, f"{n} LEDs  •  {self.layout_mode}")

    def _index_at_strip(self, pos):
        n = len(self.frame)
        cols = min(n, 50)
        rows = (n + cols - 1) // cols
        gap = 3
        cell_w = max(4.0, (self.width() - gap * (cols + 1)) / cols)
        cell_h = max(8.0, min(24.0, (self.height() - gap * (rows + 1)) / max(1, rows)))
        total_h = rows * cell_h + (rows - 1) * gap
        y0 = (self.height() - total_h) / 2.0
        col = int((pos.x() - gap) // (cell_w + gap))
        row = int((pos.y() - y0) // (cell_h + gap))
        idx = row * cols + col
        return idx if 0 <= idx < n else -1

    def _paint_at(self, pos):
        if not self.editable or self.layout_mode != "Strip":
            return
        i = self._index_at_strip(pos)
        if i >= 0:
            self.frame[i] = self.paint_color
            self.update(); self.changed.emit()

    def mousePressEvent(self, e): self._paint_at(e.position())
    def mouseMoveEvent(self, e):
        if e.buttons() & Qt.LeftButton: self._paint_at(e.position())


class ColorButton(QPushButton):
    colorChanged = Signal(tuple)

    def __init__(self, label, color, parent=None):
        super().__init__(parent)
        self.label = label
        self.color = tuple(color)
        self.clicked.connect(self.pick)
        self._refresh()

    def _refresh(self):
        self.setText(f"{self.label}  #{self.color[0]:02X}{self.color[1]:02X}{self.color[2]:02X}")
        # Text chooses black/white based on luminance for readability.
        lum = 0.299*self.color[0] + 0.587*self.color[1] + 0.114*self.color[2]
        fg = "#111" if lum > 150 else "#fff"
        self.setStyleSheet(f"background:rgb{self.color};color:{fg};font-weight:600;padding:6px;border:1px solid #607d8b;border-radius:4px;")

    def set_color(self, color, emit=True):
        self.color = tuple(color)
        self._refresh()
        if emit:
            self.colorChanged.emit(self.color)

    def pick(self):
        c = QColorDialog.getColor(QColor(*self.color), self, f"Choose {self.label}")
        if c.isValid():
            self.set_color((c.red(), c.green(), c.blue()))


class ScriptPreviewDialog(QDialog):
    def __init__(self, code, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Generated EOS Script")
        self.resize(760, 600)
        lay = QVBoxLayout(self)
        ed = QPlainTextEdit(code); ed.setReadOnly(True)
        ed.setStyleSheet("font-family:Consolas,monospace;background:#0c1116;color:#d6e2ea;")
        lay.addWidget(ed)
        row = QHBoxLayout(); row.addStretch(1)
        copy = QPushButton("Copy"); copy.clicked.connect(lambda: QApplication.clipboard().setText(code))
        close = QPushButton("Close"); close.clicked.connect(self.accept)
        row.addWidget(copy); row.addWidget(close); lay.addLayout(row)


class LedStudioDialog(QDialog):
    def __init__(self, parent=None, target="NOHD"):
        super().__init__(parent)
        self.parent_win = parent
        self.target = target
        self.setWindowTitle("EOS LED Studio 2.0")
        self.resize(1080, 760)

        self.frames = [[BLACK] * 12]
        self.delays = [120]
        self.play_idx = 0
        self.manual_mode = False
        self._building = True

        root = QVBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 10)
        root.setSpacing(8)

        # ----- device / strip setup -----
        setup = QGroupBox("Strip setup")
        sr = QHBoxLayout(setup)
        sr.addWidget(QLabel("Pin"))
        self.cb_pin = QComboBox()
        pins = list(L.PINS)
        if target == "HD": pins = [p for p in pins if p not in L.HD_RESERVED]
        self.cb_pin.addItems(pins)
        if "EXP4" in pins: self.cb_pin.setCurrentText("EXP4")
        sr.addWidget(self.cb_pin)
        sr.addWidget(QLabel("LEDs"))
        self.sp_count = QSpinBox(); self.sp_count.setRange(1, L.LIMITS["WS_MAX_COUNT"]); self.sp_count.setValue(12)
        sr.addWidget(self.sp_count)
        sr.addWidget(QLabel("Preview"))
        self.cb_layout = QComboBox(); self.cb_layout.addItems(["Strip", "Ring"]); sr.addWidget(self.cb_layout)
        sr.addWidget(QLabel("Name"))
        self.ed_name = QLineEdit("anim"); self.ed_name.setMaxLength(12); self.ed_name.setFixedWidth(100); sr.addWidget(self.ed_name)
        sr.addStretch(1)
        sr.addWidget(QLabel(f"Target: {target}"))
        root.addWidget(setup)

        self.tabs = QTabWidget(); root.addWidget(self.tabs, 1)

        # ===================================================================
        # DESIGNER TAB
        # ===================================================================
        designer = QWidget(); self.tabs.addTab(designer, "Designer")
        dl = QVBoxLayout(designer); dl.setContentsMargins(6, 8, 6, 6)
        split = QSplitter(Qt.Horizontal); dl.addWidget(split, 1)

        # Live preview left
        left = QWidget(); ll = QVBoxLayout(left); ll.setContentsMargins(0, 0, 8, 0)
        title = QLabel("<b>Live preview</b>")
        ll.addWidget(title)
        self.preview = LedPreview(); ll.addWidget(self.preview, 1)
        playrow = QHBoxLayout()
        self.btn_play = QPushButton("▶ Preview")
        self.btn_play.clicked.connect(self.toggle_play)
        playrow.addWidget(self.btn_play)
        self.btn_prev = QPushButton("◀"); self.btn_prev.clicked.connect(lambda: self.step_preview(-1)); playrow.addWidget(self.btn_prev)
        self.btn_next = QPushButton("▶"); self.btn_next.clicked.connect(lambda: self.step_preview(1)); playrow.addWidget(self.btn_next)
        self.lbl_frame = QLabel("Frame 1/1"); playrow.addWidget(self.lbl_frame)
        playrow.addStretch(1)
        ll.addLayout(playrow)
        split.addWidget(left)

        # Controls right
        right = QWidget(); rr = QVBoxLayout(right); rr.setContentsMargins(8, 0, 0, 0)
        form = QFormLayout(); form.setLabelAlignment(Qt.AlignRight)
        self.cb_effect = QComboBox(); self.cb_effect.addItems(G.EFFECT_SPECS.keys()); form.addRow("Effect", self.cb_effect)
        self.lbl_desc = QLabel(); self.lbl_desc.setWordWrap(True); self.lbl_desc.setStyleSheet("color:#90a4ae;"); form.addRow("", self.lbl_desc)
        self.cb_quality = QComboBox(); self.cb_quality.addItems(G.QUALITY_FRAMES.keys()); self.cb_quality.setCurrentText("Balanced"); form.addRow("Quality", self.cb_quality)
        self.cb_direction = QComboBox(); self.cb_direction.addItems(["Forward", "Reverse"]); form.addRow("Direction", self.cb_direction)
        self.sp_offset = QSpinBox(); self.sp_offset.setRange(0, L.LIMITS["WS_MAX_COUNT"]-1); form.addRow("Start offset", self.sp_offset)
        rr.addLayout(form)

        self.sl_speed, self.lbl_speed = self._slider_row(rr, "Speed", 0, 255, 145)
        self.sl_intensity, self.lbl_intensity = self._slider_row(rr, "Intensity", 0, 255, 165)
        self.sl_width, self.lbl_width = self._slider_row(rr, "Width / gap", 1, 30, 5)
        self.sl_bri, self.lbl_bri = self._slider_row(rr, "Brightness", 1, 255, 255)

        palbox = QGroupBox("Palette")
        pg = QGridLayout(palbox)
        defaults = G.PALETTE_PRESETS["EOS Purple"]
        self.color_buttons = []
        for i, col in enumerate(defaults):
            b = ColorButton(chr(ord('A')+i), col)
            self.color_buttons.append(b); pg.addWidget(b, i//2, i%2)
        self.cb_preset = QComboBox(); self.cb_preset.addItems(["Palette preset…"] + list(G.PALETTE_PRESETS.keys()))
        pg.addWidget(self.cb_preset, 2, 0, 1, 2)
        rr.addWidget(palbox)

        genrow = QHBoxLayout()
        self.btn_regen = QPushButton("Regenerate")
        self.btn_regen.clicked.connect(self.regenerate)
        self.btn_custom = QPushButton("Edit generated frames")
        self.btn_custom.clicked.connect(lambda: self.tabs.setCurrentIndex(1))
        genrow.addWidget(self.btn_regen); genrow.addWidget(self.btn_custom)
        rr.addLayout(genrow)
        rr.addStretch(1)
        split.addWidget(right)
        split.setSizes([660, 360])

        # ===================================================================
        # FRAMES TAB (advanced/manual)
        # ===================================================================
        frames_tab = QWidget(); self.tabs.addTab(frames_tab, "Frames / manual")
        fl = QVBoxLayout(frames_tab)
        note = QLabel("Advanced mode: paint individual LEDs or edit generated frames. Manual edits stop automatic effect regeneration until you return to Designer and change an effect control.")
        note.setWordWrap(True); note.setStyleSheet("color:#90a4ae;"); fl.addWidget(note)
        manual_split = QSplitter(Qt.Horizontal); fl.addWidget(manual_split, 1)
        self.manual_preview = LedPreview(); self.manual_preview.editable = True; self.manual_preview.layout_mode = "Strip"
        self.manual_preview.changed.connect(self.on_manual_paint)
        manual_split.addWidget(self.manual_preview)
        side = QWidget(); sv = QVBoxLayout(side)
        sv.addWidget(QLabel("<b>Frames</b>"))
        self.lst = QListWidget(); self.lst.currentRowChanged.connect(self.on_select_frame); sv.addWidget(self.lst, 1)
        drow = QHBoxLayout(); drow.addWidget(QLabel("Delay ms"))
        self.sp_delay = QSpinBox(); self.sp_delay.setRange(0, L.LIMITS["DELAY_MAX"]); self.sp_delay.valueChanged.connect(self.on_delay)
        drow.addWidget(self.sp_delay); sv.addLayout(drow)
        ops = QGridLayout()
        for i, (label, fn) in enumerate([
            ("Add", self.add_frame), ("Duplicate", self.dup_frame),
            ("Delete", self.del_frame), ("Clear", self.clear_frame),
            ("Up", lambda: self.move_frame(-1)), ("Down", lambda: self.move_frame(1))]):
            b = QPushButton(label); b.clicked.connect(fn); ops.addWidget(b, i//2, i%2)
        sv.addLayout(ops)
        sv.addWidget(QLabel("Paint colour"))
        self.paint_color_btn = ColorButton("Paint", defaults[0]); self.paint_color_btn.colorChanged.connect(self.on_paint_color)
        sv.addWidget(self.paint_color_btn)
        manual_split.addWidget(side); manual_split.setSizes([760, 260])

        # ----- budget / export -----
        budget = QGroupBox("EOS budget")
        br = QHBoxLayout(budget)
        self.lbl_budget = QLabel(); self.lbl_budget.setMinimumWidth(420)
        self.pb_payload = QProgressBar(); self.pb_payload.setRange(0, 100); self.pb_payload.setTextVisible(True)
        self.pb_data = QProgressBar(); self.pb_data.setRange(0, 100); self.pb_data.setTextVisible(True)
        br.addWidget(self.lbl_budget, 1); br.addWidget(QLabel("Payload")); br.addWidget(self.pb_payload); br.addWidget(QLabel("DATA")); br.addWidget(self.pb_data)
        root.addWidget(budget)

        bottom = QHBoxLayout()
        self.btn_script = QPushButton("View script"); self.btn_script.clicked.connect(self.view_script); bottom.addWidget(self.btn_script)
        self.btn_copy = QPushButton("Copy script"); self.btn_copy.clicked.connect(self.copy_code); bottom.addWidget(self.btn_copy)
        bottom.addStretch(1)
        self.btn_open = QPushButton("Open as new tab"); self.btn_open.clicked.connect(self.open_new); bottom.addWidget(self.btn_open)
        close = QPushButton("Close"); close.clicked.connect(self.reject); bottom.addWidget(close)
        root.addLayout(bottom)

        self.timer = QTimer(self); self.timer.timeout.connect(self._tick)
        self._wire_controls()
        self._apply_theme()
        self._building = False
        self.regenerate()

    def _slider_row(self, parent_layout, title, lo, hi, value):
        box = QHBoxLayout(); lab = QLabel(title); lab.setFixedWidth(78)
        sl = QSlider(Qt.Horizontal); sl.setRange(lo, hi); sl.setValue(value)
        val = QLabel(str(value)); val.setFixedWidth(34); val.setAlignment(Qt.AlignRight | Qt.AlignVCenter)
        box.addWidget(lab); box.addWidget(sl, 1); box.addWidget(val); parent_layout.addLayout(box)
        sl.valueChanged.connect(lambda v, lbl=val: lbl.setText(str(v)))
        return sl, val

    def _wire_controls(self):
        self.sp_count.valueChanged.connect(self.on_design_changed)
        self.cb_layout.currentTextChanged.connect(self.on_layout_changed)
        self.cb_effect.currentTextChanged.connect(self.on_effect_changed)
        self.cb_quality.currentTextChanged.connect(self.on_design_changed)
        self.cb_direction.currentTextChanged.connect(self.on_design_changed)
        self.sp_offset.valueChanged.connect(self.on_design_changed)
        for sl in (self.sl_speed, self.sl_intensity, self.sl_width, self.sl_bri):
            sl.valueChanged.connect(self.on_design_changed)
        for b in self.color_buttons:
            b.colorChanged.connect(self.on_design_changed)
        self.cb_preset.currentTextChanged.connect(self.on_preset)

    def palette(self):
        return [b.color for b in self.color_buttons]

    def on_preset(self, name):
        if name not in G.PALETTE_PRESETS:
            return
        for b, c in zip(self.color_buttons, G.PALETTE_PRESETS[name]):
            b.set_color(c, emit=False)
        self.on_design_changed()
        self.cb_preset.blockSignals(True); self.cb_preset.setCurrentIndex(0); self.cb_preset.blockSignals(False)

    def on_layout_changed(self, mode):
        self.preview.layout_mode = mode; self.preview.update()

    def on_effect_changed(self, *_):
        self.manual_mode = False
        self._update_control_relevance()
        self.regenerate()

    def on_design_changed(self, *_):
        if self._building:
            return
        self.manual_mode = False
        self.regenerate()

    def _update_control_relevance(self):
        name = self.cb_effect.currentText()
        spec = G.EFFECT_SPECS.get(name, {})
        self.lbl_desc.setText(spec.get("desc", ""))
        controls = set(spec.get("controls", ()))
        self.sl_speed.setEnabled("speed" in controls)
        self.sl_intensity.setEnabled("intensity" in controls)
        self.sl_width.setEnabled("width" in controls)
        for i, b in enumerate(self.color_buttons):
            key = f"color{chr(ord('A')+i)}"
            b.setEnabled(key in controls)

    def regenerate(self):
        if self._building:
            return
        count = self.sp_count.value()
        self.sp_offset.setMaximum(max(0, count - 1))
        frames, delays = G.render_design(
            self.cb_effect.currentText(), count,
            quality=self.cb_quality.currentText(), palette=self.palette(),
            speed=self.sl_speed.value(), intensity=self.sl_intensity.value(),
            width=self.sl_width.value(), direction=self.cb_direction.currentText(),
            offset=self.sp_offset.value())
        self.frames = [list(f) for f in frames]
        self.delays = list(delays)
        self.manual_mode = False
        self.play_idx = 0
        self.refresh_list()
        self.lst.setCurrentRow(0)
        self.show_frame(0)
        self._update_control_relevance()
        self.update_budget()

    # ----- frame/manual tools -----
    def cur(self):
        return max(0, min(len(self.frames)-1, self.lst.currentRow()))

    def refresh_list(self):
        row = self.lst.currentRow()
        self.lst.blockSignals(True); self.lst.clear()
        for i, d in enumerate(self.delays):
            self.lst.addItem(QListWidgetItem(f"Frame {i+1:02d}   {d} ms"))
        self.lst.blockSignals(False)
        if self.frames:
            self.lst.setCurrentRow(min(max(row, 0), len(self.frames)-1))

    def show_frame(self, i):
        if not self.frames:
            return
        i %= len(self.frames)
        self.preview.preview_brightness = self.sl_bri.value()
        self.manual_preview.preview_brightness = self.sl_bri.value()
        self.preview.set_frame(self.frames[i])
        self.manual_preview.set_frame(self.frames[i])
        self.lbl_frame.setText(f"Frame {i+1}/{len(self.frames)}")

    def on_select_frame(self, row):
        if 0 <= row < len(self.frames):
            self.sp_delay.blockSignals(True); self.sp_delay.setValue(self.delays[row]); self.sp_delay.blockSignals(False)
            self.show_frame(row)

    def on_paint_color(self, col): self.manual_preview.paint_color = tuple(col)

    def on_manual_paint(self):
        self.manual_mode = True
        self.frames[self.cur()] = list(self.manual_preview.frame)
        self.preview.set_frame(self.frames[self.cur()])
        self.update_budget()

    def on_delay(self, v):
        if not self.frames: return
        self.manual_mode = True
        self.delays[self.cur()] = v
        self.refresh_list(); self.update_budget()

    def add_frame(self):
        self.manual_mode = True
        i = self.cur(); self.frames.insert(i+1, [BLACK]*self.sp_count.value()); self.delays.insert(i+1, 120)
        self.refresh_list(); self.lst.setCurrentRow(i+1); self.update_budget()

    def dup_frame(self):
        self.manual_mode = True
        i = self.cur(); self.frames.insert(i+1, list(self.frames[i])); self.delays.insert(i+1, self.delays[i])
        self.refresh_list(); self.lst.setCurrentRow(i+1); self.update_budget()

    def del_frame(self):
        if len(self.frames) <= 1: return
        self.manual_mode = True
        i = self.cur(); self.frames.pop(i); self.delays.pop(i)
        self.refresh_list(); self.lst.setCurrentRow(min(i, len(self.frames)-1)); self.update_budget()

    def clear_frame(self):
        self.manual_mode = True
        i = self.cur(); self.frames[i] = [BLACK]*self.sp_count.value(); self.show_frame(i)

    def move_frame(self, d):
        i = self.cur(); j = i+d
        if 0 <= j < len(self.frames):
            self.manual_mode = True
            self.frames[i], self.frames[j] = self.frames[j], self.frames[i]
            self.delays[i], self.delays[j] = self.delays[j], self.delays[i]
            self.refresh_list(); self.lst.setCurrentRow(j)

    # ----- preview -----
    def toggle_play(self):
        if self.timer.isActive():
            self.timer.stop(); self.btn_play.setText("▶ Preview")
        else:
            self.play_idx = self.cur(); self.btn_play.setText("■ Stop"); self._tick()

    def _tick(self):
        if not self.frames: return
        self.show_frame(self.play_idx)
        d = max(10, self.delays[self.play_idx])
        self.play_idx = (self.play_idx + 1) % len(self.frames)
        self.timer.start(d)

    def step_preview(self, delta):
        if self.timer.isActive(): self.toggle_play()
        self.play_idx = (self.play_idx + delta) % len(self.frames)
        self.show_frame(self.play_idx)
        self.lst.setCurrentRow(self.play_idx)

    # ----- budget / export -----
    def update_budget(self):
        info = G.budget_info(self.sp_count.value(), len(self.frames))
        p_pct = min(100, int(info["payload_used"] * 100 / max(1, info["payload_max"])))
        d_pct = min(100, int(info["data_slots_used"] * 100 / max(1, info["data_slots_max"])))
        self.pb_payload.setValue(p_pct); self.pb_payload.setFormat(f"{info['payload_used']}/{info['payload_max']} B")
        self.pb_data.setValue(d_pct); self.pb_data.setFormat(f"{info['data_slots_used']}/{info['data_slots_max']}")
        if info["problems"]:
            self.lbl_budget.setText("⚠ " + " ".join(info["problems"])); self.lbl_budget.setStyleSheet("color:#ff8a80;")
        else:
            mode = "manual" if self.manual_mode else self.cb_quality.currentText().lower()
            self.lbl_budget.setText(f"✓ {len(self.frames)} frame(s) • {info['frame_bytes']} B/frame • {mode} • max {info['max_frames_for_count']} frames at this LED count")
            self.lbl_budget.setStyleSheet("color:#7ee787;")

    def _code(self):
        return G.generate_script(self.cb_pin.currentText(), self.ed_name.text() or "anim",
                                 self.frames, self.delays, brightness=self.sl_bri.value(),
                                 target=self.target)

    def _blocked(self):
        probs = G.check_budget(self.sp_count.value(), len(self.frames))
        if probs:
            QMessageBox.warning(self, "Out of bounds", "Fix these first:\n\n- " + "\n- ".join(probs)); return True
        return False

    def view_script(self):
        if not self._blocked(): ScriptPreviewDialog(self._code(), self).exec()

    def copy_code(self):
        if self._blocked(): return
        QApplication.clipboard().setText(self._code())
        QMessageBox.information(self, "Copied", "EOS LED script copied to the clipboard.")

    def open_new(self):
        if self._blocked(): return
        code = self._code()
        if self.parent_win and hasattr(self.parent_win, "add_tab"):
            self.parent_win.add_tab(code)
            if hasattr(self.parent_win, "run_lint"): self.parent_win.run_lint()
            self.accept()
        else:
            QApplication.clipboard().setText(code)
            QMessageBox.information(self, "Copied", "No editor window was available, so the script was copied instead.")

    def _apply_theme(self):
        self.setStyleSheet("""
            QDialog, QWidget { background:#10161c; color:#d5dde2; }
            QGroupBox { border:1px solid #2b3942; border-radius:6px; margin-top:8px; padding-top:8px; font-weight:600; }
            QGroupBox::title { subcontrol-origin:margin; left:10px; padding:0 4px; }
            QListWidget, QPlainTextEdit { background:#111a21; border:1px solid #2b3942; border-radius:4px; }
            QLineEdit, QSpinBox, QComboBox { background:#182129; border:1px solid #3b4c57; padding:5px; border-radius:4px; }
            QPushButton { background:#25343e; border:1px solid #41545f; padding:6px 10px; border-radius:4px; }
            QPushButton:hover { background:#324650; }
            QPushButton:disabled { color:#60727c; background:#182129; }
            QTabWidget::pane { border:1px solid #2b3942; }
            QTabBar::tab { background:#172129; padding:7px 14px; border:1px solid #2b3942; }
            QTabBar::tab:selected { background:#25343e; }
            QProgressBar { border:1px solid #3b4c57; border-radius:3px; text-align:center; min-width:130px; }
        """)
