# Eos — Tools

Host-side tooling for building, flashing, and maintaining an Eos modchip. Four tools:

| Tool | What it's for | Who uses it |
|---|---|---|
| **`Recovery/`** | Reflash / un-brick a board over USB — bitstream, BIOS, loader, XbDiag | **End users** |
| **`eos_pack.py`** | Legacy PrometheOS 1.5 / LZ4 BIOS image packer | Chip prep / dev |
| **`eos_pack_v2.py`** | PrometheOS 1.6+ / LZX BIOS image packer | Chip prep / dev |
| **`gen_hud.py`** | Regenerate the HDMI serve-HUD gateware | Firmware dev |

---

## Recovery/  — end-user reflash & un-brick

A point-and-click app that writes the Nano 20K's on-board flash over USB. This is the one you
hand to an end user: it recovers a **bricked bitstream** or a **bad BIOS** without an external
programmer, because the Nano's USB-JTAG bridge still works even when the FPGA design is dead.

```
Recovery/
  eos_recovery.py       the GUI
  openFPGALoader.exe    bundled programmer
  *.dll                 its runtime (libusb, libftdi1, libhidapi, zlib, MinGW)
```

**It's self-contained.** The programmer and every DLL it needs ship in this folder, so it runs
on a clean Windows machine with nothing installed but Python and PySide6 — or nothing at all,
if you freeze it.

**Run it**

```bash
pip install pyside6
python eos_recovery.py
```

Or freeze to a no-Python distributable:

```bash
pyinstaller --onedir --windowed --add-data "openFPGALoader.exe;." --add-data "*.dll;." eos_recovery.py
```

### What the four buttons do

Each section is independent, so you recover exactly what's broken.

| Card | Source | Where it lands |
|---|---|---|
| **Bitstream** | a local `.fs` you pick | the FPGA config flash |
| **BIOS** | a local `.bin` you pick | the offset in the box (defaults to `0x200000`) |
| **Loader** | downloaded — `loader.bin` | `0x200000` (bank `0xE`) |
| **XbDiag Lite** | downloaded — `xbdlite.bin` | `0x400000` (bank `0xD`) |

The two download cards need no file at all — they pull the current image straight from the
Darkone server (`http://darkone83.myddns.me:8008/EOS/`), flash it, and clean up after
themselves. Use them when you've got nothing to hand, or when you just want the current build.
They need an internet connection; everything else works offline.

Under the hood the two local cards run:

- **Bitstream** → `openFPGALoader -b tangnano20k -f <eos.fs>`
- **BIOS** → `openFPGALoader -b tangnano20k --external-flash -o <offset> <eos.bin>`

The app detects the board, streams the programmer's output live, and shows a clear pass/fail
banner.

> **The Loader card overwrites your BIOS.** `loader.bin` is the full image and lands at
> `0x200000` — the same place the BIOS card writes — so any banks you've flashed go with it.
> The app asks you to confirm before it starts. XbDiag writes to `0x400000`, which is a
> reserved area, so it doesn't ask.

> **Offsets come from the gateware.** `0x200000` is `FLOOR` in `eos_bank_ctrl.v`, and
> `0x400000` is bank `0xD`'s base plus `FLOOR`. If you ever change the bank map in the
> firmware, change the offsets in `eos_recovery.py` to match.

> **Windows driver:** first-time users may need to bind the Nano's JTAG interface to WinUSB
> with **Zadig** before the app can see the board. If Detect says "plug in your board" while a
> board is clearly connected, that's the reason.

---

## eos_pack.py  — legacy PrometheOS 1.5 BIOS image packer

Builds the legacy PrometheOS 1.5-style flashable Eos BIOS image. It takes a
**known-good PrometheOS 1.5 Xenium template image** and swaps in **only your launcher XBE**,
LZ4-compressed, into the XeniumOS bank at `0x100000`. Everything else in the image stays
byte-for-byte identical, so the 1.5 boot stage always finds the XBE where it expects it.

