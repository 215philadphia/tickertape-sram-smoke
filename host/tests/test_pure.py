"""Fast tests with no simulator: library vs the FakeChip protocol model (fake_chip.py), the board adapter against a stub
of the SDK's port API, and the loader's pure functions. Run: python3 -m unittest test_pure  (from host/tests, with
host/ and ../../test on PYTHONPATH, as `make pure` does).

Scope: these show the layers compose and that the board adapter drives the pins as documented. They do NOT show the
RTL accepts those bytes (test_host_sim.py) or that the SDK behaves like the stub (needs hardware, unverified).
"""
import json
import os
import unittest

from fake_chip import FakeChip
from ttpfst import board, driver, loader, programs, runner, spi

HERE = os.path.dirname(os.path.abspath(__file__))
TABLES = json.load(open(os.path.join(HERE, "..", "..", "test", "compiled_tables.json")))


class FakeIO:
    """Executes SPI effects directly on a FakeChip."""
    def __init__(self, chip):
        self.chip = chip

    def do(self, eff):
        if eff[0] == spi.SPI:
            self.chip.pins(eff[1], eff[2], eff[3])
            return self.chip.miso
        return None


class FakeTT:
    """Stub of the ttboard DemoBoard port API: ports with an int .value; ui_in drives the FakeChip."""
    class Port:
        def __init__(self, on_set=None, on_get=None):
            self._v, self.on_set, self.on_get = 0, on_set, on_get

        @property
        def value(self):
            return self.on_get() if self.on_get else self._v

        @value.setter
        def value(self, v):
            self._v = v
            if self.on_set:
                self.on_set(v)

    def __init__(self, chip):
        self.chip = chip
        self.ui_in = self.Port(on_set=lambda v: chip.pins(v >> 4 & 1, v >> 5 & 1, v >> 6 & 1))
        self.uo_out = self.Port(on_get=lambda: chip.miso << 7)
        self.uio_in, self.uio_out, self.uio_oe_pico = self.Port(), self.Port(), self.Port()


class Layers(unittest.TestCase):
    def test_register_roundtrip(self):
        io = FakeIO(FakeChip())
        runner.run(driver.wreg(0x10, [7, 3, 0x0B, 0x1B, 0x66, 0xA5, 0x5A, 12]), io)
        self.assertEqual(runner.run(driver.rreg(0x10, 8), io), [7, 3, 0x0B, 0x1B, 0x66, 0xA5, 0x5A, 12])

    def test_table_bytes_msb_first(self):
        chip = FakeChip()
        io = FakeIO(chip)
        runner.run(driver.write_table(1, 2, [0x0A0B0C0D]), io)
        self.assertEqual(chip.tables[1][2], 0x0A0B0C0D)
        self.assertEqual(chip.frames[-1], [0x11, 2, 0x0A, 0x0B, 0x0C, 0x0D])

    def test_loader_programs_everything(self):
        chip = FakeChip()
        io = FakeIO(chip)
        prog = TABLES["i2c_wr_dsl"]
        runner.run(loader.load(0, prog, programs.SIM["i2c_wr_dsl"], "i2c"), io)
        self.assertEqual(chip.tables[0][:len(prog["table"])], prog["table"])
        done = prog["names"].index("DONE")
        ra, rb = prog["reset_sel"]
        self.assertEqual(chip.regs[:8], [1, int(prog["msb_first"]), ra | rb << 2, 0xE4, 0b1010, (8 | 1) << 4 | 8, 0x32, done])
        self.assertEqual(chip.regs[10], 0b11)

    def test_loader_reports_stuck_table_bit(self):
        io = FakeIO(FakeChip(corrupt_table_row=5))
        with self.assertRaises(loader.LoadError) as cm:
            runner.run(loader.load(0, TABLES["uart_rx_dsl"], programs.SIM["uart_rx_dsl"], "rx"), io)
        self.assertIn("first row 5", str(cm.exception))

    def test_done_state_by_name_and_errors(self):
        prog = TABLES["i2c_wr_dsl"]
        self.assertEqual(loader.resolve_done(prog, "DONE"), prog["names"].index("DONE"))
        self.assertEqual(loader.resolve_done(prog, None), 0xFF)
        with self.assertRaises(loader.LoadError):
            loader.resolve_done(prog, "NOPE")

    def test_argument_checks(self):
        with self.assertRaises(ValueError):
            runner.run(driver.write_table(2, 0, [0]), None)
        with self.assertRaises(ValueError):
            runner.run(driver.write_table(0, 250, [0] * 10), None)

    def test_ctrl_and_fifo_commands(self):
        chip = FakeChip()
        io = FakeIO(chip)
        runner.run(driver.start(1), io)
        runner.run(driver.tx_push(1, [1, 2]), io)
        self.assertEqual(chip.frames[-2:], [[0x41, 3], [0x31, 1, 2]])
        self.assertEqual(runner.run(driver.status(1), io) >> 6, 2)
        self.assertEqual(runner.run(driver.tx_room(1), io), 1)


class BoardAdapter(unittest.TestCase):
    def test_driver_over_board_io_stub(self):
        chip = FakeChip()
        io = board.BoardIO(FakeTT(chip), 50000000)
        runner.run(driver.wreg(0x20, [0x80, 0x77]), io)
        self.assertEqual(runner.run(driver.rreg(0x20, 2), io), [0x80, 0x77])
        prog = TABLES["uart_tx_dsl"]
        runner.run(loader.load(0, prog, programs.UART_TX_BOARD, "uart_tx"), io)
        self.assertEqual(chip.tables[0][:len(prog["table"])], prog["table"])

    def test_pin_layout(self):
        chip = FakeChip()
        tt = FakeTT(chip)
        io = board.BoardIO(tt, 50000000)
        io.do((spi.SPI, 1, 1, 0, 1, False))
        self.assertEqual(tt.ui_in.value, 0x08 | 1 << 4 | 1 << 5)           # SCK=ui_in[4], MOSI=ui_in[5], CS_n=ui_in[6]
        io.do((spi.SPI, 0, 0, 1, 1, False))
        self.assertEqual(tt.ui_in.value, 0x08 | 1 << 6)
        io.do((spi.UIO_IN, 0x01, 0x01))
        self.assertEqual((tt.uio_oe_pico.value, tt.uio_in.value), (1, 1))


if __name__ == "__main__":
    unittest.main()
