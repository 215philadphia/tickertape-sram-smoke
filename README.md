# TickerTape-Out: programmable finite state transducer

A Tiny Tapeout project on the IHP CMOS5L flow (`ttihp-verilog-template@cmos5l`,
`tt-gds-action@ihp-cmos5l`), **8x4 tiles** (Jane Street competition allocation), 50 MHz.

TickerTape-Out is a protocol emulator built from two programmable finite state transducers (PFSTs).
Each core is a table-driven state machine whose transition table lives in its own IHP
`RM_IHPSG13_1P_256x32_c2_bm_bist` SRAM macro, so UART, SPI and I2C are firmware tables, not hardware blocks.
A host loads tables and configuration over an SPI port.

## At a glance

**A protocol is data, not hardware.** Each core is a state machine whose whole program is one 256-word
table in SRAM: every row picks the next state from two input bits, sets four pins, waits an exact number of
cycles and does one datapath operation. New protocols are new tables, loaded after fabrication.

**Demonstrated on the chip RTL, every one from the same compiler** ([tests](test/test_programs.py), also run
at gate level after place and route):

| Program | States | What it shows |
|---|---|---|
| UART TX / RX | 2 / 4 | RX holds sync at ±1% baud error |
| SPI controller | 4 | Mode 0, MSB first |
| I2C write | 14 | Open drain, clock-stretch aware, ACK and NACK, against a reactive target |
| Half-duplex UART | 6 | One wire: the program itself turns the line around each row (`dir` bits), zero contention cycles |
| SPI target | 19 | **The other side of SPI:** mode 0, MSB first, full duplex; MISO is released when CS is high (`dir` bits), tested down to a 12-cycle SCK period |
| PS/2 receiver | 39 | **A protocol the chip was not designed around**, with parity checked by carrying it in the state number |
| Nano-Tick trader | 4 + 9 | **Two cores, no host:** core 0 receives prices over UART, a comparator fires, core 1 sends an SPI order |
| Ethernet MAC transmitter (MII) | 20 to 46 + 1 | **A whole valid Ethernet frame** ([study](docs/ethernet.md)): an ARP request or UDP datagram compiled into the table and sent as MII nibbles to a standard PHY chip at 10 Mb/s, 50 MHz clock. Checked against a PHY model in RTL and gate-level simulation; no PHY hardware connected; transmit only |
| 10BASE-T link pulses | 4 + 2 | **The 10BASE-T line itself, in part**, at a 40 MHz clock: 100 ns pulses exactly 16 ms apart, core 0 timing core 1 through the comparator |
| 10BASE-T Manchester transmit | 4 + 24 | Preamble, SFD and up to 3 bytes at the true 10 Mb/s, every edge on the 50 ns grid. Not a full frame: the FIFO holds 3 bytes |
| 10BASE-T frame-start detector | 27 | Marks the end of the SFD while passing the line through; correct up to ±12.5 ns of edge jitter with 4 samples per bit |

**What the architecture makes possible:**

- **Exact timing for free:** a row lasts P x (1 + wait) cycles with no fetch or decode overhead, because the
  SRAM's output register *is* the state register and the next row is read during the current one.
- **Cores that react to each other:** core 0's last received byte feeds a comparator that core 1 branches on.
- **Bump in the wire:** any output can forward an input pin, directly or synchronized, while a core parses it.
- **Bus turnaround in the program:** pins in PINMODE 3 drive only in rows whose `dir` bits say so.

**Programs are checked before they run.** The [compiler](docs/toolchain.md) is a deep-embedded OCaml DSL: a
program is plain data, so the compiler walks every state and input combination and rejects unreachable
states, deadlock traps and out-of-range fields at compile time.