Use this script only when maintaining an older 1.5/LZ4 image. New builds should use
`eos_pack_v2.py` below.

The XBE region runs `0x100000`–`0x180000`, so the descriptor plus the compressed XBE has to
fit in **512 KB**. The kernel sits at `0x180000`. The output is the full image you flash to the
BIOS offset.

**Requirements:** `pip install lz4`

**Usage**

```bash
# Pack your loader XBE into a template -> flashable image
python eos_pack.py pack   <template.bin> <your_loader.xbe> <out.bin>

# Extract the embedded XBE back out
python eos_pack.py unpack <image.bin> <out.xbe>

# Inspect an image: XBE size, magic, md5, and the descriptor
python eos_pack.py verify <image.bin>
```

`pack` is the one that checks itself. After writing the image it decompresses the payload back
out and compares md5 against your original XBE, so a bad compress can't slip through. It also
refuses to write if the compressed XBE won't fit the 512 KB bank, and warns (but continues) if
your file doesn't start with `XBEH`.

`verify` is an inspection command, not a test — it prints the payload's size, magic, and md5,
prints the descriptor, and re-compresses to show you how much of the bank you're using. It
doesn't compare anything, and it doesn't return a failure code. If you want a pass/fail, use
`unpack` and diff against your XBE.

> `pack` zero-fills the rest of the XBE bank before writing the payload. That's fine for a
> whole-image flash, since the programmer erases first.

---

## eos_pack_v2.py  — PrometheOS 1.6+ LZX BIOS image packer

`eos_pack_v2.py` is the current packer for PrometheOS **1.6 and newer** Xenium images.
PrometheOS 1.6 changed the embedded XBE compression from raw LZ4 to LZX, but kept the
Xenium flash geometry. The script therefore replaces only the logical PrometheOS XBE bank
and preserves the template's bootloader, recovery area, settings, and every unrelated flash
region.

Use a **PrometheOS 1.6+ Xenium image as the template**. The 1.6 bootloader is what knows how
to decode the LZX payload; packing an LZX XBE behind the older 1.5 bootloader is not a valid
combination.

### Xenium / PrometheOS 1.6 layout

The logical XBE bank is **608 KiB** and is split around the bootloader:

| Logical bank | Flash range | Size | Purpose |
|---|---:|---:|---|
| first part | `0x100000`–`0x17FFFF` | 512 KiB | descriptor + first part of LZX XBE |
| bootloader | `0x180000`–`0x1BFFFF` | 256 KiB | preserved from the template |
| recovery / other data | `0x1C0000`–`0x1DFFFF` | 128 KiB | preserved from the template |
| continuation | `0x1E0000`–`0x1F7FFF` | 96 KiB | remainder of the logical XBE bank |
| settings / spare | `0x1F8000`–`0x1FFFFF` | 32 KiB | preserved from the template |

The logical 608 KiB bank itself is:

```text
+0x000000  u32 decompressed_size
+0x000004  u32 compressed_size
+0x000008  repeated LZX records:
             u16 compressed_block_size
             u16 uncompressed_block_size
             compressed_block_data[]
+...       zero padding to 608 KiB
```

LZX is emitted in 32 KiB blocks with a 128 KiB window, matching the PrometheOS 1.6
`LZXToolkit/libLZX` format.

### Requirements

**Windows + Python 3 only.** No Python compression package, external DLL, NuGet package, or
.NET helper is required.

The script uses the Windows system tools:

- `makecab.exe` to produce the LZX stream when packing
- `expand.exe` to independently decode the generated stream for `unpack`, `verify`, and the
  pack-time round-trip test

Both are normally present in `C:\Windows\System32`.

### Usage

