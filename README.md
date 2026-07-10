# Eos — Firmware

<div align=center>

<img src="https://github.com/Darkone83/EOS/blob/main/images/EOS.png" width=400><img src="https://github.com/Darkone83/EOS/blob/main/images/Darkone83.png" width=500>

</div>

<a href="https://discord.gg/k2BQhSJ"><img src="https://github.com/Darkone83/ModXo-Basic/blob/main/Images/discord.svg"></a>

**A clean-room LPC BIOS-loader modchip for the original Xbox, built as FPGA gateware.**

Eos runs on the **Sipeed Tang Nano 20K** (Gowin GW2AR-18C). It sits on the Xbox LPC bus,
serves a BIOS bank you pick from on-board memory, and works on **both pre-1.6 and 1.6**
consoles. It reports in over the Xbox SMBus as a Darkone control device, and — if you have a
screen plugged in — draws a live diagnostic dashboard over HDMI so you can watch exactly what
it's doing.

---

## What's in the box

| Path | What it is |
|---|---|
| `Source/` | Gowin project + FPGA gateware (`src/*.v`, `.cst`, `.sdc`, generated IP) |
| `Firmware/` | Prebuilt bitstream (`Eos.fs`) |
| `Updater/` | **EOS Updater** — native Xbox in-system update app (`src/` + `xbe/EOS_Updater.xbe`) |
| `Tools/` | Host tooling: recovery GUI, BIOS packer, HUD generator — see `Tools/readme.md` |
| `Gerbers/` | PCB fab set (`EOS.zip`), `BOM.xlsx`, `PickAndPlace.xlsx` |
| `Schematics/` | Board schematic |
| `images/` | Logos and board renders |

---

## Quick start

1. **Flash the board once.** Bitstream plus a BIOS image, both over the Nano's USB. The
   easiest way is the **Eos Recovery** app — point, click, done. CLI commands are further down
   if you'd rather.
2. **Wire it to the Xbox LPC header.** Six series resistors, power, and either a D0 connection
   (1.0–1.4) or an LFRAME# tap plus an LPC rebuild (1.6).
3. **Set the revision switch.** Open for 1.0–1.4, closed to ground for 1.6.
4. **Power on.** The LEDs and RGB tell you how far the boot got; the HDMI dashboard shows live
   serve state if a screen is attached.

After that first flash, BIOS banks update **in-system** from a running console — no programmer
needed.

---

## What it does

- **Serves the BIOS over LPC** — answers the MCPX's memory-read cycles and streams the active
  BIOS image out of SDRAM.
- **Works on 1.0–1.4 and 1.6** — D0 on the older boards, LFRAME# transaction abort on 1.6,
  picked by a hardware switch. See **Console revisions** below.
- **Xenium-style bank select** — the bank register lives at I/O `0xEF` (low nibble = bank),
  the same convention Xenium-family tools expect. It's a clean-room implementation of that
  convention — it is **not** OpenXenium.
- **In-system flashing** — an I/O path (`0xEC`/`0xED`) lets the Xbox side erase, write, read,
  and verify the backing flash, so you never need a programmer after the first flash.
- **Only answers its own ports** — Eos claims exactly `0x00EC`–`0x00EF` and nothing else, so
  it stays out of the way of other devices on the LPC bus.
- **Fast preload** — the BIOS streams from flash into SDRAM in bursts. The boot image is
  resident in about a second, and Eos serves reads the whole time it's still filling.
- **Darkone SMBus device** — shows up in an XbDiag SMBus scan as an EOS modchip at 7-bit
  `0x6E`, reporting firmware version and status, and carrying the control channel the updater
  talks to.
- **HDMI dashboard** — a colour readout of link state, bank, serve rate, the flash engine,
  the preload bar, a live map of what's been served, a serve log, and a stability panel.
- **Status LEDs / WS2812** — tells you where a boot got to without needing a screen.

---

## Hardware

