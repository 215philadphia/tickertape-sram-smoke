# Toolchain and example programs

Programs for the PFST are written in a small OCaml DSL and compiled to table words by
[`model/compiler.ml`](../model/compiler.ml). The word format the compiler emits is described in
[architecture.md](architecture.md#table-word-format-the-instruction-set).

## Writing a program

A program is plain data: a list of named states. Each state names the (at most two) input signals it
reads and gives a total function from their values to a row. There is no monadic bind and no hidden
continuation, so the compiler can walk every state and every input combination without running anything.

A complete UART transmitter, from [`model/dsl_programs.ml`](../model/dsl_programs.ml):

```ocaml
let uart_tx_dsl () =
  let states = [
    st "IDLE" [TxFull] (fun c -> if c.(0) then load ~wait:bw "DATA" else hold ~out:1 "IDLE");
    st "DATA" [CntZero] (fun c -> if c.(0) then hold ~out:1 ~wait:bw "IDLE"
                           else shift ~out:1 ~osel:1 ~wait:bw "DATA");
  ] in
  { pname = "uart_tx_dsl"; start = "IDLE"; states; msb_first = false; terminals = [] }
```

`IDLE` waits for the host to push a byte, then `LOAD`s it (driving the start bit, `out[0] = 0`). `DATA`
shifts the byte out one bit period per row, showing `OBIT` on `out[0]` (`osel`), and drives the stop bit
when the bit counter reaches 0. `bw` is the wait field for one bit period, so the baud rate is set by `wait`
and the prescaler `P`, not by hardware.

Row constructors: `hold`, `shift`, `load`, `save`, each taking `?out`, `?osel`, `?wait`, `?dir` and the
next state's name. Input signals: `In0`..`In3`, `TxFull`, `CntZero`, `Obit`, `Cmp`.

## What the compiler checks

Before emitting anything, `compile` rejects:

- duplicate, undeclared or unreachable states
- **deadlock traps**: a reachable state from which neither the start state nor a declared terminal can be
  reached (terminals are sinks the host recovers with RESTART, such as an I2C `DONE` state)
- states reading more than two inputs, or two inputs that cannot go in different slots
- `wait`, `out`, `osel` or `dir` out of range
- more than 64 states (the chip's state field is 6 bits)

It then numbers the states (start state = 0), places each state's inputs in slot A or B, and fills all
four rows of every state. Rows for a slot the state does not read are duplicated, not left empty, because
the hardware still samples that slot. The `selA`/`selB` of each row are set from the **next** state's
inputs.

## Example programs

All are in [`model/dsl_programs.ml`](../model/dsl_programs.ml), compiled and checked by
[`model/compile_test.ml`](../model/compile_test.ml).

| Program | States | What it does |
|---|---|---|
| `uart_tx_dsl` | 2 | UART transmitter, 8N1, LSB first |
| `uart_rx_dsl` | 4 | UART receiver with start-bit check and framing-error state; tested at 0 and ±1% baud error |
| `spi_tx_dsl` | 4 | SPI controller transmit, mode 0, MSB first (CS, SCK, MOSI on `out[2:0]`) |
| `i2c_wr_dsl` | 14 | I2C controller write, fast mode (400 kHz at 50 MHz), open drain, ends in a `DONE` terminal |
| `nt_trader_dsl` | 9 | "Nano-Tick" trader on core 1: when core 0's received price drops below `THRESH` (`CMP`), send a fixed 3-byte SPI order, then wait for `CMP` to clear before re-arming |
| `hd_uart_dsl` | 6 | Half-duplex single-wire UART: send a request, release the wire (`dir`), receive and save the reply |

The test file also holds programs that must be rejected (unreachable state, deadlock traps, out-of-range
fields, too many states or inputs). They prove the static checks work.

## Building and exporting

```bash
cd model && ./run_tests.sh
```

Needs `ocamlfind` with the `str` package. This builds and runs the golden-model suite and the compiler
suite, then writes every example program as JSON to `model/compiled_tables.json`: the table (row-indexed
words), state names in numbering order, reset selects and bit order. CI runs the same script on every push
and uploads the JSON as the `model_results` artifact.

## Loading a program onto the chip

Over the host SPI port ([architecture.md](architecture.md#host-interface)), with the core stopped:

1. `WRITE_TABLE` (`0x10 + c`, starting row, then 4 bytes per word, MSB first)
2. `WRITE_REG` `P`, `CFG` (MSB-first flag from the program), `RSEL` (the program's reset selects), the pin
   mux registers and `OUT_INIT`
3. `CTRL` (`0x40 + c`) with RUN and RESTART

[`test/test_pfst.py`](../test/test_pfst.py) does exactly this for a UART transmitter (`test_uart_tx`) and
decodes the result from the pin. On the Tiny Tapeout demo board, the RP2040/RP2350 can act as the SPI host.
