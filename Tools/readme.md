# Eos — Tools

Host-side tooling for building, flashing, and maintaining an Eos modchip. Three tools:

| Tool | What it's for | Who uses it |
|---|---|---|
| **`Recovery/`** | Reflash / un-brick a board over USB — bitstream and BIOS | **End users** |
| **`eos_pack.py`** | Build the flashable BIOS image from your loader XBE | Chip prep / dev |
| **`gen_hud.py`** | Regenerate the HDMI serve-HUD gateware | Firmware dev |

> Team Resurgent · Darkone83 · **Private — do not distribute**

---

## Recovery/  — end-user reflash & un-brick

A point-and-click app that writes the Nano 20K's on-board flash over USB. This is the tool
you hand to an end user: it recovers a **bricked bitstream** or a **bad BIOS** without an
external programmer, because the Nano's USB-JTAG bridge still works even when the FPGA design
is dead.

```
Recovery/
  eos_recovery.py       the GUI
  openFPGALoader.exe     bundled programmer
  *.dll                  its runtime (libusb, libftdi1, libhidapi, zlib, MinGW)
```

**It's self-contained** — the programmer and every DLL it needs ship in this folder, so it
runs on a clean Windows machine with nothing installed but Python + PySide6 (or frozen, not
even that).

**Run it**

```bash
pip install pyside6
python eos_recovery.py
```

Or freeze to a no-Python distributable:

```bash
pyinstaller --onedir --windowed --add-data "openFPGALoader.exe;." --add-data "*.dll;." eos_recovery.py
```

**Using it**

Two independent sections, each with its own Program button — recover exactly what's broken:

- **Bitstream** → `openFPGALoader -b tangnano20k -f <eos.fs>`
- **BIOS** → `openFPGALoader -b tangnano20k --external-flash -o <offset> <eos.bin>`

The app detects the board, streams the programmer's output live, and shows a clear pass/fail.

> **⚠️ BIOS offset — verify before shipping.** The gateware serves from `FLASH_OFF = 0x200000`
> (`eos_sdram_backend.v`), so the BIOS must be written there. The app currently defaults to
> `0x20000` (one fewer zero) — confirm the correct value against your board and fix the
> default in `eos_recovery.py` before public release. A wrong offset lands the BIOS inside the
> bitstream or where the FPGA can't find it.

> **Windows driver:** first-time users may need to bind the Nano's JTAG interface to WinUSB
> with **Zadig** before the app can see the board. If detect says "plug in your board" with a
> board clearly connected, that's the cause.

---

## eos_pack.py  — BIOS image packer

Builds the flashable Eos BIOS image. It takes a **known-good template image** (borrowed
Cerbios kernel + all bank geometry) and swaps in **only your launcher XBE**, LZ4-compressed,
into the XeniumOS bank at `0x100000`. Everything else in the image stays byte-for-byte
identical, so the kernel's XBE-location expectations are always satisfied — the one variable
is your XBE.

The XBE region is `0x100000`–`0x180000` (**512 KB max** for the descriptor + compressed XBE);
the kernel sits at `0x180000`. The output is the full image you flash to the BIOS offset.

**Requirements:** `pip install lz4`

**Usage**

```bash
# Pack your loader XBE into a template -> flashable image
python eos_pack.py pack   <template.bin> <your_loader.xbe> <out.bin>

# Extract the embedded XBE back out
python eos_pack.py unpack <image.bin> <out.xbe>

# Round-trip check (packs, decompresses, compares)
python eos_pack.py verify <image.bin>
```

`pack` self-verifies the payload round-trips byte-identical, and errors out if your XBE
(compressed) exceeds the 512 KB bank.

---

## gen_hud.py  — serve-HUD generator

Regenerates the HDMI serve dashboard gateware (`eos_serve_hud.v`) — the panels, layout, and
colours are defined in **this script**, not the `.v`. To change the HUD, edit the cell
definitions here and regenerate; never hand-edit the generated cell case.

Panels: title, BOOT-LINK (rev / D0 / LFRAME aborts), SERVE (bank / rate / last), FLASH
ENGINE, SDRAM preload bar, address-space serve map, serve log, stability. Colour attrs:
`0` normal · `1` header (white-on-purple) · `2` purple accent · `3` green · `4` amber ·
`5` red · `7` dim.

**Requirements:** none (Python standard library)

**Usage**

```bash
python gen_hud.py
# writes eos_serve_hud_new.v, then copy it over the active file:
#   cp eos_serve_hud_new.v  <your firmware>/src/eos_serve_hud.v
```

> **⚠️ Output path:** the script's output path is currently hard-coded to a development
> location. Open `gen_hud.py`, find the final `open(...).write(TEMPLATE)` line, and point it
> at your own `src/` before running — otherwise it writes somewhere unexpected (or fails).

---

## Requirements summary

| | Needs |
|---|---|
| `Recovery/eos_recovery.py` | `pip install pyside6` (programmer + DLLs bundled) |
| `eos_pack.py` | `pip install lz4` |
| `gen_hud.py` | Python 3 standard library only |

---

## Credits

Eos tooling © Team Resurgent / Darkone83. `openFPGALoader` is the universal FPGA programming
utility by Gwenhael Goavec-Merou and contributors — <https://github.com/trabucayre/openFPGALoader>
— bundled here under its own licence for end-user convenience.