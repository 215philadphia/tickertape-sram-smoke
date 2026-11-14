# Design evolution: from pitch to silicon

The concept behind TickerTape-Out originated with David Cox. It started as a one-page pitch: a
"bump-in-the-wire" protocol engine inspired by how trading firms parse market data in FPGAs. The core idea survived intact. Many details did not, and the
reasons are some of the most interesting engineering in the project. This page sets the original pitch
next to what was built and explains each change.

The pitch was followed by numbered specifications (v0.3, a "v1 timing" amendment, and v1.1), which the RTL
and model cite in their comments. This page compares the pitch with the design as it stands at v1.1.
Where a reason is stated in the source, the file is cited. Where a reason is our own engineering
reading of the trade-off, it says so.

## What stayed the same

- **A protocol is a state machine in SRAM, not a CPU program.** Each core concatenates its state with
  input bits to address an SRAM, and the word read back drives the pins directly. There is no instruction
  decoder or ALU.
- **A hardware wait timer** in every row, so a baud rate costs one row, not one row per clock cycle.
- **Two independent cores bridged by a comparator** on a saved byte against a host-set threshold.
- **An OCaml compiler** turning protocol descriptions into table words.
- **The Nano-Tick demo:** one core parses a price feed, the comparator fires, the other core sends a
  "BUY" order over SPI, with no host in the loop.
- **Timing closure at 50 MHz** on the Tiny Tapeout flow.

## What changed, and why

### The table word: 24 bits became 29

The pitch's word:

```
[23:18] next  [17:10] wait  [9:6] out  [5:2] dir  [1:0] cmd
```

