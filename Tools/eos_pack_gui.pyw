#!/usr/bin/env python3
"""
EOS / PrometheOS Xenium Firmware Packer GUI

PySide6 front-end for the EOS embedded-XBE packer, with optional Xenium BIOS
bank injection and PrometheOS bank-metadata generation.

Dependencies:
    pip install PySide6 lz4

The XBE packing path preserves the original eos_pack.py contract:
    0x100000: <u32 decompressed size><u32 compressed size><raw LZ4 block>
    0x180000: end of XBE region / beginning of bootloader region

Xenium user BIOS region:
    Slot 1 256K: 0x000000-0x03FFFF
    Slot 2 256K: 0x040000-0x07FFFF
    Slot 3 256K: 0x080000-0x0BFFFF
    Slot 4 256K: 0x0C0000-0x0FFFFF

Supported BIOS layouts are the Xenium-native 256K, 512K, and 1M layouts.
"""

from __future__ import annotations

import hashlib
import os
import struct
import sys
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

import lz4.block
from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QPalette
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QFrame,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QStatusBar,
    QTabWidget,
    QTableWidget,
    QTableWidgetItem,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)


APP_TITLE = "EOS Xenium Firmware Packer"
FLASH_SIZE = 0x200000

USER_REGION_OFF = 0x000000
USER_REGION_LIMIT = 0x100000
SLOT_SIZE = 0x40000
SLOT_COUNT = 4

XBE_REGION_OFF = 0x100000
XBE_REGION_LIMIT = 0x180000
XBE_REGION_MAX = XBE_REGION_LIMIT - XBE_REGION_OFF

BOOTLOADER_OFF = 0x180000
RECOVERY_OFF = 0x1C0000

# PrometheOS 1.5.0 / Xenium settings location.
SETTINGS_ABS_OFF = 0x1F8000
PROMETHEOS_VERSION = (1, 5, 0, 0)

BANKINFO_SIZE = 68
BANKINFO_COUNT = 16
SETTINGS_HEADER_SIZE = 8  # crc32 + semver
NETWORK_INFO_SIZE = 24
SETTINGS_TAIL_SIZE = 19
SETTINGS_SIZE = (
    4 + 4 + (BANKINFO_SIZE * BANKINFO_COUNT) + NETWORK_INFO_SIZE + 8 + 64 + 64 + SETTINGS_TAIL_SIZE
)

LED_COLORS = [
    ("Off", 0),
    ("Red", 1),
    ("Green", 2),
    ("Amber", 3),
    ("Blue", 4),
    ("Purple", 5),
    ("Teal", 6),
    ("White", 7),
]

BIOS_SIZES = {
    0x40000: ("256 KB", 1),
    0x80000: ("512 KB", 2),
    0x100000: ("1 MB", 4),
}


class PackerError(RuntimeError):
    pass


@dataclass
class BiosEntry:
    path: str
    name: str
    led_color: int
    start_slot: int  # 0-based physical 256K slot
    slots: int
    auto_boot: bool = False

    @property
    def size(self) -> int:
        return self.slots * SLOT_SIZE

    @property
    def offset(self) -> int:
        return self.start_slot * SLOT_SIZE

    @property
    def layout_text(self) -> str:
        first = self.start_slot + 1
        last = self.start_slot + self.slots
        if first == last:
            return f"Slot {first} / 256 KB"
        return f"Slots {first}-{last} / {self.size // 1024} KB"


# ----------------------------- Backend ---------------------------------

def compress_xbe(xbe: bytes) -> bytes:
    return lz4.block.compress(
        xbe,
        store_size=False,
        mode="high_compression",
        compression=12,
    )


