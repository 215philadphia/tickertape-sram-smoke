"""Per-program configurations for the programs in compiled_tables.json.

Each entry is the `conf` of loader.load(). The timing values (p) assume the example's chip clock, which the
examples choose; they are stated with each example. To add a program, see host/README.md.

The "sim" variants are the exact values test/test_programs.py uses (bit period BP = 40 cycles at P = 1), which the
simulation tests compare against. The "board" variants give real baud rates at a clock the demo board can make and
MicroPython can service.
"""
import json

UIO = 0x8

# ---- simulation configs: identical to test/test_programs.py ----
SIM = {
    "uart_tx_dsl": dict(p=1, out_init=1, pinmode=0b01),
    "uart_rx_dsl": dict(p=1, out_init=0, pinmode=0, inmap01=0x10 | (UIO | 4)),
    "spi_tx_dsl": dict(p=4, out_init=0b100, pinmode=0b010101),
    "i2c_wr_dsl": dict(p=1, out_init=0b11, pinmode=0b1010, inmap01=(UIO | 1) << 4 | (UIO | 0), done_state="DONE"),
    "nt_rx": dict(p=1, out_init=0, pinmode=0, inmap01=0x10 | (UIO | 0)),
    "nt_trader_dsl": dict(p=2, out_init=0b100, pinmode=0b010101),
    "ps2_rx_dsl": dict(p=1, out_init=0, pinmode=0, cfg=0b10, inmap01=(UIO | 1) << 4 | (UIO | 0),
                       inmap23=(UIO | 0) << 4 | 0x2),
}
SIM["uart_rx_core1"] = dict(p=1, out_init=0, pinmode=0, inmap01=0x10 | (UIO | 4))   # test_compiled_uart_rx

# ---- board configs ----
# UART TX at 50 MHz: bit period = 40 cycles * P, so P = 11 gives 440 cycles = 113.6 kbaud (nominal 115.2k, -1.4%).
UART_TX_BOARD = dict(p=11, out_init=1, pinmode=0b01)
# I2C at 50 MHz: P = 1 gives the fast-mode 400 kHz SCL stated in docs/toolchain.md (not measured here).
I2C_BOARD = dict(p=1, out_init=0b11, pinmode=0b1010, inmap01=(UIO | 1) << 4 | (UIO | 0), done_state="DONE")
# Nano-Tick at 10 MHz: RX P = 26 gives 1040 cycles = 9615 baud; the trader runs at P = 256 so a MicroPython host
# polling the UART line can keep up. The comparator threshold is per demo.
NANO_RX_BOARD = dict(p=26, out_init=0, pinmode=0, inmap01=0x10 | (UIO | 0))
NANO_TRADER_BOARD = dict(p=256, out_init=0b100, pinmode=0b010101)


# UART RX, SPI TX and PS/2 at slow chip clocks the RP can drive or watch (see each example for the clock).
UART_RX_BOARD = dict(p=1, out_init=0, pinmode=0, inmap01=0x10 | (UIO | 0))            # core 0, line on uio[0]
SPI_TX_BOARD = dict(p=4, out_init=0b100, pinmode=0b010101)
PS2_BOARD = SIM["ps2_rx_dsl"]


def read_tables(path):
    """Read compiled_tables.json (the snapshot in test/ or the one model/run_tests.sh writes)."""
    with open(path) as f:
        return json.load(f)
