# SPDX-License-Identifier: Apache-2.0
"""Every program compiled by the OCaml toolchain, run on the chip RTL through its pins.

Tables come from test/compiled_tables.json, a snapshot of model/compiled_tables.json that
model/run_tests.sh keeps in sync. Each test configures the chip only through the host SPI
port, exactly as the demo board's microcontroller would, then drives and decodes the protocol
pins with an independent decoder written here.
"""
import json
import os

import cocotb
from cocotb.triggers import FallingEdge

from test_pfst import Host, bit, start

HERE = os.path.dirname(os.path.abspath(__file__))
PROGS = json.load(open(os.path.join(HERE, "compiled_tables.json")))
BP = 40                                 # bit period in cycles at P=1 used by model/dsl_programs.ml

# register offsets inside a core's block (core c at 0x10 * c)
P, CFG, RSEL, OUTMAP, PINMODE, INMAP01, INMAP23, DONE_STATE, STATUS, STATE, OUT_INIT = range(11)
THRESH, IRQ_EN = 0x20, 0x21
UIO = 0x8                               # INMAP index bit: take the input from uio_in instead of ui_in


async def load(h, core, name, *, p, out_init, pinmode, inmap01=0x10, inmap23=0x32, done_state=0xFF, cfg=0):
    """Load a compiled program into a stopped core and configure it; does not start it."""
    prog = PROGS[name]
    table = prog["table"]
    await h.write_table(core, 0, table)
    assert await h.read_table(core, 0, len(table)) == table, f"{name}: table readback"
    ra, rb = prog["reset_sel"]
    base = 0x10 * core
    await h.wreg(base + OUT_INIT, out_init)                     # before any pin is driven
    await h.wreg(base + P, p, int(prog["msb_first"]) | cfg, ra | rb << 2, 0xE4, pinmode, inmap01, inmap23, done_state)
    return prog


async def run(h, core):
    await h.xfer([0x40 | core, 0x03])                           # CTRL: RESTART + RUN


async def status(h, core):
    return (await h.rreg(0x10 * core + STATUS))[0]


def uart_frames(byte_list, bp, gap_bits=3, err=0.0):
    """Idle-high UART line, 8N1 LSB first, as a list of per-cycle levels (bit period bp*(1+err))."""
    period = bp * (1.0 + err)
    edges, t = [], 10.0
    for b in byte_list:
        for k, v in enumerate([0] + [(b >> i) & 1 for i in range(8)] + [1]):
            edges.append((t + k * period, v))
        t += (10 + gap_bits) * period
    wave, j, lvl = [], 0, 1
    for n in range(int(t + 3 * period)):
        while j < len(edges) and edges[j][0] <= n:
            lvl = edges[j][1]
            j += 1
        wave.append(lvl)
    return wave


