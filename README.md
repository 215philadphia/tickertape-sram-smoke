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

## Gate 0 results (run [38829274463](https://github.com/215philadphia/tickertape-sram-smoke/actions/runs/38829274463), commit `108e940`)

**Verdict: pass.** All five criteria met on the first fully green `gds` run.

| # | Criterion | Result |
|---|---|---|
| 1 | `gds` completes | Pass (numbers below) |
| 2 | KLayout DRC | 0 errors; all 9 precheck KLayout/pin/boundary/layer checks pass. No `M3.f` edge hit, so no Metal3 obstruction needed |
| 3 | LVS | 0 errors, 0 device differences, 0 net differences |
| 4 | `precheck` | Pass |
| 5 | `gl_test` | 4/4 pass (same results as RTL) |

**Timing** (50 MHz, 20 ns period; post-PnR STA with extracted parasitics)

| Corner | Worst setup slack | Worst hold slack |
|---|---|---|
| nom_slow_1p08V_125C | +10.37 ns | +0.66 ns |
| nom_typ_1p20V_25C | +11.18 ns | +0.32 ns |
| nom_fast_1p32V_m40C | +11.64 ns | +0.13 ns |

No setup or hold violations at any corner. The worst setup path overall is
`sram0/A_DOUT -> uo_out[3]`, which is dominated by the flow's 4 ns output delay constraint.

**`A_DOUT -> A_ADDR` chase loop, slow corner: about +13.8 ns** (worst bit `A_ADDR[4]`).
The flow's `max.rpt` lists only the worst path per endpoint, which for every `A_ADDR`
pin starts at `ui_in` (so the chase slack is at least +13.20 ns). The +13.8 ns figure comes
from `tools/sdf_paths.py`, which traces the post-PnR SDF. It errs pessimistic: on the
reported `A_DOUT[19] -> uo_out[3]` path it gives 5.514 ns arrival against the flow's 5.378 ns.
About 2.2 ns of the 2.65 ns `A_DOUT[4] -> A_ADDR[4]` delay is three hold-fix delay cells
(`hold238`-`hold240`) shared with the `ui_in[4]` path. The other bits have 15.1-15.8 ns slack.

**Area and power**

| | |
|---|---|
| Die (6x4 tiles) | 916,214 um^2 |
| SRAM macro | 49,489 um^2 |
| Standard cells | 7,791 um^2 (607 cells, 37 flip-flops, 78 hold buffers) |
| Utilization | 6.35% total, 0.91% standard cells |
| Total power | 0.64 mW |

**Warnings to carry into the PFST design** (none failed signoff)
- Max slew: 24 violations at the slow corner (11 typ, 1 fast). Max cap: 11 slow, 12 typ, 14 fast.
- `[PSM-0069] Check connectivity failed on VPWR / VGND` in the IR-drop step. LVS is clean, so
  this is probably the IR tool's view of the macro stripes, but IR-drop numbers are not trustworthy until it is resolved.

## Provenance

Macro integration (PDN plugin, `odb_sram_stripes.py`, `pdn_cfg.tcl`, config keys)
is adapted from [WilliamZhang20/protocol-emulator](https://github.com/WilliamZhang20/protocol-emulator)
(Apache-2.0), which passed full TT cmos5l precheck with `RM_IHPSG13_1P_1024x8_c2_bm_bist`
([tt-support-tools PR #187](https://github.com/TinyTapeout/tt-support-tools/pull/187)).
That work in turn builds on [kdp1965/ihp-um-janestreet-prism](https://github.com/kdp1965/ihp-um-janestreet-prism).
Changes here: macro name, instance location, no Metal3 obstruction (the 1024x8 hotspot
does not transfer). SRAM models in `test/models` are from IHP-Open-PDK (Apache-2.0).