| | |
|---|---|
| Board | Sipeed Tang Nano 20K |
| FPGA | Gowin GW2AR-18C, QFN88, C8/I7 |
| Memory | 64 Mbit on-package SDRAM (BIOS lives here while serving) |
| Flash | On-board SPI flash (holds the bitstream and the BIOS banks) |
| Video | HDMI for the diagnostic dashboard |

### Wiring to the Xbox

Connect to the LPC header: `LAD0–3`, `LCLK`, `LRESET#`, `LFRAME#`, plus `3.3V` and `GND`.

Put a **22 kΩ resistor in-line on each of the six Xbox-driven inputs** — `LAD0–3`, `LCLK`, and
`LRESET#` — between the Xbox header and the Nano.

> Only feed the board LPC **3.3V**. Don't back-power the 5V rail from USB.

### Parts

| Qty | Part | Why |
|---|---|---|
| 1 | Sipeed Tang Nano 20K (GW2AR-18C) | the modchip |
| 6 | 22 kΩ resistor | in series on LAD0–3, LCLK, LRESET# |
| 1 | SPST switch or jumper | revision select (open = 1.0–1.4, GND = 1.6) |
| — | wire to the D0 point | 1.0–1.4 install (ground it, or drive it from `lpc_d0`) |
| — | wire to LFRAME# + LPC rebuild | 1.6 install |

---

## Console revisions

Eos doesn't sense the console for you — you tell it which one it's on with the **revision
switch** on `mode16_n`:

| Switch | Console | How it boots |
|---|---|---|
| **Open** | 1.0 – 1.4 | D0 (disables the onboard TSOP) |
| **Closed → GND** | 1.6 | LFRAME# transaction abort |

The dashboard prints the revision it read (`1.4` / `1.6`), so you can check the switch is set
right before you trust a boot.

### 1.0 – 1.4

D0 has to go low to disable the onboard TSOP and force an LPC boot. Two ways to do it, pick
whichever suits your board:

- **Ground D0.** Tie the D0 point to GND. Simplest, and how the current test rig is wired.
- **Drive D0 from the board.** Wire D0 to `lpc_d0` (pin 75) and let Eos handle it — it pulls
  D0 low while it's active and releases it for a stock TSOP boot, so the console can hand back
  to TSOP without you rewiring. Confirm pin 75 works as regular I/O on your board first (see
  the note in **Pinmap**); if you're not sure, just ground D0 and leave the pin off.

### 1.6

1.6 needs two things:

- **A physical LPC rebuild.** Lift the Xyclops flash off the bus, OpenXenium-style. That's
  hardware — the gateware can't do it for you.
- **LFRAME# wired to the FPGA.** With the switch set to 1.6, Eos holds LFRAME# low for each
  served memory cycle, aborting the transaction so the Xyclops stays off the bus and Eos
  answers instead. This is the transaction-abort trick from ModXo and OpenXenium (see
  **Credits**). LFRAME# is a **driven** line here, so its pad needs real drive strength — see
  the pin notes.

---

## Status lights

### Onboard LEDs (`led[5:0]`, pins 20→15)

Six LEDs that latch **boot milestones**. Each one is sticky, so a dark LED points straight at
where a boot stalled:

| LED | Lights (and stays lit) when |
|---|---|
| `led[5]` | BIOS preload done — image is resident in SDRAM |
| `led[4]` | LPC reset released — console powered, `LRESET#` seen high |
| `led[3]` | LPC clock seen — first `LCLK` edge |
| `led[2]` | LPC START seen — `LAD = 0000` framing |
| `led[1]` | Eos drove the bus — answered a cycle |
| `led[0]` | first BIOS byte served |

All six lit means the whole path is up. A gap shows the stall point — `led[3]` dark means no
`LCLK`; `led[2]` lit but `led[1]` dark means START was seen but never answered.

### WS2812 RGB (pin 79)

One RGB LED showing live state. The highest-priority thing wins, so the list is in priority
order — a flash operation always shows over idle colours:

