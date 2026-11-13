# TickerTape-Out: programmable finite state transducer

A Tiny Tapeout project on the IHP CMOS5L flow (`ttihp-verilog-template@cmos5l`,
`tt-gds-action@ihp-cmos5l`), **8x4 tiles** (Jane Street competition allocation), 50 MHz.

TickerTape-Out is a protocol emulator built from two programmable finite state transducers (PFSTs).
Each core is a table-driven state machine whose transition table lives in its own IHP
`RM_IHPSG13_1P_256x32_c2_bm_bist` SRAM macro, so UART, SPI and I2C are firmware tables, not hardware blocks.
A host loads tables and configuration over an SPI port.

The full datasheet text (how it works, SPI command set, external hardware) is in [`docs/info.md`](docs/info.md);
the pinout is in [`info.yaml`](info.yaml).

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
| `test/` | cocotb testbench (`test_pfst.py`) with the IHP SRAM simulation models in `test/models` |
| `model/` | OCaml golden model and PFST compiler, see [`model/README.md`](model/README.md) |
| `docs/info.md` | Datasheet text |
| `.github/workflows/` | `gds`, `test`, `model`, `fpga`, `docs` CI jobs |

## Running the tests

RTL testbench (needs Icarus Verilog 12 and cocotb 2.0.1):

```bash
cd test && make -B
```

5/5 pass: register reset values and read-back, table write/read through the SRAM macro, a UART transmitter
loaded into core 0 and decoded from `uo_out[4]`, UOMAP pass-through, and PINMODE 3 row-controlled pins.

Gate-level: after hardening, copy the netlist to `test/gate_level_netlist.v` and run `make -B GATES=yes`.

OCaml golden model and compiler (needs `ocamlfind`):

```bash
cd model && ./run_tests.sh
```

All checks pass: cross-checks against Python reference vectors, I2C and Nano-Tick system tests, compiler
static checks and must-reject controls; it also exports the six compiled programs to `compiled_tables.json`.

## Signoff checklist (GDS flow)

1. `gds` job completes; record `A_DOUT -> A_ADDR` slack (slow corner), cell area and utilization.
2. KLayout DRC clean. If it reports `M3.f` at a macro edge, add a Metal3 `ROUTING_OBSTRUCTIONS` strip there.
3. LVS clean (the power-hookup signoff; `ERROR_ON_PDN_VIOLATIONS` is 0).
4. `precheck` job passes.
5. `gl_test` job passes.

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