def decompress_xbe(image: bytes) -> bytes:
    if len(image) < XBE_REGION_OFF + 8:
        raise PackerError("Image is too small to contain the XeniumOS XBE descriptor.")
    dec_size, comp_size = struct.unpack_from("<II", image, XBE_REGION_OFF)
    if dec_size <= 0 or comp_size <= 0:
        raise PackerError("Embedded XBE descriptor is empty or invalid.")
    if 8 + comp_size > XBE_REGION_MAX:
        raise PackerError("Embedded XBE compressed size exceeds the 512 KB XeniumOS region.")
    payload = image[XBE_REGION_OFF + 8 : XBE_REGION_OFF + 8 + comp_size]
    try:
        raw = lz4.block.decompress(payload, uncompressed_size=dec_size)
    except Exception as exc:
        raise PackerError(f"Embedded XBE LZ4 decompression failed: {exc}") from exc
    if len(raw) != dec_size:
        raise PackerError("Embedded XBE decompressed length does not match its descriptor.")
    return raw


def inspect_xbe(image: bytes) -> dict:
    dec_size, comp_size = struct.unpack_from("<II", image, XBE_REGION_OFF)
    raw = decompress_xbe(image)
    return {
        "decompressed": dec_size,
        "compressed": comp_size,
        "usage": (8 + comp_size) / XBE_REGION_MAX * 100.0,
        "magic": raw[:4],
        "md5": hashlib.md5(raw).hexdigest(),
    }


def replace_xbe(image: bytearray, xbe: bytes) -> dict:
    comp = compress_xbe(xbe)
    blob = struct.pack("<II", len(xbe), len(comp)) + comp
    if len(blob) > XBE_REGION_MAX:
        raise PackerError(
            f"Descriptor + compressed XBE is 0x{len(blob):X} bytes; "
            f"the XeniumOS XBE region is only 0x{XBE_REGION_MAX:X}."
        )
    image[XBE_REGION_OFF:XBE_REGION_LIMIT] = b"\x00" * XBE_REGION_MAX
    image[XBE_REGION_OFF:XBE_REGION_OFF + len(blob)] = blob

    # Exact round-trip check, matching the original CLI packer's safety check.
    back = decompress_xbe(bytes(image))
    if hashlib.md5(back).digest() != hashlib.md5(xbe).digest():
        raise PackerError("XBE round-trip verification failed after packing.")

    return {
        "decompressed": len(xbe),
        "compressed": len(comp),
        "usage": len(blob) / XBE_REGION_MAX * 100.0,
        "magic": xbe[:4],
        "md5": hashlib.md5(xbe).hexdigest(),
    }


def blank_settings() -> bytearray:
    data = bytearray(SETTINGS_SIZE)
    # crc written last
    data[4:8] = bytes(PROMETHEOS_VERSION)

    # banks/network/high scores/skin/sound stay zeroed.
    tail = 4 + 4 + (BANKINFO_SIZE * BANKINFO_COUNT) + NETWORK_INFO_SIZE + 8 + 64 + 64
    defaults = bytes([
        5,    # autoBootDelay
        75,   # musicVolume
        100,  # soundVolume
        10,   # minFanSpeed
        2,    # ledColor (green)
        0,    # lcdMode
        0,    # lcdModel
        0,    # lcdAddress
        100,  # lcdBacklight
        80,   # lcdContrast
        0,    # rtcEnable
        1,    # driveSetup
        2,    # udmaModeMaster
        2,    # udmaModeSlave
        6,    # splashDelay
        0,    # vgaEnable
        0, 0, 0,  # reserved
    ])
    data[tail:tail + len(defaults)] = defaults
    update_settings_crc(data)
    return data


def settings_crc(data: bytes) -> int:
    return zlib.crc32(data[4:]) & 0xFFFFFFFF


def update_settings_crc(data: bytearray) -> None:
    struct.pack_into("<I", data, 0, settings_crc(data))


def read_settings(image: bytes) -> Tuple[bytearray, bool]:
    raw = bytearray(image[SETTINGS_ABS_OFF:SETTINGS_ABS_OFF + SETTINGS_SIZE])
    if len(raw) != SETTINGS_SIZE:
        return blank_settings(), False
    stored_crc = struct.unpack_from("<I", raw, 0)[0]
    version_ok = tuple(raw[4:8]) == PROMETHEOS_VERSION
    crc_ok = stored_crc == settings_crc(raw)
    if version_ok and crc_ok:
        return raw, True
    return blank_settings(), False


