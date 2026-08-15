# EOS Script Programming Guide

**The complete guide to writing `.eos` scripts for the EOS expansion system.**

This is the authoring companion to the *EOS Expansion System Design Specification*. The
spec defines the hardware and the system; this guide teaches you how to write the script
that runs on it. Everything here stays inside the spec's frozen limits — where a limit
matters, it's called out.

> **Mental model:** EOS Script is a tiny sequencer, closer to **assembly or BASIC** than
> to a real programming language. One command per line. The gateware reads your text
> directly and runs it in a forever loop. If you need real logic, you put a
> microcontroller on your expansion device and let EOS talk to it — EOS is the bridge,
> not the brain.

---

## Table of contents

1. What EOS Script is (and isn't)
2. How a script runs
3. Anatomy of a `.eos` file
4. Grammar rules
5. The declaration header
6. Pin types — one worked example each
7. The command set — every opcode with examples
8. Payloads: in-file data vs. live volatile data
9. Registers and the mailbox (the "door")
10. Control flow patterns
11. Complete example programs
12. Faults and debugging
13. Staying within the limits
14. Best practices
15. Quick reference (cheat sheet)

---

## 1. What EOS Script is (and isn't)

EOS Script drives the **expansion pins** (EXP1–EXP8) and exchanges messages with Xbox
software through an **I²C mailbox**. You use it to:

- **Run autonomous props** — case lights that breathe, sweep, or cycle on their own from
  the moment the console powers up. *Script only.*
- **Drive effects from Xbox software** — a game writes "boss health low" to the mailbox;
  your script turns the strip red. *Script + mailbox, no MCU.*
- **Bridge to a real accessory** — a fan controller or OLED gadget running its own MCU;
  EOS relays messages between the Xbox and your device. *Your MCU has the logic.*

> **A note on "reactive to the console":** in V1 a script reacts to two things — its own
> timing (animations) and the Xbox via the mailbox. There is **no** built-in input that
> tells the script the active bank, boot phase, or flash activity. Reacting to console
> state like that is a candidate future feature; for now, if you want that, have Xbox
> software report it into the mailbox.

**What it is not:** a general-purpose language. There is no math, no variables beyond 8
small registers, no strings, no functions you define. This is deliberate — it keeps the
gateware small and your scripts predictable. When you outgrow it, that's your signal to
add an MCU.

---

## 2. How a script runs

- **One script owns the pins.** Exactly one `.eos` file runs at a time. It is the sole
  driver of every EXP pin.
- **Flash-and-go.** The script lives in flash. It runs at boot with no HDD, no loader,
  no dashboard — even inside a game.
- **Forever loop.** Execution runs top to bottom, then wraps to the first instruction and
  repeats. `END` marks the wrap point (if you omit it, it wraps after the last line).
- **Blocking, single-threaded.** Each command finishes before the next starts. A `DELAY`
  or a WS2812 frame push blocks until done. There is no background execution and no
  interrupts.
- **Memory starts at zero.** R0–R7 and **all 256 bytes of volatile RAM** are guaranteed
  `0x00` at the start of every run — every CMD is 0, every doorbell is IDLE, every register
  and scratch byte is 0, RESULT is 0, and `OVERRUN` is clear. A level-polling script reads
  defined zeros on its first loop, never stale data.
- **The boot gate.** Nothing on the EXP pins happens until EOS has served the first BIOS
  byte. Before that, and any time there is no valid script, **every EXP pin is inactive
  (Hi-Z)**. Your script only ever runs after the console is safely coming up.

Because it loops forever and blocks, your loop's total time is its reaction latency. A
loop full of long `DELAY`s reacts slowly to the mailbox. Keep loops tight if you want
responsiveness (see §10, §14).

---

## 3. Anatomy of a `.eos` file

A `.eos` file is plain text you can write in any editor (or build in the WYSIWYG editor).
It has two parts, in order:

```
# ---- 1. Declaration header ----
TARGET NOHD
USES EXP4 AS WS2812 COUNT 2
  REG color WIDTH 3

# ---- 2. Instruction lines ----
LOOP
  WS EXP4 warm
  DELAY 1000
ENDLOOP
END

# ---- (optional) data ----
DATA warm 201000 201000        # compact hex: 2 chars per byte (spaces for grouping)
```

1. **Declaration header** (required, first) — declares your target config, which pins you
   use and as what type, and each pin's mailbox registers.
2. **Instruction lines** — the program the engine runs.
3. **`DATA` blocks** (optional) — named byte payloads (LED frames, I²C writes) referenced
   by instructions. Conventionally placed at the end; they may appear anywhere after the
   header.

**You never write the file's flash wrapper.** When the loader stores your script it adds
a small validity frame (a magic marker, a length, and a CRC) around your text. That's
bookkeeping so a half-finished upload reads as invalid — you don't type it, and you don't
type a checksum. You write only the text above.

---

## 4. Grammar rules

EOS Script is strictly **line-oriented**, like assembly:

- **One command per line.** The first word is the command (or directive); the rest are
  its operands, in fixed order.
- **Whitespace-separated operands.** Spaces or tabs between tokens. No commas required.
- **Comments** start with `#` and run to end of line. Blank lines are ignored.
- **Numbers** are decimal (`500`) or hex (`0x1F4`). Pins are `EXP1`–`EXP8`. Registers are
  `R0`–`R7`.
- **Case:** commands and keywords are upper-case by convention; the editor emits
  upper-case. Names you define (`DATA`, `DEF`) are yours.
- **Indentation is cosmetic** — indent bodies of `LOOP`/`USES` for readability; the parser
  ignores leading whitespace.

Two convenience directives are resolved at load, before the script runs (the engine makes
one indexing pass to collect them, then executes):

- **`DEF <name> <number>`** — a named constant (an "equate"). Use it for volatile offsets,
  command codes, colors, anything. `DEF HEALTH 0x08` then use `HEALTH` anywhere a number
  is expected.
- **`DATA <name> <hex>`** — a named in-file payload as **compact hex** (see §8).

Rules for names (both directives): **case-insensitive**, **≤ 16 characters**, and a
**duplicate name makes the file invalid**. A script may declare up to **64 `DEF`s** and
**32 `DATA` blocks**. Commands and keywords are also case-insensitive (`DELAY` = `delay`);
the editor writes them upper-case.

> **Why one-command-per-line matters:** it's what lets the gateware read your script with
> a small line-by-line parser instead of a full compiler. Stick to the form and your
> scripts are both human-readable and hardware-friendly.

---

## 5. The declaration header

Every script begins by declaring what it uses. The header is what tells the engine how to
configure each pin, and it's what builds the mailbox interface your Xbox app talks to.

### 5.1 `TARGET` — which hardware config

```
TARGET HD        # HD addon fitted: EXP1–EXP3 are reserved, you have EXP4–EXP8 (5 pins)
TARGET NOHD      # no HD addon: all 8 pins (EXP1–EXP8) are free
```

Required, first line. Under `TARGET HD`, using EXP1, EXP2, or EXP3 is an error — those
pins belong to the HD addon.

### 5.2 `USES` — claim a pin and give it a type

```
USES <pin> AS <TYPE> [INIT <v>] [SAFE <v>]      # single-pin type
USES <pin> AS WS2812 COUNT <n>                   # WS2812: COUNT is required
USES <sclpin> <sdapin> AS I2C                    # I²C uses a pair (SCL then SDA)
```

Types: `GPIO_IN`, `GPIO_OUT`, `PWM`, `WS2812`, `I2C`. (`1WIRE` is reserved for a later
version.)

- **`GPIO_OUT` and `PWM` must declare `INIT` and `SAFE`.** `INIT` is the value driven when
  the script starts; `SAFE` is the value driven if the script faults. There is no default
  — EXP pins have no guaranteed pull, so you must say what's safe. A missing `INIT`/`SAFE`
  makes the file invalid.
- **`WS2812` must declare `COUNT <n>`** — the number of LEDs on the strip (**1–1365**):
  `USES EXP4 AS WS2812 COUNT 60`. The engine needs the count to build the all-off
  INIT/SAFE frame (holding the data line low does *not* clear already-lit pixels). `INIT`
  and `SAFE` default to that all-off frame; you don't declare them.
- **`GPIO_IN`** is an input; **`I2C`** releases its lines (idle high).

Pin-defs are numbered `0,1,2…` in the order their `USES` blocks appear. That order also
fixes their mailbox layout (§9).

### 5.3 `REG` — declare a pin-def's mailbox registers

Indented under a `USES`, each `REG` creates a named, width-typed slot in that pin-def's
mailbox bank — a place the Xbox writes to and your script reads from.

```
USES EXP4 AS WS2812 COUNT 8
  REG color      WIDTH 3      # 3 bytes: G, R, B
  REG brightness WIDTH 1
  REG speed      WIDTH 1
```

A register means whatever your script decides it means — EOS only guarantees "N bytes at
a known offset." You publish what they mean (the WYSIWYG editor generates that doc for
you). **In V1 every register is fully read/write** for both the Xbox and the script
(there's no read-only/write-only qualifier yet). Limits: ≤ 16 registers per pin-def, bank
≤ 32 bytes total (§13).

### 5.4 `I2C_ADDR` — optional collision hint

```
I2C_ADDR 0x40 0x68     # addresses your I²C devices use; enables a best-effort warning
```

Advisory only. It lets the editor warn if two combined scripts declare the same address.
EOS can't see actual devices on the bus, so avoiding real address clashes is still up to
you.

---

## 6. Pin types — one worked example each

Each pin type gets its own sub-engine and its own commands. Below is a minimal, complete
script for each.

### 6.1 GPIO_OUT — drive a pin high/low

Blink an LED (or trigger a relay) on EXP7.

```
TARGET NOHD
USES EXP7 AS GPIO_OUT INIT 0 SAFE 0

LOOP
  SET EXP7 1
  DELAY 500
  SET EXP7 0
  DELAY 500
ENDLOOP
END
```

### 6.2 GPIO_IN — read a pin

Mirror a button on EXP5 to an LED on EXP7.

```
TARGET NOHD
USES EXP5 AS GPIO_IN
USES EXP7 AS GPIO_OUT INIT 0 SAFE 0

LOOP
  GET EXP5 R0          # R0 = button state (0/1)
  SET EXP7 R0          # drive the LED to match
  DELAY 20             # debounce-ish; keeps the loop from spinning hot
ENDLOOP
END
```

*(`SET` accepts a register as its value as well as a literal.)*

### 6.3 PWM — brightness, servos, tone

Fade-capable LED / servo drive on EXP7. `PWM <pin> <duty 0-255> <freq_hz>`; duty `0`
stops output.

```
TARGET NOHD
USES EXP7 AS PWM INIT 0 SAFE 0

LOOP
  PWM EXP7 64  1000      # 25% duty at 1 kHz
  DELAY 1000
  PWM EXP7 255 1000      # full
  DELAY 1000
ENDLOOP
END
```

### 6.4 WS2812 — addressable RGB

Push a stored frame to a strip on EXP4. WS2812 data is **GRB** order, 3 bytes per LED.

```
TARGET NOHD
USES EXP4 AS WS2812 COUNT 4

LOOP
  WS EXP4 red            # push the 'red' frame (defined below)
  DELAY 500
  WS EXP4 off
  DELAY 500
ENDLOOP
END

# 4 LEDs, GRB, compact hex (each LED = 6 hex digits G R B; spaces optional)
DATA red 00FF00 00FF00 00FF00 00FF00
DATA off 000000 000000 000000 000000
```

`DATA` payloads are **compact hex** (2 hex digits per byte); spaces are only for your eyes.
The frame length comes from the `DATA` block, so a longer strip just needs a longer `DATA`
(and a matching `COUNT`), up to the frame limit (§13).

### 6.5 I²C — talk to a device

I²C uses **two** pins (SCL then SDA). Write a config byte to a device at `0x40`, then read
2 bytes back into volatile RAM.

```
TARGET NOHD
USES EXP5 EXP6 AS I2C        # EXP5 = SCL, EXP6 = SDA

DEF SENSOR 0x40

LOOP
  I2CW SENSOR cfg            # write the 'cfg' payload to the device
  DELAY 10
  I2CR SENSOR 2 0x20         # read 2 bytes into volatile[0x20..0x21]
  DELAY 100
ENDLOOP
END

DATA cfg 0180                # compact hex: device register 0x01 <= 0x80
```

Every I²C op sets a **result code** you can check (§7.7, §12). I²C never hangs — a missing
device returns `NACK_ADDR`, a stuck bus is recovered and reported.

---

## 7. The command set — every opcode with examples

Commands fall into five groups. Argument order is fixed.

### 7.1 Pin control

| Command | Form | Does |
|---------|------|------|
| `SET` | `SET <pin> <0\|1\|Rn>` | Drive a `GPIO_OUT` pin low/high (literal or register). |
| `GET` | `GET <pin> <Rn>` | Read a `GPIO_IN` pin into a register (0/1). |
| `PWM` | `PWM <pin> <duty\|Rn> <freq_hz>` | Start continuous PWM; `duty` 0–255 (literal or register), `0` = stop. `freq` is a literal. |

```
SET EXP7 1
GET EXP5 R0
PWM EXP7 128 2000        # 50% at 2 kHz
```

### 7.2 Timing

| Command | Form | Does |
|---------|------|------|
| `DELAY` | `DELAY <count> [MS\|US]` | Blocking wait, `count` **0–65535**. Default unit `MS`. |

```
DELAY 250        # 250 milliseconds (max 65535)
DELAY 900 US     # 900 microseconds (max 65535)
```

PWM (§7.1) frequency must be **1 Hz – 100 kHz**. Values outside these ranges raise
`ARG_RANGE`.

### 7.3 WS2812

| Command | Form | Does |
|---------|------|------|
| `WS` | `WS <pin> <dataname>` | Push an in-file frame. |
| `WS` | `WS <pin> VOL <off> <len>` | Push a frame from volatile RAM (live data). |

```
WS EXP4 rainbow             # stored frame
WS EXP4 VOL 0x20 12         # 12 bytes (4 LEDs) starting at volatile 0x20
```

**A frame must be exactly `COUNT × 3` bytes** (GRB) — matching the pin's declared `COUNT`.
A wrong-length in-file frame fails load validation; a wrong-length `VOL` frame raises
`ARG_RANGE`.

### 7.4 I²C

| Command | Form | Does |
|---------|------|------|
| `I2CW` | `I2CW <addr> <dataname>` | Write an in-file payload. |
| `I2CW` | `I2CW <addr> VOL <off> <len>` | Write from volatile RAM (relay). |
| `I2CR` | `I2CR <addr> <len> <dstoff>` | Read `<len>` bytes into volatile at `<dstoff>`. |

```
I2CW 0x40 cfg
I2CW 0x40 VOL 0x09 16       # forward 16 bytes the Xbox placed at volatile 0x09
I2CR 0x40 4 0x30           # read 4 bytes -> volatile[0x30..0x33]
```

`<addr>` is the 7-bit device address (e.g. `0x40`). The bus runs at **100 kHz** in V1.
**Transfer limits differ by direction:** `I2CW` from a `DATA` block ≤ **256 B**; `I2CW`
from `VOL` ≤ the free contiguous volatile bytes; `I2CR` ≤ **64 B** and must fit its
destination (`dstoff + len ≤ 0xF8`). An I²C op never blocks forever — a stall past 1 ms
returns `TIMEOUT` in the RESULT slot (§7.7).

### 7.5 Mailbox access

| Command | Form | Does |
|---------|------|------|
| `GETMAIL` | `GETMAIL <idx> <Rn>` | Read volatile byte `<idx>` into a register. |
| `SETMAIL` | `SETMAIL <idx> <Rn\|literal>` | Write a register **or a literal** into volatile byte `<idx>`. |

```
GETMAIL 0x08 R0          # R0 = volatile[0x08]
SETMAIL 0x30 R1          # volatile[0x30] = R1  (from a register)
SETMAIL 0x01 2           # volatile[0x01] = 2   (a literal — e.g. a doorbell state)
```

`<idx>` is 0–255. These are your window into the mailbox: the Xbox writes bytes you read
with `GETMAIL`, and you report back with `SETMAIL` (§9).

### 7.6 Control flow

| Command | Form | Does |
|---------|------|------|
| `LOOP` | `LOOP [<count>]` | Begin a block. Omitted/`0` = repeat forever. Nest up to 4 deep. |
| `ENDLOOP` | `ENDLOOP` | End the innermost `LOOP`. |
| `IFMAIL` | `IFMAIL <idx> <EQ\|NE\|LT\|GT> <val> <skip>` | If the test is **false**, skip the next `<skip>` instructions. |
| `END` | `END` | Wrap to the first instruction. |
| `NOP` | `NOP` | Do nothing (padding/placeholder). |

```
LOOP 8               # counted block, runs 8 times
  WS EXP4 next
  DELAY 60
ENDLOOP

IFMAIL 0x08 LT 20 2  # if volatile[0x08] >= 20, skip the next 2 lines
  WS EXP4 red
  DELAY 100
```

`IFMAIL` compares a whole volatile byte against `<val>`. The `<skip>` count is how many
following instructions to jump over when the condition is false — count the lines in your
guarded block. *(The WYSIWYG editor offers an `IF … ENDIF` block that fills in the skip
count for you; by hand, keep guarded blocks short and count carefully.)*

### 7.7 The result slot

Every I²C op writes its outcome to a reserved volatile byte, **`0xFF` (the RESULT slot)**:
`0`=OK, `1`=NACK_ADDR, `2`=NACK_DATA, `3`=TIMEOUT, `4`=STUCK. Check it like any mailbox
byte:

```
I2CR 0x40 2 0x30
IFMAIL 0xFF EQ 0 2     # RESULT OK? run the block (on error, skip it)
  GETMAIL 0x30 R0
  SET EXP7 R0
```

---

## 8. Payloads: in-file data vs. live volatile data

`WS`, `I2CW` (and future `OW_WR`) send a block of bytes. That block comes from one of two
places:

**In-file data (a `DATA` block).** Fixed bytes baked into your script — a stored LED
frame, a fixed I²C command. Referenced by name; the length is the block's length.

```
DATA boot_sweep 001000 002000 004000
...
WS EXP4 boot_sweep
```

**Live volatile data (`VOL <off> <len>`).** Bytes the Xbox wrote into the mailbox at
runtime — this is how you **relay** live data to a device or push a frame the game
computed.

```
WS   EXP4 VOL 0x20 12       # push whatever the Xbox placed at volatile 0x20
I2CW 0x40 VOL 0x09 16       # forward 16 live bytes to an MCU at 0x40
```

Use `DATA` for anything canned; use `VOL` when the Xbox (or a prior `I2CR`) supplied the
bytes at runtime. Because reads land in volatile RAM too, you can **read-then-forward**:
`I2CR` a sensor into volatile, then `I2CW`/`WS` from that same region.

Limits: an in-file WS frame is ≤ 4095 bytes; a volatile-sourced block is bounded by the
free volatile space. An in-file `I2CW` is ≤ 256 bytes; an `I2CR` is ≤ 64 bytes and must
fit its destination (§13).

---

## 9. Registers and the mailbox (the "door")

This is how your script and Xbox software talk. The mailbox is a **door**: EOS moves
bytes through it, but *you* decide what they mean. You declare registers; your script
reads them and acts; your Xbox app writes them. EOS guarantees the transport, not the
meaning.

### 9.1 The volatile RAM map

There are **256 bytes** of volatile RAM, addressed `0x00–0xFF`. Your registers live here,
laid out **deterministically in declaration order** so you always know where they are:

- Allocation starts at `0x00` and fills upward, one **bank** per pin-def in `USES` order.
- Each bank is: **`CMD` (1 byte, the command code)**, then **`DOORBELL` (1 byte, a state
  value)**, then your `REG` slots in declared order.
- The `DOORBELL` byte holds a **state**: `0` IDLE, `1` PENDING, `2` BUSY, `3` READY (§9.3).
- After the banks comes free **scratch** space (for `I2CR` destinations and `VOL`
  buffers), up to `0xF7`.
- **`0xF8–0xFF` are reserved** by the engine. **`0xFF` is the RESULT slot** (§7.7). Never
  use these for your own data.

**Worked layout** for this header:

```
USES EXP4 AS WS2812 COUNT 8  # pin-def 0
  REG color      WIDTH 3
  REG brightness WIDTH 1
USES EXP5 EXP6 AS I2C        # pin-def 1
  REG payload    WIDTH 16
```

| Volatile | Belongs to | Meaning |
|----------|-----------|---------|
| `0x00` | pin-def 0 | `CMD` |
| `0x01` | pin-def 0 | `DOORBELL` |
| `0x02–0x04` | pin-def 0 | `color` (G,R,B) |
| `0x05` | pin-def 0 | `brightness` |
| `0x06` | pin-def 1 | `CMD` |
| `0x07` | pin-def 1 | `DOORBELL` |
| `0x08–0x17` | pin-def 1 | `payload` (16 bytes) |
| `0x18–0xF7` | — | free scratch |
| `0xFF` | engine | RESULT |

Name them with `DEF` so your code reads cleanly:

```
DEF COLOR 0x02
DEF BRIGHT 0x05
```

*(The exact offsets are also published to the Xbox at runtime through the ENUMERATE
descriptor, so a host tool can discover them; the deterministic rule above is so **you**
can predict them while writing the script.)*

### 9.2 Pattern A — level polling (simplest)

For continuous values (a brightness, a color), just read the register every loop and apply
it. No handshake needed.

```
TARGET NOHD
USES EXP7 AS PWM INIT 0 SAFE 0
  REG level WIDTH 1
DEF LEVEL 0x02               # pin-def 0: CMD@0, DOORBELL@1, level@2

LOOP
  GETMAIL LEVEL R0           # R0 = brightness the Xbox last wrote
  PWM EXP7 R0 1000           # apply it
  DELAY 30
ENDLOOP
END
```

The Xbox just writes one byte to `level` whenever it wants; the script tracks it. Perfect
for smoothly-changing values.

> **Tearing warning (important).** A **single-byte** value is always coherent — the read
> can't catch it half-written. A **multi-byte** value (a 3-byte color, say) is written by
> the Xbox as separate SMBus bytes, so a level-polling script can read a **mix of old and
> new** bytes for one frame — e.g. new G with old R and B. For continuously-updated
> *visual* data that's usually invisible (one glitched frame, gone next loop), so Pattern
> A with a multi-byte value is fine **if you accept occasional tearing**. If the multi-byte
> value must be **coherent** (a calibration triplet, a packet), use **Pattern B** — the
> doorbell guarantees you only act on a complete update.

### 9.3 Pattern B — the doorbell (discrete commands, atomic multi-byte)

When you need "do this once" semantics, or the Xbox writes several bytes that must be
applied together, use the **doorbell** so you never act on a half-written command.

**The handshake uses the `DOORBELL` state byte** (`0` IDLE, `1` PENDING, `2` BUSY, `3`
READY). `CMD` carries only the command *code* — it is not the handshake. The flow:

1. The Xbox writes the register bytes, writes `CMD`, then sets `DOORBELL = PENDING (1)`.
2. Your script sees `PENDING`, sets `DOORBELL = BUSY (2)` to take ownership, reads `CMD`
   and the bank, acts, writes any response into scratch, then sets `DOORBELL = READY (3)`.
3. The Xbox sees `READY`, reads the response, and sets `DOORBELL = IDLE (0)` to acknowledge
   — which re-arms the door. If the Xbox rings while the state isn't IDLE, its command is
   dropped and a sticky `OVERRUN` is raised for it to notice.

```
TARGET NOHD
USES EXP4 AS WS2812 COUNT 1
  REG color WIDTH 3
DEF DB0    0x01             # pin-def 0 DOORBELL byte (CMD@0, DOORBELL@1)
DEF COLOR  0x02            # pin-def 0 'color' (GRB)

LOOP
  IFMAIL DB0 EQ 1 4          # PENDING? run the handler (else skip the next 4 lines)
    SETMAIL DB0 2            #   -> BUSY (take ownership)
    WS EXP4 VOL COLOR 3      #   apply the color (now guaranteed complete, not torn)
    SETMAIL DB0 3            #   -> READY (host will ack -> IDLE)
    DELAY 2
  DELAY 20                   # idle poll interval
ENDLOOP
END
```

*(The `IFMAIL` skip count is just the number of guarded lines — 4 here. The WYSIWYG
editor's `IF … ENDIF` block counts them for you.)*

**The other half (what the Xbox app does):** read the ENUMERATE descriptor once to learn
offsets; then per command — select the pin-def, write the `color` bytes, write `CMD`, set
`DOORBELL = PENDING`; wait until `DOORBELL = READY`, read any response, set
`DOORBELL = IDLE`; if `OVERRUN` is set, the previous command wasn't consumed yet (back off
and retry). Full 0x6E register details are in the expansion spec (§5.3, §5.6).

> **Rule of thumb:** use **Pattern A** for values that change continuously (accepting a
> little tearing on multi-byte visual data), **Pattern B** for commands/events and for any
> multi-byte value that must be coherent.

---

## 10. Control flow patterns

**Forever background effect** — the default shape:

```
LOOP
  ... effect steps ...
ENDLOOP
END
```

**Counted animation step** — advance N frames then do something else:

```
LOOP 16
  WS EXP4 VOL 0x20 48
  DELAY 40
ENDLOOP
```

**React to a mailbox value** — the guard skips its block when the test is false:

```
IFMAIL HEALTH LT 25 2      # health < 25 ?
  WS EXP4 alarm            #   yes: alarm frame
  DELAY 80                 #   (2 guarded lines)
```

**Command dispatcher** — check the doorbell, then branch on the command code (Pattern B):

```
IFMAIL DB0 EQ 1 8          # PENDING? run the dispatcher (else skip the next 8 lines)
  SETMAIL DB0 2            #  1  -> BUSY
  IFMAIL CMD0 EQ 1 2       #  2  command 1?
    WS EXP4 red            #  3
    DELAY 50               #  4
  IFMAIL CMD0 EQ 2 2       #  5  command 2?
    WS EXP4 blue           #  6
    DELAY 50               #  7
  SETMAIL DB0 3            #  8  -> READY (host acks -> IDLE)
```

The doorbell (not `CMD`) is the handshake: take the command with `BUSY`, dispatch on the
`CMD` *code*, finish with `READY`; the host acknowledges by returning the doorbell to
`IDLE`. Note the inner `IFMAIL`s **count toward the outer skip** (8 lines here) — nested
skip-counting by hand is fiddly, which is exactly what the editor's `IF … ENDIF` block
removes.

**Keep loops responsive.** Reaction time equals one trip through the loop. If you want the
script to notice a mailbox change quickly, avoid long `DELAY`s on the path; break a long
wait into a short poll loop instead.

---

## 11. Complete example programs

### 11.1 Autonomous boot glow (script only)

A gentle warm pulse that just runs — the "hello world" of autonomous props. (It runs on
its own timing; it doesn't observe console state — see §1.)

```
TARGET NOHD
USES EXP4 AS WS2812 COUNT 3

LOOP
  WS EXP4 dim
  DELAY 700
  WS EXP4 warm
  DELAY 700
ENDLOOP
END

DATA dim  080400 080400 080400
DATA warm 201000 201000 201000
```

### 11.2 Game-driven strip color (script + mailbox, Pattern A)

The game continuously writes a GRB color; the strip follows it. This is Pattern A with a
3-byte value, so it can tear for a single frame if the game updates mid-read — fine for a
smoothly-changing glow. If you need every color to land exactly, use the doorbell (§9.3).

```
TARGET NOHD
USES EXP4 AS WS2812 COUNT 1
  REG color WIDTH 3
DEF COLOR 0x02

LOOP
  WS EXP4 VOL COLOR 3       # push the live color (one LED shown; widen for more)
  DELAY 25
ENDLOOP
END
```

### 11.3 I²C sensor → Xbox (read-then-report)

Read a temperature register every second and expose it to the Xbox in a mailbox byte.

```
TARGET NOHD
USES EXP5 EXP6 AS I2C
  REG temp WIDTH 1           # pin-def 0: CMD@0, DOORBELL@1, temp@2
DEF SENSOR 0x48
DEF TEMP   0x02
DEF SCRATCH 0x20

LOOP
  I2CR SENSOR 1 SCRATCH      # read 1 byte into volatile[0x20]
  IFMAIL 0xFF EQ 0 2         # RESULT OK? do the report (else skip)
    GETMAIL SCRATCH R0
    SETMAIL TEMP R0          # publish temp for the Xbox to read
  DELAY 1000
ENDLOOP
END
```

### 11.4 Relay to an MCU (script + mailbox, Pattern B)

The Xbox hands the script a block of bytes; the script forwards them verbatim to an MCU
at `0x50` when the doorbell rings, then signals completion. The doorbell guarantees the
16-byte payload is complete before it's forwarded.

```
TARGET NOHD
USES EXP5 EXP6 AS I2C
  REG payload WIDTH 16       # pin-def 0: CMD@0, DOORBELL@1, payload@2..0x11
DEF DB0     0x01            # doorbell byte
DEF PAYLOAD 0x02
DEF MCU     0x50

LOOP
  IFMAIL DB0 EQ 1 4          # PENDING? run the handler (else skip 4 lines)
    SETMAIL DB0 2            #   -> BUSY
    I2CW MCU VOL PAYLOAD 16  #   forward the 16 live bytes (now guaranteed complete)
    SETMAIL DB0 3            #   -> READY (host acks -> IDLE)
    DELAY 2
  DELAY 15
ENDLOOP
END
```

---

## 12. Faults and debugging

If the engine hits something it can't run, it **stops, drives every output pin to its
`SAFE` value, releases the buses, and records a fault.** A fault is terminal until the
next cold boot or re-flash — the script does not resume.

**Fault codes** (readable over I²C at 0x6E register `FAULT`, with the faulting
**instruction index** in `PC_LO/PC_HI` — the editor maps that index back to your source
line):

| Code | Name | Cause |
|------|------|-------|
| 0x01 | BAD_CMD | Unknown/reserved command, or a malformed line. |
| 0x02 | BAD_PIN | Using a pin you didn't declare, or the wrong command for its type. |
| 0x03 | LOOP_STACK | `ENDLOOP` with no `LOOP`, or nesting deeper than 4. |
| 0x04 | ARG_RANGE | An offset/length/argument out of range (e.g. volatile ≥ 256). |
| 0x05 | TIMEOUT | A single operation other than `DELAY` exceeded the 500 ms operation watchdog. |
| 0x06 | PERIPHERAL | An escalated, unhandled peripheral error. |

**Gross syntax errors don't fault — they invalidate.** If the file won't parse or the
declarations are inconsistent (pin collision, over budget, missing `INIT`/`SAFE`), it's
treated as *no valid script*: engine idle, all pins Hi-Z. Fix it and re-upload.

**Debugging checklist:**
- Nothing lights? Check the WS2812 byte order (**GRB**, not RGB) and that your `DATA`
  length matches your strip.
- I²C silent? Read the **RESULT slot** (`0xFF`) after the op — `NACK_ADDR` means wrong
  address or no device.
- Script seems dead? Read `STATUS`/`FAULT` at 0x6E. `FAULT != 0` with the instruction
  index tells you exactly where (the editor maps it to your line). `BOOT_GATE_OPEN = 0`
  means the console never handed off — expansion is correctly staying safe.
- Missed commands? The Xbox is likely writing faster than your loop turns — shorten the
  loop or use the doorbell's `OVERRUN` to pace it.

---

## 13. Staying within the limits

Your script must fit these bounds; the editor checks them and the engine enforces them.

| Resource | Limit | Watch out for |
|----------|-------|---------------|
| Pins | 5 (HD) / 8 (no HD) | I²C costs **2** pins. |
| Pin-defs | ≤ 8 | one per `USES`. |
| Instructions | ≤ 4096 | |
| Whole file | region 128 KB, frame 16 B | **131056 B (0x1FFF0) usable**, instructions **and** payload share it. |
| In-file payload | ≤ 16 KB decoded | as compact hex it's ~2× that in text. |
| `DEF` / `DATA` | ≤ 64 / ≤ 32 | names ≤ 16 chars, case-insensitive, no duplicates. |
| Volatile RAM | 256 B total | banks + scratch must fit in `0x00–0xF7`. |
| Registers / pin-def | ≤ 16 | |
| Bank / pin-def | ≤ 32 B | `2 + sum(REG widths) ≤ 32`. |
| Read-scratch | ≤ 64 B | your `I2CR`/`VOL` working area. |
| WS2812 frame | = `COUNT × 3` B | `COUNT` 1–1365; in-file ≤ **4095 B**; wrong length → invalid / `ARG_RANGE`. |
| I2CW (in-file) | ≤ 256 B | from a `DATA` block. |
| I2CW (`VOL`) | ≤ free volatile | contiguous bytes. |
| I2CR | ≤ 64 B | must fit `dstoff+len ≤ 0xF8`. |
| `DELAY` | ≤ 65535 | MS or US. |
| PWM freq | 1 Hz – 100 kHz | |
| Loop nesting | 4 deep | |
| Registers | R0–R7 (8) | |

**Instructions and payload share one budget.** Both live in the 131056-byte usable region, so
a payload-heavy script has room for fewer instructions and vice-versa — you won't hit both
ceilings at once.

**Volatile budget that bites:** `2 + sum(REG widths)` per bank, all banks + your scratch ≤
`0xF7` (247 usable bytes; `0xF8–0xFF` are the engine's). Eight pin-defs with fat register
banks can exhaust volatile before anything else — plan the map (§9.1) first.

---

## 14. Best practices

- **Declare `SAFE` like it matters — because it does.** It's the state your hardware lands
  in if anything goes wrong. Pick the value that's safe for *your* device (LED off, relay
  open, servo neutral).
- **Keep the loop tight for reactive scripts.** Reaction time = one loop pass. Poll in
  short intervals; don't bury a mailbox check behind a one-second `DELAY`.
- **Level-poll simple values, doorbell discrete commands.** Don't build a handshake for a
  brightness knob; don't level-poll a multi-byte packet.
- **Plan the volatile map before you write code.** Lay out banks and scratch on paper (or
  in the editor), `DEF` the offsets, then write against names.
- **Comment your register meanings.** The bytes are meaningless to EOS; your comments and
  the generated command-map doc are the contract with the Xbox app.
- **Push logic to an MCU when it grows.** If you're stacking `IFMAIL`s into something that
  wants real branching or math, that's the moment to let an MCU do the thinking and use
  EOS as the bridge.
- **Mind WS2812 timing on breadboards.** Loose wiring and the wrong data order are the two
  most common "nothing lights" causes.
- **Don't touch `0xF8–0xFF`.** That's engine space; `0xFF` is your I²C result.
- **Keep `IFMAIL` skips inside one block.** A guarded skip must not jump into or out of a
  `LOOP`/`ENDLOOP` body — skipping across a loop boundary is undefined. The editor's
  `IF … ENDIF` keeps you inside the lines. When hand-counting, count only lines within the
  same block.

---

## 15. Quick reference (cheat sheet)

**Declaration directives** *(names: case-insensitive, ≤16 chars, no duplicates)*
```
TARGET HD | NOHD
USES <pin> AS GPIO_IN | GPIO_OUT | PWM        [INIT <v>] [SAFE <v>]   # INIT+SAFE req. for OUT/PWM
USES <pin> AS WS2812 COUNT <n>                                        # COUNT required
USES <scl> <sda> AS I2C
  REG <name> WIDTH <n>            # under a USES; <=16/pin-def, bank <=32B; all RW in V1
I2C_ADDR <a> [<a> ...]           # optional advisory
DEF  <name> <number>             # named constant (<=64)
DATA <name> <hex>                # in-file payload, compact hex, 2 chars/byte (<=32 blocks)
```

**Commands** *(R0–R7 start at 0x00)*
```
NOP
SET   <pin> <0|1|Rn>
GET   <pin> <Rn>
DELAY <count> [MS|US]                 # default MS; count 0-65535
PWM   <pin> <duty|Rn> <freq_hz>       # duty 0 = stop; freq 1 Hz - 100 kHz
WS    <pin> <dataname>                # in-file frame (len = COUNT x 3; COUNT 1-1365, <=4095 B)
WS    <pin> VOL <off> <len>           # live frame (len = COUNT x 3)
I2CW  <addr> <dataname>               # in-file write (<= 256 B)
I2CW  <addr> VOL <off> <len>          # live write / relay (<= free volatile)
I2CR  <addr> <len> <dstoff>           # read -> volatile (<= 64 B; 100 kHz bus)
GETMAIL <idx> <Rn>
SETMAIL <idx> <Rn|literal>            # literal lets you write doorbell states
LOOP  [<count>]                       # 0/omitted = forever; nest <=4
ENDLOOP
IFMAIL <idx> <EQ|NE|LT|GT> <val> <skip>   # skip N instructions if FALSE (nested IFs count)
END
```

**Volatile RAM map**
```
0x00 .. banks (pin-def order): [CMD][DOORBELL][REG slots...] each
   .. free scratch (I2CR dests, VOL buffers)  .. up to 0xF7
0xF8 .. 0xFE  reserved (engine)
0xFF          RESULT slot: 0 OK, 1 NACK_ADDR, 2 NACK_DATA, 3 TIMEOUT, 4 STUCK
DOORBELL byte state: 0 IDLE, 1 PENDING, 2 BUSY, 3 READY
```

**Fault codes (0x6E `FAULT`, instruction index in `PC_LO/HI`)**
```
0x01 BAD_CMD   0x02 BAD_PIN   0x03 LOOP_STACK
0x04 ARG_RANGE 0x05 TIMEOUT   0x06 PERIPHERAL
```

**Register interaction**
```
Pattern A (values):   GETMAIL <reg> Rn -> apply        (level poll; multi-byte may tear)
Pattern B (commands): wait DOORBELL=PENDING(1) -> SETMAIL DB 2 (BUSY) -> act
                      -> SETMAIL DB 3 (READY); host acks by setting DOORBELL=IDLE(0)
```

---

*This guide fixes the authoring syntax and programming model for EOS Script V1. It stays
within the bounds of the EOS Expansion System Design Specification; where the two ever
disagree, the spec's limits and the mailbox/0x6E interface are authoritative.*