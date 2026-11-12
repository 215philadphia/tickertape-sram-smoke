# OCaml golden model and PFST compiler

- `pfst.ml` — independent OCaml model of one PFST core; `refs.ml` loads Python-exported reference vectors (`*.vec`).
- `main.ml` — golden-model suite: bit-exact cross-checks against the Python model (UART TX/RX, SPI TX), I2C and
  Nano-Tick system tests with OCaml-written slave/driver/decoders, and negative controls.
- `compiler.ml` — applicative, deep-embedded compiler from PFST programs to table words. Static checks reject
  unreachable states, deadlock traps (with declared, host-recoverable `terminals`), undeclared targets,
  out-of-range waits and rows needing more than two inputs, before anything runs.
- `dsl_programs.ml` — UART TX/RX, SPI TX, I2C write and the Nano-Tick trader written in the DSL, plus must-reject controls.
- `export_compiled.ml` — writes every compiled program as JSON (`compiled_tables.json`) for loading onto the chip.

Run `./run_tests.sh` (needs `ocamlfind` with `str`). CI runs it on every push (`.github/workflows/model.yaml`).

Known gaps versus spec v1.1: the model clears the scratchpad on RESTART (v1.1 does not); it does not model
the `dir` field (bits [28:25]) or pin modes; cycle alignment with the RTL's read-ahead is not cross-checked.
Compiled UART TX/RX and SPI TX tables have been run on the chip RTL through the host port and decoded from
the pins (rtl harness `chip_compiled_test.py`, kept with the RTL verification package).
