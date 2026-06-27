# Eos — Firmware (FPGA Gateware)

Clean-room Original Xbox LPC BIOS-loader modchip, implemented as FPGA gateware for the
**Sipeed Tang Nano 20K** (Gowin **GW2AR-18C**, QFN88). Eos presents itself on the Xbox LPC
bus as a BIOS source, serving a selectable bank from on-board memory, and renders a live
diagnostic dashboard over HDMI.

> Team Resurgent · Darkone83 · **Private — do not distribute**

---

## What it does

- **LPC BIOS server** — answers MCPX memory-read cycles on the LPC bus and streams the
  active BIOS image back, sourced from SDRAM.
- **OpenXenium-compatible bank select** — bank register at I/O `0xEF` (low nibble = bank),
  so existing tooling that targets Xenium-style banking works unchanged.
- **Flash command bridge** — I/O command path (`0xEC`/`0xED`) for erase / write / read /
  sync of the backing QSPI flash, driven by the Xbox-side loader.
- **HDMI serve HUD** — a 160×45 colour dashboard showing live serve state: boot/link,
  bank, serve rate, flash-engine op, SDRAM preload, an address-space serve map, an 8-deep
  serve log, and a stability panel.
- **Status LEDs / WS2812** — boot-status indication.

---

## Hardware

| | |
|---|---|
| Board | Sipeed Tang Nano 20K |
| FPGA | Gowin GW2AR-18C, QFN88, C8/I7 |
| On-chip | 64 Mbit SDRAM (SIP), used as the BIOS staging buffer |
| External | QSPI flash (BIOS bank storage) |
| Video | HDMI (TMDS) for the diagnostic HUD |

### LPC wiring

Connect to the Xbox LPC header: `LAD0–3`, `LCLK`, `LRESET#`, `LFRAME#`, plus `3.3V` and `GND`.

Put a **22 kΩ series resistor in-line on each of the six Xbox-driven inputs** — `LAD0`,
`LAD1`, `LAD2`, `LAD3`, `LCLK`, and `LRESET#` — between the Xbox LPC header and the Tang
Nano 20K pin. (`LFRAME#` is not seriesed; it carries an internal pull-up in the `.cst`.)

- **1.0 – 1.5:** ground **D0** (forces LPC boot / disables the onboard TSOP). External
  ground is the supported test-rig install; the FPGA does not drive D0.
- **1.6:** requires **LFRAME#** connected **and a physical LPC rebuild** (lift the Xyclops
  flash from the bus, Open-Xenium-style). 1.6 is not a gateware-only install.

> Only feed the board LPC **3.3V**. Do not back-power the LPC 5V rail from USB.

### Bill of materials

