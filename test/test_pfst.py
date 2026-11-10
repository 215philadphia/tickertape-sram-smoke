# SPDX-License-Identifier: Apache-2.0
# TickerTape-Out PFST: pin-level tests that run on RTL and on the gate-level netlist (GATES=yes).
# Everything goes through the chip pins: host SPI on ui_in[4..6] / uo_out[7], UART TX on uo_out[4].
import json
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

HERE = os.path.dirname(os.path.abspath(__file__))
H = 7                                   # host SCK half period in core clocks (3.6 MHz at 50 MHz)
UART = json.load(open(os.path.join(HERE, "uart_tx_b20.json")))


def bit(sig, i):
    v = sig.value
    if not v.is_resolvable:
        raise AssertionError(f"X/Z on {getattr(sig, '_name', 'signal')}: {v}")
    return int(v) >> i & 1


class Host:
    """SPI mode 0 host, MSB first, CS_n framed. ui_in[3] held high (idle UART line)."""
    def __init__(self, dut):
        self.dut = dut
        self.ui7 = 0                                              # ui_in[7], a general input pin

    async def cycles(self, n):
        for _ in range(n):
            await FallingEdge(self.dut.clk)

    def drive(self, sck, mosi, cs_n):
        self.dut.ui_in.value = 0x08 | sck << 4 | mosi << 5 | cs_n << 6 | self.ui7 << 7

    async def xfer(self, data):
        self.drive(0, 0, 0)
        await self.cycles(H)
        rx = []
        for j, byte in enumerate(data):
            v = 0
            for i in range(8):
                self.drive(0, byte >> (7 - i) & 1, 0)
                await self.cycles(H)
                # sample MISO at the SCK rising edge. Bytes 0-1 carry no response (command/address slots) and
                # MISO there may still show undefined SRAM data from the previous READ_TABLE's read-ahead.
                m = self.dut.uo_out.value
                if j < 2 and not m.is_resolvable:
                    b = 0
                else:
                    b = bit(self.dut.uo_out, 7)
                v = v << 1 | b
                self.drive(1, byte >> (7 - i) & 1, 0)
                await self.cycles(H)
            rx.append(v)
        self.drive(0, 0, 0)
        await self.cycles(H)
        self.drive(0, 0, 1)
        await self.cycles(8)
        return rx

    async def wreg(self, a, *v):
        await self.xfer([0x01, a, *v])

    async def rreg(self, a, n=1):
        return (await self.xfer([0x02, a] + [0] * n))[2:]

    async def write_table(self, c, row, words):
        await self.xfer([0x10 | c, row] + [b for w in words for b in w.to_bytes(4, "big")])

    async def read_table(self, c, row, n):
        r = (await self.xfer([0x20 | c, row] + [0] * (4 * n)))[2:]
        return [int.from_bytes(bytes(r[4 * j:4 * j + 4]), "big") for j in range(n)]


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())    # 50 MHz
    dut.ena.value = 1
    dut.ui_in.value = 0x48                                       # CS_n high, UART line idle
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    h = Host(dut)
    await h.cycles(10)
    dut.rst_n.value = 1
    await h.cycles(5)
    return h


@cocotb.test()
async def test_registers(dut):
    """Reset values of every core-0 register, then write/read-back with auto-increment."""
    h = await start(dut)
    got = await h.rreg(0x00, 11)
    assert got == [1, 0, 0, 0xE4, 0, 0x10, 0x32, 0xFF, 0, 0, 0], f"reset values {got}"
    await h.wreg(0x10, 7, 3, 0x0B, 0x1B, 0x66, 0xA5, 0x5A, 12)
    got = await h.rreg(0x10, 8)
    assert got == [7, 3, 0x0B, 0x1B, 0x66, 0xA5, 0x5A, 12], f"core 1 readback {got}"
    await h.wreg(0x20, 0x80, 0x77)
    assert await h.rreg(0x20, 2) == [0x80, 0x77]


@cocotb.test()
async def test_table(dut):
    """WRITE_TABLE / READ_TABLE through the macro of core 1, across a word and row boundary."""
    h = await start(dut)
    words = [0x1234567, 0x0ABCDEF, 0x1FFFFFF, 0, 0x0000001, 0x1000000, 0x0F0F0F0, 0x1555555]
    await h.write_table(1, 16, words)
    got = await h.read_table(1, 16, len(words))
    assert got == words, [hex(w) for w in got]
    await h.write_table(0, 250, words[:6])                       # rows 250..255; beyond 255 reads 0
    got = await h.read_table(0, 250, 8)
    assert got == words[:6] + [0, 0], [hex(w) for w in got]


