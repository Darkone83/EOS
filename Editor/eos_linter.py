"""
EOS Script linter — parser + validator (no GUI).

This is the safety core of the editor: it enforces every rule from the frozen
EOS Expansion System spec so a script that lints clean is guaranteed in-bounds
for the gateware. It returns:

  * diagnostics : list[Diagnostic]  (errors + warnings, with line numbers)
  * model       : ScriptModel       (pin-defs, volatile layout, counts) for the GUI

Two passes, matching the gateware's load model:
  pass 1  — collect TARGET / USES / REG / DEF / DATA; build symbols + volatile layout
  pass 2  — validate instructions (operands, types, flow, bounds)
"""

from dataclasses import dataclass, field
import eos_language as L


# --------------------------------------------------------------------------
@dataclass
class Diagnostic:
    line: int                # 1-based source line
    severity: str            # "error" | "warning"
    message: str
    col: int = 0
    hint: str = ""           # optional "how to fix" note for the UI

    def __str__(self):
        return f"{self.severity.upper()} line {self.line}: {self.message}"


@dataclass
class Register:
    name: str
    width: int
    off_in_bank: int         # offset from BANK_OFF (first REG = 2)


@dataclass
class PinDef:
    index: int
    ptype: str
    pins: list               # e.g. ["EXP4"] or ["EXP5","EXP6"] for I2C
    line: int
    count: int = None        # WS2812
    init: int = None
    safe: int = None
    regs: list = field(default_factory=list)
    bank_off: int = 0
    bank_len: int = 2        # CMD + DOORBELL minimum


@dataclass
class ScriptModel:
    target: str = None                     # "HD" | "NOHD"
    pindefs: list = field(default_factory=list)
    defs: dict = field(default_factory=dict)     # name -> value
    datas: dict = field(default_factory=dict)    # name -> byte length
    instruction_count: int = 0
    text_len: int = 0
    payload_bytes: int = 0
    pins_used: int = 0
    volatile_used: int = 0                 # bytes consumed by banks

    def pin_owner(self, pin):
        for pd in self.pindefs:
            if pin in pd.pins:
                return pd
        return None


# --------------------------------------------------------------------------
def _strip_comment(line):
    h = line.find("#")
    return line if h < 0 else line[:h]


def _parse_int(tok):
    """Return int or None. Accepts decimal or 0x hex."""
    try:
        t = tok.lower()
        if t.startswith("0x"):
            return int(t, 16)
        return int(t, 10)
    except (ValueError, AttributeError):
        return None


def _tokenize(text):
    """Yield (line_no, tokens, raw) for non-empty, de-commented lines."""
    for i, raw in enumerate(text.splitlines(), start=1):
        body = _strip_comment(raw).strip()
        if not body:
            continue
        yield i, body.split(), raw


def _hex_len_bytes(tokens):
    """Decode a DATA hex payload (whitespace-grouped) -> byte count, or None if bad."""
    s = "".join(tokens)
    if len(s) == 0 or len(s) % 2 != 0:
        return None
    try:
        int(s, 16)
    except ValueError:
        return None
    return len(s) // 2


