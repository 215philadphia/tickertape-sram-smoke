# Tests

cocotb tests that drive the whole chip (`tt_um_tickertape_pfst`) through its pins only, the way the demo board's
microcontroller would: every table, register write and byte goes in over the host SPI port, and every result is read
from the pins. They run on open-source tools: Icarus Verilog 12 and cocotb 2.0.1.

| File | Tests |
|---|---|
| `test_pfst.py` (5) | Register reset values and read-back; table write and read through the SRAM macro; a UART transmitter; UOMAP pass-through (direct and synchronized); PINMODE 3 row-controlled pins |
| `test_programs.py` (8) | Every program the OCaml compiler produces, loaded onto the chip and decoded from the pins: UART TX, UART RX at -1%, 0 and +1% baud error, SPI TX, I2C write against a reactive open-drain target (ACK and NACK), the two-core Nano-Tick trader, half-duplex UART on one PINMODE 3 wire, a PS/2 receiver, and an SPI target (MISO released when CS is high) |
| `test_ethernet.py` (4) | 10BASE-T at a 40 MHz clock ([docs/ethernet.md](../docs/ethernet.md)): link test pulses 16 ms apart, a Manchester frame at 10 Mb/s, the frame-start detector under jitter and duty-cycle distortion with the line passed through, and eleven planted bugs the checkers must catch. `eth_model.py` holds the waveform generator, the decoder and a Python model of one core that the test compares with the RTL frame by frame |

## Run them

```bash
pip install -r requirements.txt     # cocotb 2.0.1 (and pytest)
make -B                              # 17 tests, about 5 minutes (the first 13 take under a minute)
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

## Stress tests (not in the default run)

`test_stress.py` runs seeded random tests on the RTL: the SPI target with random frame lengths, SCK periods down to 12
cycles, random data, frames aborted by CS_n mid-byte (the target must resynchronise without a RESTART) and host-port
register reads in the background; random full 256-word tables on both cores; and table writes while a core runs.

```bash
make -B COCOTB_TEST_MODULES=test_stress                              # seed 1, about 2 minutes
SEED=7 STRESS_FRAMES=200 make -B COCOTB_TEST_MODULES=test_stress COCOTB_TEST_FILTER=test_stress_spi_target
```

Results so far (RTL, Icarus): seeds 1, 2 and 3 pass (60, 200 and 200 SPI-target frames, 134 of them aborted; 3 rounds
of random tables on both cores). With the target's pre-shift removed from its table, the stress test fails on the first
frame. Not run at gate level, and not run for other seeds or longer.