def uart_decode(line, bp):
    """Ideal UART decoder: start-bit edge, then sample at bit centres; checks start and stop bits."""
    got, k = [], 1
    while k < len(line) - 10 * bp:
        if line[k - 1] == 1 and line[k] == 0:
            assert line[k + bp // 2] == 0, f"bad start bit at {k}"
            v = sum(line[k + bp // 2 + bp * (i + 1)] << i for i in range(8))
            assert line[k + bp // 2 + 9 * bp] == 1, f"bad stop bit at {k}"
            got.append(v)
            k += 9 * bp + bp // 2
        k += 1
    return got


class SpiMonitor:
    """Mode 0 SPI decoder on three uio pins: bytes per CS-low frame, MSB first."""
    def __init__(self, dut, cs, sck, mosi):
        self.dut, self.pins, self.frames = dut, (cs, sck, mosi), []
        cocotb.start_soon(self._run())

    async def _run(self):
        cs_p, sck_p, bits, frame = 1, 0, [], None
        while True:
            await FallingEdge(self.dut.clk)
            cs, sck, mosi = (bit(self.dut.uio_out, p) for p in self.pins)
            if cs_p == 1 and cs == 0:
                frame, bits = [], []
            if cs == 0 and sck == 1 and sck_p == 0:
                bits.append(mosi)
                if len(bits) == 8:
                    frame.append(int("".join(map(str, bits)), 2))
                    bits = []
            if cs == 1 and cs_p == 0 and frame is not None:
                self.frames.append(frame)
                frame = None
            cs_p, sck_p = cs, sck


@cocotb.test()
async def test_compiled_uart_tx(dut):
    """uart_tx_dsl (2 states) on core 0: bytes pushed over SPI appear as 8N1 frames on uio[0]."""
    h = await start(dut)
    await load(h, 0, "uart_tx_dsl", p=1, out_init=1, pinmode=0b01)
    line = []

    async def rec():
        while True:
            await FallingEdge(dut.clk)
            line.append(bit(dut.uio_out, 0))
    cocotb.start_soon(rec())
    await run(h, 0)
    data = [0x00, 0xFF, 0x55]
    await h.xfer([0x30] + data)                                 # fills the 3-byte TX FIFO
    await h.cycles(len(data) * 11 * BP + 4 * BP)
    assert uart_decode(line, BP) == data


@cocotb.test()
async def test_compiled_uart_rx(dut):
    """uart_rx_dsl (4 states) on core 1: frames at -1%, 0 and +1% baud error, each read back with READ_SCR."""
    h = await start(dut)
    await load(h, 1, "uart_rx_dsl", p=1, out_init=0, pinmode=0, inmap01=0x10 | (UIO | 4))
    await h.wreg(IRQ_EN, 0x20)                                  # IRQ (uo_out[6]) <- core 1 RX_VALID
    dut.uio_in.value = 1 << 4                                   # idle-high line before the receiver starts
    await run(h, 1)
    data = [0x00, 0xFF, 0x55, 0xAA, 0x81, 0x42]
    for err in (-0.01, 0.0, 0.01):
        got = []
        for b in data:
            for lvl in uart_frames([b], BP, gap_bits=1, err=err):
                await FallingEdge(dut.clk)
                dut.uio_in.value = lvl << 4
            for _ in range(BP):                                 # IRQ follows the SAVE row
                if bit(dut.uo_out, 6):
                    break
                await FallingEdge(dut.clk)
            assert bit(dut.uo_out, 6), f"err={err}: no RX_VALID for {b:#x}"
            got.append((await h.xfer([0x51, 0]))[1])            # READ_SCR core 1, clears RX_VALID
        assert got == data, f"err={err}: received {[hex(x) for x in got]}"
    st = await status(h, 1)
    assert not st & 0x08, f"RX overrun, STATUS {st:#x}"


@cocotb.test()
async def test_compiled_spi_tx(dut):
    """spi_tx_dsl (4 states) on core 0, P=4: mode 0 frames (CS, SCK, MOSI on uio[2:0])."""
    h = await start(dut)
    await load(h, 0, "spi_tx_dsl", p=4, out_init=0b100, pinmode=0b010101)
    mon = SpiMonitor(dut, cs=2, sck=1, mosi=0)
    await run(h, 0)
    data = [0x00, 0xFF, 0x55, 0xAA, 0x81, 0x42]
    for b in data:
        await h.xfer([0x30, b])
    await h.cycles(200)
    assert [b for f in mon.frames for b in f] == data, f"frames {mon.frames}"


class I2cTarget:
    """Write-only I2C target on an open-drain bus with pull-ups: SDA = uio[0], SCL = uio[1].

    The chip pulls a line low by enabling its output (PINMODE 2 drives 0 only). The target
    ACKs its own address and every data byte, NACKs any other address, and logs START/STOP.
    """
    def __init__(self, dut, addr):
        self.dut, self.addr = dut, addr
        self.written, self.starts, self.stops, self.nacked = [], 0, 0, 0
        self.sda_low = False
        cocotb.start_soon(self._run())

    def lines(self):
        oe = int(self.dut.uio_oe.value)
        sda = 0 if (oe & 1 or self.sda_low) else 1
        scl = 0 if oe & 2 else 1
        return sda, scl

    async def _run(self):
        sda_p, scl_p = 1, 1
        phase, bits, byte, first, selected = "idle", 0, 0, True, False
        while True:
            await FallingEdge(self.dut.clk)
            sda, scl = self.lines()
            if scl and scl_p and sda_p and not sda:                     # START
                self.starts += 1
                phase, bits, byte, first, selected = "data", 0, 0, True, False
            elif scl and scl_p and not sda_p and sda:                   # STOP
                self.stops += 1
                phase, self.sda_low = "idle", False
            elif phase == "data" and scl and not scl_p:                 # data bit on SCL rising
                byte, bits = byte << 1 | sda, bits + 1
            elif phase == "data" and not scl and scl_p and bits == 8:   # after 8 bits: (N)ACK
                if first:
                    selected = (byte >> 1) == self.addr and not byte & 1
                    self.nacked += not selected
                elif selected:
                    self.written.append(byte)
                self.sda_low, phase = selected, "ack"
            elif phase == "ack" and not scl and scl_p:                  # end of the ACK clock
                self.sda_low = False
                phase = "data" if selected else "ignore"
                bits, byte, first = 0, 0, False
            sda, scl = self.lines()                                     # include our own change
            self.dut.uio_in.value = sda | scl << 1
            sda_p, scl_p = sda, scl


@cocotb.test()
async def test_compiled_i2c_write(dut):
    """i2c_wr_dsl (14 states) on core 0, open drain: write 6 bytes to 0x50, then a NACKed address; DONE each time."""
    h = await start(dut)
    prog = PROGS["i2c_wr_dsl"]
    done = prog["names"].index("DONE")
    await load(h, 0, "i2c_wr_dsl", p=1, out_init=0b11, pinmode=0b1010,
               inmap01=(UIO | 1) << 4 | (UIO | 0), done_state=done)
    tgt = I2cTarget(dut, 0x50)
    for addr, payload, expect in ((0x50, [0x00, 0xFF, 0x55, 0xAA, 0x81, 0x42], True),
                                  (0x51, [0x12], False)):
        before = list(tgt.written)
        queue = [addr << 1] + payload
        await run(h, 0)                                         # RESTART clears DONE and flushes the FIFO
        await h.xfer([0x30] + queue[:3])
        queue = queue[3:]
        for _ in range(400):
            st = await status(h, 0)
            if st & 0x02:                                       # DONE
                break
            if queue and (st >> 6) < 3:                         # room in the FIFO
                await h.xfer([0x30, queue.pop(0)])
        assert st & 0x02, f"addr {addr:#x}: never reached DONE (STATUS {st:#x})"
        new = tgt.written[len(before):]
        assert new == (payload if expect else []), f"addr {addr:#x}: target got {[hex(x) for x in new]}"
    assert (tgt.starts, tgt.stops, tgt.nacked) == (2, 2, 1), (tgt.starts, tgt.stops, tgt.nacked)


@cocotb.test()
async def test_compiled_nanotick(dut):
    """Both cores, no host in the loop: core 0 receives prices over UART (uart_rx_dsl), the comparator
    flags SCR < THRESH, and core 1 (nt_trader_dsl) sends one 3-byte SPI order per downward crossing."""
    h = await start(dut)
    await load(h, 0, "uart_rx_dsl", p=1, out_init=0, pinmode=0, inmap01=0x10 | (UIO | 0))
    await load(h, 1, "nt_trader_dsl", p=2, out_init=0b100, pinmode=0b010101)
    await h.wreg(THRESH, 100)
    order = [0x42, 0x55, 0x59]                                  # "BUY"
    mon = SpiMonitor(dut, cs=6, sck=5, mosi=4)
    dut.uio_in.value = 1                                        # idle-high price line before core 0 starts
    await run(h, 0)
    await run(h, 1)                                             # RESTART flushes the FIFO: push after it
    await h.xfer([0x31] + order)

    async def refill():                                         # host re-arms the message after each order
        sent = 0
        while True:
            await FallingEdge(dut.clk)
            if len(mon.frames) > sent:
                sent = len(mon.frames)
                await h.xfer([0x31] + order)
    cocotb.start_soon(refill())
    prices = [120, 90, 80, 130, 99, 150, 100, 60, 101]
    expected = 3                                                # crossings at 90, 99 and 60; 80 is no new crossing
    for lvl in uart_frames(prices, BP, gap_bits=4):
        await FallingEdge(dut.clk)
        dut.uio_in.value = lvl
    await h.cycles(400)
    assert len(mon.frames) == expected, f"{len(mon.frames)} orders, expected {expected}: {mon.frames}"
    assert all(f == order for f in mon.frames), f"orders {mon.frames}"


@cocotb.test()
async def test_compiled_half_duplex(dut):
    """hd_uart_dsl (6 states) on one wire, uio[0] in PINMODE 3: send a request, release the wire,
    receive the far end's reply. The chip and the far end must never drive the wire together."""
    h = await start(dut)
    await load(h, 0, "hd_uart_dsl", p=1, out_init=1, pinmode=0b11, inmap01=0x10 | (UIO | 0))
    await h.wreg(IRQ_EN, 0x02)                                  # IRQ <- core 0 RX_VALID
    state = {"contention": 0, "drove": False, "wire": []}
    remote = {"wave": [], "t": 0}

    async def bus():
        released, drove_p, k = None, False, 0
        while True:
            await FallingEdge(dut.clk)
            chip = bool(int(dut.uio_oe.value) & 1)
            state["drove"] |= chip
            if drove_p and not chip:
                released = k
            drove_p = chip
            if released is not None and k == released + 2 * BP and not remote["wave"]:
                req = state["req"]
                remote["wave"], remote["t"] = uart_frames([req ^ 0xFF], BP, gap_bits=0)[10:10 + 10 * BP], k
                released = None
            j = k - remote["t"]
            far = remote["wave"][j] if 0 <= j < len(remote["wave"]) else None
            if j >= len(remote["wave"]):
                remote["wave"] = []
            if chip and far is not None:
                state["contention"] += 1
            w = bit(dut.uio_out, 0) if chip else (far if far is not None else 1)
            state["wire"].append(w)
            dut.uio_in.value = w
            k += 1
    cocotb.start_soon(bus())
    await run(h, 0)
    reqs, replies = [0x00, 0xFF, 0x55, 0xA5, 0x3C], []
    for r in reqs:
        state["req"] = r
        await h.xfer([0x30, r])
        for _ in range(40 * BP):
            await FallingEdge(dut.clk)
            if bit(dut.uo_out, 6):
                break
        assert bit(dut.uo_out, 6), f"no reply saved for request {r:#x}"
        replies.append((await h.xfer([0x50, 0]))[1])
        await h.cycles(2 * BP)                                  # the program idles one bit after SAVE
    assert state["drove"], "the chip never drove the wire"
    assert state["contention"] == 0, f"{state['contention']} cycles with both ends driving"
    assert replies == [r ^ 0xFF for r in reqs], f"replies {[hex(x) for x in replies]}"
    assert uart_decode(state["wire"], BP) == [x for r in reqs for x in (r, r ^ 0xFF)], "wire trace"


def ps2_frame(b, bad_parity=False, bad_stop=False, half_p=30):
    """One PS/2 device-to-host frame as per-cycle (data, clk): DATA changes mid-way through CLK high."""
    data = [(b >> k) & 1 for k in range(8)]
    par = (1 - sum(data) % 2) ^ bad_parity                      # odd parity
    seq, prev = [], 1
    for d in [0] + data + [par, 0 if bad_stop else 1]:
        seq += [(prev, 1)] * (half_p // 2) + [(d, 1)] * (half_p - half_p // 2) + [(d, 0)] * half_p
        prev = d
    return seq + [(1, 1)] * 200


@cocotb.test()
async def test_compiled_ps2_rx(dut):
    """ps2_rx_dsl (39 states, a protocol the chip was not designed for) on core 0: CLK on uio[1],
    DATA on uio[0] (to both IN0 and IN3). Good frames are received; a parity or stop-bit error
    saves nothing and raises FLAG instead."""
    h = await start(dut)
    await load(h, 0, "ps2_rx_dsl", p=1, out_init=0, pinmode=0, cfg=0b10,      # CFG bit 1: flag mode
               inmap01=(UIO | 1) << 4 | (UIO | 0), inmap23=(UIO | 0) << 4 | 0x2)
    await h.wreg(IRQ_EN, 0x02)                                  # IRQ <- core 0 RX_VALID
    dut.uio_in.value = 0b11                                     # both lines released (pulled up)
    await run(h, 0)

    async def send(frame):
        for d, c in frame:
            await FallingEdge(dut.clk)
            dut.uio_in.value = d | c << 1

    async def receive():
        for _ in range(100):
            if bit(dut.uo_out, 6):
                return (await h.xfer([0x50, 0]))[1]             # READ_SCR clears RX_VALID
            await FallingEdge(dut.clk)
        return None

    good = [0x00, 0xFF, 0x1C, 0xF0, 0x5A, 0x81]                 # 0x1C 'A' make code, 0xF0 break prefix
    got = []
    for b in good:
        await send(ps2_frame(b))
        got.append(await receive())
    assert got == good, f"received {got}"
    assert not await status(h, 0) & 0x10, "FLAG set by a good frame"
    for kind in ({"bad_parity": True}, {"bad_stop": True}):
        await send(ps2_frame(0x33, **kind))
        assert await receive() is None, f"{kind}: a bad frame was saved"
        assert await status(h, 0) & 0x10, f"{kind}: FLAG not raised"
        await run(h, 0)                                         # RESTART clears FLAG
        assert not await status(h, 0) & 0x10
    await send(ps2_frame(0x29))                                 # still in sync afterwards
    assert await receive() == 0x29