@cocotb.test()
async def test_uart_tx(dut):
    """Load a UART TX program into core 0, push bytes over SPI, decode the frames from uo_out[4]."""
    h = await start(dut)
    B, table = UART["B"], UART["table"]
    used = max(i for i, w in enumerate(table) if w) + 1
    await h.write_table(0, 0, table[:used])
    assert await h.read_table(0, 0, used) == table[:used], "table readback"
    rs = UART["reset_sel"]
    await h.wreg(0x0A, UART["out_init"])                         # OUT_INIT before anything drives
    await h.wreg(0x00, UART["P"], 0, rs[0] | rs[1] << 2)         # P, CFG (LSB first), RSEL
    await h.wreg(0x26, 0x08)                                     # UOMAP: uo_out[4] <- core 0 out[0]
    line = []

    async def recorder():                                        # sample the TX pin every cycle from RUN on
        while True:
            await FallingEdge(dut.clk)
            line.append(bit(dut.uo_out, 4))
    cocotb.start_soon(recorder())
    await h.xfer([0x40, 0x03])                                   # CTRL core 0: RESTART + RUN
    data = [0x55, 0xA3, 0x0F]
    await h.xfer([0x30] + data)                                  # TX_PUSH (FIFO depth 3)
    st = (await h.rreg(0x08))[0]
    assert st & 1, f"core 0 not running, STATUS {st:#x}"
    await h.cycles(len(data) * 10 * B + 6 * B)
    got, k = [], 0
    while len(got) < len(data) and k < len(line) - 10 * B:
        if line[k] == 1 and line[k + 1] == 0:                    # start-bit edge
            s = k + 1
            assert line[s + B // 2] == 0, "start bit"
            v = sum(line[s + B // 2 + B * (i + 1)] << i for i in range(8))
            assert line[s + B // 2 + 9 * B] == 1, "stop bit"
            got.append(v)
            k = s + 9 * B
        k += 1
    assert got == data, f"decoded {[hex(x) for x in got]}"
    st = (await h.rreg(0x08))[0]
    assert st >> 6 == 0 and not st & 0x20, f"FIFO should be empty, no overflow: STATUS {st:#x}"


def W(nxt, wait=0, out=0, osel=0, op=0, sa=0, sb=0, dir_=0):
    return dir_ << 25 | nxt << 19 | wait << 11 | out << 7 | osel << 6 | op << 4 | sa << 2 | sb


@cocotb.test()
async def test_passthrough(dut):
    """v1.1 UOMAP pass-through: uo_out[0] <- ui_in[7] direct (same cycle), uo_out[1] <- ui_in[7] synchronized."""
    h = await start(dut)
    await h.wreg(0x22, 0xC0 | 7, 0x80 | 7)
    for v in (1, 0, 1):
        h.ui7 = v; h.drive(0, 0, 1)                               # change ui_in[7] just after a falling edge
        await Timer(5, unit="ns")
        assert bit(dut.uo_out, 0) == v, "direct pass-through must follow within the same cycle"
        assert bit(dut.uo_out, 1) != v, "synchronized pass-through must not follow immediately"
        seen = None
        for k in range(1, 4):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ns")
            if bit(dut.uo_out, 1) == v:
                seen = k; break
        assert seen == 2, f"synchronized pass-through followed after {seen} rising edges, expected 2"
        await h.cycles(3)


@cocotb.test()
async def test_row_controlled_pins(dut):
    """v1.1 PINMODE 3: a row's dir bits decide which of core 0's pins drive; released while stopped."""
    h = await start(dut)
    rows = [W(0, 0, 0b0101, dir_=0b0011)] * 2 + [W(0, 0, 0b1010, dir_=0b1100)] * 2   # row picked by IN0
    await h.write_table(0, 0, rows)
    await h.wreg(0x03, 0xE4, 0xFF)                                # OUTMAP identity, PINMODE all row-controlled
    await h.wreg(0x05, 0x17)                                      # IN0 <- ui_in[7]
    assert bit(dut.uio_oe, 0) == 0 and int(dut.uio_oe.value) & 15 == 0, "pins must be released while stopped"
    await h.xfer([0x40, 0x03])
    for a, oe, out in ((0, 0b0011, 0b0001), (1, 0b1100, 0b1000), (0, 0b0011, 0b0001)):
        h.ui7 = a; h.drive(0, 0, 1)
        await h.cycles(10)
        got_oe, got_out = int(dut.uio_oe.value) & 15, int(dut.uio_out.value) & 15
        assert (got_oe, got_out) == (oe, out), f"IN0={a}: oe {got_oe:04b} out {got_out:04b}, expected {oe:04b} {out:04b}"
    await h.xfer([0x40, 0x02])                                    # RESTART, stopped
    assert int(dut.uio_oe.value) & 15 == 0, "pins must be released after stop"
