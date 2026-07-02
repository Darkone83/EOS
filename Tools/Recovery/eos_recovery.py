#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Eos Recovery -- Darkone Customs
================================
A self-contained recovery / initial-flash tool for the Eos modchip (Tang Nano 20K).

Two independent operations, each with its own Program button so a user can recover
exactly what's broken:

    Bitstream :  openFPGALoader -b tangnano20k -f  <bitstream.fs>
    BIOS      :  openFPGALoader -b tangnano20k --external-flash -o <offset> <bios.bin>

Both write the Nano's external SPI flash over the onboard USB-JTAG bridge, so a board
with a dead bitstream is still recoverable (USB still enumerates; the FPGA design does
not have to be valid to reprogram the flash).

Ship openFPGALoader(.exe) next to this program (or freeze with PyInstaller). No install.
"""

import os
import re
import sys
import shutil
import subprocess

from PySide6.QtCore import Qt, QThread, Signal, QSettings
from PySide6.QtGui import QFont, QTextCursor, QIcon
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
    QLabel, QPushButton, QLineEdit, QPlainTextEdit, QFileDialog, QFrame,
    QSizePolicy, QMessageBox
)

# ----------------------------------------------------------------------------
APP_NAME     = "Eos Recovery"
ORG_NAME     = "Darkone Customs"
BOARD        = "tangnano20k"
BIOS_OFFSET  = "0x20000"          # default BIOS offset in external flash
ACCENT       = "#A855F7"          # Darkone purple  rgb(168,85,247)
ACCENT_DIM   = "#7E3FBF"
OK_GREEN     = "#22C55E"
ERR_RED      = "#EF4444"
BG           = "#1B1B22"
CARD         = "#26262F"
TEXT         = "#E7E7EE"
MUTED        = "#9A9AA8"


def resource_dir():
    """Folder to search for the bundled openFPGALoader binary."""
    if getattr(sys, "frozen", False):                 # PyInstaller
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def find_loader():
    """Locate openFPGALoader: bundled alongside the app first, then PATH."""
    exe = "openFPGALoader.exe" if os.name == "nt" else "openFPGALoader"
    local = os.path.join(resource_dir(), exe)
    if os.path.isfile(local):
        return local
    onpath = shutil.which(exe) or shutil.which("openFPGALoader")
    return onpath  # may be None


# ----------------------------------------------------------------------------
class LoaderWorker(QThread):
    """Runs one openFPGALoader command, streaming output line-by-line."""
    line     = Signal(str)
    finished = Signal(bool)          # True = success

    def __init__(self, argv):
        super().__init__()
        self._argv = argv

    def run(self):
        try:
            # no console window flash on Windows
            flags = 0
            if os.name == "nt":
                flags = subprocess.CREATE_NO_WINDOW
            proc = subprocess.Popen(
                self._argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1, universal_newlines=True, creationflags=flags
            )
        except FileNotFoundError:
            self.line.emit("ERROR: openFPGALoader was not found.")
            self.finished.emit(False)
            return
        except Exception as e:
            self.line.emit("ERROR: could not start openFPGALoader: %s" % e)
            self.finished.emit(False)
            return

        for raw in iter(proc.stdout.readline, ""):
            self.line.emit(raw.rstrip("\n"))
        proc.stdout.close()
        rc = proc.wait()
        self.finished.emit(rc == 0)


# ----------------------------------------------------------------------------
class Card(QFrame):
    def __init__(self):
        super().__init__()
        self.setObjectName("card")
        self.setStyleSheet(
            "#card{background:%s;border-radius:14px;}" % CARD
        )


class EosRecovery(QMainWindow):
    def __init__(self):
        super().__init__()
        self.settings = QSettings(ORG_NAME, APP_NAME)
        self.loader   = find_loader()
        self.worker   = None
        self.setWindowTitle("%s  --  %s" % (APP_NAME, ORG_NAME))
        self.setMinimumSize(720, 640)
        self._build()
        self._apply_style()
        self.detect()

    # ---- UI ----------------------------------------------------------------
    def _build(self):
        root = QWidget(); self.setCentralWidget(root)
        col = QVBoxLayout(root); col.setContentsMargins(22, 18, 22, 18); col.setSpacing(16)

        # header
        title = QLabel("Eos Recovery")
        title.setStyleSheet("font-size:24px;font-weight:700;color:%s;" % TEXT)
        sub = QLabel("Reflash your Eos modchip \u2022 Tang Nano 20K")
        sub.setStyleSheet("color:%s;font-size:12px;" % MUTED)
        head = QVBoxLayout(); head.setSpacing(2); head.addWidget(title); head.addWidget(sub)

        self.statusDot = QLabel("\u25CF")
        self.statusTxt = QLabel("Checking\u2026")
        self.statusTxt.setStyleSheet("color:%s;font-size:13px;" % MUTED)
        self.refreshBtn = QPushButton("Detect")
        self.refreshBtn.setObjectName("ghost")
        self.refreshBtn.clicked.connect(self.detect)
        st = QHBoxLayout(); st.setSpacing(8)
        st.addWidget(self.statusDot); st.addWidget(self.statusTxt)
        topbar = QHBoxLayout()
        topbar.addLayout(head); topbar.addStretch(1)
        topbar.addLayout(st); topbar.addSpacing(10); topbar.addWidget(self.refreshBtn)
        col.addLayout(topbar)

        # bitstream card
        self.bitPath = QLineEdit(self.settings.value("bit_path", "", str))
        self.bitPath.setPlaceholderText("Select the Eos bitstream  (eos.fs)")
        self.bitBtn  = QPushButton("Program Bitstream")
        self.bitBtn.setObjectName("primary")
        self.bitBtn.clicked.connect(self.program_bitstream)
        col.addWidget(self._file_card(
            "Bitstream (FPGA)",
            "Recovers a bricked or blank FPGA design. Safe to run anytime.",
            self.bitPath, self.bitBtn, browse_filter="Bitstream (*.fs *.bit);;All files (*.*)",
            offset_field=None))

        # bios card
        self.biosPath = QLineEdit(self.settings.value("bios_path", "", str))
        self.biosPath.setPlaceholderText("Select the Eos BIOS image  (eos.bin)")
        self.biosOff  = QLineEdit(self.settings.value("bios_off", BIOS_OFFSET, str))
        self.biosOff.setFixedWidth(110)
        self.biosBtn  = QPushButton("Program BIOS")
        self.biosBtn.setObjectName("primary")
        self.biosBtn.clicked.connect(self.program_bios)
        col.addWidget(self._file_card(
            "BIOS (external flash)",
            "Recovers the Eos loader/BIOS image. Programmed at the offset below.",
            self.biosPath, self.biosBtn, browse_filter="BIOS image (*.bin);;All files (*.*)",
            offset_field=self.biosOff))

        # banner
        self.banner = QLabel("")
        self.banner.setAlignment(Qt.AlignCenter)
        self.banner.setObjectName("banner")
        self.banner.setVisible(False)
        col.addWidget(self.banner)

        # log
        logLbl = QLabel("Activity")
        logLbl.setStyleSheet("color:%s;font-size:12px;font-weight:600;" % MUTED)
        col.addWidget(logLbl)
        self.log = QPlainTextEdit(); self.log.setReadOnly(True)
        self.log.setObjectName("log")
        self.log.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        mono = QFont("Consolas" if os.name == "nt" else "Monospace"); mono.setPointSize(9)
        self.log.setFont(mono)
        col.addWidget(self.log, 1)

        if not self.loader:
            self._log("WARNING: openFPGALoader was not found next to this program "
                      "or on your PATH. Place openFPGALoader%s in this folder."
                      % (".exe" if os.name == "nt" else ""))

    def _file_card(self, title, desc, path_edit, prog_btn, browse_filter, offset_field):
        card = Card()
        g = QGridLayout(card); g.setContentsMargins(18, 16, 18, 16); g.setHorizontalSpacing(10); g.setVerticalSpacing(10)
        t = QLabel(title); t.setStyleSheet("font-size:15px;font-weight:700;color:%s;" % TEXT)
        d = QLabel(desc);  d.setStyleSheet("color:%s;font-size:11px;" % MUTED); d.setWordWrap(True)
        g.addWidget(t, 0, 0, 1, 3)
        g.addWidget(d, 1, 0, 1, 3)
        browse = QPushButton("Browse\u2026"); browse.setObjectName("ghost")
        browse.clicked.connect(lambda: self._browse(path_edit, browse_filter))
        g.addWidget(path_edit, 2, 0)
        g.addWidget(browse,    2, 1)
        if offset_field is not None:
            off_row = QHBoxLayout(); off_row.setSpacing(6)
            ol = QLabel("Offset"); ol.setStyleSheet("color:%s;font-size:11px;" % MUTED)
            off_row.addWidget(ol); off_row.addWidget(offset_field); off_row.addStretch(1)
            g.addLayout(off_row, 3, 0, 1, 2)
            g.addWidget(prog_btn, 3, 2)
        else:
            g.addWidget(prog_btn, 2, 2)
        g.setColumnStretch(0, 1)
        return card

    def _apply_style(self):
        self.setStyleSheet("""
            QMainWindow, QWidget { background:%(bg)s; color:%(text)s; font-family:'Segoe UI',sans-serif; }
            QLineEdit { background:#15151B; border:1px solid #383843; border-radius:8px;
                        padding:8px 10px; color:%(text)s; }
            QLineEdit:focus { border:1px solid %(accent)s; }
            QPushButton#primary { background:%(accent)s; color:white; border:none;
                        border-radius:9px; padding:9px 16px; font-weight:700; }
            QPushButton#primary:hover  { background:%(accdim)s; }
            QPushButton#primary:disabled { background:#3A3A45; color:#77778A; }
            QPushButton#ghost { background:transparent; color:%(text)s; border:1px solid #454552;
                        border-radius:8px; padding:8px 14px; }
            QPushButton#ghost:hover { border:1px solid %(accent)s; color:%(accent)s; }
            QPlainTextEdit#log { background:#101015; border:1px solid #2C2C36; border-radius:10px;
                        color:#C9C9D6; padding:8px; }
            QLabel#banner { border-radius:10px; padding:12px; font-size:14px; font-weight:700; }
        """ % {"bg": BG, "text": TEXT, "accent": ACCENT, "accdim": ACCENT_DIM})

    # ---- helpers -----------------------------------------------------------
    def _browse(self, edit, filt):
        start = os.path.dirname(edit.text()) or self.settings.value("last_dir", "", str)
        fn, _ = QFileDialog.getOpenFileName(self, "Select file", start, filt)
        if fn:
            edit.setText(fn)
            self.settings.setValue("last_dir", os.path.dirname(fn))

    def _log(self, text):
        self.log.appendPlainText(text)
        self.log.moveCursor(QTextCursor.End)

    def _set_banner(self, text, ok):
        self.banner.setVisible(True)
        self.banner.setText(text)
        color = OK_GREEN if ok else ERR_RED
        self.banner.setStyleSheet(
            "#banner{background:%s22;color:%s;border:1px solid %s;border-radius:10px;"
            "padding:12px;font-size:14px;font-weight:700;}" % (color, color, color))

    def _set_status(self, found):
        self.statusDot.setStyleSheet(
            "color:%s;font-size:14px;" % (OK_GREEN if found else ERR_RED))
        self.statusTxt.setText("Eos board found" if found else "Plug in your Eos board")
        self.statusTxt.setStyleSheet(
            "color:%s;font-size:13px;" % (TEXT if found else MUTED))

    def _busy(self, on):
        for w in (self.bitBtn, self.biosBtn, self.refreshBtn,
                  self.bitPath, self.biosPath, self.biosOff):
            w.setEnabled(not on)

    # ---- detect ------------------------------------------------------------
    def detect(self):
        if not self.loader:
            self._set_status(False)
            return
        self.refreshBtn.setEnabled(False)
        self.statusTxt.setText("Checking\u2026")
        self._det = LoaderWorker([self.loader, "-b", BOARD, "--detect"])
        self._det_out = []
        self._det.line.connect(lambda s: self._det_out.append(s))
        self._det.finished.connect(self._detect_done)
        self._det.start()

    def _detect_done(self, ok):
        blob = "\n".join(self._det_out).lower()
        found = ok or ("idcode" in blob) or ("gowin" in blob)
        self._set_status(found)
        self.refreshBtn.setEnabled(True)

    # ---- program -----------------------------------------------------------
    def _guard(self, path, label):
        if not self.loader:
            QMessageBox.warning(self, APP_NAME,
                "openFPGALoader was not found. Place it in this folder and reopen.")
            return False
        if not path or not os.path.isfile(path):
            QMessageBox.warning(self, APP_NAME, "Please select a valid %s file first." % label)
            return False
        return True

    def program_bitstream(self):
        path = self.bitPath.text().strip()
        if not self._guard(path, "bitstream"):
            return
        self.settings.setValue("bit_path", path)
        self._run([self.loader, "-b", BOARD, "-f", path],
                  "Bitstream", "Your Eos FPGA is reflashed.")

    def program_bios(self):
        path = self.biosPath.text().strip()
        if not self._guard(path, "BIOS"):
            return
        off = self.biosOff.text().strip() or BIOS_OFFSET
        if not re.fullmatch(r"0x[0-9A-Fa-f]+|[0-9]+", off):
            QMessageBox.warning(self, APP_NAME, "Offset must be a number, e.g. 0x20000.")
            return
        self.settings.setValue("bios_path", path)
        self.settings.setValue("bios_off", off)
        self._run([self.loader, "-b", BOARD, "--external-flash", "-o", off, path],
                  "BIOS", "Your Eos BIOS is reflashed.")

    def _run(self, argv, label, ok_msg):
        self.banner.setVisible(False)
        self._busy(True)
        self._log("\n$ " + " ".join('"%s"' % a if " " in a else a for a in argv))
        self._ok_msg = ok_msg
        self._label  = label
        self.worker = LoaderWorker(argv)
        self.worker.line.connect(self._log)
        self.worker.finished.connect(self._run_done)
        self.worker.start()

    def _run_done(self, ok):
        self._busy(False)
        if ok:
            self._set_banner("\u2713  Done \u2014 %s" % self._ok_msg, True)
        else:
            self._set_banner("\u2717  %s failed \u2014 check the activity log above." % self._label, False)
        self.detect()


def main():
    app = QApplication(sys.argv)
    app.setApplicationName(APP_NAME)
    app.setOrganizationName(ORG_NAME)
    win = EosRecovery()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()