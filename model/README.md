# OCaml golden model and PFST compiler

- `pfst.ml` — independent OCaml model of one PFST core; `refs.ml` loads Python-exported reference vectors (`*.vec`).
- `main.ml` — golden-model suite: bit-exact cross-checks against the Python model (UART TX/RX, SPI TX), I2C and
  Nano-Tick system tests with OCaml-written slave/driver/decoders, and negative controls.
- `compiler.ml` — applicative, deep-embedded compiler from PFST programs to table words. Static checks reject
  unreachable states, deadlock traps (with declared, host-recoverable `terminals`), undeclared targets,
  out-of-range waits and `dir` values, programs over the chip's 64 states, and rows needing more than two
  inputs, before anything runs. Rows take an optional `~dir` (spec v1.1 word bits [28:25], fixed position).
- `dsl_programs.ml` — UART TX/RX, SPI TX, I2C write, the Nano-Tick trader and a half-duplex single-wire UART
  (uses the v1.1 `dir` field: drives the wire only while transmitting) written in the DSL, plus must-reject controls.
- `export_compiled.ml` — writes every compiled program as JSON (`compiled_tables.json`) for loading onto the chip.

Run `./run_tests.sh` (needs `ocamlfind` with `str`). CI runs it on every push (`.github/workflows/model.yaml`).

Known gaps versus spec v1.1: the model clears the scratchpad on RESTART (v1.1 does not); it models the `dir`
register but not the pin modes that consume it; cycle alignment with the RTL's read-ahead is not cross-checked.
Compiled UART TX/RX, SPI TX and half-duplex UART tables have been run on the chip RTL through the host port and
decoded from the pins, the half-duplex one on a single PINMODE 3 wire with zero contention cycles (rtl harness
`chip_compiled_test.py`, kept with the RTL verification package).
