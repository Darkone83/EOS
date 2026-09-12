#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Eos Recovery -- Darkone Customs
================================
A self-contained recovery / initial-flash tool for the Eos modchip (Tang Nano 20K).

Recovery operations are exposed independently so a user can repair exactly what is broken:

    Bitstream :  openFPGALoader -b tangnano20k -f  <bitstream.fs>          (local file)
    BIOS      :  openFPGALoader -b tangnano20k --external-flash -o <off> <bios.bin>  (local file)
    Loader    :  loader.bin   downloaded locally, then flashed -> 0x200000 (bank 0xE)
    XbDiag    :  xbdlite.bin  downloaded locally, then flashed -> 0x400000 (bank 0xD)
    Erase     :  openFPGALoader -b tangnano20k --bulk-erase

All of them write the Nano's external SPI flash over the onboard USB-JTAG bridge, so a
board with a dead bitstream is still recoverable (USB still enumerates; the FPGA design
does not have to be valid to reprogram the flash).

openFPGALoader is shipped beside the app. The in-app dependency tools only manage Python modules.
"""

import os
import sys
import shutil
import importlib.util
import subprocess
import urllib.request
import urllib.error


def _bootstrap_gui_dependency():
    """Allow a raw Windows .py launch to repair a missing PySide6 before UI import.

    A packaged Recovery executable already contains PySide6. This tiny native
    Windows prompt only exists so the source script can still provide a dependency
    installer even when the GUI toolkit itself is what is missing.
    """
    if getattr(sys, "frozen", False) or importlib.util.find_spec("PySide6") is not None:
        return

    if os.name != "nt":
        raise SystemExit(
            "PySide6 is required. Install it with: %s -m pip install PySide6" % sys.executable
        )

    try:
        import ctypes
        MB_YESNO = 0x00000004
        MB_ICONQUESTION = 0x00000020
        IDYES = 6
        choice = ctypes.windll.user32.MessageBoxW(
            None,
            "PySide6 is missing. Install it now with pip and restart Eos Recovery?",
            "Eos Recovery — Python Dependency",
            MB_YESNO | MB_ICONQUESTION,
        )
        if choice != IDYES:
            raise SystemExit("PySide6 is required to run Eos Recovery.")

        flags = subprocess.CREATE_NO_WINDOW
        rc = subprocess.call([sys.executable, "-m", "pip", "install", "PySide6"], creationflags=flags)
        if rc != 0:
            ctypes.windll.user32.MessageBoxW(
                None,
                "PySide6 installation failed. Run:\n\n%s -m pip install PySide6" % sys.executable,
                "Eos Recovery",
                0x10,
            )
            raise SystemExit(rc)

        os.execv(sys.executable, [sys.executable] + sys.argv)
    except SystemExit:
        raise
    except Exception as e:
        raise SystemExit("PySide6 is required and automatic installation failed: %s" % e)


_bootstrap_gui_dependency()

from PySide6.QtCore import Qt, QThread, Signal, QSettings
from PySide6.QtGui import QFont, QTextCursor
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

# Server assets are downloaded beside the recovery app, then programmed from that local copy.
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

# Python dependencies are only relevant when running the .py source. A packaged
# Recovery build carries these modules with it; openFPGALoader is bundled beside
# the application and is deliberately not treated as an installable dependency.
REQUIRED_PYTHON_MODULES = (
    ("PySide6", "PySide6"),
)

# Zadig is portable (no traditional installer). Recovery downloads the official
# signed executable locally and launches it so the user can bind Interface 0 to
# WinUSB. Interface 1 must be left alone because it is the UART/serial side.
ZADIG_LEAF = "zadig-2.9.exe"
ZADIG_DOWNLOAD_URL = (
    "https://github.com/pbatard/libwdi/releases/download/v1.5.1/zadig-2.9.exe"
)


def resource_dir():
    """Folder to search for the bundled openFPGALoader binary."""
    if getattr(sys, "frozen", False):                 # PyInstaller
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def local_asset_path(leaf):
    """Persistent path for a server-hosted recovery asset beside the app."""
    return os.path.join(resource_dir(), leaf)


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
    """Downloads a server asset into the recovery app's local directory.

    Data is first written to <asset>.part and atomically moved into place only
    after the download completes, so an interrupted update does not destroy an
    existing known-good local asset.
    """
    line     = Signal(str)
    finished = Signal(bool, str)     # (success, persistent local path or "")

    def __init__(self, url, dest_path):
        super().__init__()
        self._url = url
        self._dest_path = os.path.abspath(dest_path)

    def run(self):
        part_path = self._dest_path + ".part"
        try:
            parent = os.path.dirname(self._dest_path)
            if parent:
                os.makedirs(parent, exist_ok=True)

            self.line.emit("Downloading %s" % self._url)
            self.line.emit("Local asset: %s" % self._dest_path)
            req = urllib.request.Request(self._url, headers={"User-Agent": "EosRecovery"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                total = resp.getheader("Content-Length")
                total = int(total) if total and total.isdigit() else 0
                got = 0
                last_pct = -1
                with open(part_path, "wb") as f:
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
                self._cleanup(part_path)
                self.finished.emit(False, "")
                return

            os.replace(part_path, self._dest_path)
            self.line.emit("Downloaded %d bytes." % got)
            self.line.emit("Saved asset: %s" % self._dest_path)
            self.finished.emit(True, self._dest_path)
        except urllib.error.HTTPError as e:
            self.line.emit("ERROR: server returned HTTP %s." % e.code)
            self._cleanup(part_path)
            self.finished.emit(False, "")
        except urllib.error.URLError as e:
            self.line.emit("ERROR: could not reach the server (%s)." % e.reason)
            self._cleanup(part_path)
            self.finished.emit(False, "")
        except Exception as e:
            self.line.emit("ERROR: download failed: %s" % e)
            self._cleanup(part_path)
            self.finished.emit(False, "")

    @staticmethod
    def _cleanup(path):
        if path and os.path.isfile(path):
            try:
                os.remove(path)
            except OSError:
                pass


# ----------------------------------------------------------------------------
class PythonModuleInstallWorker(QThread):
    """Install missing Python modules into the active source Python environment."""
    line = Signal(str)
    finished = Signal(bool, str)

    def __init__(self, packages):
        super().__init__()
        self._packages = list(packages)

    def run(self):
        if not self._packages:
            self.finished.emit(True, "No Python modules are missing.")
            return
        if getattr(sys, "frozen", False):
            self.finished.emit(False, "Packaged builds already bundle Python modules and cannot use pip in-place.")
            return

        argv = [sys.executable, "-m", "pip", "install", "--upgrade"] + self._packages
        self.line.emit("$ " + " ".join(argv))
        try:
            flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
            proc = subprocess.Popen(
                argv,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                universal_newlines=True,
                creationflags=flags,
            )
            for raw in iter(proc.stdout.readline, ""):
                self.line.emit(raw.rstrip("\n"))
            proc.stdout.close()
            rc = proc.wait()
            if rc == 0:
                self.finished.emit(True, "Python modules installed.")
            else:
                self.finished.emit(False, "pip exited with code %d." % rc)
        except Exception as e:
            self.finished.emit(False, str(e))


# ----------------------------------------------------------------------------
class Card(QFrame):
    def __init__(self):
        super().__init__()
        self.setObjectName("card")
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Minimum)


class EosRecovery(QMainWindow):
    def __init__(self):
        super().__init__()
        self.settings = QSettings(ORG_NAME, APP_NAME)
        self.loader = find_loader()
        self.worker = None
        self.setWindowTitle("%s  --  %s" % (APP_NAME, ORG_NAME))
        self.setMinimumSize(860, 720)
        self.resize(960, 820)
        self._build()
        self._apply_style()
        self.check_python_dependencies()
        self.detect()

    # ---- UI ----------------------------------------------------------------
    def _build(self):
        root = QWidget(); root.setObjectName("root")
        self.setCentralWidget(root)
        col = QVBoxLayout(root)
        col.setContentsMargins(24, 18, 24, 18)
        col.setSpacing(10)

        # Header
        title = QLabel("Eos Recovery")
        title.setStyleSheet("font-size:24px;font-weight:700;color:%s;" % TEXT)
        sub = QLabel("Reflash your Eos modchip • Tang Nano 20K")
        sub.setStyleSheet("color:%s;font-size:12px;" % MUTED)
        head = QVBoxLayout(); head.setSpacing(1); head.addWidget(title); head.addWidget(sub)

        self.statusDot = QLabel("●")
        self.statusTxt = QLabel("Checking…")
        self.statusTxt.setStyleSheet("color:%s;font-size:13px;" % MUTED)
        self.refreshBtn = QPushButton("Detect")
        self.refreshBtn.setObjectName("ghost")
        self.refreshBtn.setToolTip(
            "Ask bundled openFPGALoader to detect the Tang Nano 20K over USB/JTAG.\n"
            "If this fails on Windows, run Zadig and bind Interface 0 to WinUSB."
        )
        self.refreshBtn.clicked.connect(self.detect)
        st = QHBoxLayout(); st.setSpacing(8)
        st.addWidget(self.statusDot); st.addWidget(self.statusTxt)
        topbar = QHBoxLayout()
        topbar.addLayout(head); topbar.addStretch(1)
        topbar.addLayout(st); topbar.addSpacing(10); topbar.addWidget(self.refreshBtn)
        col.addLayout(topbar)

        # Setup / dependencies: Python modules only. openFPGALoader ships with Recovery.
        self.depStatus = QLabel("Python modules: checking…")
        self.depStatus.setObjectName("statusLine")
        self.depStatus.setStyleSheet("color:%s;font-size:11px;" % MUTED)

        self.checkDepsBtn = QPushButton("Check Modules"); self.checkDepsBtn.setObjectName("ghost")
        self.checkDepsBtn.setToolTip(
            "Check only the Python modules Eos Recovery needs.\n"
            "openFPGALoader is bundled with Recovery and is not installed here."
        )
        self.checkDepsBtn.clicked.connect(self.check_python_dependencies)

        self.installDepsBtn = QPushButton("Install Missing"); self.installDepsBtn.setObjectName("ghost")
        self.installDepsBtn.setToolTip(
            "When running eos_recovery.py from source, install any missing Python modules with pip.\n"
            "Packaged builds already contain their Python runtime and modules."
        )
        self.installDepsBtn.clicked.connect(self.install_python_dependencies)

        self.zadigBtn = QPushButton("Download / Run Zadig"); self.zadigBtn.setObjectName("primary")
        self.zadigBtn.setToolTip(
            "Windows WinUSB setup:\n"
            "1. Options > List All Devices\n"
            "2. Select the Tang Nano / JTAG device Interface 0\n"
            "3. Choose WinUSB\n"
            "4. Replace / Install Driver\n"
            "Leave Interface 1 unchanged; it is the UART/serial interface."
        )
        self.zadigBtn.clicked.connect(self.download_or_run_zadig)
        if os.name != "nt":
            self.zadigBtn.setEnabled(False)
            self.zadigBtn.setText("Zadig (Windows only)")
        col.addWidget(self._setup_card())

        # Destructive maintenance
        self.eraseBtn = QPushButton("Erase Chip"); self.eraseBtn.setObjectName("danger")
        self.eraseBtn.setToolTip(
            "Bulk-erase the Tang Nano 20K external SPI flash using --bulk-erase.\n"
            "This removes the FPGA bitstream and every Eos BIOS/diagnostic region."
        )
        self.eraseBtn.clicked.connect(self.erase_chip)
        col.addWidget(self._action_card("Erase external flash", self.eraseBtn))

        # Bitstream
        self.bitPath = QLineEdit(self.settings.value("bit_path", "", str))
        self.bitPath.setPlaceholderText("Select Eos.fs / bitstream")
        self.bitPath.setToolTip("Local FPGA bitstream to program with openFPGALoader -f.")
        self.bitBtn = QPushButton("Program"); self.bitBtn.setObjectName("primary")
        self.bitBtn.setToolTip("Program the selected local FPGA bitstream.")
        self.bitBtn.clicked.connect(self.program_bitstream)
        self.bitOnlineBtn = QPushButton("Update from Server"); self.bitOnlineBtn.setObjectName("primary")
        self.bitOnlineBtn.setToolTip(
            "Download Eos.fs into the Recovery directory, then program that local copy."
        )
        self.bitOnlineBtn.clicked.connect(self.program_bitstream_online)
        col.addWidget(self._compact_file_card(
            "Bitstream (FPGA)", self.bitPath, "Bitstream (*.fs *.bit);;All files (*.*)",
            self.bitBtn, self.bitOnlineBtn))

        # BIOS / Loader
        self.biosPath = QLineEdit(self.settings.value("bios_path", "", str))
        self.biosPath.setPlaceholderText("Select BIOS / loader image (eos.bin)")
        self.biosPath.setToolTip("Local BIOS/loader image to write to bank 0xE at the fixed 0x200000 offset.")
        self.biosBtn = QPushButton("Program"); self.biosBtn.setObjectName("primary")
        self.biosBtn.setToolTip("Program the selected local BIOS/loader image to bank 0xE at 0x200000.")
        self.biosBtn.clicked.connect(self.program_bios)
        self.loaderBtn = QPushButton("Download Latest"); self.loaderBtn.setObjectName("primary")
        self.loaderBtn.setToolTip(
            "Download loader.bin into the Recovery directory and flash it at 0x200000.\n"
            "This replaces the complete Eos BIOS/loader image, including existing BIOS banks."
        )
        self.loaderBtn.clicked.connect(self.program_loader)
        col.addWidget(self._compact_bios_card())

        # XbDiag
        self.xbdBtn = QPushButton("Download + Flash"); self.xbdBtn.setObjectName("primary")
        self.xbdBtn.setToolTip(
            "Download xbdlite.bin into the Recovery directory and flash it to bank 0xD at 0x400000."
        )
        self.xbdBtn.clicked.connect(self.program_xbdiag)
        col.addWidget(self._action_card("XbDiag Lite  (bank 0xD, 0x400000)", self.xbdBtn))

        # Banner
        self.banner = QLabel("")
        self.banner.setAlignment(Qt.AlignCenter)
        self.banner.setObjectName("banner")
        self.banner.setVisible(False)
        col.addWidget(self.banner)

        # Activity log
        log_row = QHBoxLayout()
        logLbl = QLabel("Activity")
        logLbl.setStyleSheet("color:%s;font-size:12px;font-weight:600;" % MUTED)
        log_row.addWidget(logLbl); log_row.addStretch(1)
        col.addLayout(log_row)

        self.log = QPlainTextEdit(); self.log.setReadOnly(True)
        self.log.setObjectName("log")
        self.log.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.log.setMinimumHeight(105)
        mono = QFont("Consolas" if os.name == "nt" else "Monospace"); mono.setPointSize(9)
        self.log.setFont(mono)
        col.addWidget(self.log, 1)

        if not self.loader:
            self._log("WARNING: bundled openFPGALoader was not found beside Eos Recovery or on PATH.")

    def _setup_card(self):
        card = Card()
        card.setMinimumHeight(92)
        g = QGridLayout(card)
        g.setContentsMargins(18, 14, 18, 14)
        g.setHorizontalSpacing(10)
        g.setVerticalSpacing(8)

        t = QLabel("Setup / Dependencies")
        t.setStyleSheet("font-size:15px;font-weight:700;color:%s;" % TEXT)
        g.addWidget(t, 0, 0)
        g.addWidget(self.depStatus, 0, 1, 1, 3, alignment=Qt.AlignRight | Qt.AlignVCenter)
        g.addWidget(self.checkDepsBtn, 1, 0)
        g.addWidget(self.installDepsBtn, 1, 1)
        g.addWidget(self.zadigBtn, 1, 2, 1, 2)
        g.setColumnStretch(0, 1)
        g.setColumnStretch(1, 1)
        g.setColumnStretch(2, 1)
        g.setColumnStretch(3, 1)
        return card

    def _action_card(self, title, button):
        card = Card()
        card.setMinimumHeight(62)
        row = QHBoxLayout(card)
        row.setContentsMargins(18, 12, 18, 12)
        t = QLabel(title)
        t.setStyleSheet("font-size:15px;font-weight:700;color:%s;" % TEXT)
        row.addWidget(t)
        row.addStretch(1)
        button.setMinimumWidth(150)
        row.addWidget(button)
        return card

    def _compact_file_card(self, title, path_edit, browse_filter, local_btn, server_btn):
        card = Card()
        card.setMinimumHeight(96)
        g = QGridLayout(card)
        g.setContentsMargins(18, 12, 18, 12)
        g.setHorizontalSpacing(10)
        g.setVerticalSpacing(8)

        t = QLabel(title)
        t.setStyleSheet("font-size:15px;font-weight:700;color:%s;" % TEXT)
        browse = QPushButton("Browse…"); browse.setObjectName("ghost")
        browse.setToolTip("Choose a local file.")
        browse.clicked.connect(lambda: self._browse(path_edit, browse_filter))

        g.addWidget(t, 0, 0, 1, 4)
        g.addWidget(path_edit, 1, 0)
        g.addWidget(browse, 1, 1)
        g.addWidget(local_btn, 1, 2)
        g.addWidget(server_btn, 1, 3)
        g.setColumnStretch(0, 1)
        g.setColumnMinimumWidth(1, 96)
        g.setColumnMinimumWidth(2, 120)
        g.setColumnMinimumWidth(3, 160)
        return card

    def _compact_bios_card(self):
        card = Card()
        card.setMinimumHeight(96)
        g = QGridLayout(card)
        g.setContentsMargins(18, 12, 18, 12)
        g.setHorizontalSpacing(10)
        g.setVerticalSpacing(8)

        t = QLabel("BIOS / Loader image  (bank 0xE, 0x200000)")
        t.setStyleSheet("font-size:15px;font-weight:700;color:%s;" % TEXT)
        browse = QPushButton("Browse…"); browse.setObjectName("ghost")
        browse.setToolTip("Choose a local BIOS/loader .bin image. It will be written at the fixed 0x200000 offset.")
        browse.clicked.connect(lambda: self._browse(self.biosPath, "BIOS image (*.bin);;All files (*.*)"))

        g.addWidget(t, 0, 0, 1, 4)
        g.addWidget(self.biosPath, 1, 0)
        g.addWidget(browse, 1, 1)
        g.addWidget(self.biosBtn, 1, 2)
        g.addWidget(self.loaderBtn, 1, 3)
        g.setColumnStretch(0, 1)
        g.setColumnMinimumWidth(1, 96)
        g.setColumnMinimumWidth(2, 120)
        g.setColumnMinimumWidth(3, 160)
        return card

    def _apply_style(self):
        self.setStyleSheet("""
            QMainWindow, QWidget#root {
                background:%(bg)s; color:%(text)s; font-family:'Segoe UI',sans-serif;
            }
            QLabel { background:transparent; }
            QFrame#card { background:%(card)s; border-radius:14px; }
            QToolTip {
                background:#101015; color:%(text)s; border:1px solid #454552;
                padding:7px; font-size:11px;
            }
            QLineEdit { background:#15151B; border:1px solid #383843; border-radius:8px;
                        min-height:20px; padding:7px 10px; color:%(text)s; }
            QLineEdit:focus { border:1px solid %(accent)s; }
            QPushButton { min-height:20px; }
            QPushButton#primary { background:%(accent)s; color:white; border:none;
                        border-radius:9px; padding:8px 14px; font-weight:700; }
            QPushButton#primary:hover  { background:%(accdim)s; }
            QPushButton#primary:disabled { background:#3A3A45; color:#77778A; }
            QPushButton#danger { background:#B91C1C; color:white; border:none;
                        border-radius:9px; padding:8px 14px; font-weight:700; }
            QPushButton#danger:hover { background:#991B1B; }
            QPushButton#danger:disabled { background:#3A3A45; color:#77778A; }
            QPushButton#ghost { background:transparent; color:%(text)s; border:1px solid #454552;
                        border-radius:8px; padding:7px 12px; }
            QPushButton#ghost:hover { border:1px solid %(accent)s; color:%(accent)s; }
            QPushButton#ghost:disabled { border:1px solid #34343D; color:#666674; }
            QPlainTextEdit#log { background:#101015; border:1px solid #2C2C36; border-radius:10px;
                        color:#C9C9D6; padding:8px; }
            QLabel#banner { border-radius:10px; padding:9px; font-size:13px; font-weight:700; }
        """ % {"bg": BG, "card": CARD, "text": TEXT, "accent": ACCENT, "accdim": ACCENT_DIM})

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
        for w in (
            self.bitBtn, self.bitOnlineBtn, self.biosBtn, self.loaderBtn, self.xbdBtn,
            self.eraseBtn, self.refreshBtn, self.checkDepsBtn, self.installDepsBtn,
            self.zadigBtn, self.bitPath, self.biosPath,
        ):
            w.setEnabled(not on)

        # Install Missing is only actionable for a source run with something
        # actually absent. Do not accidentally re-enable it after a flash/download.
        if not on:
            missing = self._missing_python_modules()
            self.installDepsBtn.setEnabled(bool(missing) and not getattr(sys, "frozen", False))
            if getattr(sys, "frozen", False):
                self.installDepsBtn.setText("Modules Bundled")
            elif not missing:
                self.installDepsBtn.setText("Modules Ready")
            else:
                self.installDepsBtn.setText("Install Missing")

    # ---- Python dependencies / Windows USB setup -----------------------------
    @staticmethod
    def _missing_python_modules():
        missing = []
        for module_name, package_name in REQUIRED_PYTHON_MODULES:
            try:
                present = importlib.util.find_spec(module_name) is not None
            except (ImportError, ValueError):
                present = False
            if not present:
                missing.append((module_name, package_name))
        return missing

    def check_python_dependencies(self):
        missing = self._missing_python_modules()
        if getattr(sys, "frozen", False):
            # A frozen build already contains the runtime that is executing this UI.
            self.depStatus.setText("Python modules: bundled")
            self.installDepsBtn.setEnabled(False)
            self.installDepsBtn.setText("Modules Bundled")
            self._log("Python dependency check: packaged runtime / modules bundled.")
            return

        if missing:
            names = ", ".join(module for module, _ in missing)
            self.depStatus.setText("Missing: %s" % names)
            self.installDepsBtn.setEnabled(True)
            self.installDepsBtn.setText("Install Missing")
            self._set_banner("✗  Missing Python module(s): %s" % names, False)
            self._log("Python dependency check: missing %s" % names)
        else:
            self.depStatus.setText("Python modules: OK")
            self.installDepsBtn.setEnabled(False)
            self.installDepsBtn.setText("Modules Ready")
            self._log("Python dependency check: OK")

    def install_python_dependencies(self):
        missing = self._missing_python_modules()
        if not missing:
            self.check_python_dependencies()
            return
        if getattr(sys, "frozen", False):
            QMessageBox.information(
                self, APP_NAME,
                "This packaged Eos Recovery build already carries its Python modules."
            )
            return

        packages = [package for _, package in missing]
        reply = QMessageBox.question(
            self, APP_NAME,
            "Install the missing Python module(s) into this Python environment?\n\n%s" %
            "\n".join("• " + p for p in packages),
            QMessageBox.Yes | QMessageBox.No, QMessageBox.Yes)
        if reply != QMessageBox.Yes:
            return

        self.banner.setVisible(False)
        self._busy(True)
        self._pydep_worker = PythonModuleInstallWorker(packages)
        self._pydep_worker.line.connect(self._log)
        self._pydep_worker.finished.connect(self._python_install_done)
        self._pydep_worker.start()

    def _python_install_done(self, ok, result):
        self._busy(False)
        if ok:
            self._set_banner("✓  Python dependency install finished.", True)
        else:
            self._set_banner("✗  Python dependency install failed — check Activity.", False)
            self._log("ERROR: %s" % result)
        self.check_python_dependencies()

    def download_or_run_zadig(self):
        if os.name != "nt":
            QMessageBox.information(
                self, APP_NAME,
                "Zadig / WinUSB setup is only needed on Windows."
            )
            return

        path = local_asset_path(ZADIG_LEAF)
        if os.path.isfile(path):
            self._launch_zadig(path)
            return

        self.banner.setVisible(False)
        self._busy(True)
        self._log("\n$ download %s" % ZADIG_DOWNLOAD_URL)
        self._zadig_dl = DownloadWorker(ZADIG_DOWNLOAD_URL, path)
        self._zadig_dl.line.connect(self._log)
        self._zadig_dl.finished.connect(self._zadig_downloaded)
        self._zadig_dl.start()

    def _zadig_downloaded(self, ok, path):
        self._busy(False)
        if not ok:
            self._set_banner("✗  Zadig download failed — check Activity.", False)
            return
        self._launch_zadig(path)

    def _launch_zadig(self, path):
        instructions = (
            "Zadig: Options > List All Devices → select the Tang Nano/JTAG Interface 0 "
            "→ choose WinUSB → Replace/Install Driver. Leave Interface 1 unchanged."
        )
        self._log("\n" + instructions)
        self._set_banner("WinUSB setup: Interface 0 → WinUSB. Leave Interface 1 unchanged.", True)
        try:
            # Zadig is portable and requests elevation when required. Using the
            # runas verb makes the intended driver-install context explicit.
            import ctypes
            rc = ctypes.windll.shell32.ShellExecuteW(
                None, "runas", os.path.abspath(path), None, os.path.dirname(path), 1)
            if int(rc) <= 32:
                raise OSError("ShellExecuteW returned %s" % rc)
        except Exception as e:
            QMessageBox.warning(
                self, APP_NAME,
                "Zadig was downloaded but could not be launched.\n\n%s\n\nFile: %s" % (e, path)
            )

    # ---- destructive maintenance --------------------------------------------
    def erase_chip(self):
        if not self.loader:
            QMessageBox.warning(
                self, APP_NAME,
                "Bundled openFPGALoader was not found. Re-extract or reinstall Eos Recovery."
            )
            return

        reply = QMessageBox.warning(
            self, APP_NAME,
            "ERASE THE ENTIRE EXTERNAL FLASH?\n\n"
            "This runs openFPGALoader --bulk-erase for the Tang Nano 20K. It will remove "
            "the Eos FPGA bitstream and all data stored in external flash. The board will "
            "need to be reflashed afterward.\n\nThis cannot be undone.",
            QMessageBox.Yes | QMessageBox.No, QMessageBox.No)
        if reply != QMessageBox.Yes:
            return

        self._run([self.loader, "-b", BOARD, "--bulk-erase"],
                  "Chip erase", "External flash was bulk-erased.")

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

        if found:
            self._log("  Board detect: OK")
        else:
            self._log("  Board detect: FAILED")
            if os.name == "nt":
                self._log("  If the board is connected, use Download / Run Zadig and bind Interface 0 to WinUSB.")

    # ---- program -----------------------------------------------------------
    def _guard(self, path, label):
        if not self.loader:
            QMessageBox.warning(self, APP_NAME,
                "Bundled openFPGALoader was not found. Re-extract or reinstall Eos Recovery.")
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
                "Bundled openFPGALoader was not found. Re-extract or reinstall Eos Recovery.")
            return
        self.banner.setVisible(False)
        self._busy(True)
        self._log("\n$ download %s" % BITSTREAM_URL)
        self._dl_label  = "Bitstream"
        self._dl_ok_msg = "Your Eos FPGA is reflashed."
        self._dl = DownloadWorker(BITSTREAM_URL, local_asset_path(BITSTREAM_LEAF))
        self._dl.line.connect(self._log)
        self._dl.finished.connect(self._server_bitstream_downloaded)
        self._dl.start()

    def _server_bitstream_downloaded(self, ok, local_path):
        if not ok:
            self._busy(False)
            self._set_banner("\u2717  Bitstream download failed \u2014 check the activity log.", False)
            return
        # Flash the persisted local bitstream with the plain -f command.
        self._run([self.loader, "-b", BOARD, "-f", local_path],
                  self._dl_label, self._dl_ok_msg)

    def program_bios(self):
        path = self.biosPath.text().strip()
        if not self._guard(path, "BIOS"):
            return
        self.settings.setValue("bios_path", path)
        self._run([self.loader, "-b", BOARD, "--external-flash", "-o", BIOS_OFFSET, path],
                  "BIOS", "Your Eos BIOS is reflashed.")

    # ---- server-hosted images (persisted locally before flashing) -----------
    def _download_and_flash(self, url, offset, label, ok_msg, leaf):
        """Shared flow behind the Loader and XbDiag cards.

        Pull the image from the Darkone server into the recovery app's local
        directory, then flash that persistent local asset at `offset`. CRC is
        intentionally not checked -- the server images are known-good.
        """
        if not self.loader:
            QMessageBox.warning(self, APP_NAME,
                "Bundled openFPGALoader was not found. Re-extract or reinstall Eos Recovery.")
            return
        self.banner.setVisible(False)
        self._busy(True)
        self._log("\n$ download %s" % url)
        self._dl_offset = offset
        self._dl_label  = label
        self._dl_ok_msg = ok_msg
        self._dl = DownloadWorker(url, local_asset_path(leaf))
        self._dl.line.connect(self._log)
        self._dl.finished.connect(self._server_image_downloaded)
        self._dl.start()

    def _server_image_downloaded(self, ok, local_path):
        if not ok:
            self._busy(False)
            self._set_banner("\u2717  %s download failed \u2014 check the activity log."
                             % self._dl_label, False)
            return
        # Flash the persistent local copy that was just downloaded.
        self._run([self.loader, "-b", BOARD, "--external-flash", "-o", self._dl_offset, local_path],
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
                                 LOADER_LEAF)

    def program_xbdiag(self):
        self._download_and_flash(XBDIAG_URL, XBDIAG_OFFSET,
                                 "XbDiag", "XbDiag Lite is flashed.",
                                 XBDIAG_LEAF)


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