| Colour | Meaning |
|---|---|
| 🔴 Red, solid | flash **erase** running |
| 🟣 Purple, solid | flash **write** running |
| 🔵 Cyan, solid | flash **read / verify** running |
| 🟣 Purple, pulsing | flash **sync / reload** running |
| 🌈 Rainbow | **updater is running** (it sets this on entry, clears it on exit) |
| 🔴 Red, pulsing | LPC reset not released — console off or held in reset |
| 🟡 Yellow, pulsing | reset is high but **no LPC clock** — powering up, no `LCLK` yet |
| 🟠 Amber, solid | BIOS **preloading** into SDRAM |
| 🟢 Green, pulsing | serving a launched **user bank** |
| 🟢 Green, blinking | **active** byte serve |
| 🔵 Cyan, heartbeat | steady healthy reads |
| 🔵 Blue, heartbeat | up and clocked, no START yet — or a good idle |
| 🔵 Dim blue | resident and waiting |

Rainbow deliberately sits *under* the flash colours, so if the updater kicks off a real erase
or write you still see it. Quick read: **red/purple/cyan** is a flash op · **rainbow** is the
updater · **red/yellow** is no console or no clock · **amber** is preloading · **green** is
serving · **blue** is up and idle. The write/sync purple is the project accent (RGB 168, 85,
247).

> The amber preload is quick now — about a second. If it hangs there for several seconds
> something's wrong with the flash read path.

---

## Pinmap

Taken straight from `eos_hdmi.cst`. That file is the source of truth — check against it before
you wire anything. "Series 22k" marks the Xbox-driven inputs that take an in-line resistor.

### Xbox LPC

| Signal | Port | Pin | 22k | Pad settings |
|---|---|---|:---:|---|
| `LAD0` | `lpc_lad[0]` | 25 | ✔ | pull-up, hysteresis (bidirectional) |
| `LAD1` | `lpc_lad[1]` | 26 | ✔ | pull-up, hysteresis |
| `LAD2` | `lpc_lad[2]` | 27 | ✔ | pull-up, hysteresis |
| `LAD3` | `lpc_lad[3]` | 28 | ✔ | pull-up, hysteresis |
| `LCLK` | `lpc_lclk` | 73 | ✔ | no pull, hysteresis (input) |
| `LRESET#` | `lpc_lreset_n` | 86 | ✔ | pull-up (input) |
| `LFRAME#` | `lpc_lframe_n` | 74 | — | **driven** for 1.6 — no pull, `DRIVE=12` |
| `D0` | `lpc_d0` | **75** | — | open-drain output |
| `mode16_n` | `mode16_n` | 77 | — | revision switch — pull-up, open = pre-1.6, GND = 1.6 |

> **Why LFRAME# needs the high drive:** at the default ~8 mA an FPGA pad can't move the LPC
> bus hard enough for the MCPX to catch the abort — the logic fires but the line barely moves
> and 1.6 quietly fails to boot. `DRIVE=12` (same as ModXo) is the value that works, and the
> internal pull-up on LFRAME# has to be off so it doesn't fight the driven low.

> **D0 is a real output on pin 75.** Eos pulls it low to force LPC boot and releases it for a
> stock boot. Pin 75 was historically flagged as a config pin, which is why the test rig just
> grounds D0 externally instead — confirm it's usable as regular I/O on your board before you
> rely on the driven path.

> The four `LAD` lines don't carry an explicit drive setting in the current `.cst` — only
> LFRAME# does. If 1.6 serve data ever looks marginal, bumping LAD drive is a thing to try,
> but it isn't what the shipping build does.

### SMBus

| Signal | Port | Pin | Pad settings |
|---|---|---|---|
| `i2c_sda` | `i2c_sda` | 71 | no pull, hysteresis (mobo has bus pull-ups) |
| `i2c_scl` | `i2c_scl` | 72 | no pull, hysteresis (input) |

7-bit address **`0x6E`** (8-bit `0xDC` write / `0xDD` read — "DC" for Darkone Customs). Register
map is under **SMBus interface** below.

### HDMI

| Signal | Pins (P, N) |
|---|---|
| `TMDS_CLK` | 33, 34 |
| `TMDS_D0` | 35, 36 |
| `TMDS_D1` | 37, 38 |
| `TMDS_D2` | 39, 40 |

