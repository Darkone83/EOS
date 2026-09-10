# Eos — Firmware

<div align=center>

<img src="https://github.com/Darkone83/EOS/blob/main/images/EOS.png" width=400><img src="https://github.com/Darkone83/EOS/blob/main/images/Darkone83.png" width=500>

</div>

<a href="https://discord.gg/k2BQhSJ"><img src="https://github.com/Darkone83/ModXo-Basic/blob/main/Images/discord.svg"></a>

**A clean-room LPC BIOS-loader modchip for the original Xbox, built as FPGA gateware.**

**Current firmware: 1.0.5** · [Changelog](CHANGELOG.md)

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
| `Updater/` | **EOS Updater** — status, bank/script management, loader/XbDiag updates, backup/restore utilities |
| `Tools/` | Host tooling: recovery GUI, BIOS packer, HUD generator — see `Tools/readme.md` |
| `Gerbers/` | PCB fab set (`EOS.zip`), `BOM.xlsx`, `PickAndPlace.xlsx` |
| `Schematics/` | Board schematic |
| `Editor/` | EOS Script Editor mini-IDE, validator, and LED / GPIO-PWM / I²C studios |
| `images/` | Logos and board renders |

---

## Quick start

1. **Flash the board once.** Bitstream plus a BIOS image, both over the Nano's USB. The
   easiest way is the **EOS Recovery** app — point, click, done. CLI commands are further down
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

- **Serves the BIOS over LPC** — answers the MCPX memory-read cycles and streams the active
  BIOS image out of SDRAM.
- **Works on 1.0–1.4 and 1.6** — D0 on the older boards and LFRAME# transaction abort on 1.6,
  selected by the hardware revision switch. See **Console revisions** below.
- **Xenium-style bank select** — the bank register lives at I/O `0xEF` (low nibble = bank),
  using the long-established Xenium-family convention.
- **SD card BIOS support** — boot BIOS images directly from a FAT32 MicroSD card, with raw
  single-block read/write support available to the EOS SD path.
- **In-system flashing** — the Xbox can erase, write, read, and verify the backing flash, so
  a programmer is not required after the initial board flash.
- **Bank and recovery management** — the Xbox-side updater can flash, verify, rename, color,
  back up, restore, and clear supported BIOS regions while respecting protected banks.
- **Fast preload** — BIOS data streams from flash into SDRAM in bursts and can be served while
  the remaining image continues to fill.
- **Darkone SMBus device** — EOS reports at 7-bit `0x6E`, exposes firmware/status information,
  and carries updater and expansion-mailbox control traffic.
- **EOS Script expansion system** — programmable GPIO, PWM, WS2812, soft-I²C, mailbox, and
  doorbell handling on the expansion header. With no HD add-on, EXP1–EXP8 are available; when
  the HD add-on is present, EXP1–EXP3 are reserved and EXP4–EXP8 remain available to scripts.
- **Onboard HDMI diagnostic dashboard** — a condensed live view of boot/link, bank, flash,
  preload, SMBus, and HD status designed to keep FPGA resource use low.
- **HD add-on support — EXPERIMENTAL** — EOS can drive a compatible external ADV7511-based HD
  add-on. This support is **actively being tested and revised**; video-mode handling, handoff,
  and compatibility should not be treated as final or production-stable yet.
- **Status LEDs / WS2812** — visual boot, flash, bank, and runtime status without requiring a
  diagnostic display.

---

## PCB revisions

### V1

The V1 carrier supports the core EOS functions and is not firmware-dependent. It does not
include the bank RGB LED, HD status LED, expansion header, or RTC found on V2.

### V2

The V2 carrier exposes the full planned expansion feature set, including the RGB bank LED,
HD status LED, expansion header, and onboard RTC. Use the **current V2 fabrication and
schematic files** in the repository; the V2 package was corrected after 1.0.4-1.

---

## Hardware

| | |
|---|---|
| Board | Sipeed Tang Nano 20K |
| FPGA | Gowin GW2AR-18C, QFN88, C8/I7 |
| Memory | 64 Mbit on-package SDRAM (BIOS lives here while serving) |
| Flash | On-board SPI flash (holds the bitstream and the BIOS banks) |
| Video | Onboard HDMI diagnostic dashboard; optional experimental HD add-on |

