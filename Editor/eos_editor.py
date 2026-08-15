"""
EOS Script Editor — a beginner-friendly mini-IDE for writing .eos scripts.

Robustness:  tabbed multi-file editing, menu bar + shortcuts, find/replace,
unsaved-change tracking with a close prompt, recent files, comment toggle.

Clarity for beginners:
  * live in-bounds validation (the exact linter the gateware trusts) with red
    underlines and a click-to-jump Problems list — each error carries a fix hint
  * IntelliSense-style parameter hints: the signature of the command on the
    current line, with the operand you're typing highlighted
  * hover any token to see what it is (command signature, pin assignment, a DEF's
    value, a DATA's byte length, a register's address)
  * word autocomplete (commands, directives, pins, registers, your DEF/DATA names)
  * an "Insert" menu of ready-made, in-bounds snippets
  * a plain-English "Overview" panel + a live Pins & Budget map
  * a built-in "Guide" panel with the essentials

Run:  pip install PySide6  &&  python eos_editor.py
"""
import sys
import os
import json

from PySide6.QtCore import Qt, QRect, QSize, QTimer, Signal, QEvent, QStringListModel
from PySide6.QtGui import (QColor, QFont, QPainter, QTextFormat, QTextCharFormat,
                           QSyntaxHighlighter, QTextCursor, QAction, QKeySequence,
                           QFontDatabase, QTextDocument)
from PySide6.QtWidgets import (QApplication, QPlainTextEdit, QWidget, QTextEdit,
                               QMainWindow, QDockWidget, QListWidget, QListWidgetItem,
                               QVBoxLayout, QHBoxLayout, QLabel, QFrame, QCompleter,
                               QFileDialog, QMessageBox, QGridLayout, QScrollArea,
                               QProgressBar, QTabWidget, QLineEdit, QPushButton,
                               QStatusBar, QTextBrowser, QToolTip, QDialog)

import eos_language as L
import eos_linter as LT
import eos_report as R

APP_NAME = "EOS Script Editor"
RECENT_PATH = os.path.expanduser("~/.eos_editor_recent.json")


# ==========================================================================
class EosHighlighter(QSyntaxHighlighter):
    def __init__(self, doc):
        super().__init__(doc)
        self.user_names = set()

        def fmt(color, bold=False):
            f = QTextCharFormat(); f.setForeground(QColor(color))
            if bold: f.setFontWeight(QFont.Bold)
            return f
        self.f_cmd = fmt("#4fc3f7", True); self.f_dir = fmt("#ce93d8", True)
        self.f_kw = fmt("#80cbc4"); self.f_pin = fmt("#ffb74d")
        self.f_reg = fmt("#f06292"); self.f_num = fmt("#aed581")
        self.f_com = fmt("#546e7a"); self.f_user = fmt("#fff59d")
        self.cmds = {c.upper() for c in L.ALL_COMMAND_NAMES}
        self.dirs = {d.upper() for d in L.ALL_DIRECTIVE_NAMES}
        self.kws = {k.upper() for k in (L.SUBKEYWORDS + L.PIN_TYPES + L.CMP_OPS)}
        self.pins = {p.upper() for p in L.PINS}
        self.regs = {r.upper() for r in L.REGISTERS}

    def set_user_names(self, names): self.user_names = {n.upper() for n in names}

    def highlightBlock(self, text):
        i, n = 0, len(text)
        while i < n:
            ch = text[i]
            if ch == "#":
                self.setFormat(i, n - i, self.f_com); break
            if ch.isspace(): i += 1; continue
            j = i
            while j < n and not text[j].isspace() and text[j] != "#": j += 1
            up = text[i:j].upper()
            if up in self.cmds: self.setFormat(i, j - i, self.f_cmd)
            elif up in self.dirs: self.setFormat(i, j - i, self.f_dir)
            elif up in self.pins: self.setFormat(i, j - i, self.f_pin)
            elif up in self.regs: self.setFormat(i, j - i, self.f_reg)
            elif up in self.kws: self.setFormat(i, j - i, self.f_kw)
            elif up in self.user_names: self.setFormat(i, j - i, self.f_user)
            elif text[i].isdigit(): self.setFormat(i, j - i, self.f_num)
            i = j


# ==========================================================================
class LineNumberArea(QWidget):
    def __init__(self, editor): super().__init__(editor); self.editor = editor
    def sizeHint(self): return QSize(self.editor.line_number_area_width(), 0)
    def paintEvent(self, e): self.editor.line_number_area_paint(e)


