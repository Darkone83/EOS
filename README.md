# Eos — Firmware (FPGA Gateware)

<div align=center>

<img src="https://github.com/Darkone83/EOS/blob/main/images/EOS.png" width=400><img src="https://github.com/Darkone83/EOS/blob/main/images/Darkone83.png" width=500>

</div>

Clean-room Original Xbox LPC BIOS-loader modchip, built as FPGA gateware for the
**Sipeed Tang Nano 20K** (Gowin **GW2AR-18C**, QFN88). Eos sits on the Xbox LPC bus,
serves a selectable BIOS bank from on-board memory, supports **both pre-1.6 and 1.6**
consoles, exposes a Darkone SMBus control device, and renders a live diagnostic
dashboard over HDMI.

> Team Resurgent · Darkone83 · **Private — do not distribute**

---

## Quick start (the short version)

1. **Flash the board once** (chip prep) — bitstream + BIOS image, over the Nano's USB.
   The easiest way is the **Eos Recovery** app (point-and-click); the CLI equivalents
   are below.
2. **Wire it to the Xbox LPC header** — six series resistors, power, and either a D0
   ground (1.0–1.5) or an LFRAME# tap + LPC rebuild (1.6).
3. **Set the revision switch** — open for 1.0–1.5, closed-to-ground for 1.6.
4. **Power on.** The status LEDs and RGB tell you exactly how far the boot got; the HDMI
   HUD shows live serve state if you have a screen attached.

After chip prep, BIOS banks update **in-system** from a running unit — no programmer needed.

---

## What it does

- **LPC BIOS server** — answers MCPX memory-read cycles and streams the active BIOS image
  back from SDRAM.
- **Dual-revision support** — boots **1.0–1.5** (D0) and **1.6** (LFRAME# transaction
  abort), selected by a hardware strap. See **Revision support** below.
- **Xenium-style bank select** — bank register at I/O `0xEF` (low nibble = bank), following
  the banking convention Xenium-family tooling expects. This is a clean-room implementation
  of that convention — it is **not** OpenXenium.
- **Flash command bridge** — I/O path (`0xEC`/`0xED`) for erase / write / read / sync of
  the backing flash, driven by the Xbox-side loader.
- **Darkone SMBus device** — a slave at **7-bit `0x6E`** on the Xbox SMBus reporting
  firmware version and status, and providing the control plane for in-system BIOS updates.
  Shows up in XbDiag's SMBus scan as `EOS MODCHIP`.
- **HDMI serve HUD** — a colour dashboard: boot/link, bank, serve rate, flash-engine op,
  SDRAM preload, an address-space serve map, a serve log, the I2C engine panel, and a
  stability panel.
- **Status LEDs / WS2812** — at-a-glance boot/serve state without a screen.

---

## Hardware

| | |
|---|---|
| Board | Sipeed Tang Nano 20K |
| FPGA | Gowin GW2AR-18C, QFN88, C8/I7 |
| On-chip | 64 Mbit SDRAM (SIP), BIOS staging buffer |
| External | On-board SPI flash (bitstream + BIOS bank storage) |
| Video | HDMI (TMDS) for the diagnostic HUD |

### LPC wiring

Connect to the Xbox LPC header: `LAD0–3`, `LCLK`, `LRESET#`, `LFRAME#`, plus `3.3V` and `GND`.

Put a **22 kΩ series resistor in-line on each of the six Xbox-driven inputs** — `LAD0–3`,
`LCLK`, and `LRESET#` — between the Xbox header and the Nano pin.

> Only feed the board LPC **3.3V**. Do not back-power the LPC 5V rail from USB.

### Bill of materials

| Qty | Part | Purpose |
|---|---|---|
| 1 | Sipeed Tang Nano 20K (GW2AR-18C) | the modchip |
| 6 | 22 kΩ resistor | series on LAD0–3, LCLK, LRESET# |
| 1 | SPST switch (or jumper) | revision select (open = 1.0–1.5, GND = 1.6) |
| — | wire to D0 point | 1.0–1.5 install |
| — | wire to LFRAME# + LPC rebuild | 1.6 install |

---

## Revision support

Eos auto-detects nothing electrically — you tell it which console it's on with a
**revision strap** on `mode16_n` (pin 77, internal pull-up):

| Switch | `mode16_n` | Mode | Boot mechanism |
|---|---|---|---|
| **Open** | high | 1.0 – 1.5 | D0 (disables onboard TSOP) |
| **Closed → GND** | low | 1.6 | LFRAME# transaction abort |

