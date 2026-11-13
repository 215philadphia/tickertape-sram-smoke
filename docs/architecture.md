# Architecture and instruction set

TickerTape-Out is two **programmable finite state transducers (PFSTs)** on one Tiny Tapeout die, plus a host
SPI port, a pin mux and a comparator that links the two cores. A protocol is not a hardware block: it is a
table of up to 256 32-bit words loaded into a core's SRAM after fabrication. The RTL is in
[`src/pfst_core_sram.v`](../src/pfst_core_sram.v) (one core) and [`src/pfst_chip.v`](../src/pfst_chip.v)
(host port, registers, pin mux, comparator).

```
             ui_in / uio_in (24 pins)                                  uo_out / uio_out
                    |                                                        ^
       +------------+------------+                                           |
       | INMAP: 4 inputs per core |-------------------------+                |
       +------------+------------+                          |                |
                    v                                       v                |
   +-------------------------------+        +-------------------------------+|
   | core 0                        |        | core 1                        ||
   |  256x32 SRAM = table          |  SCR0  |  256x32 SRAM = table          ||
   |  SR, OBIT, CNT, TX FIFO, SCR  |--CMP-->|  SR, OBIT, CNT, TX FIFO, SCR  ||
   +---------------+---------------+        +---------------+---------------+|
                   | out[3:0], dir[3:0]                     |                |
                   +------------------+---------------------+                |
                                      v                                      |
                    OUTMAP / PINMODE (uio) and UOMAP (uo, with pass-through) +
```

## The core: a table-driven state machine

Each row of the table is one step of the machine. The SRAM's output register holds the row in effect, so
the SRAM itself is the state register: the next state comes straight out of the macro.

**Next-row address.** The table address is 8 bits:

```
address = { next_state[5:0], A, B }
```

`next_state` comes from the current row. `A` and `B` are two input bits, each chosen per row from four
sources, so every state has up to four successor rows, one per (A, B) combination. A state that reads no
inputs fills all four rows with the same word (the compiler does this; see [toolchain.md](toolchain.md)).

| Select value | Slot A source | Slot B source |
|---|---|---|
| 0 | `IN0` | `CNT_ZERO` (bit counter is 0) |
| 1 | `IN1` | `OBIT` (last bit shifted out) |
| 2 | `TX_FULL` (TX FIFO not empty) | `CMP` (comparator; core 1 only, 0 on core 0) |
| 3 | `IN2` | `IN3` |

The `selA`/`selB` fields of a row choose the sources that form the **next** row's address. The first
row after RUN uses the RSEL register instead.

**Datapath per core:** an 8-bit shift register `SR`, the bit last shifted out `OBIT`, a 4-bit bit counter
`CNT`, a 3-byte TX FIFO filled by the host, and a scratch register `SCR` the host reads.

## Table word format (the instruction set)

One 32-bit word per row. Bits [31:29] are unused.

| Bits | Field | Meaning |
|---|---|---|
| [1:0] | `selB` | Slot B source for the next address (table above) |
| [3:2] | `selA` | Slot A source for the next address |
| [5:4] | `op` | Datapath operation (below) |
| [6] | `osel` | 1: `out[0]` shows `OBIT` (after this row's op) instead of the `out[0]` bit |
| [10:7] | `out` | Values of the core's four outputs `out[3:0]` for this row |
| [18:11] | `wait` | Row length: the row lasts P x (1 + wait) clock cycles |
| [24:19] | `next` | Next state, 0 to 63 |
| [28:25] | `dir` | Drive enable per output, used only by pins in PINMODE 3 (spec v1.1) |

**Operations** (`op`), applied once when the row takes effect:

| Code | Op | Effect |
|---|---|---|
| 0 | `HOLD` | Nothing |
| 1 | `SHIFT` | Shift `IN0` into `SR` (LSB first: in at bit 7; MSB first: in at bit 0, per CFG). `OBIT` takes the bit shifted out. `CNT` decrements, stopping at 0. |
| 2 | `LOAD` | Pop the TX FIFO into `SR` (0 if empty) and set `CNT` to 8 |
| 3 | `SAVE` | Copy `SR` to `SCR`, set `RX_VALID` (and `RX_OVR` if it was already set), set `VALID` |

**Sticky status from rows:** fetching a row of state `DONE_STATE` sets `DONE`. With `CFG.flag_mode` set,
a row with `out[3] = 1` sets `FLAG`. Both can raise the IRQ pin.

## Timing

- **Row length is exact:** P x (1 + wait) cycles, where P is the per-core prescaler (1 to 256; 0 means 256).
  There is no counting overhead between rows.
- **Read-ahead:** the SRAM returns data one cycle after its address, so the next row is read in the **last**
  cycle of the current row. Inputs that form the address are therefore sampled in that last cycle. Internal
  sources use the values **after** the current row's op, so a 1-cycle row still sees its own op.
- **Inputs** pass through a 2-flop synchronizer (`IN0`..`IN3`).
- **Outputs are registered:** a row's `out` values appear one cycle after the row takes effect.

## Linking the cores: the comparator

`CMP = VALID0 & (SCR0 < THRESH)`, registered every cycle. Core 0 saves a byte (for example a received
price); core 1 branches on `CMP` through slot B. `VALID` is set by core 0's first `SAVE`, so core 1 cannot
act on a reset value. The two cores react to each other with no host involvement.

## Pins

The chip has 8 inputs (`ui_in`), 8 outputs (`uo_out`) and 8 bidirectional pins (`uio`), plus `clk` and
`rst_n`. The pinout is in [`info.yaml`](../info.yaml).

- **Inputs:** each core's `IN0`..`IN3` is chosen from any `ui_in` or `uio_in` pin by INMAP (4-bit index:
  bit 3 = 1 selects `uio_in`, bits [2:0] the pin).