def write_bankinfo(settings: bytearray, entry: BiosEntry) -> None:
    off = SETTINGS_HEADER_SIZE + (entry.start_slot * BANKINFO_SIZE)
    name = entry.name.encode("utf-8", "replace")[:40]
    name_field = name + b"\x00" * (64 - len(name))
    packed = struct.pack(
        "<BBBB64s",
        entry.led_color & 0xFF,
        entry.slots & 0xFF,
        1 if entry.auto_boot else 0,
        0,
        name_field,
    )
    settings[off:off + BANKINFO_SIZE] = packed


def clear_user_bank_metadata(settings: bytearray) -> None:
    for slot in range(SLOT_COUNT):
        off = SETTINGS_HEADER_SIZE + (slot * BANKINFO_SIZE)
        settings[off:off + BANKINFO_SIZE] = b"\x00" * BANKINFO_SIZE


def validate_bios_entries(entries: List[BiosEntry]) -> None:
    used = [False] * SLOT_COUNT
    auto_boot_count = 0
    for entry in entries:
        if entry.slots not in (1, 2, 4):
            raise PackerError(f"Invalid slot count for {entry.name}.")
        if entry.slots == 2 and entry.start_slot not in (0, 2):
            raise PackerError(f"512 KB BIOS {entry.name} must begin at slot 1 or 3.")
        if entry.slots == 4 and entry.start_slot != 0:
            raise PackerError(f"1 MB BIOS {entry.name} must begin at slot 1.")
        if entry.start_slot < 0 or entry.start_slot + entry.slots > SLOT_COUNT:
            raise PackerError(f"BIOS {entry.name} lies outside the Xenium 1 MB user region.")
        p = Path(entry.path)
        if not p.is_file():
            raise PackerError(f"BIOS file does not exist: {entry.path}")
        size = p.stat().st_size
        if size != entry.size:
            raise PackerError(
                f"BIOS size changed for {entry.name}: expected {entry.size} bytes, found {size}."
            )
        for s in range(entry.start_slot, entry.start_slot + entry.slots):
            if used[s]:
                raise PackerError(f"BIOS bank layout overlaps at physical slot {s + 1}.")
            used[s] = True
        if entry.auto_boot:
            auto_boot_count += 1
    if auto_boot_count > 1:
        raise PackerError("PrometheOS supports only one auto-boot bank at a time.")


def inject_bioses(image: bytearray, entries: List[BiosEntry]) -> None:
    if not entries:
        return
    validate_bios_entries(entries)

    # Deterministic image-builder behavior: rebuild the complete Xenium user region.
    image[USER_REGION_OFF:USER_REGION_LIMIT] = b"\x00" * (USER_REGION_LIMIT - USER_REGION_OFF)

    settings, _was_valid = read_settings(bytes(image))
    clear_user_bank_metadata(settings)

    for entry in entries:
        bios = Path(entry.path).read_bytes()
        start = entry.offset
        image[start:start + len(bios)] = bios
        write_bankinfo(settings, entry)

    update_settings_crc(settings)
    image[SETTINGS_ABS_OFF:SETTINGS_ABS_OFF + SETTINGS_SIZE] = settings


def verify_firmware(image: bytes) -> List[str]:
    messages: List[str] = []
    if len(image) != FLASH_SIZE:
        raise PackerError(f"Expected a 2 MB Xenium image; got 0x{len(image):X} bytes.")
    messages.append("2 MB Xenium image size: OK")

    info = inspect_xbe(image)
    messages.append(
        f"Embedded XBE: {info['decompressed']} B -> {info['compressed']} B "
        f"({info['usage']:.1f}% of 512 KB region), MD5 {info['md5'][:12]}"
    )
    if info["magic"] == b"XBEH":
        messages.append("Embedded XBE magic: XBEH / OK")
    else:
        messages.append(f"Embedded XBE magic: {info['magic']!r} / WARNING")

    raw = image[SETTINGS_ABS_OFF:SETTINGS_ABS_OFF + SETTINGS_SIZE]
    if any(raw):
        stored = struct.unpack_from("<I", raw, 0)[0]
        calc = settings_crc(raw)
        version = tuple(raw[4:8])
        if stored == calc and version == PROMETHEOS_VERSION:
            messages.append("PrometheOS 1.5.0 settings CRC: OK")
        else:
            messages.append(
                f"PrometheOS settings: WARNING (version={version[:3]}, "
                f"stored CRC={stored:08X}, calculated={calc:08X})"
            )
    else:
        messages.append("PrometheOS settings area is blank (normal for a clean release template).")

    return messages