### Wiring to the Xbox

Connect to the LPC header: `LAD0–3`, `LCLK`, `LRESET#`, `LFRAME#`, plus `3.3V` and `GND`.

Put a **22 Ω resistor in-line on each of the six Xbox-driven inputs** — `LAD0–3`, `LCLK`, and
`LRESET#` — between the Xbox header and the Nano.

> Only feed the board LPC **3.3V**. Don't back-power the 5V rail from USB.

### Parts


| Qty | Part | Why |
|---|---|---|
| 1 | Sipeed Tang Nano 20K (GW2AR-18C) | the modchip |
| 6 | 22 Ω resistor | in series on LAD0–3, LCLK, LRESET# |
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

### Status RGB LED (pin 29)

The bank status LED is programmable per user bank. After a BIOS is flashed, choose one of
11 colors or OFF from Bank Management / the supported UI. Recovery, XbDiag Lite, and SD use
reserved status colors/animations rather than user-selectable colors.

### HD Status LED (pins 30, 31)

V2 exposes two HD-status indicators: pin 30 reports PLL lock and pin 31 reports mode/handoff
status. These indicators belong to the **experimental HD add-on** path.

---

## Pinmap

Taken straight from `eos_hdmi.cst`. That file is the source of truth — check against it before
you wire anything. "Series 22" marks the Xbox-driven inputs that take an in-line resistor.

### Xbox LPC

| Signal | Port | Pin | 22 | Pad settings |
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

### Expansion header

Eight 3.3 V (LVCMOS33) expansion pins are exposed on V2. **Without an HD add-on, EOS Script
can use EXP1–EXP8.** When the HD add-on is physically present, EOS reserves EXP1–EXP3 for its
private control bus and leaves EXP4–EXP8 available to scripts. In the Script Editor, use
`TARGET HD` so the authoring tools reserve those first three pins.

The gateware also protects EXP1–EXP3 while the HD hardware probe is unresolved, preventing a
script from driving the transmitter bus during bring-up.

| Label | Port | Pin | Use |
|---|---|---|---|
| EXP1 | `adv_sda` | 52 | HD SDA when present; script I/O when no HD add-on |
| EXP2 | `adv_scl` | 53 | HD SCL when present; script I/O when no HD add-on |
| EXP3 | `adv_int` | 49 | HD INT when present; script I/O when no HD add-on |
| EXP4 | — | 55 | EOS Script / general expansion I/O |
| EXP5 | — | 48 | EOS Script / general expansion I/O |
| EXP6 | — | 51 | EOS Script / general expansion I/O |
| EXP7 | — | 54 | EOS Script / general expansion I/O |
| EXP8 | — | 56 | EOS Script / general expansion I/O |

> The HD add-on control path uses a private bus separate from the Xbox SMBus. External pull-ups
> are required on the HD harness. HD add-on support remains experimental and is actively being
> tested and revised.

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

EOS exposes its native control/status interface at 7-bit `0x6E`. It shows up in an XbDiag
SMBus scan as an EOS modchip. In 1.0.5, native readback is tied to the command for the current
transaction, reducing stale-index/version readback races on a busy shared bus.

### Registers you read

| Reg | Name | Value |
|---|---|---|
| `0x00` | MAGIC | `0xD8` (Darkone signature) |
| `0x01` | VER_MAJOR | `1` |
| `0x02` | VER_MINOR | `0` |
| `0x03` | VER_PATCH | `5` → firmware 1.0.5 |
| `0x04` | STATUS | live bits, see below |
| `0x05` | ENGINE | update-engine flags (armed / staged / CRC set / busy / err / commit-ok) |
| `0x06` | COMMIT | `{commit_bank, armed_region}` |
| `0x07`–`0x0A` | CRC32 | streaming CRC-32 result, low byte first |
| `0x0B`–`0x0C` | LOCK | lock-mask, low byte first |
| `0x10` | CMD | reads back the last command opcode |
| `0x11`–`0x14` | ARG0–3 | reads back the last command args |
| `0x15`–`0x17` | HD_DIAG | experimental HD diagnostic status/data/register echo |

**STATUS (`0x04`) bits**, low to high: `preload_done`, `mode_16`, `d0_active`,
`abort_active`, `slot1_ready`. Top three bits are zero.