The HUD prints the detected revision (`1.5` / `1.6`), so you can confirm the strap is read
correctly before trusting a boot.

### 1.0 – 1.5

Ground **D0** to disable the onboard TSOP and force LPC boot. On the current test rig D0 is
grounded externally; the gateware also contains a driven-D0 path (grounds while active,
releases only for a TSOP/stock boot), for boards that wire D0 to the FPGA.

### 1.6

1.6 needs **two** things:

- **A physical LPC rebuild** — lift the Xyclops flash off the bus, OpenXenium-style. This is
  hardware; the gateware can't substitute for it.
- **`LFRAME#` connected to the FPGA.** With the strap set to 1.6, the gateware holds
  `LFRAME#` low for the duration of each served memory-read cycle — a transaction abort that
  keeps the Xyclops off the bus so Eos serves instead. This is the transaction-abort technique proven by ModXo and OpenXenium (see **Credits**).

`LFRAME#` on 1.6 is a **driven** line (not a plain input), so its pad needs real drive
strength — see the pin notes.

---

## Pinmap

FPGA pin assignments (from `eos_hdmi.cst`). "Series 22k" marks the Xbox-driven LPC inputs
that take an in-line resistor.

### Xbox LPC interface

| Signal | FPGA pin | Series 22k | Pad notes |
|---|---|:---:|---|
| `LAD0` | 25 | ✔ | pull-up, hysteresis, **DRIVE=12** (drives serve data) |
| `LAD1` | 26 | ✔ | pull-up, hysteresis, DRIVE=12 |
| `LAD2` | 27 | ✔ | pull-up, hysteresis, DRIVE=12 |
| `LAD3` | 28 | ✔ | pull-up, hysteresis, DRIVE=12 |
| `LCLK` | 73 | ✔ | no pull, hysteresis (input) |
| `LRESET#` | 86 | ✔ | pull-up (input) |
| `LFRAME#` | 74 | — | **driven** for 1.6 abort — `PULL_MODE=NONE DRIVE=12` |
| `mode16_n` | 77 | — | revision strap — `PULL_MODE=UP` (open=pre-1.6, GND=1.6) |
| `D0` | (board-specific) | — | external ground (1.0–1.5); optional FPGA-driven path |

> **Why LFRAME# / LAD need `DRIVE=12`:** at the default ~8 mA an FPGA pad can't move the LPC
> bus hard enough for the MCPX to see it — the logic fires but the line barely shifts, and
> 1.6 silently fails to boot. 12 mA (matching ModXo) is the working value; the internal
> pull-up on `LFRAME#` must be **off** (`PULL_MODE=NONE`) so it doesn't fight the low.

### SMBus (Darkone control device)

| Signal | FPGA pin | Notes |
|---|---|---|
| `i2c_sda` | 71 | open-drain, no pull (mobo has bus pull-ups) |
| `i2c_scl` | 72 | input, no pull |

7-bit address **`0x6E`** (8-bit `0xDC`/`0xDD`). Register map: `0x00` magic (`0xD8`),
`0x01/02/03` version major/minor/patch, `0x04` status, `0x10` command, `0x11–0x14` args.

### HDMI (diagnostic HUD)

| Signal | FPGA pins (P,N) |
|---|---|
| `TMDS_CLK` | 33, 34 |
| `TMDS_D0` | 35, 36 |
| `TMDS_D1` | 37, 38 |
| `TMDS_D2` | 39, 40 |

### SPI BIOS flash

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

> **Config-pin caution:** the QFN88 exposes only ~66 user I/O; many package pins are
> power/ground/config (READY, DONE, RECONFIG_N, MODE[2:0], MSPI, JTAG). Assigning a user
> signal to one of those stops the FPGA configuring. Confirm every LPC/strap pin is a real
> GPIO — pin 75 in particular is a config pin, so don't use it for D0.
>
> The on-package SDRAM uses Gowin "magic" net names (`O_sdram_*`, `IO_sdram_dq`) and is
> **not** in the `.cst` — leave it out.

---

## Status indicators

### Onboard LEDs (`led[5:0]`, pins 20→15)

Six active-low LEDs latch **boot-progress milestones** — each is sticky, so a dark one points
straight at where a boot stalls:

| LED | Pin | Lights (and stays on) when |
|---|---|---|
| `led[5]` | 20 | BIOS preload complete — image resident in SDRAM |
| `led[4]` | 19 | LPC reset released — Xbox powered, `LRESET#` high seen |
| `led[3]` | 18 | LPC clock detected — first `LCLK` edge seen |
| `led[2]` | 17 | LPC START seen — `LAD = 0000` framing observed |
| `led[1]` | 16 | FPGA drove the `LAD` bus — responded to a cycle |
| `led[0]` | 15 | first BIOS byte served |

All six lit = full path up. A gap shows the stall point (e.g. `led[3]` dark = no `LCLK`;
`led[2]` lit but `led[1]` dark = START seen but never answered).

### WS2812 RGB (pin 79)

The single RGB shows live boot/serve state; the highest-priority condition wins:

| Colour | Meaning |
|---|---|
| 🔴 Red, pulsing | LPC reset not released — Xbox off or held in reset |
| 🟡 Yellow, pulsing | reset high but **no LPC clock** — powering, no `LCLK` yet |
| 🟠 Amber, solid | BIOS **preloading** flash → SDRAM |
| 🔴 Red, solid | flash **erase** in progress |
| 🟣 Purple, solid | flash **write** in progress |
| 🔵 Cyan, solid | flash **read / verify** in progress |
| 🟣 Purple, pulsing | flash **sync / reload** in progress |
| 🟢 Green, pulsing | serving a launched **user bank** |
| 🟢 Green, blinking | **active** LPC byte serve |
| 🔵 Cyan, heartbeat | sustained healthy reads |
| 🔵 Blue, heartbeat | ready & clocked, no START yet — or good idle |
| 🔵 Dim blue | resident and waiting (idle) |

Quick read: **red/yellow** = no Xbox or no clock · **amber** = preloading · **red/purple/cyan**
= a flash op · **green** = serving · **blue** = up and idle. The write/sync purple is the
project accent (RGB 168, 85, 247).

---

## Flashing the board (chip prep)

Bitstream and BIOS both live in the Nano's on-board SPI flash. Do this **once** per board;
after that, BIOS banks update in-system.

### Easiest: Eos Recovery app

The **Eos Recovery** GUI wraps the two commands below — pick the bitstream, pick the BIOS
image, hit each Program button. It also detects the board and doubles as the end-user
un-brick tool (JTAG-over-USB always works even with a dead bitstream). Recommended for
anyone who isn't living in a terminal.

### CLI: openFPGALoader

Both writes go over the Nano's on-board USB (BL616) — no external SPI programmer.

**1 · FPGA bitstream**

```bash
# Quick test — load to SRAM (volatile, gone on power cycle)
openFPGALoader -b tangnano20k eos.fs

# Persistent — write to flash (survives power cycle, autoboots)
openFPGALoader -b tangnano20k -f eos.fs
```

**2 · Initial BIOS image**