# --------------------------------------------------------------------------
class Linter:
    def __init__(self):
        self.diags = []
        self.model = ScriptModel()

    def err(self, line, msg, col=0, hint=""):
        self.diags.append(Diagnostic(line, "error", msg, col, hint))

    def warn(self, line, msg, col=0, hint=""):
        self.diags.append(Diagnostic(line, "warning", msg, col, hint))

    # ---- value resolution helpers (after DEFs collected) ------------------
    def resolve(self, tok):
        """int literal or DEF name -> value; None if unresolvable."""
        v = _parse_int(tok)
        if v is not None:
            return v
        key = tok.upper()
        if key in self.model.defs:
            return self.model.defs[key]
        return None

    @staticmethod
    def is_register(tok):
        return tok.upper() in L.REGISTERS

    @staticmethod
    def is_pin(tok):
        return tok.upper() in L.PINS

    # ======================================================================
    def lint(self, text):
        self.diags = []
        self.model = ScriptModel()
        self.model.text_len = len(text.encode("utf-8", "replace"))

        lines = list(_tokenize(text))

        self._pass1_declarations(lines)
        self._compute_volatile_layout()
        self._pass2_instructions(lines)
        self._global_checks()

        self.diags.sort(key=lambda d: (d.line, 0 if d.severity == "error" else 1))
        return self.diags, self.model

    # ---- pass 1 -----------------------------------------------------------
    def _pass1_declarations(self, lines):
        m = self.model
        current_pindef = None
        seen_target = False
        seen_instruction = False
        name_registry = {}   # upper name -> ("DEF"/"DATA", line)

        # First locate TARGET (must be present; should be first).
        for ln, toks, raw in lines:
            if toks[0].upper() == "TARGET":
                if seen_target:
                    self.err(ln, "Duplicate TARGET directive.")
                    continue
                seen_target = True
                if len(toks) != 2 or toks[1].upper() not in ("HD", "NOHD"):
                    self.err(ln, "TARGET must be 'TARGET HD' or 'TARGET NOHD'.")
                else:
                    m.target = toks[1].upper()

        if not seen_target:
            self.err(1, "Missing 'TARGET HD' or 'TARGET NOHD' (must be the first directive).",
                     hint="Add 'TARGET NOHD' as the first line (or 'TARGET HD' if the HD addon is fitted).")

        # Walk declarations in order.
        for ln, toks, raw in lines:
            head = toks[0].upper()

            if head == "TARGET":
                continue  # handled above

            elif head == "USES":
                seen_instruction and self.warn(
                    ln, "USES appears after an instruction; declarations belong in the header.")
                current_pindef = self._parse_uses(ln, toks)
                if current_pindef:
                    m.pindefs.append(current_pindef)

            elif head == "REG":
                if current_pindef is None:
                    self.err(ln, "REG must follow a USES (it belongs to a pin-def).")
                else:
                    self._parse_reg(ln, toks, current_pindef, name_registry)

            elif head == "I2C_ADDR":
                for a in toks[1:]:
                    if _parse_int(a) is None:
                        self.err(ln, f"I2C_ADDR expects numeric addresses; got '{a}'.")

            elif head == "DEF":
                self._parse_def(ln, toks, name_registry)

            elif head == "DATA":
                self._parse_data(ln, toks, name_registry)

            else:
                # An instruction line (validated in pass 2). Just mark ordering.
                seen_instruction = True

        # limit: pin-defs
        if len(m.pindefs) > L.LIMITS["MAX_PINDEFS"]:
            self.err(m.pindefs[L.LIMITS["MAX_PINDEFS"]].line,
                     f"Too many pin-defs ({len(m.pindefs)}); max is {L.LIMITS['MAX_PINDEFS']}.")

    def _parse_uses(self, ln, toks):
        # Forms:
        #   USES <pin> AS <TYPE> [INIT v] [SAFE v]
        #   USES <pin> AS WS2812 COUNT <n>
        #   USES <scl> <sda> AS I2C
        if "AS" not in [t.upper() for t in toks]:
            self.err(ln, "USES needs an 'AS <TYPE>' clause.")
            return None
        as_i = [t.upper() for t in toks].index("AS")
        pin_toks = toks[1:as_i]
        rest = toks[as_i + 1:]
        if not rest:
            self.err(ln, "USES ... AS is missing a type.")
            return None
        ptype = rest[0].upper()
        opts = rest[1:]

        if ptype in L.RESERVED_TYPES:
            self.err(ln, f"Type {ptype} is reserved for a later version; not available in V1.")
            return None
        if ptype not in L.PIN_TYPES:
            self.err(ln, f"Unknown pin type '{ptype}'. Valid: {', '.join(L.PIN_TYPES)}.")
            return None

        # pins
        pins = []
        for pt in pin_toks:
            if not self.is_pin(pt):
                self.err(ln, f"'{pt}' is not a pin (EXP1..EXP8).")
            else:
                pins.append(pt.upper())

        pd = PinDef(index=len(self.model.pindefs), ptype=ptype, pins=pins, line=ln)

        if ptype == "I2C":
            if len(pins) != 2:
                self.err(ln, "I2C uses exactly two pins: 'USES <scl> <sda> AS I2C'.")
        else:
            if len(pins) != 1:
                self.err(ln, f"{ptype} uses exactly one pin.")

        # options: INIT / SAFE / COUNT
        i = 0
        while i < len(opts):
            key = opts[i].upper()
            if key in ("INIT", "SAFE", "COUNT"):
                if i + 1 >= len(opts):
                    self.err(ln, f"{key} needs a value.")
                    break
                val = _parse_int(opts[i + 1])
                if val is None:
                    self.err(ln, f"{key} value must be a number; got '{opts[i+1]}'.")
                else:
                    if key == "INIT":
                        pd.init = val
                    elif key == "SAFE":
                        pd.safe = val
                    else:
                        pd.count = val
                i += 2
            else:
                self.err(ln, f"Unexpected token '{opts[i]}' in USES.")
                i += 1

        # type-specific requirements
        if ptype in L.OUTPUT_TYPES_NEED_INIT_SAFE:
            if pd.init is None or pd.safe is None:
                self.err(ln, f"{ptype} must declare both INIT and SAFE "
                             f"(e.g. 'INIT 0 SAFE 0').",
                         hint="INIT is the value at startup; SAFE is the value on fault. "
                              "For an LED, 'INIT 0 SAFE 0' (off) is usually right.")
            maxv = L.LIMITS["PWM_DUTY_MAX"] if ptype == "PWM" else 1
            for label, v in (("INIT", pd.init), ("SAFE", pd.safe)):
                if v is not None and not (0 <= v <= maxv):
                    self.err(ln, f"{label} for {ptype} must be 0..{maxv}.")
        if ptype == "WS2812":
            if pd.count is None:
                self.err(ln, "WS2812 must declare COUNT <n> (LED count, 1..1365).",
                         hint="Add COUNT with your strip length, e.g. 'USES EXP4 AS WS2812 COUNT 8'.")
            elif not (1 <= pd.count <= L.LIMITS["WS_MAX_COUNT"]):
                self.err(ln, f"WS2812 COUNT must be 1..{L.LIMITS['WS_MAX_COUNT']}.")
        return pd

    def _parse_reg(self, ln, toks, pindef, name_registry):
        # REG <name> WIDTH <n>
        if len(toks) != 4 or toks[2].upper() != "WIDTH":
            self.err(ln, "REG syntax is 'REG <name> WIDTH <n>'.")
            return
        name = toks[1]
        width = _parse_int(toks[3])
        self._check_name(ln, name, "REG", name_registry, scope=pindef)
        if width is None or width < 1:
            self.err(ln, "REG WIDTH must be a positive number.")
            return
        pindef.regs.append(Register(name.upper(), width, 0))
        if len(pindef.regs) > L.LIMITS["MAX_REGS_PER_PINDEF"]:
            self.err(ln, f"Too many registers in one pin-def "
                         f"(max {L.LIMITS['MAX_REGS_PER_PINDEF']}).")

    def _parse_def(self, ln, toks, name_registry):
        if len(toks) != 3:
            self.err(ln, "DEF syntax is 'DEF <name> <number>'.")
            return
        name, val = toks[1], _parse_int(toks[2])
        self._check_name(ln, name, "DEF", name_registry)
        if val is None:
            self.err(ln, f"DEF value must be a number; got '{toks[2]}'.")
            return
        self.model.defs[name.upper()] = val
        if len([k for k in name_registry.values() if k[0] == "DEF"]) > L.LIMITS["MAX_DEF"]:
            self.err(ln, f"Too many DEF constants (max {L.LIMITS['MAX_DEF']}).")

    def _parse_data(self, ln, toks, name_registry):
        if len(toks) < 3:
            self.err(ln, "DATA syntax is 'DATA <name> <hex>'.")
            return
        name = toks[1]
        self._check_name(ln, name, "DATA", name_registry)
        nbytes = _hex_len_bytes(toks[2:])
        if nbytes is None:
            self.err(ln, "DATA payload must be an even-length hex string "
                         "(e.g. 'DATA red 00FF00').")
            return
        self.model.datas[name.upper()] = nbytes
        self.model.payload_bytes += nbytes
        if len([k for k in name_registry.values() if k[0] == "DATA"]) > L.LIMITS["MAX_DATA"]:
            self.err(ln, f"Too many DATA blocks (max {L.LIMITS['MAX_DATA']}).")

    def _check_name(self, ln, name, kind, name_registry, scope=None):
        up = name.upper()
        if len(name) > L.LIMITS["MAX_NAME_LEN"]:
            self.err(ln, f"Name '{name}' is too long (max {L.LIMITS['MAX_NAME_LEN']} chars).")
        # REG names are scoped per pin-def; DEF/DATA are global
        if kind == "REG":
            for r in (scope.regs if scope else []):
                if r.name == up:
                    self.err(ln, f"Duplicate register name '{name}' in this pin-def.")
            return
        if up in name_registry:
            prev_kind, prev_ln = name_registry[up]
            self.err(ln, f"Duplicate {kind} name '{name}' "
                         f"(already a {prev_kind} on line {prev_ln}).")
        else:
            name_registry[up] = (kind, ln)
        if up in {t.upper() for t in (L.ALL_COMMAND_NAMES + L.ALL_DIRECTIVE_NAMES
                                      + L.PINS + L.REGISTERS + L.SUBKEYWORDS)}:
            self.warn(ln, f"Name '{name}' shadows a keyword; consider renaming.")

    # ---- volatile layout (deterministic; guide §9.1, spec §5.4) -----------
    def _compute_volatile_layout(self):
        off = 0
        top = L.LIMITS["VOLATILE_USABLE_TOP"]
        for pd in self.model.pindefs:
            pd.bank_off = off
            cur = 2  # CMD + DOORBELL
            for r in pd.regs:
                r.off_in_bank = cur
                cur += r.width
            pd.bank_len = cur
            if pd.bank_len > L.LIMITS["MAX_BANK"]:
                self.err(pd.line, f"Register bank for pin-def {pd.index} is "
                                  f"{pd.bank_len} B; max is {L.LIMITS['MAX_BANK']} "
                                  f"(2 + sum of REG widths).",
                     hint="Reduce register widths or split across fewer registers (2 bytes are reserved for CMD+DOORBELL).")
            off += pd.bank_len
        self.model.volatile_used = off
        if off > top:
            last = self.model.pindefs[-1] if self.model.pindefs else None
            self.err(last.line if last else 1,
                     f"Register banks need {off} B but only {top} B of volatile RAM "
                     f"is usable (0x00..0xF7). Reduce registers/pin-defs.")

    # ---- pass 2 -----------------------------------------------------------
    def _pass2_instructions(self, lines):
        # Build the ordered instruction list (skip declarations).
        decl_heads = set(L.ALL_DIRECTIVE_NAMES)
        instrs = []
        for ln, toks, raw in lines:
            if toks[0].upper() in decl_heads:
                continue
            instrs.append((ln, toks))
        self.model.instruction_count = len(instrs)

        if len(instrs) > L.LIMITS["MAX_INSTRUCTIONS"]:
            self.err(instrs[L.LIMITS["MAX_INSTRUCTIONS"]][0],
                     f"Too many instructions ({len(instrs)}); "
                     f"max {L.LIMITS['MAX_INSTRUCTIONS']}.")

        # loop-depth per instruction (for IFMAIL boundary checks) + matching
        loop_stack = []
        depth = [0] * len(instrs)
        kind = [""] * len(instrs)   # "LOOP"/"ENDLOOP"/"" per instr
        for i, (ln, toks) in enumerate(instrs):
            head = toks[0].upper()
            if head == "LOOP":
                depth[i] = len(loop_stack)
                kind[i] = "LOOP"
                loop_stack.append((i, ln))
                if len(loop_stack) > L.LIMITS["LOOP_NEST_MAX"]:
                    self.err(ln, f"LOOP nested deeper than {L.LIMITS['LOOP_NEST_MAX']}.")
            elif head == "ENDLOOP":
                if not loop_stack:
                    self.err(ln, "ENDLOOP without a matching LOOP.",
                    hint="Remove this ENDLOOP or add a LOOP above it.")
                    depth[i] = 0
                else:
                    loop_stack.pop()
                    depth[i] = len(loop_stack)
                kind[i] = "ENDLOOP"
            else:
                depth[i] = len(loop_stack)
        for _, oln in loop_stack:
            self.err(oln, "LOOP without a matching ENDLOOP.",
                     hint="Every LOOP needs an ENDLOOP to close it.")

        # validate each instruction
        for i, (ln, toks) in enumerate(instrs):
            self._validate_instruction(ln, toks, i, instrs, kind)

    def _validate_instruction(self, ln, toks, idx, instrs, kind):
        head = toks[0].upper()
        args = toks[1:]

        if head in L.RESERVED_COMMANDS:
            self.err(ln, L.RESERVED_COMMANDS[head])
            return
        if head not in L.COMMANDS:
            self.err(ln, f"Unknown command '{toks[0]}'.",
                     hint="Check spelling. Valid commands: " + ", ".join(L.ALL_COMMAND_NAMES) + ".")
            return

        handler = getattr(self, f"_c_{head.lower()}", None)
        if handler:
            handler(ln, args, idx, instrs, kind)

    # ---- per-command validators -------------------------------------------
    def _need_argc(self, ln, head, args, n):
        if len(args) != n:
            self.err(ln, f"{head} expects {n} operand(s), got {len(args)}.")
            return False
        return True

    def _pin_of_type(self, ln, tok, wanted, cmd):
        if not self.is_pin(tok):
            self.err(ln, f"{cmd}: '{tok}' is not a pin (EXP1..EXP8).")
            return None
        pd = self.model.pin_owner(tok.upper())
        if pd is None:
            self.err(ln, f"{cmd}: pin {tok.upper()} is not declared with USES.")
            return None
        if pd.ptype != wanted:
            self.err(ln, f"{cmd} needs a {wanted} pin, but {tok.upper()} is {pd.ptype}.")
            return None
        return pd

    def _check_reg(self, ln, tok, cmd):
        if not self.is_register(tok):
            self.err(ln, f"{cmd}: '{tok}' is not a register (R0..R7).")
            return False
        return True

    def _check_range(self, ln, tok, lo, hi, label):
        v = self.resolve(tok)
        if v is None:
            self.err(ln, f"{label}: '{tok}' is not a number or known DEF.")
            return None
        if not (lo <= v <= hi):
            self.err(ln, f"{label} must be {lo}..{hi} (got {v}).")
        return v

    def _c_nop(self, ln, args, idx, instrs, kind):
        self._need_argc(ln, "NOP", args, 0)

    def _c_set(self, ln, args, idx, instrs, kind):
        if not self._need_argc(ln, "SET", args, 2):
            return
        self._pin_of_type(ln, args[0], "GPIO_OUT", "SET")
        if not self.is_register(args[1]):
            v = self.resolve(args[1])
            if v is None or v not in (0, 1):
                self.err(ln, "SET value must be 0, 1, or a register.")

    def _c_get(self, ln, args, idx, instrs, kind):
        if not self._need_argc(ln, "GET", args, 2):
            return
        self._pin_of_type(ln, args[0], "GPIO_IN", "GET")
        self._check_reg(ln, args[1], "GET")

    def _c_delay(self, ln, args, idx, instrs, kind):
        if len(args) not in (1, 2):
            self.err(ln, "DELAY syntax: 'DELAY <count> [MS|US]'.")
            return
        self._check_range(ln, args[0], 0, L.LIMITS["DELAY_MAX"], "DELAY count")
        if len(args) == 2 and args[1].upper() not in L.DELAY_UNITS:
            self.err(ln, "DELAY unit must be MS or US.")

    def _c_pwm(self, ln, args, idx, instrs, kind):
        if not self._need_argc(ln, "PWM", args, 3):
            return
        self._pin_of_type(ln, args[0], "PWM", "PWM")
        if not self.is_register(args[1]):
            self._check_range(ln, args[1], 0, L.LIMITS["PWM_DUTY_MAX"], "PWM duty")
        self._check_range(ln, args[2], L.LIMITS["PWM_FREQ_MIN"],
                          L.LIMITS["PWM_FREQ_MAX"], "PWM frequency")

    def _c_ws(self, ln, args, idx, instrs, kind):
        # WS <pin> <dataname>  |  WS <pin> VOL <off> <len>
        if len(args) < 2:
            self.err(ln, "WS syntax: 'WS <pin> <dataname>' or 'WS <pin> VOL <off> <len>'.")
            return
        pd = self._pin_of_type(ln, args[0], "WS2812", "WS")
        expect = (pd.count * 3) if (pd and pd.count) else None
        if args[1].upper() == "VOL":
            if len(args) != 4:
                self.err(ln, "WS VOL syntax: 'WS <pin> VOL <off> <len>'.")
                return
            off = self._check_range(ln, args[2], 0, 0xFF, "WS VOL off")
            length = self.resolve(args[3])
            if length is None:
                self.err(ln, f"WS VOL len: '{args[3]}' is not a number/DEF.")
            else:
                if expect is not None and length != expect:
                    self.err(ln, f"WS frame length must equal COUNT x 3 = {expect} "
                                 f"(got {length}).")
                if off is not None and off + length > L.LIMITS["VOLATILE_USABLE_TOP"]:
                    self.err(ln, f"WS VOL off+len exceeds usable volatile "
                                 f"(0x00..0xF7).")
        else:
            if len(args) != 2:
                self.err(ln, "WS in-file syntax: 'WS <pin> <dataname>'.")
                return
            name = args[1].upper()
            if name not in self.model.datas:
                self.err(ln, f"WS references unknown DATA '{args[1]}'.")
            else:
                nbytes = self.model.datas[name]
                if expect is not None and nbytes != expect:
                    self.err(ln, f"DATA '{args[1]}' is {nbytes} B but WS needs "
                                 f"COUNT x 3 = {expect} B.",
                             hint="A WS frame is 3 bytes (G,R,B) per LED. Match your DATA length to COUNT x 3.")
                if nbytes > L.LIMITS["WS_MAX_FRAME_BYTES"]:
                    self.err(ln, f"WS frame {nbytes} B exceeds max "
                                 f"{L.LIMITS['WS_MAX_FRAME_BYTES']} B.")

    def _require_i2c_bus(self, ln, cmd):
        if not any(pd.ptype == "I2C" for pd in self.model.pindefs):
            self.err(ln, f"{cmd} needs an I2C bus — declare 'USES <scl> <sda> AS I2C'.")

    def _c_i2cw(self, ln, args, idx, instrs, kind):
        # I2CW <addr> <dataname>  |  I2CW <addr> VOL <off> <len>
        if len(args) < 2:
            self.err(ln, "I2CW syntax: 'I2CW <addr> <dataname>' or "
                         "'I2CW <addr> VOL <off> <len>'.")
            return
        self._require_i2c_bus(ln, "I2CW")
        self._check_range(ln, args[0], 0, 0x7F, "I2CW address")
        if args[1].upper() == "VOL":
            if len(args) != 4:
                self.err(ln, "I2CW VOL syntax: 'I2CW <addr> VOL <off> <len>'.")
                return
            off = self._check_range(ln, args[2], 0, 0xFF, "I2CW VOL off")
            length = self.resolve(args[3])
            if length is None:
                self.err(ln, f"I2CW VOL len: '{args[3]}' is not a number/DEF.")
            elif off is not None and off + length > L.LIMITS["VOLATILE_USABLE_TOP"]:
                self.err(ln, "I2CW VOL off+len exceeds usable volatile (0x00..0xF7).")
        else:
            if len(args) != 2:
                self.err(ln, "I2CW in-file syntax: 'I2CW <addr> <dataname>'.")
                return
            name = args[1].upper()
            if name not in self.model.datas:
                self.err(ln, f"I2CW references unknown DATA '{args[1]}'.")
            elif self.model.datas[name] > L.LIMITS["I2CW_DATA_MAX"]:
                self.err(ln, f"I2CW in-file payload {self.model.datas[name]} B exceeds "
                             f"max {L.LIMITS['I2CW_DATA_MAX']} B.")

    def _c_i2cr(self, ln, args, idx, instrs, kind):
        if not self._need_argc(ln, "I2CR", args, 3):
            return
        self._require_i2c_bus(ln, "I2CR")
        self._check_range(ln, args[0], 0, 0x7F, "I2CR address")
        length = self._check_range(ln, args[1], 1, L.LIMITS["I2CR_MAX"], "I2CR length")
        dst = self._check_range(ln, args[2], 0, 0xFF, "I2CR dstoff")
        if length is not None and dst is not None:
            if dst + length > L.LIMITS["VOLATILE_USABLE_TOP"]:
                self.err(ln, "I2CR destination (dstoff+len) exceeds usable volatile "
                             "(must be <= 0xF8).")

    def _c_getmail(self, ln, args, idx, instrs, kind):
        if not self._need_argc(ln, "GETMAIL", args, 2):
            return
        self._check_range(ln, args[0], 0, 255, "GETMAIL idx")
        self._check_reg(ln, args[1], "GETMAIL")

    def _c_setmail(self, ln, args, idx, instrs, kind):
        if not self._need_argc(ln, "SETMAIL", args, 2):
            return
        self._check_range(ln, args[0], 0, 255, "SETMAIL idx")
        if not self.is_register(args[1]):
            self._check_range(ln, args[1], 0, 255, "SETMAIL value")

    def _c_loop(self, ln, args, idx, instrs, kind):
        if len(args) > 1:
            self.err(ln, "LOOP syntax: 'LOOP' or 'LOOP <count>'.")
            return
        if len(args) == 1 and self.resolve(args[0]) is None:
            self.err(ln, f"LOOP count '{args[0]}' is not a number/DEF.")

    def _c_endloop(self, ln, args, idx, instrs, kind):
        self._need_argc(ln, "ENDLOOP", args, 0)

    def _c_end(self, ln, args, idx, instrs, kind):
        self._need_argc(ln, "END", args, 0)

    def _c_ifmail(self, ln, args, idx, instrs, kind):
        if not self._need_argc(ln, "IFMAIL", args, 4):
            return
        self._check_range(ln, args[0], 0, 255, "IFMAIL idx")
        if args[1].upper() not in L.CMP_OPS:
            self.err(ln, f"IFMAIL comparison must be one of {', '.join(L.CMP_OPS)}.")
        self._check_range(ln, args[2], 0, 255, "IFMAIL value")
        skip = self.resolve(args[3])
        if skip is None or skip < 0:
            self.err(ln, "IFMAIL skip count must be a non-negative number.")
            return
        # skip must not run past the end or cross a LOOP/ENDLOOP boundary
        if idx + skip >= len(instrs):
            self.err(ln, f"IFMAIL skip ({skip}) runs past the end of the program.")
            return
        balance = 0
        for j in range(idx + 1, idx + 1 + skip):
            if kind[j] == "LOOP":
                balance += 1
            elif kind[j] == "ENDLOOP":
                balance -= 1
            if balance < 0:
                self.err(ln, "IFMAIL skip crosses an ENDLOOP boundary "
                             "(a guarded skip must stay inside its block).")
                return
        if balance != 0:
            self.err(ln, "IFMAIL skip crosses a LOOP boundary "
                         "(a guarded skip must stay inside its block).")

    # ---- global checks ----------------------------------------------------
    def _global_checks(self):
        m = self.model
        # pin conflicts + budget + HD reservation
        used = {}
        for pd in m.pindefs:
            for p in pd.pins:
                if p in used:
                    self.err(pd.line, f"Pin {p} is already used by pin-def "
                                      f"{used[p].index} (line {used[p].line}).",
                              hint="Each pin can only be one thing. Pick a different EXP pin.")
                else:
                    used[p] = pd
                if m.target == "HD" and p in L.HD_RESERVED:
                    self.err(pd.line, f"{p} is reserved by the HD addon under TARGET HD "
                                      f"(use EXP4..EXP8).",
                              hint="Move this to one of EXP4-EXP8, or switch to 'TARGET NOHD' if the HD addon is not fitted.")
        m.pins_used = sum(2 if pd.ptype == "I2C" else len(pd.pins) for pd in m.pindefs)
        budget = L.LIMITS["PINS_HD"] if m.target == "HD" else L.LIMITS["PINS_NOHD"]
        if m.pins_used > budget:
            self.err(m.pindefs[-1].line if m.pindefs else 1,
                     f"Pin budget exceeded: {m.pins_used} pins used, "
                     f"limit is {budget} for TARGET {m.target or '??'} "
                     f"(I2C costs 2).")
        # more than one I2C bus
        if sum(1 for pd in m.pindefs if pd.ptype == "I2C") > 1:
            self.err(m.pindefs[0].line, "Only one I2C bus is allowed in V1.")
        # payload + text size
        if m.payload_bytes > L.LIMITS["MAX_PAYLOAD_DECODED"]:
            self.err(1, f"Total in-file payload {m.payload_bytes} B exceeds "
                        f"{L.LIMITS['MAX_PAYLOAD_DECODED']} B.")
        if m.text_len > L.LIMITS["MAX_TEXT_LEN"]:
            self.err(1, f"Script text {m.text_len} B exceeds MAX_TEXT_LEN "
                        f"{L.LIMITS['MAX_TEXT_LEN']} B (0x1FFF0).")


# convenience
def lint_text(text):
    return Linter().lint(text)