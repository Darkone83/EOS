#!/usr/bin/env python3
"""
eos_pack.py - EOS embedded-XBE packer for PrometheOS 1.6+ Xenium images.

PrometheOS 1.6+ changed its embedded XBE from raw LZ4 to LZX.  The Xenium
image still stores a little-endian descriptor followed by the compressed
payload, but the logical XBE bank is 608 KiB split around the bootloader:

    0x100000-0x17FFFF   first 512 KiB of logical XBE bank
    0x180000-0x1BFFFF   Xenium bootloader (preserved from template)
    0x1C0000-0x1DFFFF   recovery/other data (preserved from template)
    0x1E0000-0x1F7FFF   final 96 KiB of logical XBE bank
    0x1F8000-0x1FFFFF   settings/spare (preserved from template)

Logical XBE bank format:

    u32 decompressed_size
    u32 compressed_size
    repeated LZX records:
        u16 compressed_block_size
        u16 uncompressed_block_size
        compressed_block_data[compressed_block_size]
    zero padding to 608 KiB

No third-party DLL or Python compression module is required.  On Windows this
script uses the built-in makecab.exe/expand.exe LZX implementation.  The LZX
window is fixed to 128 KiB (CompressionMemory=17), matching Team Resurgent's
PrometheOS 1.6 LZXToolkit/libLZX default.

Usage:
    pack:    python eos_pack.py pack   <template.bin> <loader.xbe> <out.bin>
    unpack:  python eos_pack.py unpack <image.bin> <out.xbe>
    verify:  python eos_pack.py verify <image.bin>
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import Iterable, List, Tuple


FLASH_SIZE = 0x200000

XBE_PRIMARY_OFF = 0x100000
XBE_PRIMARY_SIZE = 0x080000       # 512 KiB
BOOTLOADER_OFF = 0x180000
BOOTLOADER_SIZE = 0x040000        # 256 KiB
XBE_CONT_OFF = 0x1E0000
XBE_CONT_SIZE = 0x018000          # 96 KiB
XBE_BANK_SIZE = XBE_PRIMARY_SIZE + XBE_CONT_SIZE  # 608 KiB

LZX_WINDOW_BITS = 17              # 128 KiB, PrometheOS 1.6/libLZX default
LZX_CHUNK_SIZE = 0x8000           # 32 KiB CFDATA/LZX frame size

CAB_FLAG_PREV = 0x0001
CAB_FLAG_NEXT = 0x0002
CAB_FLAG_RESERVE = 0x0004
CAB_COMP_LZX = 0x0003


class PackerError(RuntimeError):
    pass


def _tool(name: str) -> str:
    path = shutil.which(name)
    if path:
        return path

    # System32 normally is already on PATH, but this makes the failure mode
    # deterministic for stripped-down shells.
    windir = os.environ.get("WINDIR") or os.environ.get("SystemRoot")
    if windir:
        candidate = Path(windir) / "System32" / name
        if candidate.is_file():
            return str(candidate)

    raise PackerError(
        f"{name} was not found. PrometheOS 1.6 packing requires Windows' "
        f"built-in {name}."
    )


def _run(args: List[str], cwd: Path | None = None) -> None:
    proc = subprocess.run(
        args,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    )
    if proc.returncode != 0:
        raise PackerError(
            f"Command failed ({proc.returncode}): {' '.join(args)}\n{proc.stdout.strip()}"
        )


def _read_c_string(buf: bytes, pos: int) -> int:
    end = buf.find(b"\x00", pos)
    if end < 0:
        raise PackerError("Malformed CAB: unterminated string.")
    return end + 1


def _cab_to_lzx_stream(cab: bytes) -> Tuple[bytes, int]:
    """Extract PrometheOS/libLZX-style framed LZX data from a single-folder CAB."""
    if len(cab) < 36:
        raise PackerError("CAB output is too small.")

    (
        sig,
        _reserved1,
        cb_cabinet,
        _reserved2,
        _coff_files,
        _reserved3,
        ver_minor,
        ver_major,
        c_folders,
        _c_files,
        flags,
        _set_id,
        _i_cab,
    ) = struct.unpack_from("<4sIIIII BBHHHHH", cab, 0)

    if sig != b"MSCF":
        raise PackerError("makecab output does not contain an MSCF CAB header.")
    if cb_cabinet > len(cab):
        raise PackerError("Malformed CAB: declared cabinet size exceeds file size.")
    if c_folders != 1:
        raise PackerError(f"Expected one CAB folder, got {c_folders}.")

    pos = 36
    cb_cf_folder = 0
    cb_cf_data = 0

    if flags & CAB_FLAG_RESERVE:
        if pos + 4 > len(cab):
            raise PackerError("Malformed CAB reserve header.")
        cb_cf_header, cb_cf_folder, cb_cf_data = struct.unpack_from("<HBB", cab, pos)
        pos += 4 + cb_cf_header

    if flags & CAB_FLAG_PREV:
        pos = _read_c_string(cab, pos)
        pos = _read_c_string(cab, pos)
    if flags & CAB_FLAG_NEXT:
        pos = _read_c_string(cab, pos)
        pos = _read_c_string(cab, pos)

    if pos + 8 + cb_cf_folder > len(cab):
        raise PackerError("Malformed CAB folder entry.")

    coff_cab_start, c_cf_data, type_compress = struct.unpack_from("<IHH", cab, pos)
    method = type_compress & 0x000F
    window_bits = (type_compress >> 8) & 0x001F

    if method != CAB_COMP_LZX:
        raise PackerError(f"makecab did not produce LZX data (type=0x{type_compress:04X}).")
    if window_bits != LZX_WINDOW_BITS:
        raise PackerError(
            f"Unexpected LZX window {window_bits}; expected {LZX_WINDOW_BITS}."
        )

    pos = coff_cab_start
    framed = bytearray()
    total_uncompressed = 0

    for index in range(c_cf_data):
        if pos + 8 + cb_cf_data > len(cab):
            raise PackerError(f"Malformed CAB CFDATA header at block {index}.")

        _checksum, cb_data, cb_uncomp = struct.unpack_from("<IHH", cab, pos)
        pos += 8
        if cb_cf_data:
            pos += cb_cf_data

        if pos + cb_data > len(cab):
            raise PackerError(f"Malformed CAB CFDATA payload at block {index}.")
        if cb_data > 0xFFFF or cb_uncomp > 0xFFFF:
            raise PackerError("CAB block size does not fit PrometheOS LZX framing.")
        if cb_uncomp == 0 or cb_uncomp > LZX_CHUNK_SIZE:
            raise PackerError(
                f"Unexpected uncompressed LZX block size 0x{cb_uncomp:X} at block {index}."
            )

        framed += struct.pack("<HH", cb_data, cb_uncomp)
        framed += cab[pos : pos + cb_data]
        total_uncompressed += cb_uncomp
        pos += cb_data

    if not framed:
        raise PackerError("makecab produced no LZX CFDATA blocks.")

    return bytes(framed), total_uncompressed


def _parse_lzx_stream(stream: bytes, expected_size: int | None = None) -> List[Tuple[int, int, bytes]]:
    """Validate and split PrometheOS/libLZX framed LZX data."""
    blocks: List[Tuple[int, int, bytes]] = []
    pos = 0
    total_uncompressed = 0

    while pos < len(stream):
        if pos + 4 > len(stream):
            raise PackerError("Truncated LZX block header.")
        cb_data, cb_uncomp = struct.unpack_from("<HH", stream, pos)
        pos += 4

        if cb_data == 0:
            raise PackerError("Invalid zero-length LZX block.")
        if cb_uncomp == 0 or cb_uncomp > LZX_CHUNK_SIZE:
            raise PackerError(f"Invalid LZX uncompressed block size 0x{cb_uncomp:X}.")
        if pos + cb_data > len(stream):
            raise PackerError("Truncated LZX block payload.")

        data = stream[pos : pos + cb_data]
        blocks.append((cb_data, cb_uncomp, data))
        total_uncompressed += cb_uncomp
        pos += cb_data

    if expected_size is not None and total_uncompressed != expected_size:
        raise PackerError(
            f"LZX stream expands to 0x{total_uncompressed:X} bytes, "
            f"descriptor says 0x{expected_size:X}."
        )

    return blocks


def _makecab_lzx(raw: bytes) -> bytes:
    """Compress bytes to the PrometheOS 1.6/libLZX block stream using makecab.exe.

    Use makecab's direct source/destination mode instead of a DDF.  A DDF is
    unnecessary for a single file and can make MakeCAB interpret the file line
    as layout metadata rather than as an input file.
    """
    makecab = _tool("makecab.exe")

    with tempfile.TemporaryDirectory(prefix="eos_lzx_") as td:
        root = Path(td)
        source = root / "payload.xbe"
        cab_path = root / "payload.cab"

        source.write_bytes(raw)

        # Microsoft documents /D variables as valid in direct source/destination
        # mode.  These two settings force the same 128 KiB LZX window used by
        # PrometheOS 1.6 / libLZX.
        _run(
            [
                makecab,
                "/V0",
                "/D",
                "CompressionType=LZX",
                "/D",
                f"CompressionMemory={LZX_WINDOW_BITS}",
                str(source),
                str(cab_path),
            ],
            cwd=root,
        )

        if not cab_path.is_file():
            raise PackerError("makecab completed but payload.cab was not produced.")

        stream, total_uncompressed = _cab_to_lzx_stream(cab_path.read_bytes())
        if total_uncompressed != len(raw):
            raise PackerError(
                f"makecab block total is 0x{total_uncompressed:X}, expected 0x{len(raw):X}."
            )
        _parse_lzx_stream(stream, len(raw))
        return stream


def _lzx_stream_to_cab(stream: bytes, filename: str = "payload.xbe") -> bytes:
    """Wrap a PrometheOS/libLZX framed stream in a minimal CAB for expand.exe."""
    blocks = _parse_lzx_stream(stream)
    total_uncompressed = sum(b[1] for b in blocks)

    name = filename.encode("ascii", "replace") + b"\x00"
    header_size = 36
    folder_off = header_size
    folder_size = 8
    files_off = folder_off + folder_size
    file_entry_size = 16 + len(name)
    data_off = files_off + file_entry_size
    data_size = sum(8 + cb_data for cb_data, _cb_uncomp, _data in blocks)
    cabinet_size = data_off + data_size

    type_compress = CAB_COMP_LZX | (LZX_WINDOW_BITS << 8)

    out = bytearray()
    out += struct.pack(
        "<4sIIIII BBHHHHH",
        b"MSCF",
        0,
        cabinet_size,
        0,
        files_off,
        0,
        3,  # minor
        1,  # major
        1,  # folders
        1,  # files
        0,  # flags
        0,  # setID
        0,  # iCabinet
    )
    out += struct.pack("<IHH", data_off, len(blocks), type_compress)
    out += struct.pack(
        "<IIHHHH",
        total_uncompressed,
        0,      # folder-relative offset
        0,      # folder index
        0,      # date
        0,      # time
        0x20,   # archive attribute
    )
    out += name

    for cb_data, cb_uncomp, data in blocks:
        # A zero CFDATA checksum means no checksum validation is requested.
        out += struct.pack("<IHH", 0, cb_data, cb_uncomp)
        out += data

    if len(out) != cabinet_size:
        raise PackerError("Internal CAB builder size mismatch.")
    return bytes(out)


def _expand_lzx(stream: bytes) -> bytes:
    """Decode a PrometheOS/libLZX block stream with Windows expand.exe."""
    expand = _tool("expand.exe")

    with tempfile.TemporaryDirectory(prefix="eos_unlzx_") as td:
        root = Path(td)
        cab_path = root / "payload.cab"
        out_dir = root / "out"
        out_dir.mkdir()
        cab_path.write_bytes(_lzx_stream_to_cab(stream))

        _run([expand, str(cab_path), "-F:*", str(out_dir)], cwd=root)

        files = [p for p in out_dir.iterdir() if p.is_file()]
        if len(files) != 1:
            raise PackerError(f"expand.exe produced {len(files)} files; expected one.")
        return files[0].read_bytes()


def _logical_bank_from_image(image: bytes) -> bytes:
    if len(image) != FLASH_SIZE:
        raise PackerError(f"Expected a 2 MiB Xenium image; got 0x{len(image):X} bytes.")
    return (
        image[XBE_PRIMARY_OFF : XBE_PRIMARY_OFF + XBE_PRIMARY_SIZE]
        + image[XBE_CONT_OFF : XBE_CONT_OFF + XBE_CONT_SIZE]
    )


def _payload_from_image(image: bytes) -> Tuple[int, int, bytes]:
    bank = _logical_bank_from_image(image)
    if len(bank) < 8:
        raise PackerError("XBE bank is too small for its descriptor.")

    dec_size, comp_size = struct.unpack_from("<II", bank, 0)
    if dec_size == 0 or comp_size == 0:
        raise PackerError("Embedded XBE descriptor is empty.")
    if comp_size > XBE_BANK_SIZE - 8:
        raise PackerError(
            f"Embedded compressed size 0x{comp_size:X} exceeds the 608 KiB Xenium XBE bank."
        )

    stream = bank[8 : 8 + comp_size]
    _parse_lzx_stream(stream, dec_size)
    return dec_size, comp_size, stream


def _scatter_bank(image: bytearray, bank: bytes) -> None:
    if len(bank) != XBE_BANK_SIZE:
        raise PackerError("Internal logical XBE bank size mismatch.")

    image[XBE_PRIMARY_OFF : XBE_PRIMARY_OFF + XBE_PRIMARY_SIZE] = bank[:XBE_PRIMARY_SIZE]
    image[XBE_CONT_OFF : XBE_CONT_OFF + XBE_CONT_SIZE] = bank[XBE_PRIMARY_SIZE:]


def pack(template_path: str, xbe_path: str, out_path: str) -> None:
    template = Path(template_path).read_bytes()
    if len(template) != FLASH_SIZE:
        raise PackerError(
            f"Template must be exactly 2 MiB; got 0x{len(template):X} bytes."
        )

    xbe = Path(xbe_path).read_bytes()
    if not xbe:
        raise PackerError("Input XBE is empty.")
    if xbe[:4] != b"XBEH":
        print("WARNING: input does not start with XBEH magic - is it a real XBE?")

    stream = _makecab_lzx(xbe)
    blob = struct.pack("<II", len(xbe), len(stream)) + stream
    if len(blob) > XBE_BANK_SIZE:
        raise PackerError(
            f"descriptor + LZX XBE needs 0x{len(blob):X} bytes, "
            f"but the PrometheOS 1.6 Xenium bank is only 0x{XBE_BANK_SIZE:X}."
        )

    # PrometheOS' CompressBank() returns a zero-initialized logical bank.  The
    # surrounding 2 MiB template remains untouched; only these two bank slices
    # are replaced.
    bank = bytearray(XBE_BANK_SIZE)
    bank[: len(blob)] = blob

    image = bytearray(template)
    boot_before = bytes(image[BOOTLOADER_OFF : BOOTLOADER_OFF + BOOTLOADER_SIZE])
    _scatter_bank(image, bytes(bank))
    boot_after = bytes(image[BOOTLOADER_OFF : BOOTLOADER_OFF + BOOTLOADER_SIZE])
    if boot_before != boot_after:
        raise PackerError("Internal error: bootloader region was modified.")

    # Verify the actual framed stream through the independent Windows decoder,
    # not merely the CAB makecab originally emitted.
    roundtrip = _expand_lzx(stream)
    if roundtrip != xbe:
        raise PackerError("LZX round-trip mismatch after CAB-to-PrometheOS reframing.")

    Path(out_path).write_bytes(image)
    usage = 100.0 * len(blob) / XBE_BANK_SIZE
    print(
        f"packed -> {out_path}  "
        f"(XBE {len(xbe)} B -> LZX {len(stream)} B, {usage:.1f}% of 608 KiB bank)"
    )
    print(f"md5: {hashlib.md5(xbe).hexdigest()}")
    print("bootloader: preserved byte-for-byte")
    print("self-verify: payload round-trips byte-identical  OK")


def unpack(image_path: str, out_path: str) -> None:
    image = Path(image_path).read_bytes()
    dec_size, comp_size, stream = _payload_from_image(image)
    raw = _expand_lzx(stream)
    if len(raw) != dec_size:
        raise PackerError(
            f"Decoded XBE size is 0x{len(raw):X}; descriptor says 0x{dec_size:X}."
        )
    Path(out_path).write_bytes(raw)
    print(
        f"unpacked -> {out_path}  "
        f"({len(raw)} bytes, compressed={comp_size}, magic={raw[:4]!r})"
    )


def verify(image_path: str) -> None:
    image = Path(image_path).read_bytes()
    dec_size, comp_size, stream = _payload_from_image(image)
    blocks = _parse_lzx_stream(stream, dec_size)
    raw = _expand_lzx(stream)
    if len(raw) != dec_size:
        raise PackerError(
            f"Decoded XBE size is 0x{len(raw):X}; descriptor says 0x{dec_size:X}."
        )

    primary_used = min(8 + comp_size, XBE_PRIMARY_SIZE)
    continuation_used = max(0, (8 + comp_size) - XBE_PRIMARY_SIZE)

    print(f"image: 0x{len(image):X} bytes")
    print(f"descriptor decsz=0x{dec_size:X} compsz=0x{comp_size:X}")
    print(f"LZX blocks: {len(blocks)}  window={1 << LZX_WINDOW_BITS} bytes")
    print(
        f"bank use: primary 0x{primary_used:X}/0x{XBE_PRIMARY_SIZE:X}, "
        f"continuation 0x{continuation_used:X}/0x{XBE_CONT_SIZE:X}"
    )
    print(
        f"XBE: {len(raw)} bytes, magic={raw[:4]!r}, "
        f"md5={hashlib.md5(raw).hexdigest()}"
    )
    print("verify: LZX stream decoded successfully")


def main(argv: List[str]) -> int:
    if len(argv) < 2:
        print(__doc__.strip())
        return 2

    cmd = argv[1].lower()
    try:
        if cmd == "pack" and len(argv) == 5:
            pack(argv[2], argv[3], argv[4])
        elif cmd == "unpack" and len(argv) == 4:
            unpack(argv[2], argv[3])
        elif cmd == "verify" and len(argv) == 3:
            verify(argv[2])
        else:
            print(__doc__.strip())
            return 2
    except (OSError, PackerError, struct.error) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