**Verified in layers** ([write-up](docs/verification.md)): formal proofs, for every program, that rows last
exactly P x (1 + wait) cycles and that the FIFO and pins behave ([formal/](formal/README.md)); an independent golden
model bit-exact against an earlier Python model; protocol references written from the specs; must-reject compiler
controls; deliberately broken tables that the tests must catch; and RTL plus gate-level tests on the chip itself.
Signoff on the Tiny Tapeout flow: timing met, DRC and LVS clean, precheck passes ([status](#signoff-status)).

**What it is for.** A reprogrammable tool for hardware debugging: emulate either side of a low-speed
protocol, or sit in the wire and parse a live line while passing it through. Its ideas (deterministic
table-driven parsing, host-free reaction between engines, compile-time checked state machines) are the
ones trading firms use at full scale in FPGAs, for example in hardware pre-trade risk checks
([applications](docs/applications.md)).

## Documentation

| Document | Contents |
|---|---|
| [Architecture and instruction set](docs/architecture.md) | Core, table word format, timing, comparator, pins, host commands, register map |
| [Toolchain and example programs](docs/toolchain.md) | The OCaml DSL and compiler, its static checks, the example programs, loading a program |
| [10 Mbit Ethernet study](docs/ethernet.md) | Real frames through a PHY chip over MII; three measured pieces of the 10BASE-T line driven directly; the exact limits; what a version 2 would need |
| [Verification approach](docs/verification.md) | Golden model, independent protocol references, negative controls, RTL and gate-level tests, signoff, known gaps |
| [Formal proofs](formal/README.md) | What is proved for every program, the assumptions, what is not proved, and how to rerun them |
| [Applications](docs/applications.md) | What the chip is for (hardware debugging), and where its ideas apply in trading hardware |
| [Gate 0](docs/gate0.md) | The smoke test that proved the SRAM macro on this flow before the design was written, with its signoff results |
| [Design evolution](docs/design-evolution.md) | From the original pitch to the built design: what changed and why |
| [Host software](host/README.md) | Loading programs from the Tiny Tapeout demo board: driver, loader, examples, what is and is not verified |
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
| `tools/` | `sdf_paths.py`: the timing-path tracer used to measure Gate 0's SRAM loop |
| `macro/` | IHP 256x32 SRAM macro LEF |
| `librelane_plugin_sram_pdn.py`, `odb_sram_stripes.py` | Macro power hookup for the LibreLane flow |
| `test/` | cocotb tests: chip features (`test_pfst.py`), every compiled program on the chip (`test_programs.py`) the Ethernet MAC transmitter over MII (`test_mii.py`) and the 10BASE-T programs at 40 MHz (`test_ethernet.py`), with the IHP SRAM simulation models in `test/models` |
| `study/` | Version-2 Ethernet transmit sketch for an area estimate. A study, not part of the chip |
| `model/` | OCaml golden model and PFST compiler, see [`model/README.md`](model/README.md) |
| `host/` | Demo-board host software (MicroPython): loader, examples and simulation tests, see [`host/README.md`](host/README.md) |
| `docs/` | Datasheet text (`info.md`) and the documents listed above |
| `.github/workflows/` | `gds`, `test`, `model`, `fpga`, `docs` CI jobs |

## Running the tests

RTL testbench (needs Icarus Verilog 12 and cocotb 2.0.1):

```bash
cd test && make -B
```

21/21 pass (about 6 minutes; the 13 that are not Ethernet take under a minute). `test_pfst.py` covers the chip's features: registers, table write/read through the SRAM macro,
a UART transmitter, UOMAP pass-through and PINMODE 3 row-controlled pins. `test_programs.py` runs every
program the OCaml compiler produces on the chip and decodes the pins: UART TX, UART RX at ±1% baud error,
SPI TX, I2C write against a reactive target, the two-core Nano-Tick trader, half-duplex UART on one wire,
a PS/2 receiver with parity checking, and an SPI target answering a master. `test_ethernet.py` runs the 10BASE-T
programs with a 40 MHz clock: link test pulses, a Manchester frame, the frame-start detector under jitter, and
eleven planted bugs that its checkers must catch. `test_mii.py` sends complete Ethernet frames as MII nibbles to a
model of a PHY chip and checks every field, the frame check sequence and the signal timing
([docs/ethernet.md](docs/ethernet.md)).

Gate-level: after hardening, copy the netlist to `test/gate_level_netlist.v` and run `make -B GATES=yes`. More in
[`test/README.md`](test/README.md).

OCaml golden model and compiler (needs `ocamlfind`):

```bash
cd model && ./run_tests.sh
```

All checks pass: cross-checks against Python reference vectors, I2C and Nano-Tick system tests, compiler
static checks and must-reject controls; it also exports the sixteen compiled programs to `compiled_tables.json`.

Formal proofs (needs `yosys`, `cvc5` and SymbiYosys; see [`formal/README.md`](formal/README.md)):

```bash
formal/run.sh
```

The proofs cover the core's exact row timing, the TX FIFO, flags and reset behaviour, and pin safety, for every
program; the whole suite takes about a minute.

## Signoff status

From [gds run #79](https://github.com/215philadphia/tickertape-sram-smoke/actions/runs/43758521649) on commit
`fa0fd32`; reports are on the `results-fa0fd32-43762985107` branch published by the collector. The RTL is unchanged
from the earlier signoff runs (#28, #55, #73). Two flow changes since run #73 are described below: both SRAM macros
are at orientation MX, and each timing corner now loads the matching SRAM timing library.

| Check | Result |
|---|---|
| `gds` job | Pass. Die 1724.16 x 710.64 um (8x4), core area 1.208 mm², utilization 14.9% (standard cells 7.3%) |
| Setup, slow corner (1.08 V, 125 C) | Met. Worst slack 6.20 ns (`rst_n` input to a flip-flop); worst register-to-register slack 9.01 ns, which bounds the `A_DOUT -> A_ADDR` loop |
| Hold | Met. Worst slack 0.059 ns (fast corner) |
| KLayout DRC | Clean (precheck: SG13CMOS5L DRC, pin labels, zero area) |
| LVS | Clean (0 errors, 0 unmatched nets, devices or pins); this is the power-hookup signoff |
| Antenna | 0 violations |
| `precheck` job | Pass |
| `gl_test` job | Pass |

Open items:

- **Electrical rule violations** in post-route STA: 0 max-capacitance, 2 max-slew and 1 max-fanout violation. The
  slew violators are two SRAM address inputs driven by hold-fix delay cells: `sram1/A_ADDR[1]` (0.904 ns against a
  0.595 ns limit at the slow corner, 0.584 against 0.476 ns at the typical corner) and `sram1/A_ADDR[0]` (0.720 ns,
  slow corner only); the fast corner has none. The fanout violator is the clock root buffer `clkbuf_0_clk_regs` (16
  against a limit of 8). They do not fail the flow, but should be fixed or explained before submission.
- **Why the macros are MX:** each SRAM's signal pins sit on its y=0 edge. At R0 that edge faced away from the TT I/O
  pins on the die's top edge, so nets wrapped around the macros. With both macros at R0 (run #73) the flow left 21
  max-cap, 11 max-slew and 3 max-fanout violations (setup slack 4.17 ns); flipping only `sram0` gave 2/19/1; flipping
  both (run #77) gave 0/7/1 and halved the routed wirelength (490k to 263k um). DRC, LVS, precheck and gl_test pass in
  all three.
- **SRAM timing libraries per corner:** up to run #77 every corner loaded the typical SRAM library, because the
  `lib` keys in `src/config.json` (`nom_*`, `min_*`, `max_*`) were matched against corner names that all start with
  `nom_`. The keys are now `*_typ_*`, `*_fast_*` and `*_slow_*`, so the slow corner uses the slow SRAM library
  (1.08 V, 125 C) and the fast corner the fast one (1.32 V, -55 C; the closest available to the corner's -40 C).
  Earlier slow- and fast-corner numbers therefore used typical SRAM timing. With the right libraries (run #79)
  register-to-register setup slack went from 11.35 to 9.01 ns and hold slack from 0.106 to 0.059 ns, both still met.
- Expected and accepted by config: 16264 pdngen power-grid warnings (the SRAM stripes are bridged after that check;
  LVS is the connectivity signoff) and 182 Magic illegal-overlap reports (false positive on the macro's LEF Metal4
  obstruction; Magic DRC is off and KLayout DRC is the physical signoff).

If KLayout DRC ever reports `M3.f` at a macro edge, add a Metal3 `ROUTING_OBSTRUCTIONS` strip there.

## History

This repo started as Gate 0, a single-macro smoke test that checked whether a user SRAM of this size survives
GDS, precheck, LVS and gate-level test on the CMOS5L flow. It passed all five checks; the PFST design replaced
that test design. Results: [docs/gate0.md](docs/gate0.md).

## Credits and provenance

**Concept:** David Cox originated the idea behind TickerTape-Out: a programmable finite state transducer
used as a "bump-in-the-wire" protocol engine. See [design evolution](docs/design-evolution.md) for how the
concept became the built design.

**Design, implementation, development and engineering:** Jonathan Clark.

Macro integration (PDN plugin, `odb_sram_stripes.py`, `pdn_cfg.tcl`, config keys)
is adapted from [WilliamZhang20/protocol-emulator](https://github.com/WilliamZhang20/protocol-emulator)
(Apache-2.0), which passed full TT cmos5l precheck with `RM_IHPSG13_1P_1024x8_c2_bm_bist`
([tt-support-tools PR #187](https://github.com/TinyTapeout/tt-support-tools/pull/187)).
That work in turn builds on [kdp1965/ihp-um-janestreet-prism](https://github.com/kdp1965/ihp-um-janestreet-prism).
SRAM models in `test/models` are from IHP-Open-PDK (Apache-2.0).