The built word ([architecture.md](architecture.md#table-word-format-the-instruction-set)):

```
[28:25] dir  [24:19] next  [18:11] wait  [10:7] out  [6] osel  [5:4] op  [3:2] selA  [1:0] selB
```

**Address width forced input selection.** The pitch formed the address from the state and the
"physical inputs". With 6 state bits and 4 inputs that is 10 address bits: 1,024 rows. The IHP macro
that fits a core has 256 rows, or 8 address bits. So the built design addresses with the state plus **two**
input bits, and each row names which two of eight sources (pins, FIFO-full, bit counter, last bit out,
comparator) the *next* row will branch on. That costs 4 bits per word (`selA`, `selB`), and it means a
state can branch on internal conditions such as "byte finished" as well as pins. 64 states x 4 rows is
exactly one 256 x 32 macro.

**`osel` removes a row per bit value.** Without it, sending a byte needs separate rows for "drive 0" and
"drive 1". With `osel`, a row shows the shift register's output bit on `out[0]`, so a UART transmitter is
2 states (`uart_tx_dsl`).

**`dir` moved and narrowed.** In the pitch, every row set every pin's direction. In v1.1, each pin has a
static mode set by the host (input, push-pull, open drain, or row-controlled), and the row's `dir` bits
matter only for row-controlled pins. Open drain for I2C is then a pin setting, not something every row
of the program must repeat. `dir` sits at fixed bits [28:25] so that every table written before v1.1,
which has those bits 0, still works unchanged (`src/pfst_core_sram.v`, word-layout comment).

### The operations: Load_Scratchpad and Compare became LOAD and SAVE

The pitch's commands were `Hold`, `Shift`, `Load_Scratchpad` and `Compare`. The built ops are `HOLD`,
`SHIFT`, `LOAD` (pop a byte the host pushed into a 3-byte TX FIFO, and set the bit counter to 8) and `SAVE`
(copy the shift register to the scratch register the comparator and host read).

- **Transmitting needed a data source.** A row-only design has no way to get bytes from the host into the
  shift register. `LOAD` and the TX FIFO are that path, and they made programmable transmitters possible.
- **Compare stopped being an op.** The comparator evaluates `VALID & (SCR < THRESH)` continuously and
  presents the result as an input bit that core 1 can branch on (`src/pfst_chip.v`). No row has to spend
  its op on comparing.
- **`VALID` was added** so core 1 cannot trade on the scratch register's reset value before any price has
  arrived. A negative control in `model/main.ml` checks this: without the gate, the trader fires at reset.

### The cores: fixed roles became identical cores

The pitch made core 0 the receiver and core 1 the transmitter. The built cores are identical, and either
can run any program: the half-duplex UART both transmits and receives on one core, and the I2C master drives
the bus while reading back ACKs and clock stretching on the same core. The only
asymmetry is that the comparator feeds core 1. Our reading: fixing roles would have halved the chip's
flexibility, the competition's main judging criterion, for no saving in area.

### The comparator: "asynchronous interrupt" became a registered branch input

The pitch described the comparator firing an asynchronous interrupt to wake core 1. Built, it is a
registered bit sampled like any other branch input. Our reading: an asynchronous signal entering a
synchronous state machine invites metastability, and a registered bit keeps every reaction exactly
repeatable, which is the "zero jitter" the pitch promised. The cost is a few clock cycles of latency
(tens of nanoseconds at 50 MHz).

### Area: 6x4 tiles became 8x4

The pitch targeted 6x4 tiles (about 0.7 mm²). The competition raised the allocation to 8x4 tiles, confirmed
for the March 2027 shuttle, and the design uses it: core area 1.21 mm², two SRAM macros side by side,
15% utilization ([signoff](../README.md#signoff-status)). Before any PFST RTL existed, the project's first
step was a single-macro smoke test, which proved an IHP SRAM of this size survives the full Tiny Tapeout
flow.

### The compiler: monadic combinators became plain data

The pitch showed a monadic parser-combinator DSL:

```ocaml
let uart_rx = wait_for_start_bit >>= read_8_bits >>= verify_stop_bit >>= load_to_scratchpad
```

The built DSL deliberately has **no bind** (`model/compiler.ml`, header comment). In a monadic DSL, the
rest of the program after each `>>=` is an OCaml closure. The compiler cannot look inside a closure
without running it, so it cannot enumerate the state graph. The built DSL makes a program plain data: a
list of named states, each naming the inputs it reads and giving a total function from their values to a
row ([toolchain.md](toolchain.md)). The compiler can then walk every state and every input combination,
and it **rejects unreachable states and deadlock traps before a program ever runs**. That trade, less
syntactic elegance for programs that are checked at compile time, is the most important change in the
project.

Because a program is still ordinary OCaml, generating states remains easy: the PS/2 receiver builds its 30
parity-tracking bit states with a loop.

The output also changed from a hex payload to JSON (table words, state names, reset selects, bit order),
which the RTL tests load directly.

### Verification: from a plan to what was built

The pitch planned formal verification with SymbiYosys through a Hardcaml wrapper, and ASCII-waveform
expect tests with Hardcaml Waveterm. **The Waveterm tests were not built. The formal proofs were,** with
SymbiYosys and plain SystemVerilog properties instead of a Hardcaml wrapper. What was built
([verification.md](verification.md)):

- formal proofs of the core's exact timing, FIFO, flags and reset behaviour, and of pin safety, for every
  program ([formal/](../formal/README.md))
- an independent OCaml golden model, bit-exact against an earlier Python model
- protocol references written from the specs (UART, SPI, I2C with a timing checker)
- compile-time checks with must-reject programs
- deliberately broken tables that the tests must catch
- cocotb tests running every compiled program on the chip RTL, also at gate level after place and route

The verification write-up lists the gaps this leaves, including what the formal proofs do not cover.

### Nano-Tick: 10BASE-T Ethernet became UART

The pitch's Nano-Tick received prices as a 10BASE-T Ethernet UDP feed. The built demo receives them over
UART. Our reading of why Ethernet does not fit this architecture: 10BASE-T is Manchester-coded at
10 Mb/s, so a bit lasts 5 clock cycles at 50 MHz and mid-bit transitions are 2.5 cycles apart. Inputs pass
a 2-flop synchronizer and the engine takes one row per cycle, which leaves no margin to recover the clock
reliably. It would also need an external line receiver for the differential pair. The demo's point was
never the physical layer: it is two cores reacting to each other with no host, and that works today
([test](../test/test_programs.py), `test_compiled_nanotick`).

## Summary

| | Pitch | Built (v1.1) |
|---|---|---|
| Word | 24 bits | 29 bits in a 32-bit SRAM word |
| Address | State + physical inputs | State + 2 inputs selected per row |
| Ops | Hold, Shift, Load_Scratchpad, Compare | HOLD, SHIFT, LOAD (TX FIFO), SAVE |
| Cores | Core 0 RX, core 1 TX | Two identical cores |
| Comparator | Asynchronous interrupt | Registered branch input, gated by `VALID` |
| Pin direction | Every row sets every pin | Per-pin mode; row `dir` for row-controlled pins |
| Area | 6x4 tiles, ~0.7 mm² | 8x4 tiles, 1.21 mm² core |
| Compiler | Monadic combinators, hex output | Applicative data with compile-time checks, JSON output |
| Verification | Formal (planned), Hardcaml Waveterm (planned) | Formal proofs (SymbiYosys), golden model, references, negative controls, RTL and gate-level tests |
| Nano-Tick feed | 10BASE-T Ethernet | UART |
| Protocols | UART baseline | UART, SPI, I2C, half-duplex UART, PS/2, two-core Nano-Tick |
