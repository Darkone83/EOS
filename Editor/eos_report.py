"""
eos_report — turn a linted ScriptModel into plain-English guidance for the user.

Two audiences:
  describe(model)       -> what this script sets up, in plain words
  host_contract(model)  -> what an Xbox app needs to know to talk to it
"""
import eos_language as L

_TYPE_WORDS = {
    "GPIO_IN": "reads a digital input",
    "GPIO_OUT": "drives a digital output",
    "PWM": "drives a PWM output (dimming / servo / tone)",
    "WS2812": "drives an addressable RGB strip",
    "I2C": "talks to I²C devices",
}


def describe(model):
    if not model.pindefs and model.instruction_count == 0:
        return "Empty script. Start with a TARGET line and a USES declaration."

    lines = []
    tgt = model.target or "??"
    if tgt == "HD":
        lines.append("Target: HD addon fitted — EXP1–EXP3 are reserved, "
                     "you're using EXP4–EXP8.")
    elif tgt == "NOHD":
        lines.append("Target: no HD addon — all of EXP1–EXP8 are available.")

    if model.pindefs:
        lines.append("")
        lines.append("This script sets up:")
        for pd in model.pindefs:
            what = _TYPE_WORDS.get(pd.ptype, pd.ptype)
            pins = " + ".join(pd.pins) if pd.pins else "?"
            extra = ""
            if pd.ptype == "WS2812" and pd.count:
                extra = f" ({pd.count} LEDs)"
            regs = ""
            if pd.regs:
                regs = "  — mailbox registers: " + ", ".join(
                    r.name.lower() for r in pd.regs)
            lines.append(f"  • pin-def {pd.index}: {pins} {what}{extra}{regs}")

    # resource summary
    budget = L.LIMITS["PINS_HD"] if tgt == "HD" else L.LIMITS["PINS_NOHD"]
    lines.append("")
    lines.append("Footprint:")
    lines.append(f"  • {model.pins_used}/{budget} pins")
    lines.append(f"  • {model.volatile_used}/248 bytes of mailbox RAM used by registers")
    lines.append(f"  • {model.instruction_count}/{L.LIMITS['MAX_INSTRUCTIONS']} instructions")
    if model.payload_bytes:
        lines.append(f"  • {model.payload_bytes} bytes of in-file data (LED frames / "
                     f"I²C payloads)")
    return "\n".join(lines)


def descriptor_view(model):
    """Human-readable twin of the wire capability descriptor (spec §5.4/§4.5).
    This is exactly what the gateware serves over 0x6E with WINKIND=0, so the
    exported doc equals the host's on-wire ABI."""
    lines = ["Capability descriptor (host reads it over 0x6E, WINKIND=0 — spec §5.4):",
             f"  ABI_VER = 1    PINDEF_COUNT = {len(model.pindefs)}", ""]
    for pd in model.pindefs:
        phys = 0
        for p in pd.pins:
            if p in L.PINS:
                phys |= 1 << L.PINS.index(p)
        tcode = L.PIN_TYPE_CODES.get(pd.ptype, 0)
        base = pd.bank_off
        lines.append(f"  pin-def {pd.index}:")
        lines.append(f"    TYPE=0x{tcode:02X} ({pd.ptype})   "
                     f"PHYS_PINS=0x{phys:02X} ({'/'.join(pd.pins)})")
        lines.append(f"    CMD_OFF=0x{base:02X}  DOORBELL_OFF=0x{base+1:02X}  "
                     f"BANK_OFF=0x{base:02X}  BANK_LEN={pd.bank_len}  "
                     f"REG_COUNT={len(pd.regs)}")
        for rid, r in enumerate(pd.regs):
            lines.append(f"      REG {rid} {r.name.lower():<10} "
                         f"REG_OFF={r.off_in_bank}  REG_WIDTH={r.width}  "
                         f"REG_FLAGS=0x03 (RW)")
        lines.append("")
    return "\n".join(lines).rstrip()


def host_contract(model):
    """What the Xbox-side app must know to drive this script's mailbox."""
    banks = [pd for pd in model.pindefs if pd.regs]
    if not banks:
        return ("This script declares no mailbox registers, so Xbox software can't "
                "send it anything — it runs on its own.\n\n"
                "To let a game talk to it, add REG lines under a USES, e.g.:\n"
                "    USES EXP4 AS WS2812 COUNT 8\n"
                "      REG color WIDTH 3")

    out = ["Your Xbox app talks to this device over SMBus at 0x6E.",
           "Registers live in the mailbox at these volatile offsets:", ""]
    for pd in banks:
        base = pd.bank_off
        out.append(f"pin-def {pd.index}  ({pd.ptype}, {'/'.join(pd.pins)})")
        out.append(f"    CMD       @ 0x{base:02X}   (command code you choose)")
        out.append(f"    DOORBELL  @ 0x{base+1:02X}   "
                   f"(0 IDLE · 1 PENDING · 2 BUSY · 3 READY)")
        for rid, r in enumerate(pd.regs):
            a = base + r.off_in_bank
            span = f"0x{a:02X}" if r.width == 1 else f"0x{a:02X}–0x{a+r.width-1:02X}"
            out.append(f"    reg {rid} {r.name.lower():<10} @ {span}  "
                       f"({r.width} byte{'s' if r.width > 1 else ''}, read/write)")
        out.append("")
    out.append("Doorbell handshake (for a coherent multi-byte command):")
    out.append("  1. write the register bytes")
    out.append("  2. write CMD (your command code)")
    out.append("  3. write DOORBELL = 1 (PENDING)")
    out.append("  4. wait until DOORBELL = 3 (READY), read any reply, then write 0 (IDLE)")
    out.append("For a single continuously-changing byte you can skip the doorbell and "
               "just write the register (the script level-polls it).")
    return "\n".join(out)