The packed `eos.bin` (the full 2 MB BIOS, produced by the loader's `eos_pack.py`) is written
to the SPI flash at the gateware's serve base:

```bash
openFPGALoader -b tangnano20k --external-flash -o 0x200000 eos.bin
```

> ⚠️ **CONFIRM THE OFFSET.** The gateware serves from `FLASH_OFF = 0x200000`
> (`eos_sdram_backend.v`), so the BIOS must be written there. Some of the working tooling
> shows `-o 0x20000` (one fewer zero) — that would land the BIOS *inside* the ~570 KB
> bitstream and is almost certainly a typo. Verify `0x200000` against your board before
> publishing, and make the Recovery app default match.

The image's internal layout maps to banks (physical flash = `0x200000` + offset-in-image):

| Offset in image | Contents | Bank (`0xEF`) |
|---|---|---|
| `0x000000` | user bank region | `0x3` (256K) · `0x7` (512K) · `0x9` (1MB) |
| `0x040000` | user 256K bank | `0x4` |
| `0x080000` | user 256K / 512K bank | `0x5` · `0x8` |
| `0x0C0000` | user 256K bank | `0x6` |
| `0x100000` | XeniumOS / loader XBE | `0x2` |
| `0x180000` | kernel — cold-boot default | `0x1` (BOOT) |
| `0x1C0000` | recovery | `0xA` |

The board cold-boots bank `0x1` (kernel @ image `0x180000`); the kernel selects `0xEF=0x2`
to launch the loader XBE at image `0x100000`.

**Recovery:** JTAG/SRAM configuration always works regardless of what's in flash, so a bad
bitstream is never bricking — reload SRAM to confirm a fix, then rewrite flash.

### 3 · BIOS updates (in-system)

With a bootable image present, banks are rewritten from a running unit — push a new image
over the loader's HTTP/OTA or FTP path, stage and validate it, commit to a bank via the flash
engine (`0xEC`/`0xED`), select the bank, and warm-reset so the FPGA serves it. No programmer.

---

## Building

Synthesis is done in **Gowin EDA**. Target device must be **GW2AR-18C QN88 C8/I7** across
project, constraints, and programmer — a mismatch is the usual "won't configure" cause.

1. Open the project in Gowin EDA and add all `src/*.v` sources.
2. Ensure the memory-init hex files are present in `src/` next to the RTL — they're read at
   synthesis via `$readmemh`, and a missing one silently zero-fills (e.g. a blank HUD):
   `eos_font.hex`, `eos_attr.hex`, `eos_logo.hex`, `eos_screen.hex`.
3. Apply `eos_hdmi.cst`.
4. Synthesize → Place & Route → generate the bitstream (`.fs`).

---

## Source layout

```
Eos.gprj / Eos.gprj.user      Gowin EDA project

src/
  eos_hdmi_top.v        top level: clocks, LPC, SDRAM, HUD, D0/LFRAME, I2C, video
  eos_lpc_loader.v      LPC cycle decode + serve; drives the 1.6 LFRAME abort window
  eos_boot_ctrl.v       1.6 LFRAME# abort (mode16_n-gated)
  eos_bank_ctrl.v       0xEF bank register + address mapping + commit engine
  eos_flash_cmd.v       flash command bridge (0xEC/0xED) + scratch-stage path
  eos_flash_reader.v    flash read path
  eos_sdram_backend.v   SDRAM serve path + preload + scratch (update staging)
  eos_sdram_pll.v       SDRAM PLL wrapper
  sdram.v               SDRAM controller
  eos_stream_cache.v    serve stream cache
  eos_crc32.v           streaming CRC-32 over scratch (update validate)
  eos_i2c.v             Darkone SMBus slave (0x6E) + update command engine
  eos_serve_hud.v       serve dashboard (generated)
  eos_text_rendre.v     colour text renderer + logo overlay
  eos_char_buffer.v     char cell buffer
  eos_attr_buffer.v     colour-attr cell buffer
  eos_font_rom.v        8x16 font ROM  (reads eos_font.hex)
  eos_logo_rom.v        EOS logo ROM   (reads eos_logo.hex)
  eos_video_timing.v    HDMI video timing
  eos_ws2812.v          WS2812 status LED
  *.hex                 memory inits (font / attr / logo / screen)
  eos_hdmi.cst          pin + IO constraints
  eos_hdmi.sdc          timing constraints

  dvi_tx/               Gowin DVI/HDMI-TX IP    (generated)
  gowin_rpll/           Gowin rPLL IP           (generated)
  sdram_pll/            Gowin SDRAM PLL IP      (generated)
```

> The serve HUD is **generated** — regenerate it with the HUD generator rather than
> hand-editing the cell case in `eos_serve_hud.v`. The updater datapath (scratch staging →
> CRC validate → commit) spans `eos_sdram_backend`, `eos_bank_ctrl`, `eos_crc32`, and
> `eos_i2c`, driven by the SMBus command plane — built, but not yet exercised on hardware.

---

## HUD notes

Generator-driven. To change panels/layout, regenerate with the HUD generator rather than
hand-editing the cell case in `eos_serve_hud.v`. Colour attrs: 0 normal · 1 header (white-on-purple) ·
2 purple accent · 3 green · 4 amber · 5 red · 7 dim. The I2C engine panel (address, version,
last command, RX count, select) replaced the old SMBus-telemetry panel.

---

## Credits

Eos firmware © Team Resurgent / Darkone83.

The **`0xEF` banking convention** is Xenium-style and long-established in the OG Xbox
community; Eos's bank system is a clean-room implementation of that convention and is **not**
derived from OpenXenium.

The **1.6 LFRAME# transaction-abort + LPC-rebuild approach** follows two community references,
credited with thanks:

- **ModXo** — by **Team Resurgent** — <https://github.com/Team-Resurgent/Modxo>
- **OpenXenium** — by **Ryzee119** — <https://github.com/Ryzee119/OpenXenium>

Eos's LFRAME behaviour was matched against these known-good designs; no code from either is
included.
