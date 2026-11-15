# Host software for the Tiny Tapeout demo board

Loads OCaml-compiled programs (`compiled_tables.json`) onto the TickerTape-Out chip over its SPI host port and
runs them. The chip loses its tables and registers whenever it is reset or deselected, so every session starts
with a load.

**Status, stated plainly.** Everything below the board adapter is tested against the chip RTL in simulation (see
[Verification](#verification)). The board adapter (`ttpfst/board.py`, `open_board`) has **never run on a real
board**: no hardware was available, and the chip is not fabricated. It is written from the SDK source and tested
only against a stub of the SDK's port API. Treat the timing numbers in the examples as estimates until measured.

## Layout

| File | Role |
|---|---|
| `ttpfst/spi.py` | SPI mode 0 master as a generator of pin effects. The only place that knows bit timing |
| `ttpfst/driver.py` | Host commands: `wreg`, `rreg`, `write_table`, `read_table`, `tx_push`, `ctrl`/`start`/`stop`, `read_scr`, `status`, `tx_room` |
| `ttpfst/loader.py` | `load(core, prog, conf)`: stop, write table, read it back, write registers, read them back |
| `ttpfst/programs.py` | Configurations (`conf`) for each program: `SIM` (equal to `test/test_programs.py`) and `*_BOARD` |
| `ttpfst/runner.py` | `run(gen, io)`: executes a generator against the board or any io object |
| `ttpfst/board.py` | `BoardIO` and `open_board()` for the demo board (MicroPython SDK) |
| `examples/` | `uart_tx.py`, `uart_rx.py`, `spi_tx.py`, `spi_target.py`, `i2c_write.py`, `ps2_rx.py`, `nano_tick.py` (both cores) |
| `tests/` | cocotb tests on the RTL, fast protocol-model tests, and `mutate.sh` (planted bugs) |

### How one code base runs on the board and in simulation

Driver functions are generators. They never touch a pin: they `yield` an *effect* such as
`(SPI, sck, mosi, cs_n, n_halves, strict)` and are sent back the result (the MISO level). On the board
`runner.run` executes the effects through the SDK; under cocotb `tests/cocotb_io.py` executes the very same
effects against the RTL. Effects are listed in `ttpfst/spi.py`. The code avoids anything MicroPython lacks
(no typing, dataclasses or `async`).

## Chip facts used (from this repo, checked against the tests)

- Host SPI: mode 0, MSB first. `ui_in[4]` SCK, `ui_in[5]` MOSI, `ui_in[6]` CS_n, MISO on `uo_out[7]`.
  SCK at most 4 MHz with a 50 MHz chip clock; `ui_in[3]` is kept high like the testbench does.
- Commands: `0x01` WRITE_REG, `0x02` READ_REG, `0x10+c` WRITE_TABLE, `0x20+c` READ_TABLE, `0x30+c` TX_PUSH,
  `0x40+c` CTRL (bit 0 RUN, bit 1 RESTART), `0x50+c` READ_SCR. Responses arrive from the third byte of a frame.
- Tables load only while the core is stopped. `loader.load` stops the core first.
- CS_n must stay high at least 8 chip cycles between frames; `spi.py` holds it 2 SPI half periods.
- The 3-byte TX FIFO overflows if you push a 4th byte; check `tx_room` first.

## Board setup

The board is the Tiny Tapeout demo board (RP2350) running the official MicroPython firmware
([tt-micropython-firmware](https://github.com/TinyTapeout/tt-micropython-firmware), SDK package `ttboard`).
The SDK API this code relies on (read from that repository's `src/ttboard/demoboard.py`):

| Need | SDK call |
|---|---|
| Get the board | `DemoBoard.get()` |
| RP drives the inputs, watches the outputs | `tt.mode = RPMode.ASIC_RP_CONTROL` |
| Select the design | `tt.shuttle.tt_um_tickertape_pfst.enable()` |
| Clock | `tt.clock_project_PWM(hz)` / `tt.clock_project_stop()` |
| Reset | `tt.reset_project(True)` then `(False)` |
| Pins | `tt.ui_in.value` (RP writes), `tt.uo_out.value` (RP reads), `tt.uio_in.value`, `tt.uio_out.value`, `tt.uio_oe_pico.value` (1 = RP drives that pin) |

**Blocking dependency:** `tt.shuttle.<name>` only exists for designs in the shuttle the firmware knows, which
needs the chip to be fabricated and the firmware's shuttle list to include it. Until then `open_board()` raises
`AttributeError`. Nothing here can work before that. `uio` pins are bidirectional: only set an `oe` bit for a pin
the chip does not drive (`INMAP` sources 8 to 15), or the RP and the chip contend.

Install on the board (from your PC, with [`mpremote`](https://docs.micropython.org/en/latest/reference/mpremote.html)):

```bash
mpremote cp -r host/ttpfst :ttpfst
mpremote cp -r host/examples :examples
mpremote cp test/compiled_tables.json :compiled_tables.json
mpremote repl
```

then in the REPL: `import examples.uart_tx as e; e.main()`. Use a fresh `compiled_tables.json` from
`cd model && ./run_tests.sh` when programs change (`model/compiled_tables.json`).

### Wiring and Pmods (all 3.3 V)

| Example | Pins | External parts |
|---|---|---|
| `uart_tx` | `uio[0]` = TX | USB-UART adapter RX to `uio[0]`, GND common. 115200 baud nominal (113.6 kbaud actual) |
| `i2c_write` | `uio[0]` SDA, `uio[1]` SCL | **Pull-ups required**: 2.2 to 4.7 kOhm from SDA and SCL to 3.3 V (the chip only pulls low). Target must be a 3.3 V device |
| `uart_rx` | none (the RP drives the line on `uio[0]`) | none |
| `spi_tx` | `uio[2]` CS_n, `uio[1]` SCK, `uio[0]` MOSI | logic analyzer or an SPI device (3.3 V) |
| `spi_target` | none (the RP plays the master on `ui_in[2:0]`); MISO on `uio[0]` | for a real master: its MOSI, SCK, CS_n to `ui_in[0]`, `ui_in[1]`, `ui_in[2]`, MISO from `uio[0]`, all 3.3 V |
| `ps2_rx` | none (the RP plays a keyboard on `uio[1:0]`) | a real keyboard needs level shifting and pull-ups: untested |
| `nano_tick` | none for the price line (the RP drives `uio[0]` itself); orders on `uio[6:4]` (CS, SCK, MOSI) | Optional: logic analyzer on `uio[6:4]` |

The I2C example only writes (it does not read), so a sensor or EEPROM is exercised through its write path.

## Running the examples

Each example exposes a generator (`send`, `receive`, `write`, `trade`, ...) used by the simulation tests, and `main()` for the
board. They all follow the same sequence, taken from `test/test_programs.py`: `loader.load` (stop, table with
read-back, `OUT_INIT`, registers with read-back), then `driver.start` (RESTART and RUN), then push TX bytes **after**
the start (RESTART flushes the FIFO).

| Example | Chip clock | Config | Expected |
|---|---|---|---|
| `uart_tx` | 50 MHz | P = 11 | 8N1 frames at 113.6 kbaud on `uio[0]` |
| `i2c_write` | 50 MHz | P = 1 | ACK from the target, `DONE` in STATUS; wrong address gives NACK and still `DONE` |
| `uart_rx` | 1 MHz | P = 1 | each byte read back with `READ_SCR`, no `RX_OVR`; tolerant of +-1% baud error in simulation |
| `spi_tx` | 1 MHz | P = 4 | each pushed byte appears as one mode 0 frame (SCK rate not measured) |
| `spi_target` | 1 MHz | P = 1, half period 100 cycles | the pushed reply bytes come back on MISO and each MOSI byte is read with `READ_SCR` |
| `ps2_rx` | 100 kHz | P = 1 | good frames received; bad parity or stop bit saves nothing and raises `FLAG` |
| `nano_tick` | 10 MHz | RX P = 26, trader P = 256 | prices 120, 90, 80, 130, 99, 150, 100, 60, 101 with threshold 100 give 3 orders `BUY` |

Not covered: the half-duplex UART (`hd_uart_dsl`) has no host example or board configuration; it needs a reactive far end on one wire (see `test_compiled_half_duplex`).

## Adding a program

1. Write it in `model/dsl_programs.ml`, run `cd model && ./run_tests.sh`; it exports `compiled_tables.json`
   (and the snapshot in `test/` is kept in sync).
2. Add a configuration to `ttpfst/programs.py`: a dict with `p`, `out_init`, `pinmode` and optionally `cfg`,
   `outmap`, `inmap01`, `inmap23`, `done_state` (a state number or a state **name**), `thresh`, `uomap`. Meaning
   of every key: top of `ttpfst/loader.py`. Port the values from the program's test in `test/test_programs.py`.
3. Write a generator like the examples: `yield from loader.load(core, tables[name], conf, name)`,
   `yield from driver.start(core)`, then the pushes and polls the protocol needs.
4. Add a simulation test in `tests/test_host_sim.py` that runs the generator and checks the pins with an
   independent decoder (reuse the decoders in `test/test_programs.py`).

## Verification

```bash
cd host/tests
make pure          # fast, no simulator: library and board adapter against a protocol model
make -B            # host software against the chip RTL (cocotb + Icarus)
./mutate.sh        # plants bugs in a copy of the library; every one must make a test fail
```

CI runs all three on every push (`.github/workflows/host.yaml`). Results of the last local run are in the pull
request description. What each level does and does not show:

| Level | Shows | Does not show |
|---|---|---|
| `make -B` (RTL) | The host's bytes are accepted by the chip RTL; tables and registers read back through the independent reference `Host` (so a symmetric byte-order bug cannot hide); UART TX, I2C write and Nano-Tick behave as in `test_programs.py` | Anything about real clocks, MicroPython speed or the board |
| `make pure` | The effect layer and the board adapter drive the documented pins in the documented order against a model of *our reading* of the protocol | That the RTL or the SDK agrees (the model is not evidence about either) |
| `mutate.sh` | The tests are able to fail on the planted faults listed in the script | That no other bug exists |
| `restart_semantics` test | `start()` clears DONE and flushes the TX FIFO of a core that already ran (closes the gap `mutate.sh` found in the first version) | |
| Hardware | Not done | Everything marked unverified above |
