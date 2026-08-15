"""
EOS Script language definition — the single source of truth for the editor.

Mirrors the frozen EOS Expansion System spec (v-freeze) and the EOS Script
Programming Guide. Every constant here is a spec limit; every command entry is
the authoring syntax. The linter validates against these; the GUI shows them as
IntelliSense-style hints and completions.
"""

# --------------------------------------------------------------------------
# Frozen limits (spec §4.9, §4.10, §5)
# --------------------------------------------------------------------------
LIMITS = {
    "PINS_HD": 5,              # usable pins with the HD addon (EXP4..EXP8)
    "PINS_NOHD": 8,            # usable pins without HD (EXP1..EXP8)
    "MAX_PINDEFS": 8,
    "MAX_INSTRUCTIONS": 4096,
    "MAX_TEXT_LEN": 0x1FFF0,   # 131056 bytes
    "MAX_PAYLOAD_DECODED": 16 * 1024,   # 16 KB total in-file payload
    "MAX_DEF": 64,
    "MAX_DATA": 32,
    "MAX_NAME_LEN": 16,
    "VOLATILE_SIZE": 256,
    "VOLATILE_USABLE_TOP": 0xF8,   # 0x00..0xF7 usable; 0xF8..0xFF engine-reserved
    "MAX_BANK": 32,                # 2 + sum(REG widths) <= 32
    "MAX_REGS_PER_PINDEF": 16,
    "MAX_READ_SCRATCH": 64,
    "WS_MAX_COUNT": 1365,          # 1365 * 3 = 4095 <= 4096 buffer
    "WS_MAX_FRAME_BYTES": 4095,
    "I2CW_DATA_MAX": 256,
    "I2CR_MAX": 64,
    "DELAY_MAX": 65535,
    "PWM_FREQ_MIN": 1,
    "PWM_FREQ_MAX": 100_000,
    "PWM_DUTY_MAX": 255,
    "LOOP_NEST_MAX": 4,
    "NUM_REGISTERS": 8,            # R0..R7
    "RESULT_SLOT": 0xFF,
}

RESULT_CODES = {0: "OK", 1: "NACK_ADDR", 2: "NACK_DATA", 3: "TIMEOUT", 4: "STUCK"}

# --------------------------------------------------------------------------
# Pins (spec §1)
# --------------------------------------------------------------------------
PINS = ["EXP1", "EXP2", "EXP3", "EXP4", "EXP5", "EXP6", "EXP7", "EXP8"]
PIN_FPGA = {"EXP1": 52, "EXP2": 53, "EXP3": 49, "EXP4": 55,
            "EXP5": 48, "EXP6": 51, "EXP7": 54, "EXP8": 56}
HD_RESERVED = {"EXP1", "EXP2", "EXP3"}   # reserved by the HD addon under TARGET HD

# --------------------------------------------------------------------------
# Pin types
# --------------------------------------------------------------------------
PIN_TYPES = ["GPIO_IN", "GPIO_OUT", "PWM", "WS2812", "I2C"]
# Frozen descriptor TYPE codes (spec §4.5) — the wire enum the host reads.
PIN_TYPE_CODES = {"GPIO_IN": 0x00, "GPIO_OUT": 0x01, "PWM": 0x02,
                  "WS2812": 0x03, "I2C": 0x04, "1WIRE": 0x05}
RESERVED_TYPES = ["1WIRE"]
OUTPUT_TYPES_NEED_INIT_SAFE = {"GPIO_OUT", "PWM"}

REGISTERS = [f"R{i}" for i in range(LIMITS["NUM_REGISTERS"])]
CMP_OPS = ["EQ", "NE", "LT", "GT"]
DELAY_UNITS = ["MS", "US"]