### Expansion mailbox

Runtime interface to the expansion engine (runs in `clk_sd`). Registers live in the
`0x40` window; there are **8 pin-def doorbells** selected by `SEL`.
 
### Registers
 
| Reg | R/W | Name | Meaning |
|---|---|---|---|
| `0x40` | R | STATUS | status bits (below) |
| `0x41` | R | FAULT | fault code (below) |
| `0x42` / `0x43` | R | PC_LO / PC_HI | program counter |
| `0x44` | R | ABI_VER | `0x01` |
| `0x45` | R | PINDEF_COUNT | number of pin-defs |
| `0x46` | R/W | SEL | selected pin-def (0–7) |
| `0x47` | R/W | PAGE | volatile-window page |
| `0x48` | R/W | WINKIND | `0x00` = descriptor stream, else volatile window |
| `0x49` | R/W | DOORBELL | R: `{OVERRUN[7], state[1:0]}`; W: request transition |
| `0x4A` | R/W | CMD | selected pin-def's command byte (writable only while doorbell = IDLE) |
| `0x4B` | R | RESULT | result byte (mirrors volatile `0xFF`) |
| `0x50–0x6F` | R/(W) | WINDOW | descriptor capability stream (WINKIND `0x00`) or volatile RAM (`page*32 + offset`) |
 
### STATUS (`0x40`) bits
 
| Bit | Flag |
|---|---|
| 0 | RUNNING |
| 1 | FAULT |
| 2 | IMAGE_VALID |
| 3 | BOOT_GATE |
| 4 | BUSY |
| 5–7 | reserved (0) |
 
### Doorbell states (`0x49`, bits [1:0])
 
| State | Name | Owner / transition |
|---|---|---|
| `0` | IDLE | host writes `1` (IDLE → PENDING) |
| `1` | PENDING | host set; script picks it up |
| `2` | BUSY | script |
| `3` | READY | script set; host writes `0` (READY → IDLE) |
 
Bit 7 = **OVERRUN** (sticky): set on an illegal ring (writing `1` when not IDLE, or
`0` when not READY). Cleared on a §6c reload / `mbx_clr`. Writes to `0xF8..0xFF` are
ignored.
 
Handshake: host sets `SEL` → writes args to `CMD`/volatile window → rings
(`0x49` = 1) → script runs (→ BUSY), writes `RESULT`, sets READY → host reads
`RESULT` → clears (`0x49` = 0).
 
### Fault codes (`0x41`)
 
| Code | Meaning |
|---|---|
| `0x01` | BADCMD — unknown command line |
| `0x02` | BADPIN — bad pin reference |
| `0x03` | LOOP — loop stack over/underflow |
| `0x04` | ARG — bad argument |
| `0x05` | TIMEOUT |

### Commands you write (to `0x10`, args in `0x11`–`0x14`)

| Opcode | Command | Effect |
|---|---|---|
| `0x01` | PING | liveness, no change |
| `0x02` / `0x03` | ABORT / CLEAR | disarms and invalidates the staged image |
| `0x30` | SELECT | latches `arg0[3:0]`; see **Known interface notes** |
| `0x36` | BOOTMODE | latches `arg0[1:0]`; see **Known interface notes** |
| `0x37` | SETLOCK | updates the bank lock mask |
| `0x38` | LEDMODE | `arg0`: 0 = normal, 1 = rainbow |
| `0x39` | DESCRELOAD | re-read the descriptor block |
| `0x3A` | SETBANKCOLOR | set RGB color for user banks 1–4 |
| `0x3B` | ADVREAD | experimental HD diagnostic register read |
| `0x3D` | HUDMODE | enable/disable the onboard diagnostic HUD engine |
| `0xN0` / `0xN1` / `0xN3` / `0xN4` | ARM / SETCRC / VALIDATE / COMMIT | staged update flow for region N |

The loader and XbDiag update paths use staged data plus CRC validation before commit. Bank
flashing in the updater also performs post-write verification before a bank is accepted.

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

### Easiest: the EOS Recovery app

The **EOS Recovery** GUI wraps the two commands below — pick the bitstream, pick the BIOS
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