class CodeEditor(QPlainTextEdit):
    paramHint = Signal(str, int)

    def __init__(self, model_provider):
        super().__init__()
        self.model_provider = model_provider
        self.line_area = LineNumberArea(self)
        self.blockCountChanged.connect(self.update_line_area_width)
        self.updateRequest.connect(self.update_line_area)
        self.cursorPositionChanged.connect(self.on_cursor)
        self.update_line_area_width(0)
        mono = QFontDatabase.systemFont(QFontDatabase.FixedFont); mono.setPointSize(12)
        self.setFont(mono); self.setTabStopDistance(28)
        self.setLineWrapMode(QPlainTextEdit.NoWrap); self.setMouseTracking(True)
        self.error_lines = {}
        self.completer = QCompleter(self); self.completer.setWidget(self)
        self.completer.setCaseSensitivity(Qt.CaseInsensitive)
        self.completer.activated.connect(self.insert_completion)
        self.cmodel = QStringListModel(L.completion_words(), self.completer)
        self.completer.setModel(self.cmodel)

    def line_number_area_width(self):
        digits = max(3, len(str(max(1, self.blockCount()))))
        return 14 + self.fontMetrics().horizontalAdvance("9") * digits
    def update_line_area_width(self, _):
        self.setViewportMargins(self.line_number_area_width(), 0, 0, 0)
    def update_line_area(self, rect, dy):
        if dy: self.line_area.scroll(0, dy)
        else: self.line_area.update(0, rect.y(), self.line_area.width(), rect.height())
        if rect.contains(self.viewport().rect()): self.update_line_area_width(0)
    def resizeEvent(self, e):
        super().resizeEvent(e); cr = self.contentsRect()
        self.line_area.setGeometry(QRect(cr.left(), cr.top(),
                                         self.line_number_area_width(), cr.height()))
    def line_number_area_paint(self, event):
        p = QPainter(self.line_area); p.fillRect(event.rect(), QColor("#1b2027"))
        block = self.firstVisibleBlock(); num = block.blockNumber()
        top = self.blockBoundingGeometry(block).translated(self.contentOffset()).top()
        bottom = top + self.blockBoundingRect(block).height()
        while block.isValid() and top <= event.rect().bottom():
            if block.isVisible() and bottom >= event.rect().top():
                ln = num + 1
                if ln in self.error_lines:
                    p.setPen(QColor("#ff5252"))
                    p.drawText(2, int(top), 10, self.fontMetrics().height(),
                               Qt.AlignLeft, "\u25cf")
                    p.setPen(QColor("#ff8a80"))
                else:
                    p.setPen(QColor("#546e7a"))
                p.drawText(0, int(top), self.line_area.width() - 6,
                           self.fontMetrics().height(), Qt.AlignRight, str(ln))
            block = block.next(); top = bottom
            bottom = top + self.blockBoundingRect(block).height(); num += 1

    def set_errors(self, error_lines):
        self.error_lines = error_lines; self.refresh_extra_selections(); self.line_area.update()
    def refresh_extra_selections(self):
        sels = []
        cur = QTextEdit.ExtraSelection()
        cur.format.setBackground(QColor("#20272f"))
        cur.format.setProperty(QTextFormat.FullWidthSelection, True)
        cur.cursor = self.textCursor(); cur.cursor.clearSelection(); sels.append(cur)
        for ln in self.error_lines:
            b = self.document().findBlockByNumber(ln - 1)
            if not b.isValid(): continue
            sel = QTextEdit.ExtraSelection()
            sel.format.setUnderlineStyle(QTextCharFormat.WaveUnderline)
            sel.format.setUnderlineColor(QColor("#ff5252"))
            c = QTextCursor(b); c.select(QTextCursor.LineUnderCursor)
            sel.cursor = c; sels.append(sel)
        self.setExtraSelections(sels)
    def goto_line(self, ln):
        b = self.document().findBlockByNumber(ln - 1)
        if b.isValid():
            self.setTextCursor(QTextCursor(b)); self.centerCursor(); self.setFocus()

    def on_cursor(self):
        self.refresh_extra_selections()
        c = self.textCursor(); text = c.block().text(); col = c.positionInBlock()
        toks = text[:col].split(); head = toks[0] if toks else ""
        arg_index = max(0, len(toks) - 1)
        if col > 0 and text[:col].endswith(" "): arg_index = len(toks)
        self.paramHint.emit(head, arg_index)

    def event(self, e):
        if e.type() == QEvent.ToolTip:
            cur = self.cursorForPosition(e.pos()); cur.select(QTextCursor.WordUnderCursor)
            tip = self._tooltip_for(cur.selectedText())
            if tip: QToolTip.showText(e.globalPos(), tip, self)
            else: QToolTip.hideText()
            return True
        return super().event(e)

    def _tooltip_for(self, word):
        if not word: return ""
        up = word.upper(); sig = L.signature_of(word)
        if sig: return sig
        model = self.model_provider()
        if model is None: return ""
        if up in L.PINS:
            pd = model.pin_owner(up)
            if pd: return f"{up} — {pd.ptype} (pin-def {pd.index})"
            return f"{up} — unused pin (FPGA {L.PIN_FPGA.get(up)})"
        if up in model.defs:
            v = model.defs[up]; return f"DEF {word} = {v} (0x{v:02X})"
        if up in model.datas:
            return f"DATA {word} — {model.datas[up]} bytes"
        for pd in model.pindefs:
            for r in pd.regs:
                if r.name == up:
                    a = pd.bank_off + r.off_in_bank
                    return (f"register {word.lower()} — {r.width} B @ volatile "
                            f"0x{a:02X} (pin-def {pd.index})")
        return ""

    def text_under_cursor(self):
        c = self.textCursor(); c.select(QTextCursor.WordUnderCursor); return c.selectedText()
    def insert_completion(self, completion):
        tc = self.textCursor(); prefix = self.completer.completionPrefix()
        extra = len(completion) - len(prefix)
        tc.movePosition(QTextCursor.Left); tc.movePosition(QTextCursor.EndOfWord)
        tc.insertText(completion[len(completion) - extra:]); self.setTextCursor(tc)
    def refresh_completions(self, defs, datas, regs):
        self.cmodel.setStringList(L.completion_words(defs, datas, regs))
    def keyPressEvent(self, e):
        if self.completer.popup().isVisible() and e.key() in (
                Qt.Key_Enter, Qt.Key_Return, Qt.Key_Escape, Qt.Key_Tab, Qt.Key_Backtab):
            e.ignore(); return
        super().keyPressEvent(e)
        prefix = self.text_under_cursor()
        if len(prefix) >= 1 and (prefix[-1].isalnum() or prefix[-1] == "_"):
            if prefix != self.completer.completionPrefix():
                self.completer.setCompletionPrefix(prefix)
                self.completer.popup().setCurrentIndex(
                    self.completer.completionModel().index(0, 0))
            cr = self.cursorRect()
            cr.setWidth(self.completer.popup().sizeHintForColumn(0) +
                        self.completer.popup().verticalScrollBar().sizeHint().width())
            self.completer.complete(cr)
        else:
            self.completer.popup().hide()

    def toggle_comment(self):
        c = self.textCursor(); c.beginEditBlock()
        start, end = c.selectionStart(), c.selectionEnd()
        c.setPosition(start); s_blk = c.blockNumber()
        c.setPosition(end); e_blk = c.blockNumber()
        doc = self.document()
        blocks = [doc.findBlockByNumber(i) for i in range(s_blk, e_blk + 1)]
        active = [b for b in blocks if b.text().strip()]
        all_commented = active and all(b.text().lstrip().startswith("#") for b in active)
        for b in blocks:
            if not b.text().strip(): continue
            cur = QTextCursor(b); txt = b.text()
            if all_commented:
                idx = txt.find("#"); lead = len(txt) - len(txt.lstrip())
                cur.setPosition(b.position() + idx); cur.deleteChar()
                if idx + 1 < len(txt) and txt[idx + 1] == " ": cur.deleteChar()
            else:
                cur.setPosition(b.position()); cur.insertText("# ")
        c.endEditBlock()