```bash
# Pack the EOS loader into a PrometheOS 1.6+ Xenium template
python eos_pack_v2.py pack <prometheos-1.6-template.bin> <default.xbe> <out.bin>

# Example used by the EOS build workflow
python eos_pack_v2.py pack prometheos-xenium.bin default.xbe new_eos.bin

# Extract the embedded XBE
python eos_pack_v2.py unpack <image.bin> <out.xbe>

# Decode and inspect an image
python eos_pack_v2.py verify <image.bin>
```

### What `pack` preserves

`pack` starts from the complete 2 MiB template and replaces only these two physical slices:

```text
0x100000-0x17FFFF
0x1E0000-0x1F7FFF
```

The bootloader at `0x180000-0x1BFFFF` is explicitly checked before and after packing and must
remain byte-for-byte identical. This lets EOS use the stock PrometheOS 1.6 boot stage while
launching the custom EOS XBE.

The script also:

- requires an exact 2 MiB Xenium template;
- warns if the input executable does not begin with `XBEH`;
- refuses a payload larger than the complete 608 KiB logical bank;
- converts the Windows CAB LZX output into PrometheOS' block framing;
- decodes that framed result independently with `expand.exe`;
- compares the decoded XBE byte-for-byte with the original before writing the final image;
- reports the XBE MD5 and logical-bank usage.

A successful pack ends with:

```text
bootloader: preserved byte-for-byte
self-verify: payload round-trips byte-identical  OK
```

### `verify`

`verify` reconstructs the logical XBE bank from both physical flash slices, validates the
descriptor and every LZX block, expands the XBE, and reports:

- 2 MiB image size;
- decompressed and compressed sizes;
- LZX block count and 128 KiB window;
- usage of the 512 KiB primary region and 96 KiB continuation region;
- XBE magic and MD5;
- successful LZX decode.

Unlike the old `eos_pack.py` inspection path, `eos_pack_v2.py verify` actually decodes the
LZX payload and returns an error when the image or stream is malformed.

---

## gen_hud.py  — serve-HUD generator

Regenerates the HDMI serve dashboard gateware (`eos_serve_hud.v`). The panels, layout, and
colours all live in **this script**, not in the `.v`. To change the HUD, edit the cell
definitions here and regenerate.

**Never hand-edit `eos_serve_hud.v`.** It happened once: an I2C panel was added straight to the
`.v` and never brought back here, which left the generator 62 cells and 9 module ports behind
the firmware. Running it then produced a module the top level couldn't build against.

Panels: title, BOOT-LINK (rev / D0 / LFRAME aborts), SERVE (bank / rate / last), FLASH ENGINE,
I2C ENGINE (address / version / last command / RX count / select), SDRAM preload bar,
address-space serve map, serve log, stability. Colour attrs: `0` normal · `1` header
(white-on-purple) · `2` purple accent · `3` green · `4` amber · `5` red · `7` dim.

**Requirements:** none (Python standard library)

**Usage**

```bash
# Write straight over the firmware's copy
python gen_hud.py ../Source/src/eos_serve_hud.v

# Or with no argument, drops eos_serve_hud.v in the current folder
python gen_hud.py
```

It prints the cell count when it's done (607 at the time of writing) and warns about any cell
written twice. Six overlaps at row 4 are expected — the D0 field paints blanks and then
overwrites them in the same scan pass. Anything else is a layout bug. A cell outside the
160×45 grid is a hard error.

---

## Requirements summary

| | Needs |
|---|---|
| `Recovery/eos_recovery.py` | `pip install pyside6` (programmer + DLLs bundled). Internet for the Loader / XbDiag cards. |
| `eos_pack.py` | Legacy only: `pip install lz4` |
| `eos_pack_v2.py` | Windows + Python 3; uses built-in `makecab.exe` and `expand.exe`; no pip packages |
| `gen_hud.py` | Python 3 standard library only |

---

## Credits

Eos tooling © Team Resurgent / Darkone83. `openFPGALoader` is the universal FPGA programming
utility by Gwenhael Goavec-Merou and contributors — <https://github.com/trabucayre/openFPGALoader>
— bundled here under its own licence for end-user convenience.