Once a bootable image is on the board, BIOS banks can be rewritten from a running console.
The updater validates targets, writes the requested region, and verifies the result before the
new bank is treated as complete.

### EOS Updater

The **EOS Updater** (`Updater/`) is the native Xbox management application. The 1.0.5 build is
organized around six top-level areas:

- **EOS Status** — reads the installed EOS identity/version and live device state.
- **Bank Management** — flash, verify, rename, delete, and set per-bank status colors, including
  descriptor handling for larger BIOS layouts.
- **EOS Scripts** — install, replace, inspect, or remove the active `.eos` expansion script.
- **Update Loader** — staged loader update with additional validation, confirmation, and an
  optional safety backup/restore path for BIOS banks, Recovery, and configuration.
- **Update XbDiag Lite** — version-aware XbDiag update and verification.
- **Utilities** — manual bank backup/restore and maintenance/reset functions.

The updater UI now renders against the active Xbox video mode/backbuffer instead of assuming a
480-line output, improving presentation across 480i/480p, PAL 576i, 720p, and 1080i modes.

Ships as `Updater/xbe/EOS_Updater.xbe` with full source in `Updater/src/`.

---

## Building

Synthesis is done in **Gowin EDA**. The device has to be **GW2AR-18C QN88 C8/I7** across the
project, constraints, and programmer — a mismatch is the usual "won't configure" reason.

1. Open the project in Gowin EDA and add all `src/*.v` sources.
2. Make sure the memory-init hex files are in `src/` next to the RTL — they are read at
   synthesis, and a missing file may silently zero-fill the corresponding ROM/RAM:
   `eos_font.hex`, `eos_attr.hex`, `eos_logo.hex`, `eos_screen.hex`,
   `eos_hud_microcode.hex`, and `eos_xhd_bios_modes.hex`.
3. Apply `eos_hdmi.cst` and `eos_hdmi.sdc`.
4. Under **Project → Configuration → Bitstream → sysControl**, set Loading Rate to **62.5 MHz**.
5. Under **Project → Configuration → Place & Route → Dual-Purpose Pin**, enable **Use SSPI as
   regular IO** and **Use MSPI as regular IO**.
6. Synthesize → Place & Route → generate the bitstream (`.fs`).

A clean build produces **no synthesis warnings**. If width-truncation, unused-input, or
clock-relationship warnings come back, something regressed — the maintainer notes at the bottom
explain what each guards against.

### The dashboard is generated

`eos_serve_hud.v` is generated by `Tools/gen_hud.py`; edit the generator/layout source rather
than hand-editing the generated module:

```bash
python3 Tools/gen_hud.py Source/src/eos_serve_hud.v
```

The current condensed HUD uses static screen/attribute ROM plus
`eos_hud_microcode.hex` for **102 dynamic cells**. The older serve-log/map/rate/stability
telemetry panels were removed to reclaim FPGA LUTs and registers while retaining the primary
boot, preload, flash, SMBus, bank, and HD status information.

---

### Known interface notes

- **SELECT (`0x30`)** and **BOOTMODE (`0x36`)** latch cleanly, but their outputs are not
  currently consumed by the rest of the FPGA. Normal bank selection still uses the `0xEF` I/O
  register.
- **SETLOCK (`0x37`)** updates the lock mask used by the staged bank-commit path, but the
  region-3 ARM opcode conflict below prevents that SMBus bank path from being reached today.
- **Scratch physical wipe** remains optional/unhooked; ABORT/CLEAR still performs the logical
  invalidate/disarm required to prevent stale staged data from committing.

### Bank-region ARM collides with SELECT

The "arm an arbitrary bank" command (region 3, opcode `0x30`) shares its opcode with SELECT,
which is decoded first, so **region-3 ARM does not run through this SMBus command path**. The
loader and XbDiag staged-update regions are unaffected. Bank Management uses its supported
flash/descriptor path instead.

---

## EOS Script system

EOS Script provides a small expansion runtime for the V2 header. Scripts can declare GPIO
inputs/outputs, PWM, WS2812, soft-I²C devices, mailbox registers, and doorbell-style host
commands. The gateware validates the stored script before enabling its pins; invalid/reloading
scripts are held in a safe state.