# ==========================================================================
class EditorTab(QWidget):
    def __init__(self):
        super().__init__()
        self.path = None; self.dirty = False; self.model = None; self.diags = []
        lay = QVBoxLayout(self); lay.setContentsMargins(0, 0, 0, 0)
        self.editor = CodeEditor(lambda: self.model)
        self.highlighter = EosHighlighter(self.editor.document())
        lay.addWidget(self.editor)
    def title(self):
        base = os.path.basename(self.path) if self.path else "untitled"
        return ("* " + base) if self.dirty else base


# ==========================================================================
class FindBar(QWidget):
    def __init__(self, get_editor):
        super().__init__(); self.get_editor = get_editor
        lay = QHBoxLayout(self); lay.setContentsMargins(6, 4, 6, 4)
        self.find = QLineEdit(); self.find.setPlaceholderText("Find")
        self.repl = QLineEdit(); self.repl.setPlaceholderText("Replace")
        b_next = QPushButton("Next"); b_prev = QPushButton("Prev")
        b_rep = QPushButton("Replace"); b_all = QPushButton("All")
        b_close = QPushButton("\u2715"); b_close.setFixedWidth(28)
        for w in (self.find, b_next, b_prev, self.repl, b_rep, b_all, b_close):
            lay.addWidget(w)
        b_next.clicked.connect(lambda: self.do_find(True))
        b_prev.clicked.connect(lambda: self.do_find(False))
        self.find.returnPressed.connect(lambda: self.do_find(True))
        b_rep.clicked.connect(self.do_replace); b_all.clicked.connect(self.do_replace_all)
        b_close.clicked.connect(self.hide); self.hide()
    def show_bar(self): self.show(); self.find.setFocus(); self.find.selectAll()
    def do_find(self, forward=True):
        ed = self.get_editor()
        if not ed: return
        f = QTextDocument.FindFlags()
        if not forward: f |= QTextDocument.FindBackward
        if not ed.find(self.find.text(), f):
            c = ed.textCursor(); c.movePosition(QTextCursor.Start if forward else QTextCursor.End)
            ed.setTextCursor(c); ed.find(self.find.text(), f)
    def do_replace(self):
        ed = self.get_editor()
        if not ed: return
        c = ed.textCursor()
        if c.hasSelection() and c.selectedText() == self.find.text():
            c.insertText(self.repl.text())
        self.do_find(True)
    def do_replace_all(self):
        ed = self.get_editor()
        if ed and self.find.text():
            ed.setPlainText(ed.toPlainText().replace(self.find.text(), self.repl.text()))


# ==========================================================================
PIN_COLORS = {"GPIO_IN": "#4dd0e1", "GPIO_OUT": "#4db6ac", "PWM": "#9575cd",
              "WS2812": "#ff8a65", "I2C": "#ffd54f"}


class StatBar(QWidget):
    def __init__(self, label):
        super().__init__()
        lay = QHBoxLayout(self); lay.setContentsMargins(0, 1, 0, 1)
        self.name = QLabel(label); self.name.setMinimumWidth(66)
        self.bar = QProgressBar(); self.bar.setTextVisible(True); self.bar.setFixedHeight(15)
        lay.addWidget(self.name); lay.addWidget(self.bar)
    def set(self, used, total):
        self.bar.setMaximum(total); self.bar.setValue(min(used, total))
        self.bar.setFormat(f"{used}/{total}")
        col = "#ff5252" if used > total else ("#ffb300" if used > 0.85 * total else "#66bb6a")
        self.bar.setStyleSheet(
            "QProgressBar{border:1px solid #37474f;border-radius:3px;background:#1b2027;}"
            f"QProgressBar::chunk{{background:{col};border-radius:2px;}}")