| Qty | Part | Purpose |
|---|---|---|
| 1 | Sipeed Tang Nano 20K (GW2AR-18C) | the modchip |
| 6 | 22 kΩ resistor | series on LAD0–3, LCLK, LRESET# |
| — | wire to D0 point | ground for 1.0–1.5 (or LFRAME# + LPC rebuild for 1.6) |

---

## Pinmap

FPGA pin assignments (from `eos_hdmi.cst`). "Series 22k" marks the Xbox-driven LPC inputs
that take an in-line resistor.

### Xbox LPC interface

| Signal | FPGA pin | Series 22k | Pull / notes |
|---|---|:---:|---|
| `LAD0` | 25 | ✔ | pull-up, hysteresis |
| `LAD1` | 26 | ✔ | pull-up, hysteresis |
| `LAD2` | 27 | ✔ | pull-up, hysteresis |
| `LAD3` | 28 | ✔ | pull-up, hysteresis |
| `LCLK` | 73 | ✔ | no pull, hysteresis |
| `LRESET#` | 86 | ✔ | pull-up |
| `LFRAME#` | 74 | — | pull-up, hysteresis (input; 1.6 install) |
| `D0` | — | — | external ground (1.0–1.5); not wired to FPGA |

### HDMI (diagnostic HUD)

| Signal | FPGA pins (P,N) |
|---|---|
| `TMDS_CLK` | 33, 34 |
| `TMDS_D0` | 35, 36 |
| `TMDS_D1` | 37, 38 |
| `TMDS_D2` | 39, 40 |

### QSPI BIOS flash

| Signal | FPGA pin |
|---|---|
| `flash_clk` | 59 |
| `flash_cs_n` | 60 |
| `flash_mosi` | 61 |
| `flash_miso` | 62 |

### Clock / reset / status

| Signal | FPGA pin | Notes |
|---|---|---|
| `sys_clk` | 4 | 27 MHz onboard crystal |
| `rst_btn` | 88 | onboard button |
| `ws2812` | 79 | status LED |
| `led[0..5]` | 15, 16, 17, 18, 19, 20 | status LEDs |

> The on-package SDRAM uses Gowin "magic" net names (`O_sdram_*`, `IO_sdram_dq`) and is
> **not** in the `.cst` — leave it out.

---

## Status indicators

### Onboard LEDs (`led[5:0]`, pins 20→15)

Six active-low onboard LEDs latch **boot-progress milestones** — each is sticky, so once its
event is seen the LED stays on. A healthy boot lights them up as the Xbox comes alive, and a
dark one points straight at where things stall:

| LED | Pin | Lights (and stays on) when |
|---|---|---|
| `led[5]` | 20 | BIOS preload complete — image resident in SDRAM |
| `led[4]` | 19 | LPC reset released — Xbox powered, `LRESET#` high seen |
| `led[3]` | 18 | LPC clock detected — first `LCLK` edge seen |
| `led[2]` | 17 | LPC START seen — `LAD = 0000` framing observed |
| `led[1]` | 16 | FPGA drove the `LAD` bus — responded to a cycle |
| `led[0]` | 15 | first BIOS byte served |

All six lit = full path up: resident → clocked → framed → responding → serving. A gap shows
the stall point (e.g. `led[3]` dark = no `LCLK`; `led[2]` lit but `led[1]` dark = START seen
but never answered).

### WS2812 RGB (pin 79)

The single addressable RGB shows live **boot/serve state**; the highest-priority condition
wins, so it always reflects the most significant thing happening:

| Colour | Meaning |
|---|---|
| 🔴 Red, pulsing | LPC reset not released / not seen — Xbox off or held in reset |
| 🟡 Yellow, pulsing | reset high but **no LPC clock** — powering, no `LCLK` yet |
| 🟠 Amber, solid | BIOS **preloading** flash → SDRAM |
| 🔴 Red, solid | flash **erase** (DELETE) in progress |
| 🟣 Purple, solid | flash **write** (PROGRAM) in progress |
| 🔵 Cyan, solid | flash **read** (VERIFY) in progress |
| 🟣 Purple, pulsing | flash **sync** (RELOAD) in progress |
| 🟢 Green, pulsing | serving a launched **user bank** (not the boot/loader bank) |
| 🟢 Green, blinking | **active** LPC byte serve |
| 🔵 Cyan, heartbeat | sustained healthy reads — ongoing boot activity |
| 🔵 Blue, heartbeat | ready & clocked, no START yet — or known-good idle after activity |
| 🔵 Dim blue | resident and waiting (idle) |

Quick read: **red / yellow** = no Xbox or no clock · **amber** = preloading · **red / purple
/ cyan** = a flash op · **green** = serving · **blue** = up and idle. The write/sync purple is
the project accent (RGB 168, 85, 247).

---

## Building

Synthesis is done in **Gowin EDA** (IDE or command-line). Target device must be set to
**GW2AR-18C QN88 C8/I7** across the project, constraints, and programmer — a mismatch here
is the usual cause of "won't configure."

1. Open the project in Gowin EDA and add all `src/*.v` sources.
2. Ensure the memory-init hex files are present in `src/` next to the RTL — they are read
   at synthesis time via `$readmemh` and a missing one silently zero-fills (e.g. a blank
   HUD): `eos_font.hex`, `eos_attr.hex`, `eos_logo.hex`, `eos_screen.hex`.
3. Apply the constraints file `eos_hdmi.cst`.
4. Run Synthesize → Place & Route → generate the bitstream (`.fs`).

> The on-package SDRAM uses Gowin "magic" net names (`O_sdram_*`, `IO_sdram_dq`) and must be
> left **out** of the `.cst`.

---

## Flashing (chip prep)

Both the bitstream and the BIOS live in the board's **onboard flash**, in two regions:

1. **FPGA bitstream** → offset `0x0` (autoboots the gateware), and
2. **initial BIOS image** → offset `0x200000` (directly above the bitstream; the gateware
   serves banks from here).

Both are written with **openFPGALoader** over the on-board USB — no external SPI programmer.
Do both once during chip prep; after that, BIOS banks update in-system (step 3).

### 1 · FPGA bitstream

The Tang Nano 20K configures from its config flash on power-up (MSPI autoboot). Use either
the Gowin Programmer or `openFPGALoader` over the on-board USB (BL616).

**openFPGALoader**

```bash
# Quick test — load to SRAM (volatile, gone on power cycle)
openFPGALoader -b tangnano20k eos.fs

# Persistent — write to config flash (survives power cycle, autoboots)
openFPGALoader -b tangnano20k -f eos.fs
```

**Gowin Programmer**

- **SRAM Program** → volatile, fastest, for bring-up.
- **exFlash Erase,Program thru GAO-Bridge** → persistent install.
  - Flash Device: **Generic Flash**
  - Download speed: **2.5 MHz** (or lower)
  - **Skip Verify** unless you need it — it roughly doubles the time.

Recovery: JTAG/SRAM configuration always works regardless of what's in flash, so a bad
bitstream is never bricking — reprogram SRAM to confirm a fix, then rewrite flash.

> **Config-pin caution:** the QFN88 exposes only ~66 user I/O. Many package pins are
> power/ground/config (READY, DONE, RECONFIG_N, MODE[2:0], the MSPI flash pins, JTAG).
> Driving one of those low will stop the FPGA from configuring. Only assign user signals to
> confirmed GPIO pins.

### 2 · Initial BIOS image

The packed `eos.bin` (produced per the **loader README** with `eos_pack.py`) is the full
**2 MB BIOS**, written to onboard flash **offset `0x200000`** — directly above the bitstream,
with the same openFPGALoader/USB as step 1:

```bash
openFPGALoader -b tangnano20k -f -o 0x200000 eos.bin
```

The gateware serves banks from this `0x200000` base, so the image's internal layout maps to
banks as follows (physical flash = `0x200000` + offset-in-image):

| Offset in image | Contents | Bank (`0xEF`) |
|---|---|---|
| `0x000000` | user bank region | `0x3` (256K) · `0x7` (512K) · `0x9` (1MB) |
| `0x040000` | user 256K bank | `0x4` |
| `0x080000` | user 256K / 512K bank | `0x5` · `0x8` |
| `0x0C0000` | user 256K bank | `0x6` |
| `0x100000` | XeniumOS / loader XBE | `0x2` |
| `0x180000` | kernel — cold-boot default | `0x1` (BOOT) |
| `0x1C0000` | recovery | `0xA` |

`eos_pack.py` produces this layout directly, so it's a single write to `0x200000`. The board
cold-boots bank `0x1` (kernel @ image `0x180000`); the kernel then selects `0xEF=0x2` to
launch the loader XBE at image `0x100000`.

### 3 · BIOS updates (in-system)

With a bootable image present, BIOS banks are rewritten from a running unit — push a new
image over the loader's HTTP/OTA path (or FTP), commit it to a bank via the flash engine
(`0xEC`/`0xED` command bridge), select the bank, and warm-reset so the FPGA serves it. No
external programmer needed.

---

## Source layout

```
src/
  eos_hdmi_top.v        top level: clocks, LPC, SDRAM, HUD, video
  eos_lpc_loader.v      LPC cycle decode + bank/IO bridge (runs on LCLK)
  eos_lpc_probe.v       LPC bus probe/diagnostics
  eos_bank_ctrl.v       0xEF bank register + address mapping
  eos_flash_cmd.v       QSPI flash command bridge (0xEC/0xED)
  eos_flash_reader.v    flash read path
  eos_sdram_backend.v   SDRAM serve path + preload
  eos_sdram_pll.v       SDRAM clocking
  sdram.v               SDRAM controller
  eos_stream_cache.v    serve stream cache
  eos_serve_hud.v       generated serve dashboard  (see tools/gen_hud.py)
  eos_text_rendre.v     colour text renderer + logo overlay
  eos_char_buffer.v     char cell buffer
  eos_attr_buffer.v     colour-attr cell buffer
  eos_font_rom.v        8x16 font ROM  (reads eos_font.hex)
  eos_logo_rom.v        EOS logo ROM   (reads eos_logo.hex)
  eos_ws2812.v          WS2812 status LED
  eos_serve_selftest.v  serve self-test
  testpattern.v         HDMI test pattern
  *.hex                 memory inits (font / attr / logo / screen)
  eos_hdmi.cst          pin + IO constraints

tools/
  gen_hud.py            regenerates eos_serve_hud.v (layout = edit here, not the .v)
```

> `eos_boot_ctrl.v` (D0 / LFRAME boot control) is in the tree but currently **not
> instantiated** — the test rig grounds D0 externally. `eos_serve_hud_new.v` is the
> generator's working output; `eos_serve_hud.v` is the active copy.

---

## HUD notes

The dashboard is generator-driven. To change panels/layout, edit `tools/gen_hud.py` and
regenerate — don't hand-edit the cell case in the `.v`. Colour attrs: 0 normal · 1
header (white-on-purple) · 2 purple accent · 3 green · 4 amber · 5 red · 7 dim.

---

## Credits

Eos firmware © Team Resurgent / Darkone83. OpenXenium banking model and the 1.6 LFRAME/LPC
rebuild approach are the community-established references this implementation is compatible
with.