### SPI flash

| Signal | Pin |
|---|---|
| `flash_clk` | 59 |
| `flash_cs_n` | 60 |
| `flash_mosi` | 61 |
| `flash_miso` | 62 |

### Clock / reset / status

| Signal | Port | Pin | Notes |
|---|---|---|---|
| `sys_clk` | `sys_clk` | 4 | 27 MHz onboard oscillator |
| `rst_btn` | `rst_btn` | 88 | onboard button (POR does the real reset) |
| `ws2812` | `ws2812` | 79 | status RGB |
| `led[0..5]` | `led[5:0]` | 15, 16, 17, 18, 19, 20 | status LEDs |

> **Config-pin caution.** The QFN88 only exposes about 66 usable I/O — a lot of the package
> pins are power, ground, or config (READY, DONE, RECONFIG_N, MODE, MSPI, JTAG). Put a user
> signal on one of those and the FPGA won't configure. The SPI flash pins (59–62) are the MSPI
> config pins, so you have to enable **Project → Configuration → Dual-Purpose Pin → "Use MSPI
> as regular IO"** or the design can't drive them. Pin 75 (`lpc_d0`) is in the same category —
> see the D0 note above.
>
> The on-package SDRAM uses Gowin's magic net names (`O_sdram_*`, `IO_sdram_dq`) and isn't in
> the `.cst` — leave it out.

---

## SMBus interface

Eos is a register-file slave at 7-bit `0x6E`. The master writes an index byte, then reads or
writes data. It shows up in an XbDiag SMBus scan as an EOS modchip.

### Registers you read

| Reg | Name | Value |
|---|---|---|
| `0x00` | MAGIC | `0xD8` (Darkone signature) |
| `0x01` | VER_MAJOR | `1` |
| `0x02` | VER_MINOR | `0` |
| `0x03` | VER_PATCH | `0` → firmware 1.0.0 |
| `0x04` | STATUS | live bits, see below |
| `0x05` | ENGINE | update-engine flags (armed / staged / CRC set / busy / err / commit-ok) |
| `0x06` | COMMIT | `{commit_bank, armed_region}` |
| `0x07`–`0x0A` | CRC32 | streaming CRC-32 result, low byte first |
| `0x0B`–`0x0C` | LOCK | lock-mask, low byte first |
| `0x10` | CMD | reads back the last command opcode |
| `0x11`–`0x14` | ARG0–3 | reads back the last command args |

**STATUS (`0x04`) bits**, low to high: `preload_done`, `mode_16`, `d0_active`,
`abort_active`, `slot1_ready`. Top three bits are zero.

### Commands you write (to `0x10`, args in `0x11`–`0x14`)

| Opcode | Command | Effect |
|---|---|---|
| `0x01` | PING | liveness, no change |
| `0x02` / `0x03` | ABORT / CLEAR | disarms and invalidates the staged image |
| `0x38` | LEDMODE | `arg0`: 0 = normal, 1 = rainbow |
| `0x39` | DESCRELOAD | re-read the descriptor block |
| `0xN0` / `0xN1` / `0xN4` | ARM / SETCRC / COMMIT | update flow for region N |

The updater drives ARM → SETCRC → COMMIT for the **loader** (region 1) and **XbDiag**
(region 2). A few other opcodes are decoded but don't do anything yet — see **Active Notes**.

---

## Performance

Flash → SDRAM streaming, 256-byte bursts:

| Region | Size | Time |
|---|---:|---:|
| Boot region | 1792 KB | ~0.9 s |
| XbDiag window (slot 1) | 768 KB | ~0.4 s |
| Oversized-bank region | 1024 KB | ~0.5 s |

Two things worth knowing about where that time goes:

- **The boot preload doesn't slow the boot down.** Eos fills the image top-down, and the
  console reads from the top first, so the part that matters is resident almost immediately.
  Everything after that is served out of SDRAM while the rest keeps filling underneath.
- **Launching XbDiag does wait for its window** to finish filling — nothing overlaps it — so
  that's where the faster preload is actually visible. It's roughly 4–5× quicker than before.

