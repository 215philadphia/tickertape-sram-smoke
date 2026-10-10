# TickerTape-Out — Gate 0: SRAM macro smoke test

One IHP `RM_IHPSG13_1P_256x32_c2_bm_bist` SRAM macro pushed through the official
Tiny Tapeout CMOS5L flow (`ttihp-verilog-template@cmos5l`, `tt-gds-action@ihp-cmos5l`,
6x4 tiles, 50 MHz). This repo exists to answer one question before any TickerTape-Out
RTL is written: **does a user SRAM macro of the size the PFST core needs survive
GDS, precheck, LVS and gate-level test on this flow?**

## What the design does

| `uio_in[1:0]` | Mode  | `uo_out` |
|---|---|---|
| `00` | Idle  | `0` |
| `01` | Self-test: write all 256 words, read back, compare; inverted pattern first, then true pattern | `{done, pass, err_count[5:0]}` |
| `10` | Chase: `A_ADDR <= A_DOUT[7:0]` every cycle | `A_DOUT[7:0]` (counts 0..255 after a self-test) |
| `11` | Manual read: `A_ADDR = ui_in` | byte `uio_in[3:2]` of `A_DOUT` |

Chase mode is the point: it is the PFST next-state loop, with the SRAM output
register acting as the state register. The flow's STA report times that path directly.

## Pass criteria (check in this order)

1. `gds` job completes. Record from the run summary: `A_DOUT -> A_ADDR` path slack
   (slow corner), total cell area, utilization.
2. KLayout DRC clean. If it reports `M3.f` at the macro's edge, add a Metal3
   `ROUTING_OBSTRUCTIONS` strip there (see WZ's `macro/.../README.md` for the pattern).
3. LVS clean. This is the power-hookup signoff (`ERROR_ON_PDN_VIOLATIONS` is 0).
4. `precheck` job passes.
5. `gl_test` job passes (same cocotb tests against the gate-level netlist).

## Local RTL test (verified)

```
cd test && make        # needs iverilog 12 + cocotb 2.0.1
```
4/4 pass: self-test passes; injected corruption of 3 words is counted as exactly
3 errors; chase walks all 256 addresses one per cycle; manual read returns every byte.

## Provenance

Macro integration (PDN plugin, `odb_sram_stripes.py`, `pdn_cfg.tcl`, config keys)
is adapted from [WilliamZhang20/protocol-emulator](https://github.com/WilliamZhang20/protocol-emulator)
(Apache-2.0), which passed full TT cmos5l precheck with `RM_IHPSG13_1P_1024x8_c2_bm_bist`
([tt-support-tools PR #187](https://github.com/TinyTapeout/tt-support-tools/pull/187)).
That work in turn builds on [kdp1965/ihp-um-janestreet-prism](https://github.com/kdp1965/ihp-um-janestreet-prism).
Changes here: macro name, instance location, no Metal3 obstruction (the 1024x8 hotspot
does not transfer). SRAM models in `test/models` are from IHP-Open-PDK (Apache-2.0).

