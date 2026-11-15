"""io object for the Tiny Tapeout demo board (RP2350, official MicroPython SDK "ttboard").

UNVERIFIED ON HARDWARE. This module is checked only against a stub of the SDK's port API in
host/tests/test_board_stub.py; nothing here has run on a real board or with a fabricated chip.
SDK facts used (read from github.com/TinyTapeout/tt-micropython-firmware, src/ttboard/demoboard.py):
  DemoBoard.get(), RPMode.ASIC_RP_CONTROL, tt.shuttle.<project>.enable(), tt.clock_project_PWM(hz),
  tt.reset_project(bool), ports ui_in / uo_out / uio_in / uio_out / uio_oe_pico with an int `.value`
  (named from the ASIC's point of view: the RP writes ui_in and reads uo_out).
"""
import time

from . import spi

PROJECT = "tt_um_tickertape_pfst"
UI_BASE = 0x08           # ui_in[3] high, as in the simulation Host (the INMAP default sources read it)
SCK, MOSI, CS_N, MISO = 4, 5, 6, 7


class BoardIO:
    """Executes effects on a ttboard.DemoBoard. `clock_hz` is the chip clock the effects' cycle counts refer to."""

    def __init__(self, tt, clock_hz, half_period_us=0, ui_other=0):
        self.tt = tt
        self.clock_hz = clock_hz
        self.half_period_us = half_period_us     # extra delay per SPI half period; 0 = as fast as MicroPython goes
        self.ui_other = ui_other                 # extra ui_in bits (ui_in[7] and INMAP sources) to keep driven
        self.oe = 0
        self.t0 = 0
        self.ui = UI_BASE | ui_other

    def _cycles_us(self, cycles):
        return cycles * 1000000 // self.clock_hz

    def _sleep_us(self, us):
        if us > 0:
            time.sleep_us(us) if hasattr(time, "sleep_us") else time.sleep(us / 1e6)

    def do(self, eff):
        k = eff[0]
        if k == spi.SPI:
            _, sck, mosi, cs_n, n, strict = eff
            v = (self.ui & ~((1 << SCK) | (1 << MOSI) | (1 << CS_N))) | sck << SCK | mosi << MOSI | cs_n << CS_N
            self.ui = v
            self.tt.ui_in.value = v
            self._sleep_us(self.half_period_us * n)
            m = (self.tt.uo_out.value >> MISO) & 1
            return m
        if k == spi.WAIT:
            self._sleep_us(self._cycles_us(eff[1]))
            return None
        if k == spi.UIO_OUT:
            return self.tt.uio_out.value
        if k == spi.UIO_IN:
            _, value, oe = eff
            self.oe = oe
            self.tt.uio_oe_pico.value = oe
            self.tt.uio_in.value = value
            return None
        if k == spi.UO_OUT:
            return self.tt.uo_out.value
        if k == spi.MARK:
            self.t0 = time.ticks_us() if hasattr(time, "ticks_us") else int(time.time() * 1e6)
            return None
        if k == spi.UNTIL:
            target = self._cycles_us(eff[1])
            now = time.ticks_us() if hasattr(time, "ticks_us") else int(time.time() * 1e6)
            self._sleep_us(self.t0 + target - now)
            return None
        if k == spi.UI_LOW:
            self.ui = (self.ui & ~0x07) | (eff[1] & 0x07)
            self.tt.ui_in.value = self.ui
            return None
        if k == spi.ELAPSED:
            now = time.ticks_us() if hasattr(time, "ticks_us") else int(time.time() * 1e6)
            return (now - self.t0) * self.clock_hz // 1000000
        raise ValueError("unknown effect %r" % (eff,))


def open_board(clock_hz=50000000, project=PROJECT, ui_other=0):
    """Select the design, clock it, reset it, and return a BoardIO. Needs the design to be in the released
    shuttle the board's firmware knows (tt.shuttle.<name> does not exist for an unfabricated design)."""
    from ttboard.demoboard import DemoBoard
    from ttboard.mode import RPMode
    tt = DemoBoard.get()
    tt.mode = RPMode.ASIC_RP_CONTROL
    getattr(tt.shuttle, project).enable()
    tt.clock_project_stop()
    tt.reset_project(True)
    tt.ui_in.value = UI_BASE | ui_other
    tt.uio_oe_pico.value = 0
    tt.clock_project_PWM(clock_hz)
    time.sleep(0.01)
    tt.reset_project(False)
    time.sleep(0.01)
    return BoardIO(tt, clock_hz, ui_other=ui_other)