- **Bidirectional pins:** `uio[3:0]` belong to core 0, `uio[7:4]` to core 1. For each pin, OUTMAP picks
  which `out` bit drives it and PINMODE sets its mode:

| PINMODE | Mode |
|---|---|
| 0 | Input (not driven) |
| 1 | Push-pull |
| 2 | Open drain: drives low for 0, releases for 1 (for I2C; needs external pull-ups) |
| 3 | Row-controlled: driven only while the current row's `dir` bit for that output is 1 (half-duplex, bus turnaround) |

- **Outputs:** `uo_out[5:0]` are set by UOMAP. Each can mirror any core output, or forward an input pin
  directly (gate delay only) or through a 2-flop synchronizer, while a core parses the same line. This is
  the "bump in the wire" mode. `uo_out[6]` is IRQ and `uo_out[7]` is the host SPI MISO.

## Host interface

SPI mode 0, MSB first: `ui_in[4]` SCK, `ui_in[5]` MOSI, `ui_in[6]` CS_n, MISO on `uo_out[7]`. Keep SCK at
or below 4 MHz with a 50 MHz clock. A response byte is shifted out during the byte after the one that
requested it. `c` is the core number (0 or 1).

| Command | Bytes sent | Effect |
|---|---|---|
| `WRITE_REG` | `0x01`, addr, data... | Write registers, address auto-increments |
| `READ_REG` | `0x02`, addr, dummy... | Register data returned from the 3rd byte on, address auto-increments |
| `WRITE_TABLE` | `0x10 + c`, row, 4 bytes per word (MSB first)... | Write table rows, row auto-increments. Ignored while the core runs. |
| `READ_TABLE` | `0x20 + c`, row, dummy... | Table words returned from the 3rd byte on. Reads 0 while the core runs. |
| `TX_PUSH` | `0x30 + c`, byte | Push a byte into the core's TX FIFO |
| `CTRL` | `0x40 + c`, value | Bit 0 RUN, bit 1 RESTART |
| `READ_SCR` | `0x50 + c`, dummy | Returns `SCR` and clears `RX_VALID` |

RESTART flushes the TX FIFO and clears `DONE`, `FLAG` and `TX_OVR`. It keeps `SCR`, `RX_VALID`, `RX_OVR`
and `VALID`, which only `READ_SCR` or reset clear. RUN starts from state 0. Tables can only be read or
written while a core is stopped, because each core's SRAM is single-port.

### Register map

Core registers sit at `0x00 + n` for core 0 and `0x10 + n` for core 1.

| n | Register | Reset | Contents |
|---|---|---|---|
| 0 | `P` | 1 | Prescaler (0 means 256) |
| 1 | `CFG` | 0 | Bit 0 MSB-first shifting, bit 1 flag mode |
| 2 | `RSEL` | 0 | Slot selects for the first row: bits [1:0] A, [3:2] B |
| 3 | `OUTMAP` | `0xE4` | 2 bits per pin: which `out` bit drives the pin (reset: identity) |
| 4 | `PINMODE` | 0 | 2 bits per pin (table above) |
| 5 | `INMAP01` | `0x10` | `IN0` source [3:0], `IN1` source [7:4] |
| 6 | `INMAP23` | `0x32` | `IN2` source [3:0], `IN3` source [7:4] |
| 7 | `DONE_STATE` | `0xFF` | State whose fetch sets `DONE` (`0xFF`: none) |
| 8 | `STATUS` (read) | | `{TX level[1:0], TX_OVR, FLAG, RX_OVR, RX_VALID, DONE, RUN}` |
| 9 | `STATE` (read) | | Current state |
| 10 | `OUT_INIT` | 0 | Output values while stopped and after RESTART |

| Address | Register | Contents |
|---|---|---|
| `0x20` | `THRESH` | Comparator threshold |
| `0x21` | `IRQ_EN` | Per core c: bit 4c `DONE`, bit 4c+1 `RX_VALID`, bit 4c+2 `FLAG` |
| `0x22`–`0x27` | `UOMAP[0..5]` | For `uo_out[j]`: bit 7 = 1 forwards input [3:0], directly if bit 6 = 1 or synchronized if 0. Otherwise bit 3 = 1 mirrors core [2], output [1:0]. |

## Reset and reload

Everything that matters is reset by `rst_n`; flip-flops do not power up at 0. Tiny Tapeout powers a design
down when it is deselected, so the host reloads tables and registers after selecting it again. The usual
start sequence: with the core stopped, `WRITE_TABLE`, then set `P`, `CFG`, `RSEL`, pin modes and `OUT_INIT`,
then `CTRL` with RUN and RESTART.

## Size

Each core's table is 64 states x 4 rows = 256 words, exactly one IHP `RM_IHPSG13_1P_256x32_c2_bm_bist`
macro. The chip uses two macros on an 8x4 tile allocation at 50 MHz. Signoff results are in the
[README](../README.md#signoff-status).
