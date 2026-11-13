# TickerTape-Out: programmable finite state transducer

A Tiny Tapeout project on the IHP CMOS5L flow (`ttihp-verilog-template@cmos5l`,
`tt-gds-action@ihp-cmos5l`), **8x4 tiles** (Jane Street competition allocation), 50 MHz.

TickerTape-Out is a protocol emulator built from two programmable finite state transducers (PFSTs).
Each core is a table-driven state machine whose transition table lives in its own IHP
`RM_IHPSG13_1P_256x32_c2_bm_bist` SRAM macro, so UART, SPI and I2C are firmware tables, not hardware blocks.
A host loads tables and configuration over an SPI port.

## Documentation

| Document | Contents |
|---|---|
| [Architecture and instruction set](docs/architecture.md) | Core, table word format, timing, comparator, pins, host commands, register map |
| [Toolchain and example programs](docs/toolchain.md) | The OCaml DSL and compiler, its static checks, seven example programs, loading a program |
| [Verification approach](docs/verification.md) | Golden model, independent protocol references, negative controls, RTL and gate-level tests, signoff, known gaps |
| [Use of AI tools](docs/ai-use.md) | What AI tools were used for and how their output was checked |
| [Datasheet text](docs/info.md) | Tiny Tapeout datasheet: how it works, how to test, external hardware |

The pinout is in [`info.yaml`](info.yaml).

## How it works (summary)

- Every table row sets the next state, four output pins, a wait time, a direction field (spec v1.1) and one
  datapath operation (hold, shift, load from a 3-byte TX FIFO, save to a scratch register).
- The next row address is the current state plus two input bits chosen per row. Every row lasts exactly
  P x (1 + wait) clock cycles; the SRAM output is read one cycle ahead, in the last cycle of the current row.
- Core 0's saved byte feeds a comparator that core 1 can branch on, so the cores react to each other without the host.
- Any of `uo_out[5:0]` can forward an input pin (direct or through a 2-flop synchronizer) while a core parses it,
  and PINMODE 3 pins drive only in rows whose `dir` bits say so, for half-duplex buses.

## Pins

| Pins | Function |
|---|---|
| `ui_in[4]`, `ui_in[5]`, `ui_in[6]`, `uo_out[7]` | Host SPI: SCK, MOSI, CS_n, MISO (mode 0, SCK at or below 4 MHz) |
| `ui_in[3:0]`, `ui_in[7]` | Input sources selectable by INMAP |
| `uo_out[5:0]` | UOMAP mirrors of core outputs or pass-through inputs |
| `uo_out[6]` | IRQ |
| `uio[3:0]` / `uio[7:4]` | Protocol pins of core 0 / core 1 |

## Repository layout

| Path | Contents |
|---|---|
| `src/` | RTL: `tt_um_tickertape_pfst.v` (top, two SRAM macros), `pfst_chip.v`, `pfst_core_sram.v`; flow config `config.json`, `pdn_cfg.tcl` |
| `macro/` | IHP 256x32 SRAM macro LEF |
| `librelane_plugin_sram_pdn.py`, `odb_sram_stripes.py` | Macro power hookup for the LibreLane flow |
| `test/` | cocotb tests: chip features (`test_pfst.py`) and every compiled program on the chip (`test_programs.py`), with the IHP SRAM simulation models in `test/models` |
| `model/` | OCaml golden model and PFST compiler, see [`model/README.md`](model/README.md) |
| `docs/` | Datasheet text (`info.md`) and the documents listed above |
| `.github/workflows/` | `gds`, `test`, `model`, `fpga`, `docs` CI jobs |

## Running the tests

RTL testbench (needs Icarus Verilog 12 and cocotb 2.0.1):

```bash
cd test && make -B
```

12/12 pass. `test_pfst.py` covers the chip's features: registers, table write/read through the SRAM macro,
a UART transmitter, UOMAP pass-through and PINMODE 3 row-controlled pins. `test_programs.py` runs every
program the OCaml compiler produces on the chip and decodes the pins: UART TX, UART RX at ±1% baud error,
SPI TX, I2C write against a reactive target, the two-core Nano-Tick trader, half-duplex UART on one wire, and
a PS/2 receiver with parity checking.

Gate-level: after hardening, copy the netlist to `test/gate_level_netlist.v` and run `make -B GATES=yes`.

OCaml golden model and compiler (needs `ocamlfind`):

```bash
cd model && ./run_tests.sh
```

All checks pass: cross-checks against Python reference vectors, I2C and Nano-Tick system tests, compiler
static checks and must-reject controls; it also exports the seven compiled programs to `compiled_tables.json`.

## Signoff status

From [gds run #28](https://github.com/215philadphia/tickertape-sram-smoke/actions/runs/43453786318) on `main`
(commit `19754a1`); reports are on the `results-19754a1-43468440259` branch published by the collector.

| Check | Result |
|---|---|
| `gds` job | Pass. Die 1724.16 x 710.64 um (8x4), core area 1.208 mm², utilization 15.1% (standard cells 7.6%) |
| Setup, slow corner (1.08 V, 125 C) | Met. Worst slack 4.17 ns (`rst_n` input to `sram1`); worst register-to-register slack 10.89 ns, which bounds the `A_DOUT -> A_ADDR` loop |
| Hold | Met. Worst slack 0.107 ns (fast corner) |
| KLayout DRC | Clean (precheck: SG13CMOS5L DRC, pin labels, zero area) |
| LVS | Clean (0 errors, 0 unmatched nets, devices or pins); this is the power-hookup signoff |
| Antenna | 0 violations |
| `precheck` job | Pass |
| `gl_test` job | Pass |

Open items:

- **Electrical rule violations** in post-route STA: 21 max-capacitance, up to 11 max-slew and 3 max-fanout
  violations (all corners report them). They do not fail the flow, but should be fixed or explained before submission.
- Expected and accepted by config: 16264 pdngen power-grid warnings (the SRAM stripes are bridged after that check;
  LVS is the connectivity signoff) and 182 Magic illegal-overlap reports (false positive on the macro's LEF Metal4
  obstruction; Magic DRC is off and KLayout DRC is the physical signoff).

If KLayout DRC ever reports `M3.f` at a macro edge, add a Metal3 `ROUTING_OBSTRUCTIONS` strip there.

## History

This repo started as Gate 0, a single-macro smoke test that checked whether a user SRAM of this size survives
GDS, precheck, LVS and gate-level test on the CMOS5L flow. The PFST design replaced that test design.

## Provenance

Macro integration (PDN plugin, `odb_sram_stripes.py`, `pdn_cfg.tcl`, config keys)
is adapted from [WilliamZhang20/protocol-emulator](https://github.com/WilliamZhang20/protocol-emulator)
(Apache-2.0), which passed full TT cmos5l precheck with `RM_IHPSG13_1P_1024x8_c2_bm_bist`
([tt-support-tools PR #187](https://github.com/TinyTapeout/tt-support-tools/pull/187)).
That work in turn builds on [kdp1965/ihp-um-janestreet-prism](https://github.com/kdp1965/ihp-um-janestreet-prism).
SRAM models in `test/models` are from IHP-Open-PDK (Apache-2.0).
