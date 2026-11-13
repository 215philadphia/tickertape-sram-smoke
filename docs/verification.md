# Verification approach

The design is checked at five levels, each by something written independently of what it checks. Every
level below runs in CI on each push; the commands are given so anyone can rerun them with open-source tools.

| Level | What is checked | Where | Runs in CI |
|---|---|---|---|
| 1. Golden model | An OCaml model of one core, bit-exact against traces from an earlier Python model | `model/main.ml` | `model` workflow |
| 2. Protocol behaviour | Programs on the model, decoded by independent protocol references (UART, SPI, I2C, Nano-Tick) | `model/main.ml`, `model/compile_test.ml` | `model` workflow |
| 3. Compiler | Static checks reject bad programs; good programs compile and decode correctly | `model/compile_test.ml` | `model` workflow |
| 4. RTL and gate level | cocotb tests drive the real top level through the host SPI port | `test/test_pfst.py` | `test` and `gds` (`gl_test`) workflows |
| 5. Physical signoff | Tiny Tapeout flow: STA, KLayout DRC, LVS, precheck | `.github/workflows/gds.yaml` | `gds` workflow |

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

The `gds` workflow runs the same tests against the **gate-level netlist** after place and route (`gl_test`),
which catches synthesis and tool errors as well as RTL bugs.

The compiled UART TX, UART RX, SPI TX and half-duplex UART tables have also been run on the chip RTL
through the host port and decoded from the pins, the half-duplex one on a single PINMODE 3 wire with zero
contention cycles. That harness (`chip_compiled_test.py`) is kept with the RTL verification package and is
not in this repository.

## 5. Physical signoff

The Tiny Tapeout flow (LibreLane on IHP CMOS5L) runs static timing at three corners, KLayout DRC, LVS and
the Tiny Tapeout precheck. A collector workflow publishes the timing, DRC and LVS reports for every commit
to a `results-<sha>-<run>` branch, so results can be compared across runs. Current numbers are in the
[README](../README.md#signoff-status).

## Known gaps

- The OCaml model has the `dir` register but not the pin modes that consume it, nor `DONE`, `FLAG`,
  `TX_OVR` or `OUT_INIT`.
- Cycle alignment between the model and the RTL's read-ahead is not cross-checked automatically.
- The in-repo RTL tests run one protocol table (a UART transmitter, `test/uart_tx_b20.json`). The
  OCaml-compiled programs are checked on the RTL only by the harness that is not in this repository.
- No formal verification yet.

## Running everything

```bash
cd test && make -B
```

```bash
cd model && ./run_tests.sh
```

The first needs Icarus Verilog 12 and cocotb 2.0.1; the second needs `ocamlfind`. Both are open source.
