# Tests

cocotb tests that drive the whole chip (`tt_um_tickertape_pfst`) through its pins only, the way the demo board's
microcontroller would: every table, register write and byte goes in over the host SPI port, and every result is read
from the pins. They run on open-source tools: Icarus Verilog 12 and cocotb 2.0.1.

| File | Tests |
|---|---|
| `test_pfst.py` (5) | Register reset values and read-back; table write and read through the SRAM macro; a UART transmitter; UOMAP pass-through (direct and synchronized); PINMODE 3 row-controlled pins |
| `test_programs.py` (7) | Every program the OCaml compiler produces, loaded onto the chip and decoded from the pins: UART TX, UART RX at -1%, 0 and +1% baud error, SPI TX, I2C write against a reactive open-drain target (ACK and NACK), the two-core Nano-Tick trader, half-duplex UART on one PINMODE 3 wire, and a PS/2 receiver |

## Run them

```bash
pip install -r requirements.txt     # cocotb 2.0.1 (and pytest)
make -B                              # 12 tests, a minute or two
```

`test_programs.py` loads its tables from `compiled_tables.json`, a snapshot of what the compiler produces.
`model/run_tests.sh` fails if the snapshot is out of date; refresh it with `cp ../model/compiled_tables.json .` after
changing a program.

## Gate level

After the Tiny Tapeout flow has hardened the design, copy the final netlist to `gate_level_netlist.v` and run the same
tests against it (CI does this in the `gl_test` job):

```bash
make -B GATES=yes
```

## Waveforms

```bash
gtkwave tb.fst tb.gtkw
```

or `surfer tb.fst`. Use `make -B FST=` and edit `tb.v` to write `tb.vcd` instead.

The formal proofs are separate: see [`../formal/README.md`](../formal/README.md).