Reads are served the whole time any fill is running.

---

## Flashing the board

The bitstream and the BIOS both live in the Nano's SPI flash. You do this **once** per board;
after that, banks update in-system.

### Easiest: the Eos Recovery app

The **Eos Recovery** GUI wraps the two commands below — pick the bitstream, pick the BIOS
image, hit each Program button. It finds the board for you and doubles as the un-brick tool
(JTAG-over-USB always works, even with a dead bitstream). Use this unless you live in a
terminal.

### CLI: openFPGALoader

Both writes go over the Nano's onboard USB — no external programmer.

**Bitstream**

```bash
# Quick test — load to SRAM (gone on power cycle)
openFPGALoader -b tangnano20k eos.fs

# Persistent — write to flash (survives power cycle, autoboots)
openFPGALoader -b tangnano20k -f eos.fs
```

**BIOS image**

The packed `eos.bin` (the full 2 MB image, from the loader's `eos_pack.py`) gets written to the
flash at Eos's serve base:

```bash
openFPGALoader -b tangnano20k --external-flash -o 0x200000 eos.bin
```

The image maps to banks like this (physical flash address = `0x200000` + offset in image):

| Offset in image | Contents | Bank (`0xEF`) |
|---|---|---|
| `0x000000` | user bank region | `0x3` (256K) · `0x7` (512K) · `0x9` (1MB) |
| `0x040000` | user 256K bank | `0x4` |
| `0x080000` | user 256K / 512K bank | `0x5` · `0x8` |
| `0x0C0000` | user 256K bank | `0x6` |
| `0x100000` | XeniumOS / loader XBE | `0x2` |
| `0x180000` | kernel — cold-boot default | `0x1` (BOOT) |
| `0x1C0000` | recovery | `0xA` |

The board cold-boots bank `0x1` (kernel at image `0x180000`), and the kernel selects `0xEF=0x2`
to launch the loader XBE at image `0x100000`.

Above the 2 MB image, a few runtime regions live higher in flash: bank `0xE` is the
full-image loader-commit target, `0xD` is the XbDiag reserve, `0x0` is the oversized-bank
region, `0xB`/`0xC` are the config bank-table and settings, and `0xF` is the descriptor block.
Every physical target is `0x200000 + bank_base + offset`.

### Updating BIOS banks (in-system)

Once a bootable image is on the board, you rewrite banks from a running console — push a new
image over the loader's network/FTP path, stage and validate it, commit it to a bank through
the flash engine, pick the bank, and warm-reset so Eos serves it. No programmer.

The **EOS Updater** (`Updater/`) is the native Xbox app for this. It loads a full image into
RAM (local file or network), stages it to the FPGA in chunks, validates it with a streaming
CRC-32, and **stops for you to confirm** right before it writes to flash. It handles the
loader, BIOS, and XbDiag update flows over the Darkone SMBus channel, with a version gate for
XbDiag. Ships as `Updater/xbe/EOS_Updater.xbe` with full source in `Updater/src/`.

---

## Building

Synthesis is done in **Gowin EDA**. The device has to be **GW2AR-18C QN88 C8/I7** across the
project, constraints, and programmer — a mismatch is the usual "won't configure" reason.

1. Open the project in Gowin EDA and add all `src/*.v` sources.
2. Make sure the memory-init hex files are in `src/` next to the RTL — they're read at
   synthesis, and a missing one silently zero-fills (a blank dashboard, for instance):
   `eos_font.hex`, `eos_attr.hex`, `eos_logo.hex`, `eos_screen.hex`.
3. Apply `eos_hdmi.cst` and `eos_hdmi.sdc`.
4. Synthesize → Place & Route → generate the bitstream (`.fs`).

A clean build produces **no synthesis warnings**. If width-truncation, unused-input, or
clock-relationship warnings come back, something regressed — the maintainer notes at the bottom
explain what each guards against.

### The dashboard is generated

`eos_serve_hud.v` is produced by `Tools/gen_hud.py` — don't hand-edit it, edit the generator
and regenerate:

```bash
python3 Tools/gen_hud.py Source/src/eos_serve_hud.v
```

It emits the whole module (607 cells). Panels: title, boot/link, serve, flash engine, I2C
engine, SDRAM preload, address-space serve map, serve log, stability.

---

## Active Notes

Work in progress and things that are wired up but not finished. Stated plainly so nobody trips
over them.

### SMBus commands with no effect yet

Some opcodes are decoded and latch cleanly, but their outputs aren't consumed by anything on
the FPGA yet:

- **SELECT (`0x30`)**, **BOOTMODE (`0x36`)** — the values land in registers, but nothing acts
  on them. Bank selection today goes through the `0xEF` I/O register, not SMBus.
- **SETLOCK (`0x37`) / lock-mask** — the mask is stored and readable at `0x0B`/`0x0C`, and the
  default (`0x0402`) marks the boot and recovery banks locked, but the one place that check
  would apply can't currently be reached (see below), so it doesn't block anything yet.
- **Scratch physical-wipe** — ABORT/CLEAR does the logical flush (disarm + invalidate) that
  matters for safety; the optional physical scratch wipe it also signals isn't hooked up.

### Bank-region ARM collides with SELECT

The "arm an arbitrary bank" command (region 3, opcode `0x30`) shares its opcode with SELECT,
which is decoded first — so **region-3 arm never runs**. This doesn't affect the updater, which
only arms the **loader** and **XbDiag** regions (`0x10` / `0x20`). It does mean SETLOCK's bank
lock has nothing to enforce against yet. Fixing it means giving bank-arm its own opcode, which
is a firmware + updater change and is deliberately left for later.

---

## Source layout

```
Eos.gprj                      Gowin EDA project

src/
  eos_hdmi_top.v        top level: clocks, LPC, SDRAM, HUD, D0/LFRAME, I2C, video
  eos_lpc_loader.v      LPC cycle decode + serve; drives the 1.6 LFRAME abort
  eos_boot_ctrl.v       1.6 LFRAME# abort (mode16_n-gated)
  eos_bank_ctrl.v       0xEF bank register + address map + flash write engine
  eos_flash_cmd.v       flash command bridge (0xEC/0xED) + scratch staging
  eos_flash_reader.v    SPI flash read path (burst reads with backpressure)
  eos_sdram_backend.v   SDRAM serve + preload + scratch
  eos_sdram_pll.v       SDRAM PLL wrapper
  sdram.v               SDRAM controller
  eos_crc32.v           streaming CRC-32 (update validate)
  eos_i2c.v             Darkone SMBus slave (0x6E) + update command engine
  eos_serve_hud.v       serve dashboard  ** GENERATED — edit Tools/gen_hud.py **
  eos_text_rendre.v     colour text renderer + logo overlay
  eos_char_buffer.v     char cell buffer
  eos_attr_buffer.v     colour-attr cell buffer
  eos_font_rom.v        8x16 font ROM  (eos_font.hex)
  eos_logo_rom.v        EOS logo ROM   (eos_logo.hex)
  eos_video_timing.v    HDMI video timing
  eos_ws2812.v          WS2812 status LED
  *.hex                 memory inits (font / attr / logo / screen)
  eos_hdmi.cst          pin + IO constraints
  eos_hdmi.sdc          timing constraints

  dvi_tx/  gowin_rpll/  sdram_pll/    Gowin IP (generated)
```

---

## Credits

Eos firmware © Team Resurgent / Darkone83.

The **`0xEF` banking convention** is Xenium-style and long-established in the OG Xbox scene;
Eos's bank system is a clean-room implementation of it and is **not** derived from OpenXenium.

The **1.6 LFRAME# transaction-abort + LPC-rebuild approach** follows two community references,
credited with thanks:

- **ModXo** — by **Team Resurgent** — <https://github.com/Team-Resurgent/Modxo>
- **OpenXenium** — by **Ryzee119** — <https://github.com/Ryzee119/OpenXenium>

Eos's LFRAME behaviour was matched against these known-good designs; no code from either is
included.
