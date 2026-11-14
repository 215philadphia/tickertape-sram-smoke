"""Simulation io: executes the host library's effects against the chip RTL under cocotb.

This is the async twin of ttpfst.runner.run + board.BoardIO. SPI timing is the same 7 chip cycles per half period
as test/test_pfst.py's reference Host, so the host library and the reference drive the chip identically.
"""
from cocotb.triggers import FallingEdge

from ttpfst import spi

H = 7   # chip cycles per SPI half period, as in test/test_pfst.py


class CocoIO:
    def __init__(self, dut, ref_host):
        self.dut = dut
        self.ref = ref_host          # reference Host (test_pfst.Host): shares ui7 and the ui_in layout
        self.now = 0
        self.t0 = 0

    async def cycles(self, n):
        for _ in range(n):
            await FallingEdge(self.dut.clk)
        self.now += n

    async def do(self, eff):
        k = eff[0]
        if k == spi.SPI:
            _, sck, mosi, cs_n, n, strict = eff
            self.dut.ui_in.value = 0x08 | sck << 4 | mosi << 5 | cs_n << 6 | self.ref.ui7 << 7
            await self.cycles(H * n)
            v = self.dut.uo_out.value
            if not v.is_resolvable:
                if strict:
                    raise AssertionError("X/Z on MISO: %s" % v)
                return 0
            return (int(v) >> 7) & 1
        if k == spi.WAIT:
            await self.cycles(eff[1])
            return None
        if k == spi.UIO_OUT:
            v = self.dut.uio_out.value
            if not v.is_resolvable:
                raise AssertionError("X/Z on uio_out: %s" % v)
            return int(v)
        if k == spi.UIO_IN:
            self.dut.uio_in.value = eff[1]
            return None
        if k == spi.UO_OUT:
            return int(self.dut.uo_out.value)
        if k == spi.MARK:
            self.t0 = self.now
            return None
        if k == spi.UNTIL:
            await self.cycles(max(0, self.t0 + eff[1] - self.now))
            return None
        if k == spi.ELAPSED:
            return self.now - self.t0
        raise ValueError("unknown effect %r" % (eff,))

    async def run(self, gen):
        try:
            eff = next(gen)
            while True:
                eff = gen.send(await self.do(eff))
        except StopIteration as e:
            return e.value