# ------------------------------- GUI -----------------------------------

class BiosDialog(QDialog):
    def __init__(self, parent: QWidget, path: str, occupied: List[bool], existing: Optional[BiosEntry] = None):
        super().__init__(parent)
        self.setWindowTitle("Add BIOS" if existing is None else "Edit BIOS")
        self.path = path
        self.occupied = occupied
        self.existing = existing

        p = Path(path)
        size = p.stat().st_size
        if size not in BIOS_SIZES:
            raise PackerError("BIOS must be exactly 256 KB, 512 KB, or 1 MB.")
        self.size_label, self.slots = BIOS_SIZES[size]

        form = QFormLayout(self)
        self.file_edit = QLineEdit(str(p))
        self.file_edit.setReadOnly(True)
        form.addRow("BIOS file:", self.file_edit)

        self.size_edit = QLineEdit(self.size_label)
        self.size_edit.setReadOnly(True)
        form.addRow("Size:", self.size_edit)

        self.name_edit = QLineEdit(existing.name if existing else p.stem)
        self.name_edit.setMaxLength(40)
        form.addRow("Bank name:", self.name_edit)

        self.slot_combo = QComboBox()
        for slot in self.valid_starts():
            first = slot + 1
            last = slot + self.slots
            label = f"Slot {first}" if self.slots == 1 else f"Slots {first}-{last}"
            self.slot_combo.addItem(label, slot)
        if existing:
            idx = self.slot_combo.findData(existing.start_slot)
            if idx >= 0:
                self.slot_combo.setCurrentIndex(idx)
        form.addRow("Placement:", self.slot_combo)

        self.led_combo = QComboBox()
        for name, value in LED_COLORS:
            self.led_combo.addItem(name, value)
        if existing:
            idx = self.led_combo.findData(existing.led_color)
            if idx >= 0:
                self.led_combo.setCurrentIndex(idx)
        else:
            self.led_combo.setCurrentIndex(self.led_combo.findData(2))
        form.addRow("LED color:", self.led_combo)

        self.auto_boot = QCheckBox("Auto-boot this BIOS")
        self.auto_boot.setChecked(existing.auto_boot if existing else False)
        form.addRow("", self.auto_boot)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        form.addRow(buttons)

        if self.slot_combo.count() == 0:
            raise PackerError("There is no valid free placement for this BIOS size.")

    def valid_starts(self) -> List[int]:
        if self.slots == 4:
            candidates = [0]
        elif self.slots == 2:
            candidates = [0, 2]
        else:
            candidates = [0, 1, 2, 3]

        starts = []
        for start in candidates:
            ok = True
            for s in range(start, start + self.slots):
                if self.occupied[s]:
                    ok = False
                    break
            if ok:
                starts.append(start)
        return starts

    def entry(self) -> BiosEntry:
        return BiosEntry(
            path=self.path,
            name=self.name_edit.text().strip() or Path(self.path).stem,
            led_color=int(self.led_combo.currentData()),
            start_slot=int(self.slot_combo.currentData()),
            slots=self.slots,
            auto_boot=self.auto_boot.isChecked(),
        )


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP_TITLE)
        self.resize(920, 690)
        self.template_path = ""
        self.xbe_path = ""
        self.bios_entries: List[BiosEntry] = []

        root = QWidget()
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)

        title = QLabel("EOS Firmware Packer")
        title.setObjectName("title")
        subtitle = QLabel("EOS image builder • embedded XBE + BIOS banks")
        subtitle.setObjectName("subtitle")
        layout.addWidget(title)
        layout.addWidget(subtitle)

        template_group = QGroupBox("Base firmware image")
        template_row = QHBoxLayout(template_group)
        self.template_edit = QLineEdit()
        self.template_edit.setReadOnly(True)
        browse_template = QPushButton("Browse…")
        browse_template.clicked.connect(self.choose_template)
        template_row.addWidget(self.template_edit, 1)
        template_row.addWidget(browse_template)
        layout.addWidget(template_group)

        self.tabs = QTabWidget()
        self.tabs.addTab(self.make_xbe_tab(), "Embedded XBE")
        self.tabs.addTab(self.make_bios_tab(), "BIOS Banks")
        self.tabs.addTab(self.make_verify_tab(), "Verify / Log")
        layout.addWidget(self.tabs, 1)

        bottom = QHBoxLayout()
        self.build_btn = QPushButton("Build Firmware Image…")
        self.build_btn.setObjectName("primary")
        self.build_btn.clicked.connect(self.build_image)
        verify_btn = QPushButton("Verify Base Image")
        verify_btn.clicked.connect(self.verify_template)
        bottom.addStretch(1)
        bottom.addWidget(verify_btn)
        bottom.addWidget(self.build_btn)
        layout.addLayout(bottom)

        self.setStatusBar(QStatusBar())
        self.apply_style()
        self.try_default_template()

    def make_xbe_tab(self) -> QWidget:
        tab = QWidget()
        layout = QVBoxLayout(tab)

        current = QGroupBox("Current embedded XBE")
        grid = QGridLayout(current)
        self.xbe_dec = QLabel("—")
        self.xbe_comp = QLabel("—")
        self.xbe_md5 = QLabel("—")
        self.xbe_magic = QLabel("—")
        self.xbe_usage = QProgressBar()
        self.xbe_usage.setRange(0, 1000)
        self.xbe_usage.setTextVisible(True)
        grid.addWidget(QLabel("Decompressed:"), 0, 0)
        grid.addWidget(self.xbe_dec, 0, 1)
        grid.addWidget(QLabel("Compressed:"), 1, 0)
        grid.addWidget(self.xbe_comp, 1, 1)
        grid.addWidget(QLabel("Magic:"), 0, 2)
        grid.addWidget(self.xbe_magic, 0, 3)
        grid.addWidget(QLabel("MD5:"), 1, 2)
        grid.addWidget(self.xbe_md5, 1, 3)
        grid.addWidget(QLabel("XeniumOS region usage:"), 2, 0)
        grid.addWidget(self.xbe_usage, 2, 1, 1, 3)
        layout.addWidget(current)

        replace = QGroupBox("Replacement XBE (optional)")
        v = QVBoxLayout(replace)
        row = QHBoxLayout()
        self.xbe_edit = QLineEdit()
        self.xbe_edit.setReadOnly(True)
        browse = QPushButton("Select XBE…")
        browse.clicked.connect(self.choose_xbe)
        clear = QPushButton("Clear")
        clear.clicked.connect(self.clear_xbe)
        row.addWidget(self.xbe_edit, 1)
        row.addWidget(browse)
        row.addWidget(clear)
        v.addLayout(row)
        self.xbe_candidate = QLabel("No replacement selected; the base image XBE will be preserved.")
        self.xbe_candidate.setWordWrap(True)
        v.addWidget(self.xbe_candidate)
        layout.addWidget(replace)

        row2 = QHBoxLayout()
        extract = QPushButton("Extract Embedded XBE…")
        extract.clicked.connect(self.extract_xbe)
        row2.addWidget(extract)
        row2.addStretch(1)
        layout.addLayout(row2)
        layout.addStretch(1)
        return tab

    def make_bios_tab(self) -> QWidget:
        tab = QWidget()
        layout = QVBoxLayout(tab)
        info = QLabel(
            "Build a PrometheOS-ready Xenium user-bank region. Supported BIOS sizes: "
            "256 KB, 512 KB, and 1 MB. The bank table, names, LED colors, and optional "
            "auto-boot flag are written into PrometheOS settings automatically."
        )
        info.setWordWrap(True)
        layout.addWidget(info)

        self.bios_table = QTableWidget(0, 5)
        self.bios_table.setHorizontalHeaderLabels(["Placement", "Size", "Name", "LED", "BIOS file"])
        self.bios_table.setSelectionBehavior(QTableWidget.SelectRows)
        self.bios_table.setSelectionMode(QTableWidget.SingleSelection)
        self.bios_table.setEditTriggers(QTableWidget.NoEditTriggers)
        hdr = self.bios_table.horizontalHeader()
        hdr.setSectionResizeMode(0, QHeaderView.ResizeToContents)
        hdr.setSectionResizeMode(1, QHeaderView.ResizeToContents)
        hdr.setSectionResizeMode(2, QHeaderView.ResizeToContents)
        hdr.setSectionResizeMode(3, QHeaderView.ResizeToContents)
        hdr.setSectionResizeMode(4, QHeaderView.Stretch)
        layout.addWidget(self.bios_table, 1)

        controls = QHBoxLayout()
        add = QPushButton("Add BIOS…")
        add.clicked.connect(self.add_bios)
        remove = QPushButton("Remove Selected")
        remove.clicked.connect(self.remove_bios)
        clear = QPushButton("Clear Banks")
        clear.clicked.connect(self.clear_bioses)
        controls.addWidget(add)
        controls.addWidget(remove)
        controls.addWidget(clear)
        controls.addStretch(1)
        layout.addLayout(controls)

        self.bank_usage = QLabel("User BIOS region: empty / 1024 KB")
        layout.addWidget(self.bank_usage)
        return tab

    def make_verify_tab(self) -> QWidget:
        tab = QWidget()
        layout = QVBoxLayout(tab)
        self.log = QTextEdit()
        self.log.setReadOnly(True)
        self.log.setPlaceholderText("Verification and build results appear here.")
        layout.addWidget(self.log)
        row = QHBoxLayout()
        clear = QPushButton("Clear Log")
        clear.clicked.connect(self.log.clear)
        row.addStretch(1)
        row.addWidget(clear)
        layout.addLayout(row)
        return tab

    def apply_style(self) -> None:
        self.setStyleSheet(
            """
            QMainWindow, QWidget { background: #111019; color: #ece8f7; font-size: 10pt; }
            QLabel#title { font-size: 20pt; font-weight: 700; color: #f3eaff; }
            QLabel#subtitle { color: #aaa4b8; margin-bottom: 6px; }
            QGroupBox { border: 1px solid #302a3c; border-radius: 9px; margin-top: 10px; padding-top: 12px; }
            QGroupBox::title { subcontrol-origin: margin; left: 12px; padding: 0 5px; color: #cdb8ef; }
            QLineEdit, QTextEdit, QTableWidget, QComboBox {
                background: #181522; border: 1px solid #373045; border-radius: 6px; padding: 6px;
                selection-background-color: #7f4db2;
            }
            QHeaderView::section { background: #211b2d; color: #d9cbea; border: 0; padding: 7px; }
            QPushButton {
                background: #2b2238; border: 1px solid #49365d; border-radius: 7px;
                padding: 7px 13px; color: #eee8f5;
            }
            QPushButton:hover { background: #382848; border-color: #76509b; }
            QPushButton#primary { background: #6f3ca0; border-color: #9965c8; font-weight: 700; }
            QPushButton#primary:hover { background: #8250b4; }
            QTabWidget::pane { border: 1px solid #302a3c; border-radius: 8px; }
            QTabBar::tab { background: #1d1826; padding: 8px 16px; margin-right: 2px; }
            QTabBar::tab:selected { background: #39234e; color: white; }
            QProgressBar { border: 1px solid #3a3047; border-radius: 6px; text-align: center; background: #181522; }
            QProgressBar::chunk { background: #7545a4; border-radius: 5px; }
            """
        )

    def try_default_template(self) -> None:
        here = Path(sys.argv[0]).resolve().parent
        candidate = here / "Xenium Prometheos V1.5.0.bin"
        if candidate.is_file():
            self.load_template(str(candidate))

    def append_log(self, text: str) -> None:
        self.log.append(text)

    def fail(self, message: str) -> None:
        QMessageBox.critical(self, APP_TITLE, message)
        self.statusBar().showMessage(message, 7000)
        self.append_log(f"ERROR: {message}")

    def choose_template(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Select Xenium firmware image", "", "Binary images (*.bin);;All files (*)")
        if path:
            self.load_template(path)

    def load_template(self, path: str) -> None:
        try:
            raw = Path(path).read_bytes()
            if len(raw) != FLASH_SIZE:
                raise PackerError(f"Xenium template must be exactly 2 MB; this file is {len(raw)} bytes.")
            info = inspect_xbe(raw)
        except Exception as exc:
            self.fail(str(exc))
            return

        self.template_path = path
        self.template_edit.setText(path)
        self.update_xbe_info(info)
        self.statusBar().showMessage("Base firmware loaded.", 4000)
        self.append_log(f"Loaded template: {path}")

    def update_xbe_info(self, info: dict) -> None:
        self.xbe_dec.setText(f"{info['decompressed']:,} bytes")
        self.xbe_comp.setText(f"{info['compressed']:,} bytes")
        self.xbe_magic.setText(repr(info["magic"]))
        self.xbe_md5.setText(info["md5"])
        self.xbe_usage.setValue(int(info["usage"] * 10))
        self.xbe_usage.setFormat(f"{info['usage']:.1f}%")

    def choose_xbe(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Select replacement XBE", "", "Xbox Executables (*.xbe);;All files (*)")
        if not path:
            return
        try:
            raw = Path(path).read_bytes()
            comp = compress_xbe(raw)
            total = len(comp) + 8
            if total > XBE_REGION_MAX:
                raise PackerError(
                    f"Compressed payload requires 0x{total:X} bytes but only 0x{XBE_REGION_MAX:X} are available."
                )
            magic = raw[:4]
            self.xbe_path = path
            self.xbe_edit.setText(path)
            warning = "" if magic == b"XBEH" else "  WARNING: input does not begin with XBEH."
            self.xbe_candidate.setText(
                f"{len(raw):,} bytes -> {len(comp):,} bytes LZ4, {100*total/XBE_REGION_MAX:.1f}% of region.{warning}"
            )
        except Exception as exc:
            self.fail(str(exc))

    def clear_xbe(self) -> None:
        self.xbe_path = ""
        self.xbe_edit.clear()
        self.xbe_candidate.setText("No replacement selected; the base image XBE will be preserved.")

    def extract_xbe(self) -> None:
        if not self.template_path:
            self.fail("Select a base firmware image first.")
            return
        out, _ = QFileDialog.getSaveFileName(self, "Extract embedded XBE", "PrometheOS.xbe", "Xbox Executables (*.xbe)")
        if not out:
            return
        try:
            raw = decompress_xbe(Path(self.template_path).read_bytes())
            Path(out).write_bytes(raw)
            self.append_log(f"Extracted XBE -> {out} ({len(raw):,} bytes)")
            self.statusBar().showMessage("Embedded XBE extracted.", 4000)
        except Exception as exc:
            self.fail(str(exc))

    def occupied_slots(self) -> List[bool]:
        occupied = [False] * SLOT_COUNT
        for entry in self.bios_entries:
            for s in range(entry.start_slot, entry.start_slot + entry.slots):
                occupied[s] = True
        return occupied

    def add_bios(self) -> None:
        path, _ = QFileDialog.getOpenFileName(self, "Select BIOS", "", "BIOS images (*.bin);;All files (*)")
        if not path:
            return
        try:
            size = Path(path).stat().st_size
            if size not in BIOS_SIZES:
                raise PackerError(f"BIOS must be exactly 256 KB, 512 KB, or 1 MB; selected file is {size:,} bytes.")
            dialog = BiosDialog(self, path, self.occupied_slots())
            if dialog.exec() != QDialog.Accepted:
                return
            entry = dialog.entry()
            if entry.auto_boot:
                for old in self.bios_entries:
                    old.auto_boot = False
            self.bios_entries.append(entry)
            self.bios_entries.sort(key=lambda e: e.start_slot)
            self.refresh_bios_table()
        except Exception as exc:
            self.fail(str(exc))

    def remove_bios(self) -> None:
        row = self.bios_table.currentRow()
        if row < 0 or row >= len(self.bios_entries):
            return
        self.bios_entries.pop(row)
        self.refresh_bios_table()

    def clear_bioses(self) -> None:
        self.bios_entries.clear()
        self.refresh_bios_table()

    def refresh_bios_table(self) -> None:
        self.bios_table.setRowCount(len(self.bios_entries))
        used = 0
        led_names = {value: name for name, value in LED_COLORS}
        for row, entry in enumerate(self.bios_entries):
            placement = f"Slot {entry.start_slot + 1}" if entry.slots == 1 else f"Slots {entry.start_slot + 1}-{entry.start_slot + entry.slots}"
            size = f"{entry.size // 1024} KB"
            name = entry.name + ("  [AUTO]" if entry.auto_boot else "")
            values = [placement, size, name, led_names.get(entry.led_color, str(entry.led_color)), entry.path]
            for col, value in enumerate(values):
                self.bios_table.setItem(row, col, QTableWidgetItem(value))
            used += entry.size
        self.bank_usage.setText(f"User BIOS region: {used // 1024} KB used / 1024 KB")

    def verify_template(self) -> None:
        if not self.template_path:
            self.fail("Select a base firmware image first.")
            return
        try:
            messages = verify_firmware(Path(self.template_path).read_bytes())
            self.append_log("\nVERIFY BASE IMAGE")
            for msg in messages:
                self.append_log("  " + msg)
            self.tabs.setCurrentIndex(2)
            self.statusBar().showMessage("Verification complete.", 4000)
        except Exception as exc:
            self.fail(str(exc))

    def build_image(self) -> None:
        if not self.template_path:
            self.fail("Select a base firmware image first.")
            return
        default_name = str(Path(self.template_path).with_name(Path(self.template_path).stem + "-custom.bin"))
        out, _ = QFileDialog.getSaveFileName(self, "Save packed firmware image", default_name, "Binary images (*.bin)")
        if not out:
            return
        try:
            image = bytearray(Path(self.template_path).read_bytes())
            if len(image) != FLASH_SIZE:
                raise PackerError("Base image is no longer exactly 2 MB.")

            self.append_log("\nBUILD")
            self.append_log(f"  Base: {self.template_path}")

            if self.xbe_path:
                xbe = Path(self.xbe_path).read_bytes()
                info = replace_xbe(image, xbe)
                self.append_log(
                    f"  XBE: {len(xbe):,} B -> {info['compressed']:,} B "
                    f"({info['usage']:.1f}% of region), round-trip OK"
                )
            else:
                self.append_log("  XBE: preserved from base image")

            if self.bios_entries:
                inject_bioses(image, self.bios_entries)
                self.append_log("  User BIOS region rebuilt:")
                for entry in self.bios_entries:
                    self.append_log(
                        f"    {entry.layout_text}: {entry.name} / "
                        f"{Path(entry.path).name}" + (" / AUTO" if entry.auto_boot else "")
                    )
                self.append_log("  PrometheOS bank metadata + CRC updated")
            else:
                self.append_log("  BIOS banks: preserved from base image")

            # Final verification before writing.
            messages = verify_firmware(bytes(image))
            Path(out).write_bytes(image)
            self.append_log(f"  Output: {out}")
            self.append_log("  Final verification:")
            for msg in messages:
                self.append_log("    " + msg)
            self.tabs.setCurrentIndex(2)
            self.statusBar().showMessage("Firmware image built and verified.", 6000)
            QMessageBox.information(self, APP_TITLE, f"Firmware image built successfully:\n\n{out}")
        except Exception as exc:
            self.fail(str(exc))


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName(APP_TITLE)
    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