In 1.0.5, validated script starts/restarts **reapply GPIO `INIT` values**, and HD presence no
longer disables the entire script runtime. Instead, the hardware reserves EXP1–EXP3 only when
the HD add-on is physically present, leaving EXP4–EXP8 available.

The desktop **EOS Script Editor** in `Editor/` provides live validation, autocomplete, hints,
pin/budget reporting, and specialized LED, GPIO/PWM, and I²C studios. Generated identifiers
follow the 16-character EOS symbol limit.

---

## Source layout

```
Eos.gprj                      Gowin EDA project

src/
  eos_hdmi_top.v        top level: clocks, LPC, SDRAM, HUD, expansion, SMBus, HD integration
  eos_lpc_loader.v      LPC cycle decode + BIOS serve; drives the 1.6 LFRAME abort
  eos_boot_ctrl.v       1.6 LFRAME# abort control (mode16_n-gated)
  eos_bank_ctrl.v       0xEF bank register + address map + flash write engine
  eos_bank_led.v        bank/status RGB framework and color persistence path
  eos_exp_engine.v      EOS Script parser/runtime, mailbox, GPIO, PWM, WS2812, soft-I²C
  eos_exp_pkg.vh        expansion widths, offsets, opcodes, and shared constants
  eos_flash_cmd.v       flash command bridge (0xEC/0xED) + scratch staging
  eos_flash_reader.v    SPI flash read path (burst reads with backpressure)
  eos_sd_spi.v          raw MicroSD SPI single-block read/write engine
  eos_sd_precache.v     SD-to-SDRAM BIOS precache path
  eos_sdram_backend.v   SDRAM serve + preload + scratch
  eos_sdram_pll.v       SDRAM PLL wrapper
  sdram.v               SDRAM controller
  eos_crc32.v           streaming CRC-32 validator
  eos_i2c.v             EOS SMBus slave (0x6E), update commands, expansion mailbox transport
  eos_i2c_master.v      private I²C master used by the experimental HD add-on path
  eos_hd.v              experimental HD add-on control, mode, and handoff layer
  eos_serve_hud.v       condensed diagnostic HUD **GENERATED — edit Tools/gen_hud.py**
  eos_text_rendre.v     color text renderer + logo overlay
  eos_char_buffer.v     character-cell buffer
  eos_attr_buffer.v     color-attribute cell buffer
  eos_font_rom.v        8x16 font ROM (`eos_font.hex`)
  eos_logo_rom.v        EOS logo ROM (`eos_logo.hex`)
  eos_video_timing.v    onboard diagnostic HDMI video timing
  eos_ws2812.v          WS2812 status LED driver
  *.hex                 memory init / HUD microcode / HD mode tables
  eos_hdmi.cst          pin + I/O constraints
  eos_hdmi.sdc          timing constraints

  dvi_tx/  gowin_rpll/  sdram_pll/    Gowin IP (generated)
```

---

## Credits

EOS firmware © Team Resurgent / Darkone83.

The **`0xEF` banking convention** is Xenium-style and long-established in the OG Xbox scene;
Eos's bank system is a clean-room implementation of it and is **not** derived from OpenXenium.

Thanks to **Ander-Zero** for the X-RTC project

- **X-RTC** - by **Adner-Zero** - <https://github.com/Andr-Zero/X-RTC>

The **1.6 LFRAME# transaction-abort + LPC-rebuild approach** follows two community references,
credited with thanks:

- **ModXo** — by **Team Resurgent** — <https://github.com/Team-Resurgent/Modxo>
- **OpenXenium** — by **Ryzee119** — <https://github.com/Ryzee119/OpenXenium>

Builders Note

Eos's LFRAME behaviour was matched against these known-good designs; no code from either is
included.

The **experimental HD addon support** is a gateware translation of **X-HD** by **Team
Resurgent** — <https://github.com/Team-Resurgent/X-HD> — with the low-level **ADV7511**
HDMI-transmitter handling deriving from work by **Ryzee119** — <https://github.com/Ryzee119>.
The ADV7511 init sequences, encoder profiles, and video-timing data are traceable to that
source and are credited with thanks under their respective licenses: **X-HD is GPLv3**, and the
ADV7511 register primitives carry **Ryzee119's MIT** header. Eos's HD addon module is a
derivative work of X-HD and is distributed under **GPLv3** accordingly.
