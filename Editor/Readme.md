# EOS Script Editor — a mini-IDE for `.eos`

A beginner-friendly desktop IDE for writing EOS Script. It enforces **every rule
in the frozen EOS Expansion spec**, so a script that shows no errors here is
guaranteed in-bounds for the gateware.

## Why it's beginner-friendly

- **Live validation** with the exact linter the gateware trusts. Errors get red
  wavy underlines and a click-to-jump **Problems** list — and **every error comes
  with a plain-English fix hint**.
- **Parameter hints (IntelliSense-style):** the **Hint** panel shows the current
  command's signature with the operand you're typing highlighted.
- **Hover any word** to see what it is — a command's signature, a pin's
  assignment, a `DEF`'s value, a `DATA`'s byte length, or a register's exact
  mailbox address.
- **Autocomplete** for commands, directives, pins, registers, and your own
  `DEF`/`DATA` names.
- **Insert menu** of ready-made, in-bounds snippets (WS2812 strip, I²C device,
  GPIO, PWM, doorbell handler, level-poll).
- **Overview panel** — a plain-English description of what your script does *and*
  the exact contract your Xbox app needs (mailbox addresses + the doorbell
  handshake), plus a live **Pins & Budget** map.
- **Built-in Guide** panel: EOS Script in 90 seconds.

## Mini-IDE features

Tabbed multi-file editing · menu bar + keyboard shortcuts · Find/Replace
(`Ctrl+F`) · comment toggle (`Ctrl+/`) · undo/redo · font zoom · unsaved-change
tracking with a save prompt on close · **Open Recent** · save guard that warns
before writing a script with errors · command-map export.

## Install & run

Requires Python 3.9+.

```bash
pip install PySide6
python eos_editor.py
```

## Files

| File | Role |
|------|------|
| `eos_editor.py`   | The PySide6 mini-IDE (run this). |
| `eos_linter.py`   | Parser + validator — the safety core (no GUI). |
| `eos_language.py` | Frozen limits + command/directive signatures. |
| `eos_report.py`   | Plain-English "what it does" + host-contract text. |
| `examples/*.eos`  | Sample scripts. |

## Headless validation

The validator is importable and GUI-free — handy for a pre-flash check or CI:

```python
import eos_linter
diags, model = eos_linter.lint_text(open("script.eos").read())
errors = [d for d in diags if d.severity == "error"]
```

`model` carries the parsed pin-defs and the computed volatile layout, so an
uploader can reuse it.

## Keyboard shortcuts

`Ctrl+N/O/S` new/open/save · `Ctrl+Shift+S` save as · `Ctrl+F` find ·
`Ctrl+/` toggle comment · `Ctrl+Z / Ctrl+Shift+Z` undo/redo ·
`Ctrl+= / Ctrl+-` font size · `Ctrl+Q` quit.