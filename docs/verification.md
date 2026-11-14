# Verification approach

The design is checked at six levels, each by something written independently of what it checks. Every
level below runs in CI on each push; the commands are given so anyone can rerun them with open-source tools.

| Level | What is checked | Where | Runs in CI |
|---|---|---|---|
| 1. Golden model | An OCaml model of one core, bit-exact against traces from an earlier Python model | `model/main.ml` | `model` workflow |
| 2. Protocol behaviour | Programs on the model, decoded by independent protocol references (UART, SPI, I2C, Nano-Tick) | `model/main.ml`, `model/compile_test.ml` | `model` workflow |
| 3. Compiler | Static checks reject bad programs; good programs compile and decode correctly | `model/compile_test.ml` | `model` workflow |
| 4. RTL and gate level | cocotb tests drive the real top level through the host SPI port, including every compiled program | `test/test_pfst.py`, `test/test_programs.py` | `test` and `gds` (`gl_test`) workflows |
| 5. Physical signoff | Tiny Tapeout flow: STA, KLayout DRC, LVS, precheck | `.github/workflows/gds.yaml` | `gds` workflow |
| 6. Formal proofs | SymbiYosys proofs of the core's timing, FIFO, flags and reset behaviour, and of pin safety, for every program | `formal/` | `formal` workflow |

## 1. Golden model: an independent second implementation

[`model/pfst.ml`](../model/pfst.ml) is an OCaml model of one PFST core, written separately from an earlier
Python model. The Python model is not in this repository; its outputs are, as vector files
(`model/*.vec`: a table, its configuration and the expected pin trace). For UART TX, UART RX (including an
early-sampling case) and SPI TX, the OCaml core must reproduce the Python trace **bit for bit**. Two
implementations agreeing exactly is strong evidence both read the spec the same way.

## 2. Independent protocol references

A matching trace only shows the two models agree. To show the output is actually the protocol,
[`model/refs.ml`](../model/refs.ml), [`model/i2c_env.ml`](../model/i2c_env.ml) and
[`model/nanotick_env.ml`](../model/nanotick_env.ml) decode the waveforms with references written from the
protocol specs, not from either model:

- **UART:** an ideal decoder that samples at exact bit centres and reports the worst edge-timing error.
- **SPI:** a mode 0 decoder.
- **I2C:** a reactive open-drain target (it ACKs, can stretch the clock and can be slow) and a fast-mode
  timing checker that flags any setup, hold or bus-free violation.
- **Nano-Tick:** a randomized price stream, the comparator's `VALID` and `CMP` behaviour from the spec,
  and an SPI decode of the orders, compared with the trades the stream should cause.

## 3. Compiler: correct by construction where possible

[`model/compile_test.ml`](../model/compile_test.ml) compiles each example program, runs it on the golden
model and decodes the result with the references above. It also checks the state count of each program,
and for the half-duplex UART that there are **zero cycles of bus contention** on the shared wire.

Static checks are tested with programs that must be **rejected**, each for the right reason: an
unreachable state, a single-state and a two-state deadlock trap, a transition to an undeclared state,
out-of-range `wait` and `dir` fields, three inputs on one state, 65 states, and a real trap hidden beside a
legitimate terminal. One more test documents a known limit: the compiler trusts a programmer's
`terminals` declaration and cannot tell if it is wrong.

## Negative controls: proving the tests can fail

A test that cannot fail proves nothing. [`model/main.ml`](../model/main.ml) deliberately breaks things and
requires the checks to catch them:

- one corrupted `wait` bit in the UART RX table
- a `LOAD` turned into `HOLD` in the UART TX table
- the comparator not gated by `VALID` (must trade at reset)
- a wrong reset select with a slow host (must lose sync)
- the I2C bus-free time after STOP set to zero (must trip the timing checker)
- RESTART behaviour: clears the model's receive log but keeps `SCR`, matching spec v1.1 section 5 and the RTL

## 4. RTL and gate level

[`test/test_pfst.py`](../test/test_pfst.py) drives the real top level (`tt_um_tickertape_pfst`, with the
IHP SRAM simulation models) only through its pins, as a host on the demo board would:

| Test | Checks |
|---|---|
| `test_registers` | Reset value of every core 0 register, then write and read back with auto-increment |
| `test_table` | `WRITE_TABLE` and `READ_TABLE` through core 1's SRAM across word and row boundaries, including past row 255 |
| `test_uart_tx` | Load a UART transmitter, push bytes, decode the frames from `uo_out[4]`, check the FIFO is empty with no overflow |
| `test_passthrough` | UOMAP forwarding: direct (same cycle) and synchronized |
| `test_row_controlled_pins` | PINMODE 3: the row's `dir` bits decide which pins drive; all pins released while stopped |

### Every compiled program, on the chip

[`test/test_programs.py`](../test/test_programs.py) loads each program the OCaml compiler produces onto
the chip through the host SPI port, as the demo board would, and checks the protocol on the pins with a
decoder written in the test:

