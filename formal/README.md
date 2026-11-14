# Formal proofs

Proofs with [SymbiYosys](https://github.com/YosysHQ/sby) (Yosys 0.33, solver cvc5) of properties of the
PFST core and of the chip's pin muxing.

```bash
formal/run.sh          # everything: core.sby and chip.sby, each with prove, bmc and cover tasks
formal/run.sh core     # the core only
formal/run.sh chip     # the chip only
```

Needs `yosys`, `cvc5` and SymbiYosys. On Ubuntu 24.04: `apt install yosys cvc5`, then install the SymbiYosys
release tagged `yosys-0.33` (see `.github/workflows/formal.yaml`). Other solvers do not work well here: the
distribution's boolector (1.5.118) cannot read the models, and z3 4.8.12 does not finish on the timer's arithmetic.

**`src/` is never modified.** `run.sh` pastes `pfst_core_props.vh` and `pfst_chip_props.vh` into *copies* of the RTL
in `formal/build/` (so the properties can see internal registers), and runs the proofs on those. The properties
are not part of the synthesized design.

## Why these proofs cover every program

The IHP SRAM macros are outside the core. In the proofs their outputs are free inputs, so every property holds
for **every possible table contents**, that is, for every program, not just the seven we have written and tested.

## What is proved

Each task is `prove` (k-induction: an unbounded proof, with the base case run from reset), `bmc` (a bounded check
from reset, which finds counterexamples with a trace) and `cover` (shows the interesting cases are reachable, so a
property is not vacuously true).

### Core (`pfst_core_props.vh`, proved for every value of `P` and `wait`)

| | Property |
|---|---|
| T1 | **Every row lasts exactly P x (1 + wait) cycles.** A row is (1 + wait) back-to-back periods of exactly `P` cycles; the end-of-row signal fires in the last cycle of the last period and in no other; the timer never runs past the end or underflows. |
| T2 | The next row is read in the last cycle of the current one and takes effect in the very next cycle (no gap, no overhead); no read is issued while a row is in progress. |
| T3 | The table SRAM is never written while the core runs. |
| T4 | Any reset, RESTART or stop returns the core to its start state, pins to `OUT_INIT`, and releases every row-controlled drive enable. |
| T5 | The TX FIFO matches a 3-byte queue model for **every** push/pop sequence: oldest byte first, level 0 to 3, overflow flag set by a push into a full FIFO and by nothing else. A `LOAD` from an empty FIFO returns the byte last loaded (0 after reset or RESTART). |
| T6 | `SAVE` copies `SR` to `SCR` and sets `RX_VALID` and `VALID`. |
| T7 | `RX_OVR` is raised by a `SAVE` while `RX_VALID` is still set, and by nothing else. |
| T8 | RESTART keeps `SCR`, `RX_OVR` and `VALID` (spec v1.1 section 5), and changes `RX_VALID` only through `READ_SCR`. |
| T9 | `DONE` and `FLAG` stay set until RESTART or reset. |

T1 is stated without a multiplier: the proof counts periods and accumulates `P` once per completed period, so
"P x (1 + wait)" is established as repeated addition. Stating it as a product of two free variables is beyond
the solvers available (z3 and cvc5 both ran for more than 15 minutes without an answer).

### Chip (`pfst_chip_props.vh`)

| | Property |
|---|---|
| P1 | A pin in PINMODE 0 (input) is never driven. |
| P2 | An open-drain pin (PINMODE 2) only ever drives low, never high. |
| P3 | A row-controlled pin (PINMODE 3) is not driven once its core has been stopped. |
| P4 | Out of reset, no bidirectional pin is driven. |
| P5 | A stopped core has released all its row-controlled drive enables. |
| P6 | A core's SRAM write strobe is never high while that core runs. |

## Assumptions

1. The proofs start from reset.
2. **`P` is not changed while a core is running.** The host sets `P` while the core is stopped; the RTL does not
   enforce it. T1 is proved under this assumption, and `P` is otherwise arbitrary. (Changing `P` mid-run changes row
   lengths; this is documented in `docs/architecture.md`.)

## What is not proved

- **The SRAM timing contract.** The core assumes the macro returns the row read one cycle after the address and
  then holds it steady. That is checked by simulation (RTL and gate level), not here.
- **Datapath results** other than the FIFO and `SAVE`: the contents of `SR` and `CNT` after `SHIFT`, and the pin
  values a row produces, are covered by simulation and the golden-model cross-checks.
- **The host SPI protocol**: only its effect on pin safety (P1 to P4, P6) is proved.
- **The comparator and UOMAP pass-through.**
- **Timing and layout** (the Tiny Tapeout flow covers those).

## Checking that the proofs can fail

A proof that cannot fail proves nothing. Five bugs were planted, one at a time, in copies of the RTL, and each is
caught with a counterexample: a prescaler off by one, a wait value off by one, the table SRAM written while running,
the FIFO overflow flag removed, and RESTART clearing `SCR`. The bounded check finds each within 3 to 6 cycles.

Findings from the proofs: the documentation said `LOAD` from an empty FIFO returns 0; the proof showed it returns
the last loaded byte, and the docs were corrected. The OCaml golden model does not clear its copy of that byte on
RESTART, while the RTL does (a minor difference that only matters if a program reads `SR` after a `LOAD` from an
empty FIFO).