# --------------------------------------------------------------------------
# Commands (spec §4.3, guide §7) — signature + description for IntelliSense.
# 'kind' groups them in the reference panel.
# --------------------------------------------------------------------------
COMMANDS = {
    "NOP":     {"sig": "NOP",
                "desc": "Do nothing (placeholder / padding).", "kind": "flow"},
    "SET":     {"sig": "SET <pin> <0|1|Rn>",
                "desc": "Drive a GPIO_OUT pin low/high (literal 0/1 or a register).",
                "kind": "pin"},
    "GET":     {"sig": "GET <pin> <Rn>",
                "desc": "Read a GPIO_IN pin (0/1) into a register.", "kind": "pin"},
    "DELAY":   {"sig": "DELAY <count> [MS|US]",
                "desc": "Blocking wait. count 0-65535. Default unit MS.", "kind": "timing"},
    "PWM":     {"sig": "PWM <pin> <duty|Rn> <freq_hz>",
                "desc": "Continuous PWM. duty 0-255 (0 stops). freq 1 Hz-100 kHz.",
                "kind": "pin"},
    "WS":      {"sig": "WS <pin> <dataname>   |   WS <pin> VOL <off> <len>",
                "desc": "Push a WS2812 GRB frame. Length must equal COUNT x 3.",
                "kind": "protocol"},
    "I2CW":    {"sig": "I2CW <addr> <dataname>   |   I2CW <addr> VOL <off> <len>",
                "desc": "I2C write. In-file DATA <=256 B, or live bytes from volatile.",
                "kind": "protocol"},
    "I2CR":    {"sig": "I2CR <addr> <len> <dstoff>",
                "desc": "I2C read <=64 B into volatile at dstoff. Result in slot 0xFF.",
                "kind": "protocol"},
    "GETMAIL": {"sig": "GETMAIL <idx> <Rn>",
                "desc": "Read volatile byte idx (0-255) into a register.", "kind": "mailbox"},
    "SETMAIL": {"sig": "SETMAIL <idx> <Rn|literal>",
                "desc": "Write a register or a literal (0-255) into volatile byte idx.",
                "kind": "mailbox"},
    "LOOP":    {"sig": "LOOP [<count>]",
                "desc": "Begin a loop. 0/omitted = forever. Nest up to 4 deep.",
                "kind": "flow"},
    "ENDLOOP": {"sig": "ENDLOOP",
                "desc": "End the innermost LOOP.", "kind": "flow"},
    "IFMAIL":  {"sig": "IFMAIL <idx> <EQ|NE|LT|GT> <val> <skip>",
                "desc": "If the test is FALSE, skip the next <skip> instructions.",
                "kind": "flow"},
    "END":     {"sig": "END",
                "desc": "Wrap execution to the first instruction (forever loop).",
                "kind": "flow"},
}

RESERVED_COMMANDS = {
    "OW_RESET": "1-Wire is reserved for V1.1 and not available in V1.",
    "OW_WR": "1-Wire is reserved for V1.1 and not available in V1.",
    "OW_RD": "1-Wire is reserved for V1.1 and not available in V1.",
}

# --------------------------------------------------------------------------
# Directives (spec §3b, guide §5, §4) — signature + description.
# --------------------------------------------------------------------------
DIRECTIVES = {
    "TARGET":   {"sig": "TARGET HD|NOHD",
                 "desc": "Hardware config (first line). HD reserves EXP1-EXP3.",
                 "kind": "decl"},
    "USES":     {"sig": "USES <pin> AS <TYPE> [INIT v] [SAFE v]   (WS2812: COUNT n; I2C: two pins)",
                 "desc": "Declare a pin-def. GPIO_OUT/PWM need INIT+SAFE; WS2812 needs COUNT.",
                 "kind": "decl"},
    "REG":      {"sig": "REG <name> WIDTH <n>",
                 "desc": "Declare a mailbox register in the current pin-def. <=16/pin-def.",
                 "kind": "decl"},
    "I2C_ADDR": {"sig": "I2C_ADDR <a> [<a> ...]",
                 "desc": "Optional device-address hint for collision warnings.",
                 "kind": "decl"},
    "DEF":      {"sig": "DEF <name> <number>",
                 "desc": "Named constant (equate). Use for offsets, codes, values.",
                 "kind": "decl"},
    "DATA":     {"sig": "DATA <name> <hex>",
                 "desc": "In-file payload as compact hex (2 chars/byte).",
                 "kind": "decl"},
}

# Keywords used inside directives/commands (for completion & highlighting)
SUBKEYWORDS = ["AS", "INIT", "SAFE", "COUNT", "WIDTH", "VOL", "HD", "NOHD",
               "MS", "US", "EQ", "NE", "LT", "GT"]

ALL_COMMAND_NAMES = list(COMMANDS.keys())
ALL_DIRECTIVE_NAMES = list(DIRECTIVES.keys())

# Doorbell state enum (guide §9.3) — surfaced as hints for SETMAIL on a doorbell byte
DOORBELL_STATES = {0: "IDLE", 1: "PENDING", 2: "BUSY", 3: "READY"}


def signature_of(word):
    """Return an IntelliSense signature+desc for a command/directive keyword."""
    w = word.upper()
    if w in COMMANDS:
        c = COMMANDS[w]
        return f"{c['sig']}\n{c['desc']}"
    if w in DIRECTIVES:
        d = DIRECTIVES[w]
        return f"{d['sig']}\n{d['desc']}"
    if w in RESERVED_COMMANDS:
        return f"{w}  (RESERVED)\n{RESERVED_COMMANDS[w]}"
    return None


def completion_words(defs=None, datas=None, regs=None):
    """All words the completer should offer."""
    words = list(ALL_COMMAND_NAMES) + list(ALL_DIRECTIVE_NAMES)
    words += PINS + REGISTERS + PIN_TYPES + SUBKEYWORDS
    words += list(defs or []) + list(datas or []) + list(regs or [])
    # de-dup, keep stable order
    seen, out = set(), []
    for w in words:
        if w not in seen:
            seen.add(w); out.append(w)
    return out