| Test | Program | Checks |
|---|---|---|
| `test_compiled_uart_tx` | `uart_tx_dsl` | Pushed bytes appear as 8N1 frames |
| `test_compiled_uart_rx` | `uart_rx_dsl` | Frames at -1%, 0 and +1% baud error are received; each read back with `READ_SCR` via the IRQ pin; no overrun |
| `test_compiled_spi_tx` | `spi_tx_dsl` | Mode 0 frames decoded from CS, SCK and MOSI |
| `test_compiled_i2c_write` | `i2c_wr_dsl` | Open drain with a reactive target: 6 bytes written and ACKed, then a wrong address is NACKed; DONE reached each time; exactly one START and STOP per transaction |
| `test_compiled_nanotick` | `uart_rx_dsl` + `nt_trader_dsl` | **Both cores, no host in the loop:** core 0 receives prices, the comparator fires below `THRESH`, core 1 sends exactly one 3-byte SPI order per downward crossing |
| `test_compiled_half_duplex` | `hd_uart_dsl` | One wire in PINMODE 3: request out, reply in, **zero cycles where both ends drive** |
| `test_compiled_ps2_rx` | `ps2_rx_dsl` | A new protocol: PS/2 frames received; a parity error and a stop-bit error each save nothing and raise `FLAG`; the receiver stays in sync afterwards |

The tables come from `test/compiled_tables.json`, a snapshot of the compiler output.
`model/run_tests.sh` fails if the snapshot differs from what the compiler produces, so the RTL tests
cannot silently run stale tables. These tests were themselves checked by breaking tables on purpose: an
I2C master that stops after the first byte, a trader that re-arms without waiting for the price to
recover (23 orders instead of 3), and a PS/2 receiver that accepts any parity bit all fail.

The `gds` workflow runs all of these tests against the **gate-level netlist** after place and route
(`gl_test`), which catches synthesis and tool errors as well as RTL bugs.

## 5. Physical signoff

The Tiny Tapeout flow (LibreLane on IHP CMOS5L) runs static timing at three corners, KLayout DRC, LVS and
the Tiny Tapeout precheck. A collector workflow publishes the timing, DRC and LVS reports for every commit
to a `results-<sha>-<run>` branch, so results can be compared across runs. Current numbers are in the
[README](../README.md#signoff-status).

## 6. Formal proofs

Simulation checks the programs we wrote. [`formal/`](../formal/README.md) proves properties of the RTL for
**every possible program**: the SRAM contents are a free input to the proofs, so a property holds whatever
table is loaded. The tool is SymbiYosys (Yosys with the cvc5 solver); the properties are plain SystemVerilog,
pasted into a copy of the RTL so that `src/` is never modified.

Proved for the core, for every prescaler `P` and every `wait`:

- **Every row lasts exactly P x (1 + wait) cycles.** The end of a row fires in the last cycle of the
  (1 + wait)-th period of `P` cycles and in no other cycle, so the timer cannot underflow or overrun.
- The next row is read in the last cycle and takes effect in the next one: no gap, no overhead.
- The TX FIFO matches a 3-byte queue model for every push and pop sequence, with the overflow flag set by a
  push into a full FIFO and nothing else.
- `SAVE`, `RX_OVR`, RESTART keeping `SCR` (spec v1.1 section 5), sticky `DONE` and `FLAG`, and the start state
  after reset, RESTART or stop.
- The table SRAM is never written while the core runs.

Proved at chip level: an open-drain pin never drives high, an input pin is never driven, a stopped core has
released its row-controlled pins, and no bidirectional pin is driven out of reset.

The proofs are unbounded (k-induction); a bounded check from reset and cover points (which show the interesting
cases are reachable, so no property is vacuous) run alongside. To show the proofs can fail, five bugs were
planted in copies of the RTL, one at a time (a prescaler off by one, a wait off by one, table writes while
running, the FIFO overflow flag removed, RESTART clearing `SCR`), and each is caught with a counterexample.

The proofs assume `P` is not changed while a core runs; the RTL does not enforce this, and the host contract
is documented in [architecture.md](architecture.md#host-interface). They found one documentation error: a `LOAD`
from an empty FIFO returns the byte last loaded, not 0.

## Known gaps

- The OCaml model has the `dir` register but not the pin modes that consume it, nor `DONE`, `FLAG`,
  `TX_OVR` or `OUT_INIT`.
- Cycle alignment between the model and the RTL's read-ahead is not cross-checked automatically.
- The formal proofs do not cover the datapath results (`SR`, `CNT`) beyond `SAVE` and the FIFO, address formation, the
  SPI protocol beyond its effect on pin safety, the comparator, UOMAP pass-through, or the SRAM timing contract
  (see [formal/README.md](../formal/README.md#what-is-not-proved)).
- The OCaml model keeps the last loaded TX byte across RESTART, while the RTL clears it to 0 (visible only if a
  program reads `SR` after a `LOAD` from an empty FIFO).

## Running everything

```bash
cd test && make -B
```

```bash
cd model && ./run_tests.sh
```

The first needs Icarus Verilog 12 and cocotb 2.0.1; the second needs `ocamlfind`. Both are open source.
