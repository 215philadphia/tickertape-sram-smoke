# Gate 0: proving the SRAM macro before writing the design

Before any TickerTape-Out RTL existed, this repository held a smoke test with one question: **does a user
SRAM macro of the size the PFST core needs survive GDS, precheck, LVS and gate-level test on the Tiny Tapeout
CMOS5L flow?** If it had not, the whole architecture (a state machine whose state register is the SRAM's
output register) would have needed rethinking. It passed, and the PFST design replaced the test design.

This page is a historical record. The numbers below are for the Gate 0 design, not the chip being submitted;
the current signoff is in the [README](../README.md#signoff-status).

## The test design

One IHP `RM_IHPSG13_1P_256x32_c2_bm_bist` macro, the same macro each PFST core uses, on a **6x4 tile** die at
50 MHz (the allocation at the time; the competition later raised it to 8x4).

| `uio_in[1:0]` | Mode | `uo_out` |
|---|---|---|
| `00` | Idle | `0` |
| `01` | Self-test: write all 256 words, read back, compare; inverted pattern first, then true pattern | `{done, pass, err_count[5:0]}` |
| `10` | Chase: `A_ADDR <= A_DOUT[7:0]` every cycle | `A_DOUT[7:0]` (counts 0..255 after a self-test) |
| `11` | Manual read: `A_ADDR = ui_in` | byte `uio_in[3:2]` of `A_DOUT` |

**Chase mode is the point:** it is the PFST next-state loop, with the SRAM's output feeding its own address,
so the flow's timing analysis measures exactly the path the later design depends on.

RTL tests (4): the self-test passes; 3 deliberately corrupted words are counted as exactly 3 errors; chase
walks all 256 addresses, one per cycle; manual read returns every byte.

## Result: pass on all five criteria

From [gds run #12](https://github.com/215philadphia/tickertape-sram-smoke/actions/runs/38829274463), commit
`108e940`, 16 October 2026.

| # | Criterion | Result |
|---|---|---|
| 1 | `gds` completes | Pass |
| 2 | KLayout DRC | 0 errors; all 9 precheck checks (KLayout, pins, boundary, layers) pass. No `M3.f` error at the macro edge, so no Metal3 obstruction needed |
| 3 | LVS | 0 errors, 0 device differences, 0 net differences: the macro's power hookup is correct |
| 4 | `precheck` | Pass |
| 5 | `gl_test` | 4/4 pass, the same as RTL |

**Timing** (20 ns period, post-route analysis with extracted parasitics):

| Corner | Worst setup slack | Worst hold slack |
|---|---|---|
| Slow, 1.08 V, 125 C | +10.37 ns | +0.66 ns |
| Typical, 1.20 V, 25 C | +11.18 ns | +0.32 ns |
| Fast, 1.32 V, -40 C | +11.64 ns | +0.13 ns |

The worst setup path is `sram0/A_DOUT -> uo_out[3]`, dominated by the flow's 4 ns output-delay constraint.

**The chase loop (`A_DOUT -> A_ADDR`), slow corner: about +13.8 ns of slack** (worst bit `A_ADDR[4]`), so the
loop at the heart of the PFST had about two thirds of the clock period to spare. The flow's own report lists
only the worst path into each pin, which for every `A_ADDR` pin starts at `ui_in`, so it bounds the chase slack
at no less than +13.20 ns without measuring it. The +13.8 ns figure comes from
[`tools/sdf_paths.py`](../tools/sdf_paths.py), which traces the post-route timing file (SDF) directly. It errs
pessimistic: on the reported `A_DOUT[19] -> uo_out[3]` path it gives a 5.514 ns arrival against the flow's
5.378 ns. About 2.2 ns of the 2.65 ns `A_DOUT[4] -> A_ADDR[4]` delay was three hold-fix delay cells shared with
the `ui_in[4]` path; the other bits had 15.1 to 15.8 ns of slack.

**Area and power:**

| | |
|---|---|
| Die (6x4 tiles) | 916 214 um² |
| SRAM macro | 49 489 um² |
| Standard cells | 7 791 um² (607 cells, 37 flip-flops, 78 hold buffers) |
| Utilization | 6.35% total, 0.91% standard cells |
| Total power | 0.64 mW |

## What it predicted, and what happened

Gate 0 passed, but it also left warnings, recorded at the time as things to carry into the PFST design:

| Warning at Gate 0 | What happened in the PFST design |
|---|---|
| 24 max-slew and 11 to 14 max-capacitance violations at the macro's pins | The same class of violation appeared at both macros' pins (21 max-cap, 11 max-slew). Flipping both macros so their pins face the logic cleared every capacitance violation; one slew violation remains ([README](../README.md#signoff-status)) |
| Hold-fix delay cells sit in the SRAM address path | They are the drivers of the remaining slew violation |
| `[PSM-0069] Check connectivity failed on VPWR / VGND` in the IR-drop step, while LVS was clean | Still accepted by configuration (`ERROR_ON_PDN_VIOLATIONS: 0`); LVS remains the power-connectivity signoff. IR-drop numbers from the flow are not relied on |
| No `M3.f` DRC error at the macro edge | Still none with two macros |

## Provenance and limits

- The results were first read from the run's reports on 10 November 2026 and kept on the
  `claude/gate0-results` branch, from which this page is taken.
- The run's artifacts expire on 14 January 2027, so on 17 November 2026 the collector workflow archived its
  signoff reports in the `results-108e940-44203006494` branch. Every number on this page was checked against
  that archive (timing summary, metrics, precheck, gate-level results, hold-repair log), except the chase-loop
  slack, which comes from `tools/sdf_paths.py` and the SDF file, which the archive does not keep.
- The Gate 0 design itself is not in the current tree; it is in the history at commit `108e940`.
