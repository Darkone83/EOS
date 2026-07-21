#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Eos Recovery -- Darkone Customs
================================
A self-contained recovery / initial-flash tool for the Eos modchip (Tang Nano 20K).

Four independent operations, each with its own Program button so a user can recover
exactly what's broken:

    Bitstream :  openFPGALoader -b tangnano20k -f  <bitstream.fs>          (local file)
    BIOS      :  openFPGALoader -b tangnano20k --external-flash -o <off> <bios.bin>  (local file)
    Loader    :  loader.bin   downloaded from the Darkone server -> 0x200000 (bank 0xE)
    XbDiag    :  xbdlite.bin  downloaded from the Darkone server -> 0x400000 (bank 0xD)

All of them write the Nano's external SPI flash over the onboard USB-JTAG bridge, so a
board with a dead bitstream is still recoverable (USB still enumerates; the FPGA design
does not have to be valid to reprogram the flash).

Ship openFPGALoader(.exe) next to this program (or freeze with PyInstaller). No install.
"""

import os
import re
import sys
import shutil
import tempfile
import subprocess
import urllib.request
import urllib.error

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

# Physical flash offsets. These come straight from eos_bank_ctrl.v bank_base()
# plus FLOOR (0x200000), and must match the gateware:
#     bank 0xE  base 0x000000  ->  phys 0x200000   full loader/BIOS image
#     bank 0xD  base 0x200000  ->  phys 0x400000   XbDiag Lite reserve
BIOS_OFFSET   = "0x200000"        # default BIOS offset in external flash
LOADER_OFFSET = "0x200000"        # loader image lives in bank 0xE (phys 0x200000)
XBDIAG_OFFSET = "0x400000"        # XbDiag Lite lives in bank 0xD (phys 0x400000)

# Loader and XbDiag are pulled from the same server the updater uses (no local file).
# CRC is intentionally not checked here -- the server images are known-good.
SERVER_HOST  = "darkone83.myddns.me"
SERVER_PORT  = 8008
SERVER_BASE  = "/EOS"

def _server_url(leaf):
    return "http://%s:%d%s/%s" % (SERVER_HOST, SERVER_PORT, SERVER_BASE, leaf)

LOADER_LEAF  = "loader.bin"
XBDIAG_LEAF  = "xbdlite.bin"
BITSTREAM_LEAF = "Eos.fs"           # gateware bitstream on the Darkone server
LOADER_URL   = _server_url(LOADER_LEAF)
XBDIAG_URL   = _server_url(XBDIAG_LEAF)
BITSTREAM_URL = _server_url(BITSTREAM_LEAF)
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
class DownloadWorker(QThread):
    """Downloads a file from a URL to a temp path, streaming progress lines."""
    line     = Signal(str)
    finished = Signal(bool, str)     # (success, temp_path or "")

    def __init__(self, url, prefix="eos_"):
        super().__init__()
        self._url = url
        self._prefix = prefix

    def run(self):
        tmp_path = ""
        try:
            self.line.emit("Downloading %s" % self._url)
            req = urllib.request.Request(self._url, headers={"User-Agent": "EosRecovery"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                total = resp.getheader("Content-Length")
                total = int(total) if total and total.isdigit() else 0
                fd, tmp_path = tempfile.mkstemp(suffix=".bin", prefix=self._prefix)
                got = 0
                last_pct = -1
                with os.fdopen(fd, "wb") as f:
                    while True:
                        chunk = resp.read(65536)
                        if not chunk:
                            break
                        f.write(chunk)
                        got += len(chunk)
                        if total:
                            # only log every 5% so a 2 MB image doesn't spam the log
                            pct = (got * 100) // total
                            if pct >= last_pct + 5 or got == total:
                                self.line.emit("  %d / %d bytes (%d%%)" % (got, total, pct))
                                last_pct = pct
                        else:
                            self.line.emit("  %d bytes" % got)
            if got == 0:
                self.line.emit("ERROR: downloaded file is empty.")
                self._cleanup(tmp_path)
                self.finished.emit(False, "")
                return
            self.line.emit("Downloaded %d bytes." % got)
            self.finished.emit(True, tmp_path)
        except urllib.error.HTTPError as e:
            self.line.emit("ERROR: server returned HTTP %s." % e.code)
            self._cleanup(tmp_path)
            self.finished.emit(False, "")
        except urllib.error.URLError as e:
            self.line.emit("ERROR: could not reach the server (%s)." % e.reason)
            self._cleanup(tmp_path)
            self.finished.emit(False, "")
        except Exception as e:
            self.line.emit("ERROR: download failed: %s" % e)
            self._cleanup(tmp_path)
            self.finished.emit(False, "")

    @staticmethod
    def _cleanup(path):
        if path and os.path.isfile(path):
            try:
                os.remove(path)
            except OSError:
                pass


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

        # ---- Bitstream (FPGA) : local file OR server, one card ----
        self.bitPath = QLineEdit(self.settings.value("bit_path", "", str))
        self.bitPath.setPlaceholderText("Select the Eos bitstream  (eos.fs)")
        self.bitBtn  = QPushButton("Program"); self.bitBtn.setObjectName("primary")
        self.bitBtn.clicked.connect(self.program_bitstream)
        self.bitOnlineBtn = QPushButton("Update from Server"); self.bitOnlineBtn.setObjectName("primary")
        self.bitOnlineBtn.clicked.connect(self.program_bitstream_online)
        col.addWidget(self._unit_card(
            "Bitstream (FPGA)",
            "Recovers a bricked or blank FPGA design. Flash a local eos.fs, or pull the "
            "latest from the Darkone server. Safe to run anytime.",
            path_edit=self.bitPath, browse_filter="Bitstream (*.fs *.bit);;All files (*.*)",
            local_btn=self.bitBtn,
            server_btn=self.bitOnlineBtn,
            server_hint="No file? Update the gateware to the latest release:"))

        # ---- BIOS / Loader (bank 0xE @ 0x200000) : local file OR server, one card ----
        self.biosPath = QLineEdit(self.settings.value("bios_path", "", str))
        self.biosPath.setPlaceholderText("Select a BIOS / loader image  (eos.bin)")
        self.biosOff  = QLineEdit(self.settings.value("bios_off", BIOS_OFFSET, str))
        self.biosOff.setFixedWidth(110)
        self.biosBtn  = QPushButton("Program"); self.biosBtn.setObjectName("primary")
        self.biosBtn.clicked.connect(self.program_bios)
        self.loaderBtn = QPushButton("Download Latest"); self.loaderBtn.setObjectName("primary")
        self.loaderBtn.clicked.connect(self.program_loader)
        col.addWidget(self._unit_card(
            "BIOS / Loader image  (bank 0xE, 0x200000)",
            "Writes the loader/BIOS image to bank 0xE. Flash your own eos.bin at the "
            "offset below, or download the current Eos loader from the server. Either "
            "way this replaces the whole BIOS image.",
            path_edit=self.biosPath, browse_filter="BIOS image (*.bin);;All files (*.*)",
            offset_field=self.biosOff, local_btn=self.biosBtn,
            server_btn=self.loaderBtn,
            server_hint="No eos.bin to hand? Pull the current loader image:"))

        # ---- XbDiag Lite (bank 0xD) : server only, one card ----
        self.xbdBtn = QPushButton("Download + Flash"); self.xbdBtn.setObjectName("primary")
        self.xbdBtn.clicked.connect(self.program_xbdiag)
        col.addWidget(self._unit_card(
            "XbDiag Lite  (bank 0xD, 0x400000)",
            "Downloads XbDiag Lite from the Darkone server and flashes it to bank 0xD. "
            "No file needed \u2014 use this to install or recover XbDiag.",
            server_btn=self.xbdBtn))

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

    def _unit_card(self, title, desc, *, path_edit=None, browse_filter=None,
                   offset_field=None, local_btn=None, server_btn=None,
                   server_hint=None):
        """One card per function. Optional local row (Browse [+ Offset] + local_btn)
        and/or an online row (server_hint + server_btn). Keeps each function to a
        single card instead of a local card + a server card."""
        card = Card()
        g = QGridLayout(card); g.setContentsMargins(18, 16, 18, 16)
        g.setHorizontalSpacing(10); g.setVerticalSpacing(10)
        t = QLabel(title); t.setStyleSheet("font-size:15px;font-weight:700;color:%s;" % TEXT)
        d = QLabel(desc);  d.setStyleSheet("color:%s;font-size:11px;" % MUTED); d.setWordWrap(True)
        g.addWidget(t, 0, 0, 1, 3)
        g.addWidget(d, 1, 0, 1, 3)
        row = 2
        # --- local file row (optional) ---
        if path_edit is not None:
            browse = QPushButton("Browse\u2026"); browse.setObjectName("ghost")
            browse.clicked.connect(lambda: self._browse(path_edit, browse_filter))
            g.addWidget(path_edit, row, 0)
            g.addWidget(browse,    row, 1)
            if offset_field is not None:
                off_row = QHBoxLayout(); off_row.setSpacing(6)
                ol = QLabel("Offset"); ol.setStyleSheet("color:%s;font-size:11px;" % MUTED)
                off_row.addWidget(ol); off_row.addWidget(offset_field); off_row.addStretch(1)
                row += 1
                g.addLayout(off_row, row, 0, 1, 2)
                g.addWidget(local_btn, row, 2)
            else:
                g.addWidget(local_btn, row, 2)
            row += 1
        # --- online row (optional): a subtle divider label + the server button ---
        if server_btn is not None:
            if server_hint:
                h = QLabel(server_hint)
                h.setStyleSheet("color:%s;font-size:11px;" % MUTED); h.setWordWrap(True)
                g.addWidget(h, row, 0, 1, 2)
            g.addWidget(server_btn, row, 2)
            row += 1
        g.setColumnStretch(0, 1)
        return card

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

    def _server_card(self, title, desc, prog_btn):
        """A card with no file picker -- the image is pulled from the server."""
        card = Card()
        g = QGridLayout(card); g.setContentsMargins(18, 16, 18, 16)
        g.setHorizontalSpacing(10); g.setVerticalSpacing(10)
        t = QLabel(title); t.setStyleSheet("font-size:15px;font-weight:700;color:%s;" % TEXT)
        d = QLabel(desc);  d.setStyleSheet("color:%s;font-size:11px;" % MUTED); d.setWordWrap(True)
        g.addWidget(t, 0, 0, 1, 3)
        g.addWidget(d, 1, 0, 1, 3)
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
        for w in (self.bitBtn, self.biosBtn, self.loaderBtn, self.xbdBtn, self.refreshBtn,
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

    def program_bitstream_online(self):
        """Download the current bitstream (Eos.fs) from the server, then program
        the FPGA flash with it. Unlike the loader/XbDiag images (which flash to a
        SPI offset via --external-flash), the bitstream is written with the plain
        `-f` command, so it uses its own download-then-flash path."""
        if not self.loader:
            QMessageBox.warning(self, APP_NAME,
                "openFPGALoader was not found. Place it in this folder and reopen.")
            return
        self.banner.setVisible(False)
        self._busy(True)
        self._log("\n$ download %s" % BITSTREAM_URL)
        self._dl_label  = "Bitstream"
        self._dl_ok_msg = "Your Eos FPGA is reflashed."
        self._dl = DownloadWorker(BITSTREAM_URL, prefix="bitstream_")
        self._dl.line.connect(self._log)
        self._dl.finished.connect(self._server_bitstream_downloaded)
        self._dl.start()

    def _server_bitstream_downloaded(self, ok, tmp_path):
        if not ok:
            self._busy(False)
            self._set_banner("\u2717  Bitstream download failed \u2014 check the activity log.", False)
            return
        # Flash the freshly-downloaded bitstream with the plain -f command.
        # _run_done removes the temp file.
        self._tmp_image = tmp_path
        self._run([self.loader, "-b", BOARD, "-f", tmp_path],
                  self._dl_label, self._dl_ok_msg)

    def program_bios(self):
        path = self.biosPath.text().strip()
        if not self._guard(path, "BIOS"):
            return
        off = self.biosOff.text().strip() or BIOS_OFFSET
        if not re.fullmatch(r"0x[0-9A-Fa-f]+|[0-9]+", off):
            QMessageBox.warning(self, APP_NAME, "Offset must be a number, e.g. 0x200000.")
            return
        self.settings.setValue("bios_path", path)
        self.settings.setValue("bios_off", off)
        self._run([self.loader, "-b", BOARD, "--external-flash", "-o", off, path],
                  "BIOS", "Your Eos BIOS is reflashed.")

    # ---- server-hosted images (no local file) -------------------------------
    def _download_and_flash(self, url, offset, label, ok_msg, prefix):
        """Shared flow behind the Loader and XbDiag cards.

        Pull the image from the Darkone server to a temp file, flash it at
        `offset`, then delete the temp file. CRC is intentionally not checked --
        the server images are known-good.
        """
        if not self.loader:
            QMessageBox.warning(self, APP_NAME,
                "openFPGALoader was not found. Place it in this folder and reopen.")
            return
        self.banner.setVisible(False)
        self._busy(True)
        self._log("\n$ download %s" % url)
        self._dl_offset = offset
        self._dl_label  = label
        self._dl_ok_msg = ok_msg
        self._dl = DownloadWorker(url, prefix=prefix)
        self._dl.line.connect(self._log)
        self._dl.finished.connect(self._server_image_downloaded)
        self._dl.start()

    def _server_image_downloaded(self, ok, tmp_path):
        if not ok:
            self._busy(False)
            self._set_banner("\u2717  %s download failed \u2014 check the activity log."
                             % self._dl_label, False)
            return
        # Flash the freshly-downloaded image; _run_done removes the temp file.
        self._tmp_image = tmp_path
        self._run([self.loader, "-b", BOARD, "--external-flash", "-o", self._dl_offset, tmp_path],
                  self._dl_label, self._dl_ok_msg)

    def program_loader(self):
        # loader.bin is the FULL image and lands at 0x200000 (bank 0xE) -- the same
        # region the BIOS card writes. That is destructive, so confirm first.
        # XbDiag writes 0x400000 (a reserve) and needs no prompt.
        if self.loader:
            reply = QMessageBox.question(
                self, APP_NAME,
                "This downloads the current Eos loader image and writes it to "
                "0x200000, replacing your whole BIOS image.\n\n"
                "Any BIOS banks you have flashed will be overwritten.\n\nContinue?",
                QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
            if reply != QMessageBox.Yes:
                return
        self._download_and_flash(LOADER_URL, LOADER_OFFSET,
                                 "Loader", "Your Eos loader image is reflashed.",
                                 prefix="loader_")

    def program_xbdiag(self):
        self._download_and_flash(XBDIAG_URL, XBDIAG_OFFSET,
                                 "XbDiag", "XbDiag Lite is flashed.",
                                 prefix="xbdlite_")


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
        # Remove the downloaded temp image, if this run used one (Loader or XbDiag).
        tmp = getattr(self, "_tmp_image", "")
        if tmp:
            try:
                if os.path.isfile(tmp):
                    os.remove(tmp)
            except OSError:
                pass
            self._tmp_image = ""
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