class PinsPanel(QWidget):
    def __init__(self):
        super().__init__()
        root = QVBoxLayout(self); root.setSpacing(6)
        root.addWidget(QLabel("<b>Pins</b>"))
        self.pin_labels = {}
        grid = QGridLayout(); grid.setSpacing(4)
        for i, pin in enumerate(L.PINS):
            lbl = QLabel(pin); lbl.setAlignment(Qt.AlignCenter)
            lbl.setFixedHeight(24); lbl.setFrameShape(QFrame.StyledPanel)
            self.pin_labels[pin] = lbl; grid.addWidget(lbl, i // 2, i % 2)
        root.addLayout(grid)
        root.addWidget(QLabel("<b>Budget</b>"))
        self.s_pins = StatBar("Pins"); self.s_vol = StatBar("Mailbox")
        self.s_instr = StatBar("Instr"); self.s_pay = StatBar("Data")
        for s in (self.s_pins, self.s_vol, self.s_instr, self.s_pay): root.addWidget(s)
        root.addStretch(1)
    def update_model(self, model):
        used = {p: None for p in L.PINS}
        for pd in model.pindefs:
            for p in pd.pins: used[p] = pd.ptype
        hd = model.target == "HD"
        for pin, lbl in self.pin_labels.items():
            if hd and pin in L.HD_RESERVED:
                lbl.setStyleSheet("background:#242424;color:#616161;border:1px dashed #616161;")
                lbl.setText(f"{pin}\u00b7HD")
            elif used[pin]:
                c = PIN_COLORS.get(used[pin], "#78909c")
                lbl.setStyleSheet(f"background:{c};color:#10161c;font-weight:bold;")
                lbl.setText(f"{pin}\u00b7{used[pin]}")
            else:
                lbl.setStyleSheet("background:#1b2027;color:#78909c;border:1px solid #37474f;")
                lbl.setText(pin)
        budget = L.LIMITS["PINS_HD"] if hd else L.LIMITS["PINS_NOHD"]
        self.s_pins.set(model.pins_used, budget)
        self.s_vol.set(model.volatile_used, L.LIMITS["VOLATILE_USABLE_TOP"])
        self.s_instr.set(model.instruction_count, L.LIMITS["MAX_INSTRUCTIONS"])
        self.s_pay.set(model.payload_bytes, L.LIMITS["MAX_PAYLOAD_DECODED"])


# ==========================================================================
SNIPPETS = {
    "WS2812 strip": "USES EXP4 AS WS2812 COUNT 8\n  REG color WIDTH 3\n",
    "GPIO output (blink)":
        "USES EXP7 AS GPIO_OUT INIT 0 SAFE 0\n"
        "# in the loop:\n#   SET EXP7 1\n#   DELAY 500\n#   SET EXP7 0\n#   DELAY 500\n",
    "PWM output":
        "USES EXP7 AS PWM INIT 0 SAFE 0\n# in the loop:  PWM EXP7 128 1000\n",
    "I2C device (read)":
        "USES EXP5 EXP6 AS I2C\nDEF DEVICE 0x40\n"
        "# in the loop:\n#   I2CR DEVICE 2 0x20\n#   IFMAIL 0xFF EQ 0 1\n#     GETMAIL 0x20 R0\n",
    "Doorbell handler (Pattern B)":
        "DEF DB0 0x01\n# in the loop:\nIFMAIL DB0 EQ 1 4\n  SETMAIL DB0 2\n"
        "  # ... act on the command ...\n  SETMAIL DB0 3\n  DELAY 2\n",
    "Level-poll a register (Pattern A)":
        "# assumes: REG level WIDTH 1  ->  DEF LEVEL 0x02\nGETMAIL LEVEL R0\nPWM EXP7 R0 1000\n",
}

TEMPLATE = """# EOS Script — new file.  Hover any word for help; check Problems below.
TARGET NOHD

USES EXP4 AS WS2812 COUNT 8
  REG color WIDTH 3

# --- program (runs forever) ---
LOOP
  WS EXP4 warm
  DELAY 700
ENDLOOP
END

# --- data (compact hex: one GRB triple per LED) ---
DATA warm 201000 201000 201000 201000 201000 201000 201000 201000
"""

# --------------------------------------------------------------------------
# "New" templates — each is a complete, in-bounds starting point.
# key -> (glyph, one-line description, body)
# --------------------------------------------------------------------------
NEW_TEMPLATES = {
    "Autonomous WS2812 effect": ("\U0001F308",
        "A strip that animates on its own — no Xbox needed.",
        """# Autonomous WS2812 effect — animates on its own, no Xbox needed.
TARGET NOHD

# One addressable strip on EXP4. Set COUNT to your real LED count.
USES EXP4 AS WS2812 COUNT 8

# Runs forever: fade between two frames.
LOOP
  WS EXP4 dim
  DELAY 600
  WS EXP4 warm
  DELAY 600
ENDLOOP
END

# Frames: compact hex, 3 bytes (G R B) per LED. 8 LEDs = 24 bytes.
DATA dim  080400 080400 080400 080400 080400 080400 080400 080400
DATA warm 201000 201000 201000 201000 201000 201000 201000 201000
"""),

    "Xbox-controlled lighting": ("\U0001F3AE",
        "A game writes a color; the strip follows it (mailbox).",
        """# Xbox-controlled lighting — a game writes a color, the strip follows it.
TARGET NOHD

USES EXP4 AS WS2812 COUNT 1
  REG color WIDTH 3            # 3 bytes: G, R, B — the Xbox writes this

DEF COLOR 0x02                 # 'color' offset (CMD@0x00, DOORBELL@0x01, color@0x02)

LOOP
  WS EXP4 VOL COLOR 3         # push whatever color the Xbox last wrote
  DELAY 25
ENDLOOP
END
"""),

    "GPIO input / output": ("\U0001F518",
        "Read a button, drive an LED — the basics.",
        """# GPIO input/output — mirror a button to an LED.
TARGET NOHD

USES EXP5 AS GPIO_IN                    # a button/switch on EXP5
USES EXP7 AS GPIO_OUT INIT 0 SAFE 0     # an LED on EXP7 (off at start and on fault)

LOOP
  GET EXP5 R0                  # read the button into R0 (0 or 1)
  SET EXP7 R0                  # drive the LED to match
  DELAY 20                     # ~50 Hz poll
ENDLOOP
END
"""),

    "PWM device": ("\U0001F506",
        "Dim an LED or drive a fan; the Xbox can set the level.",
        """# PWM device — drive a fan or dim an LED; the Xbox can set the level.
TARGET NOHD

USES EXP7 AS PWM INIT 0 SAFE 0
  REG level WIDTH 1            # the Xbox writes a 0..255 duty here

DEF LEVEL 0x02                 # 'level' offset (CMD@0x00, DOORBELL@0x01, level@0x02)

LOOP
  GETMAIL LEVEL R0            # read the requested level (0 at power-up)
  PWM EXP7 R0 1000            # apply as PWM duty at 1 kHz (0 stops output)
  DELAY 30
ENDLOOP
END
"""),

    "I\u00b2C accessory / MCU bridge": ("\U0001F517",
        "Relay a command block from the Xbox to your MCU (doorbell).",
        """# I2C accessory / MCU bridge — relay a command block from the Xbox to an MCU.
TARGET NOHD

USES EXP5 EXP6 AS I2C           # SCL on EXP5, SDA on EXP6
  REG payload WIDTH 8           # 8 bytes the Xbox fills before ringing

DEF DB0     0x01                # doorbell byte (CMD@0x00, DOORBELL@0x01)
DEF PAYLOAD 0x02                # payload starts at 0x02
DEF MCU     0x50                # your MCU's I2C address

LOOP
  IFMAIL DB0 EQ 1 4            # doorbell PENDING? run the 4-line handler
    SETMAIL DB0 2             #   -> BUSY (we took it)
    I2CW MCU VOL PAYLOAD 8    #   forward the 8 live bytes to the MCU
    SETMAIL DB0 3             #   -> READY (Xbox reads, then sets IDLE)
    DELAY 2
  DELAY 15                     # idle poll interval
ENDLOOP
END
"""),

    "Empty advanced script": ("\U0001F4C4",
        "Minimal scaffolding — full control for power users.",
        """# Advanced / empty — full control, minimal scaffolding.
TARGET NOHD

# 1) Declare pin-defs and any REG mailbox slots here, e.g.:
#      USES EXP4 AS WS2812 COUNT 16
#        REG color WIDTH 3
#
# 2) Optional constants and payloads:
#      DEF NAME 0x00
#      DATA name <hex>
#
# 3) Program — one command per line, runs forever:
LOOP
  NOP
  DELAY 100
ENDLOOP
END
"""),
}

DEFAULT_TEMPLATE = NEW_TEMPLATES["Autonomous WS2812 effect"][2]


class NewScriptDialog(QDialog):
    """Large-choice picker shown by File -> New."""
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("New EOS Script")
        self.setMinimumWidth(460)
        self.chosen = None
        lay = QVBoxLayout(self)
        head = QLabel("<b>Start from a template</b>")
        head.setStyleSheet("font-size:14px;padding:4px 2px;")
        lay.addWidget(head)
        for key, (glyph, desc, body) in NEW_TEMPLATES.items():
            btn = QPushButton(f"{glyph}   {key}\n        {desc}")
            btn.setStyleSheet(
                "text-align:left; padding:10px 12px; font-size:13px;")
            btn.setMinimumHeight(52)
            btn.clicked.connect(lambda checked=False, b=body: self._pick(b))
            lay.addWidget(btn)
        cancel = QPushButton("Cancel")
        cancel.clicked.connect(self.reject)
        lay.addWidget(cancel)

    def _pick(self, body):
        self.chosen = body
        self.accept()


GUIDE_HTML = """
<h2>EOS Script in 90 seconds</h2>
<p>A script is plain text, <b>one command per line</b> (like assembly). It runs in a
<b>forever loop</b> from the moment the console powers up.</p>
<h3>1 &middot; Declare what you use</h3>
<pre>TARGET NOHD
USES EXP4 AS WS2812 COUNT 8
  REG color WIDTH 3</pre>
<h3>2 &middot; Write the program</h3>
<pre>LOOP
  WS EXP4 warm
  DELAY 700
ENDLOOP
END</pre>
<h3>3 &middot; Add data</h3>
<pre>DATA warm 201000 201000 ...</pre>
<p>Compact hex, 3 bytes (G R B) per LED.</p>
<h3>Talking to the Xbox</h3>
<p>Declare <code>REG</code>s; the Xbox writes them over the mailbox and your script reads
them with <code>GETMAIL</code>. For a single changing value just poll it; for a coherent
multi-byte command use the <b>doorbell</b> (Insert menu).</p>
<h3>Staying safe</h3>
<ul>
<li>Outputs (GPIO_OUT, PWM) must declare <code>INIT</code> and <code>SAFE</code>.</li>
<li>WS2812 needs <code>COUNT</code>; a frame is exactly COUNT&times;3 bytes.</li>
<li>The editor blocks anything the gateware would reject &mdash; watch Problems.</li>
</ul>
<p><i>Tip: use the <b>Insert</b> menu for ready-made snippets; hover any word for help.</i></p>
"""


# ==========================================================================
class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP_NAME); self.resize(1240, 820)
        self.tabs = QTabWidget(); self.tabs.setTabsClosable(True); self.tabs.setMovable(True)
        self.tabs.tabCloseRequested.connect(self.close_tab)
        self.tabs.currentChanged.connect(self.on_tab_changed)
        central = QWidget(); v = QVBoxLayout(central); v.setContentsMargins(0, 0, 0, 0)
        self.find_bar = FindBar(self.current_editor)
        v.addWidget(self.tabs); v.addWidget(self.find_bar)
        self.setCentralWidget(central)
        self.timer = QTimer(self); self.timer.setInterval(250); self.timer.setSingleShot(True)
        self.timer.timeout.connect(self.run_lint)
        self._build_docks(); self._build_menu(); self._build_status()
        self.recent = self._load_recent(); self._refresh_recent_menu()
        self._apply_theme(); self._open_default()

    def current_tab(self):
        w = self.tabs.currentWidget(); return w if isinstance(w, EditorTab) else None
    def current_editor(self):
        t = self.current_tab(); return t.editor if t else None

    def add_tab(self, text="", path=None):
        tab = EditorTab(); tab.path = path; tab.editor.setPlainText(text)
        tab.editor.textChanged.connect(self._on_text_changed)
        tab.editor.paramHint.connect(self.show_param_hint)
        tab.editor.cursorPositionChanged.connect(self._update_pos)
        idx = self.tabs.addTab(tab, tab.title()); self.tabs.setCurrentIndex(idx)
        return tab

    def on_tab_changed(self, _): self.run_lint()
    def _on_text_changed(self):
        t = self.current_tab()
        if t and not t.dirty:
            t.dirty = True; self.tabs.setTabText(self.tabs.currentIndex(), t.title())
        self.timer.start()

    def close_tab(self, index):
        tab = self.tabs.widget(index)
        if isinstance(tab, EditorTab) and tab.dirty:
            r = QMessageBox.question(self, "Unsaved changes",
                    f"Save changes to {tab.title().lstrip('* ')}?",
                    QMessageBox.Save | QMessageBox.Discard | QMessageBox.Cancel)
            if r == QMessageBox.Cancel: return
            if r == QMessageBox.Save:
                self.tabs.setCurrentIndex(index)
                if not self.save_file(): return
        self.tabs.removeTab(index)
        if self.tabs.count() == 0: self._open_default()

    def _build_docks(self):
        self.problems = QListWidget()
        self.problems.itemActivated.connect(self.jump_to_problem)
        self.problems.itemClicked.connect(self.jump_to_problem)
        d1 = QDockWidget("Problems", self); d1.setWidget(self.problems)
        self.addDockWidget(Qt.BottomDockWidgetArea, d1)
        self.hint = QLabel("type a command\u2026"); self.hint.setTextFormat(Qt.RichText)
        self.hint.setWordWrap(True); self.hint.setStyleSheet("padding:6px;font-family:monospace;")
        d2 = QDockWidget("Hint", self); d2.setWidget(self.hint)
        self.addDockWidget(Qt.BottomDockWidgetArea, d2)
        self.tabifyDockWidget(d1, d2); d1.raise_()
        self.pins = PinsPanel()
        sc = QScrollArea(); sc.setWidgetResizable(True); sc.setWidget(self.pins)
        d3 = QDockWidget("Pins & Budget", self); d3.setWidget(sc)
        self.addDockWidget(Qt.RightDockWidgetArea, d3)
        self.overview = QTextBrowser(); self.overview.setStyleSheet("font-family:monospace;font-size:11px;")
        d4 = QDockWidget("Overview", self); d4.setWidget(self.overview)
        self.addDockWidget(Qt.RightDockWidgetArea, d4)
        guide = QTextBrowser(); guide.setHtml(GUIDE_HTML)
        d5 = QDockWidget("Guide", self); d5.setWidget(guide)
        self.addDockWidget(Qt.RightDockWidgetArea, d5)
        ref = QListWidget()
        for name in L.ALL_DIRECTIVE_NAMES: ref.addItem(f"\u25c6 {L.DIRECTIVES[name]['sig']}")
        for name in L.ALL_COMMAND_NAMES: ref.addItem(f"\u25b8 {L.COMMANDS[name]['sig']}")
        ref.setStyleSheet("font-family:monospace;font-size:11px;")
        d6 = QDockWidget("Reference", self); d6.setWidget(ref)
        self.addDockWidget(Qt.RightDockWidgetArea, d6)
        for d in (d5, d6, d4): self.tabifyDockWidget(d3, d)
        d3.raise_()
        self._docks = {"Problems": d1, "Hint": d2, "Pins & Budget": d3,
                       "Overview": d4, "Guide": d5, "Reference": d6}

    def _build_menu(self):
        mb = self.menuBar()
        mf = mb.addMenu("&File")
        self._act(mf, "New", self.new_file, "Ctrl+N")
        self._act(mf, "Open\u2026", self.open_file, "Ctrl+O")
        self.recent_menu = mf.addMenu("Open Recent")
        mf.addSeparator()
        self._act(mf, "Save", self.save_file, "Ctrl+S")
        self._act(mf, "Save As\u2026", self.save_file_as, "Ctrl+Shift+S")
        mf.addSeparator()
        self._act(mf, "Export command-map\u2026", self.export_doc)
        mf.addSeparator()
        self._act(mf, "Quit", self.close, "Ctrl+Q")
        me = mb.addMenu("&Edit")
        self._act(me, "Undo", lambda: self._ed_do("undo"), "Ctrl+Z")
        self._act(me, "Redo", lambda: self._ed_do("redo"), "Ctrl+Shift+Z")
        me.addSeparator()
        self._act(me, "Find / Replace", self.find_bar.show_bar, "Ctrl+F")
        self._act(me, "Toggle comment", self._toggle_comment, "Ctrl+/")
        mi = mb.addMenu("&Insert")
        for name, body in SNIPPETS.items():
            a = QAction(name, self)
            a.triggered.connect(lambda checked=False, b=body: self._insert_snippet(b))
            mi.addAction(a)
        mt = mb.addMenu("&Tools")
        self._act(mt, "LED Studio\u2026", self.open_led_studio)
        mv = mb.addMenu("&View")
        for d in self._docks.values(): mv.addAction(d.toggleViewAction())
        mv.addSeparator()
        self._act(mv, "Bigger font", lambda: self._zoom(1), "Ctrl+=")
        self._act(mv, "Smaller font", lambda: self._zoom(-1), "Ctrl+-")
        mh = mb.addMenu("&Help")
        self._act(mh, "Show Guide", lambda: self._docks["Guide"].raise_())
        self._act(mh, "About", self._about)

    def _act(self, menu, name, slot, shortcut=None):
        a = QAction(name, self); a.triggered.connect(slot)
        if shortcut: a.setShortcut(QKeySequence(shortcut))
        menu.addAction(a); return a
    def _ed_do(self, what):
        ed = self.current_editor()
        if ed: getattr(ed, what)()
    def _toggle_comment(self):
        ed = self.current_editor()
        if ed: ed.toggle_comment()
    def _zoom(self, d):
        ed = self.current_editor()
        if ed:
            f = ed.font(); f.setPointSize(max(8, f.pointSize() + d)); ed.setFont(f)
    def _insert_snippet(self, body):
        ed = self.current_editor()
        if ed: ed.textCursor().insertText(body)
    def open_led_studio(self):
        from eos_ledstudio import LedStudioDialog
        tab = self.current_tab()
        target = tab.model.target if (tab and tab.model and tab.model.target) else "NOHD"
        LedStudioDialog(self, target=target).exec()
    def _about(self):
        QMessageBox.information(self, "About",
            f"{APP_NAME}\nWrites .eos scripts and validates them against the frozen "
            "EOS Expansion spec.\nIf it lints clean here, the gateware will accept it.")

    def _build_status(self):
        sb = QStatusBar(); self.setStatusBar(sb)
        self.st_state = QLabel("ready"); self.st_counts = QLabel(""); self.st_pos = QLabel("Ln 1, Col 1")
        sb.addWidget(self.st_state, 1)
        sb.addPermanentWidget(self.st_counts); sb.addPermanentWidget(self.st_pos)
    def _update_pos(self):
        ed = self.current_editor()
        if not ed: return
        c = ed.textCursor(); self.st_pos.setText(f"Ln {c.blockNumber()+1}, Col {c.positionInBlock()+1}")

    def run_lint(self):
        tab = self.current_tab()
        if not tab: return
        diags, model = LT.lint_text(tab.editor.toPlainText())
        tab.model = model; tab.diags = diags
        self.problems.clear()
        err_lines, n_err, n_warn = {}, 0, 0
        for d in diags:
            icon = "\u26d4" if d.severity == "error" else "\u26a0"
            msg = f"{icon} line {d.line}: {d.message}"
            if d.hint: msg += f"\n     \u21b3 {d.hint}"
            item = QListWidgetItem(msg); item.setData(Qt.UserRole, d.line)
            item.setForeground(QColor("#ff8a80" if d.severity == "error" else "#ffd54f"))
            if d.severity == "error": err_lines.setdefault(d.line, (d.message, d.hint)); n_err += 1
            else: n_warn += 1
            self.problems.addItem(item)
        if not diags:
            self.problems.addItem("\u2713 No problems \u2014 this script is in bounds.")
        tab.editor.set_errors(err_lines); self.pins.update_model(model)
        names = list(model.defs) + list(model.datas) + \
                [r.name for pd in model.pindefs for r in pd.regs]
        tab.highlighter.set_user_names(names); tab.highlighter.rehighlight()
        tab.editor.refresh_completions(list(model.defs), list(model.datas),
                                       [r.name for pd in model.pindefs for r in pd.regs])
        self.overview.setPlainText(R.describe(model) + "\n\n"
                                   + "\u2500\u2500 For your Xbox app \u2500\u2500\n"
                                   + R.host_contract(model))
        state = "\u2713 in bounds" if n_err == 0 else f"\u26d4 {n_err} error(s)"
        if n_warn: state += f" \u00b7 {n_warn} warning(s)"
        self.st_state.setText(state)
        self.st_counts.setText(f"{model.instruction_count} instr \u00b7 "
                               f"{model.pins_used} pins \u00b7 {model.volatile_used}/248 mailbox")
        self._update_pos()

    def jump_to_problem(self, item):
        ln = item.data(Qt.UserRole); ed = self.current_editor()
        if ln and ed: ed.goto_line(ln)

    def show_param_hint(self, head, arg_index):
        base = L.COMMANDS.get((head or "").upper()) or L.DIRECTIVES.get((head or "").upper())
        if not base:
            self.hint.setText("<i>type a command\u2026</i>"); return
        parts = base["sig"].split()
        if 0 < arg_index < len(parts):
            parts[arg_index] = f"<b><u>{parts[arg_index]}</u></b>"
        self.hint.setText(f"<span style='color:#4fc3f7'>{' '.join(parts)}</span>"
                          f"<br><span style='color:#b0bec5'>{base['desc']}</span>")

    def _open_default(self):
        self.add_tab(DEFAULT_TEMPLATE); self.run_lint()

    def new_file(self):
        dlg = NewScriptDialog(self)
        if dlg.exec() and dlg.chosen is not None:
            self.add_tab(dlg.chosen); self.run_lint()
        elif self.tabs.count() == 0:
            self._open_default()
    def open_file(self):
        fn, _ = QFileDialog.getOpenFileName(self, "Open .eos", "", "EOS Script (*.eos);;All (*)")
        if fn: self._open_path(fn)
    def _open_path(self, fn):
        try:
            with open(fn, encoding="utf-8") as fh: text = fh.read()
        except OSError as e:
            QMessageBox.warning(self, "Open failed", str(e)); return
        self.add_tab(text, path=fn); self.run_lint(); self._push_recent(fn)
    def save_file(self):
        tab = self.current_tab()
        if not tab: return False
        return self.save_file_as() if not tab.path else self._write(tab, tab.path)
    def save_file_as(self):
        tab = self.current_tab()
        if not tab: return False
        fn, _ = QFileDialog.getSaveFileName(self, "Save .eos", "script.eos", "EOS Script (*.eos)")
        if not fn: return False
        if not fn.endswith(".eos"): fn += ".eos"
        tab.path = fn; ok = self._write(tab, fn)
        if ok: self._push_recent(fn)
        return ok
    def _write(self, tab, fn):
        errs = [d for d in tab.diags if d.severity == "error"]
        if errs:
            r = QMessageBox.warning(self, "Script has errors",
                    f"This script has {len(errs)} error(s) and EOS would reject it.\nSave anyway?",
                    QMessageBox.Save | QMessageBox.Cancel)
            if r != QMessageBox.Save: return False
        try:
            with open(fn, "w", encoding="utf-8") as fh: fh.write(tab.editor.toPlainText())
        except OSError as e:
            QMessageBox.warning(self, "Save failed", str(e)); return False
        tab.dirty = False; self.tabs.setTabText(self.tabs.currentIndex(), tab.title())
        self.st_state.setText(f"saved {os.path.basename(fn)}"); return True
    def export_doc(self):
        tab = self.current_tab()
        if not tab or not tab.model or not tab.model.pindefs:
            QMessageBox.information(self, "Nothing to export",
                                   "Declare some pin-defs and registers first."); return
        doc = ("# EOS device command-map (generated)\n\n"
               + R.descriptor_view(tab.model) + "\n\n"
               + "## Host how-to\n\n" + R.host_contract(tab.model) + "\n")
        fn, _ = QFileDialog.getSaveFileName(self, "Export command-map", "command_map.md",
                                            "Markdown (*.md)")
        if fn:
            with open(fn, "w", encoding="utf-8") as fh: fh.write(doc)
            self.st_state.setText(f"exported {os.path.basename(fn)}")

    def _load_recent(self):
        try:
            with open(RECENT_PATH) as fh: return json.load(fh)[:8]
        except Exception: return []
    def _save_recent(self):
        try:
            with open(RECENT_PATH, "w") as fh: json.dump(self.recent, fh)
        except Exception: pass
    def _push_recent(self, fn):
        fn = os.path.abspath(fn)
        self.recent = ([fn] + [p for p in self.recent if p != fn])[:8]
        self._save_recent(); self._refresh_recent_menu()
    def _refresh_recent_menu(self):
        self.recent_menu.clear()
        if not self.recent:
            a = self.recent_menu.addAction("(none)"); a.setEnabled(False); return
        for p in self.recent:
            a = self.recent_menu.addAction(os.path.basename(p)); a.setToolTip(p)
            a.triggered.connect(lambda checked=False, path=p: self._open_path(path))

    def closeEvent(self, e):
        for i in range(self.tabs.count()):
            tab = self.tabs.widget(i)
            if isinstance(tab, EditorTab) and tab.dirty:
                self.tabs.setCurrentIndex(i)
                r = QMessageBox.question(self, "Unsaved changes",
                        f"Save changes to {tab.title().lstrip('* ')}?",
                        QMessageBox.Save | QMessageBox.Discard | QMessageBox.Cancel)
                if r == QMessageBox.Cancel: e.ignore(); return
                if r == QMessageBox.Save and not self.save_file(): e.ignore(); return
        e.accept()

    def _apply_theme(self):
        self.setStyleSheet("""
            QMainWindow, QWidget { background:#10161c; color:#cfd8dc; }
            QPlainTextEdit { background:#141b22; color:#eceff1; border:none;
                             selection-background-color:#37474f; }
            QTabWidget::pane { border:1px solid #263238; }
            QTabBar::tab { background:#1b2027; color:#b0bec5; padding:6px 12px; }
            QTabBar::tab:selected { background:#141b22; color:#eceff1; }
            QListWidget, QTextBrowser { background:#141b22; border:1px solid #263238; }
            QDockWidget::title { background:#1b2027; padding:4px; }
            QMenuBar { background:#1b2027; } QMenuBar::item:selected { background:#263238; }
            QMenu { background:#1b2027; border:1px solid #37474f; }
            QMenu::item:selected { background:#263238; }
            QStatusBar { background:#1b2027; }
            QLineEdit { background:#1b2027; border:1px solid #37474f; padding:3px; border-radius:3px; }
            QPushButton { background:#263238; border:1px solid #37474f; padding:4px 8px; border-radius:3px; }
            QPushButton:hover { background:#37474f; }
        """)


def main():
    app = QApplication(sys.argv); app.setStyle("Fusion")
    win = MainWindow(); win.show(); sys.exit(app.exec())


if __name__ == "__main__":
    main()