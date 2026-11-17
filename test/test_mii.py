# SPDX-License-Identifier: Apache-2.0
"""The chip as a 10 Mb/s Ethernet MAC transmitter over MII, at the 50 MHz signoff clock (docs/ethernet.md).

A frame compiled into core 0's table (mii_arp_dsl, mii_udp_dsl) is sent as nibbles on TXD[3:0] = uio[3:0] with
TX_EN = uio[4] from core 1 (mii_txen_dsl). The test plays the PHY: it supplies TX_CLK (2.5 MHz, not synchronous
to the chip clock) on ui_in[7] and samples TXD and TX_EN on each rising edge, as IEEE 802.3 clause 22 says a
PHY does. What it checks is written from the standard and from the protocols carried, not from the programs:
preamble and SFD, the frame check sequence (zlib.crc32), the frame's fields, and the timing of the signals
against the sampling edge.

No PHY hardware is involved: this is a simulation against a model of the PHY's MII side.
"""
import os
import random
import struct
import zlib

import cocotb
from cocotb.triggers import Timer, ValueChange
from cocotb.utils import get_sim_time

from test_pfst import start
from test_programs import PROGS

TXCLK_PS = 400_000                      # 2.5 MHz: one nibble (22.2.2.1)
MARGIN_PS = 100_000                     # required distance of any TXD/TX_EN change from a sampling edge
MAC = bytes.fromhex("020000000001")
IP = bytes([10, 0, 0, 1])
BCAST = b"\xff" * 6
P, CFG, RSEL, OUTMAP, PINMODE, INMAP01, INMAP23, DONE_STATE, STATUS, STATE, OUT_INIT = range(11)
GL = os.environ.get("GATES") == "yes"
FRAMES = int(os.environ.get("MII_FRAMES", "6" if GL else "20"))


def now():
    return int(get_sim_time(unit="ps"))


# ---- the frames, built here independently of model/dsl_programs.ml ----
def ethernet(dst, src, ethertype, payload):
    body = dst + src + struct.pack("!H", ethertype) + payload
    body += b"\x00" * max(0, 60 - len(body))
    return body + zlib.crc32(body).to_bytes(4, "little")


def arp_frame():
    return ethernet(BCAST, MAC, 0x0806, struct.pack("!HHBBH", 1, 0x0800, 6, 4, 1) + MAC + IP + b"\x00" * 6 + IP)


def udp_frame():
    text = b"TickerTape-Out\n"
    udp = struct.pack("!HHHH", 5000, 5000, 8 + len(text), 0) + text
    hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0, 64, 17, 0, IP, b"\xff" * 4)
    s = sum(struct.unpack("!10H", hdr))
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    hdr = hdr[:10] + struct.pack("!H", ~s & 0xFFFF) + hdr[12:]
    return ethernet(BCAST, MAC, 0x0800, hdr + udp)


# ---- the PHY side ----
class Phy:
    """Drives TX_CLK on ui_in[7] and records every change of (TXD, TX_EN) on uio_out[4:0] with its time."""
    def __init__(self, dut, h, ppm=0.0, phase_ps=0):
        self.dut, self.h, self.on = dut, h, True
        self.half = TXCLK_PS / 2 * (1 + ppm * 1e-6)
        self.rises, self.changes = [], []
        self.t0 = now() + phase_ps + 1
        cocotb.start_soon(self._clock())
        cocotb.start_soon(self._record())
        for s in (dut.uo_out, dut.uio_oe):
            cocotb.start_soon(self._xz(s))

    async def _clock(self):
        k = 0
        while self.on:
            t = int(self.t0 + k * self.half)
            if t > now():
                await Timer(t - now(), unit="ps")
            self.h.ui7 = 1 - (k & 1)                          # even steps are rising edges
            self.h._write()
            if not k & 1:
                self.rises.append(now())
            k += 1

    def _read(self):
        v = self.dut.uio_out.value
        assert v.is_resolvable, f"X/Z on uio_out: {v} at {now()} ps"
        return int(v) & 0x1F

    async def _record(self):
        last = self._read()
        self.changes.append((now(), last))
        while self.on:
            await ValueChange(self.dut.uio_out)
            v = self._read()
            if self.changes[-1][0] == now():                  # zero-width simulator glitches within one time step
                self.changes.pop()
            if not self.changes or self.changes[-1][1] != v:
                self.changes.append((now(), v))

    async def _xz(self, s):
        while self.on:
            assert s.value.is_resolvable, f"X/Z on {s._name}: {s.value} at {now()} ps"
            await ValueChange(s)

    def stop(self):
        self.on = False

    def value_at(self, t):
        v = self.changes[0][1]
        for tc, vc in self.changes:
            if tc >= t:
                break
            v = vc
        return v


def mii_check(phy, expect):
    """Violations found in what the PHY saw, and (frame bytes, worst setup ps, worst hold ps)."""
    bad = []
    nib, frames, cur = [], [], None
    for t in phy.rises:
        v = phy.value_at(t)
        if v & 0x10:                                           # TX_EN sampled high: a nibble of the frame
            cur = [] if cur is None else cur
            cur.append(v & 15)
        else:
            if cur is not None:
                frames.append(cur)
                cur = None
            if v & 15:
                bad.append(f"TXD is {v & 15:#x} at {t} ps while TX_EN is low")
    if cur is not None:
        bad.append("TX_EN still high at the end of the recording")
        frames.append(cur)
    if len(frames) != 1:
        return bad + [f"{len(frames)} frames seen, expected 1"], None
    nib = frames[0]
    # timing: every change of TXD or TX_EN must keep clear of the sampling edges
    first, last = phy.rises[0], phy.rises[-1]
    inside = [t for t, _ in phy.changes[1:] if first <= t < last]
    setup = min((min(r - t for r in phy.rises if r > t) for t in inside), default=None)
    hold = min((min(t - r for r in phy.rises if r <= t) for t in inside), default=None)
    if setup is None or setup < MARGIN_PS:
        bad.append(f"a signal changes {setup} ps before a TX_CLK rising edge")
    if hold is None or hold < MARGIN_PS:
        bad.append(f"a signal changes {hold} ps after a TX_CLK rising edge")
    # TX_EN rises with the first preamble nibble and falls with the end of the last nibble (22.2.2.3)
    edges = [(t, a, b) for (_, a), (t, b) in zip(phy.changes, phy.changes[1:]) if (a ^ b) & 0x10]
    if len(edges) != 2:
        bad.append(f"TX_EN changes {len(edges)} times")
    else:
        (t_on, a, b), (t_off, c, d) = edges
        if b & 15 != 5 or a & 15 != 0:
            bad.append(f"TX_EN rises with TXD going {a & 15:#x} -> {b & 15:#x}, not with the first preamble nibble")
        if d & 15 != 0:
            bad.append(f"TXD is {d & 15:#x} when TX_EN falls, not back to idle in the same cycle")
    if len(nib) % 2:
        bad.append(f"odd number of nibbles: {len(nib)}")
    octets = bytes(lo | hi << 4 for lo, hi in zip(nib[0::2], nib[1::2]))         # low nibble first
    if octets[:8] != b"\x55" * 7 + b"\xd5":
        bad.append(f"preamble and SFD are {octets[:8].hex()}")
    frame = octets[8:]
    if len(frame) < 64:
        bad.append(f"frame is {len(frame)} bytes, below the 64-byte minimum")
    elif zlib.crc32(frame[:-4]) != int.from_bytes(frame[-4:], "little"):
        bad.append(f"frame check sequence {frame[-4:].hex()} is wrong for this frame")
    if frame != expect:
        bad.append(f"frame differs from the expected one at byte {next((i for i, (x, y) in enumerate(zip(frame, expect)) if x != y), min(len(frame), len(expect)))}")
    return bad, (frame, setup, hold)


async def load(h, core, prog, *, pinmode, inmap01=0x10, table=None):
    await h.xfer([0x40 | core, 0x00])
    table = table if table is not None else prog["table"]
    await h.write_table(core, 0, table)
    assert await h.read_table(core, 0, len(table)) == table, "table readback"
    ra, rb = prog["reset_sel"]
    await h.wreg(0x10 * core + OUT_INIT, 0)
    await h.wreg(0x10 * core + P, 1, int(prog["msb_first"]), ra | rb << 2, 0xE4, pinmode, inmap01, 0x32, 0xFF)


async def mii_setup(h, name, table=None):
    """Core 0 carries the frame (TXD on uio[3:0], TX_CLK from ui_in[7] as IN1); core 1 makes TX_EN on uio[4]."""
    await h.wreg(0x20, 0x80)                                   # THRESH
    await load(h, 0, PROGS[name], pinmode=0b01010101, inmap01=0x70, table=table)
    await load(h, 1, PROGS["mii_txen_dsl"], pinmode=0b01)
    await h.xfer([0x41, 0x03])                                 # core 1: RUN


async def mii_send(dut, h, rng, second=0xFF, ppm=None, align=True):
    """Send the loaded frame once against a PHY with a random clock phase. Returns the Phy recording."""
    await h.xfer([0x40, 0x02])                                 # core 0: stop and RESTART (empties the FIFO, clears CMP's cause)
    await h.xfer([0x30, 0x40, second])                         # the two page bytes, pushed while stopped
    ppm = rng.uniform(-200, 200) if ppm is None else ppm
    phy = Phy(dut, h, ppm=ppm, phase_ps=rng.randrange(TXCLK_PS))
    await Timer(2 * TXCLK_PS, unit="ps")
    await h.xfer([0x40, 0x01])                                 # core 0: RUN
    await Timer(170 * TXCLK_PS, unit="ps")                     # 144 nibbles and some idle
    phy.stop()
    await Timer(TXCLK_PS, unit="ps")
    return phy


@cocotb.test()
async def test_mii_arp(dut):
    """A gratuitous ARP request sent over MII: every field, the FCS and the signal timing as a PHY sees them."""
    h = await start(dut)
    await mii_setup(h, "mii_arp_dsl")
    rng, expect = random.Random(22), arp_frame()
    worst_s = worst_h = 10 ** 9
    for _ in range(FRAMES):
        phy = await mii_send(dut, h, rng)
        bad, info = mii_check(phy, expect)
        assert not bad, bad
        frame, setup, hold = info
        worst_s, worst_h = min(worst_s, setup), min(worst_h, hold)
    # the fields of the frame the PHY received, parsed from its bytes
    dst, src, etype = frame[:6], frame[6:12], struct.unpack("!H", frame[12:14])[0]
    htype, ptype, hlen, plen, op = struct.unpack("!HHBBH", frame[14:22])
    sha, spa, tha, tpa = frame[22:28], frame[28:32], frame[32:38], frame[38:42]
    assert (dst, src, etype) == (BCAST, MAC, 0x0806)
    assert (htype, ptype, hlen, plen, op) == (1, 0x0800, 6, 4, 1), "ARP request for IPv4 over Ethernet"
    assert sha == MAC and spa == IP and tpa == IP and tha == b"\x00" * 6, "gratuitous: sender and target IP equal"
    assert len(frame) == 64
    dut._log.info(f"MII ARP: {FRAMES} frames of 64 bytes correct; worst setup {worst_s / 1000:.0f} ns, "
                  f"worst hold {worst_h / 1000:.0f} ns against a 400 ns nibble")


@cocotb.test()
async def test_mii_udp(dut):
    """A different frame by loading a different table: a UDP datagram with a valid IPv4 header checksum."""
    h = await start(dut)
    await mii_setup(h, "mii_udp_dsl")
    rng, expect = random.Random(23), udp_frame()
    for _ in range(max(FRAMES // 4, 2)):
        phy = await mii_send(dut, h, rng)
        bad, info = mii_check(phy, expect)
        assert not bad, bad
    frame = info[0]
    ip = frame[14:34]
    s = sum(struct.unpack("!10H", ip))
    s = (s & 0xFFFF) + (s >> 16)
    assert (s & 0xFFFF) + (s >> 16) == 0xFFFF, "IPv4 header checksum"
    assert ip[9] == 17 and frame[34:38] == struct.pack("!HH", 5000, 5000), "UDP, port 5000 to 5000"
    n = struct.unpack("!H", frame[38:40])[0] - 8
    assert frame[42:42 + n] == b"TickerTape-Out\n"
    dut._log.info(f"MII UDP: payload {frame[42:42 + n]!r} in a {len(frame)}-byte frame, IPv4 checksum valid")


@cocotb.test()
async def test_mii_clock_tolerance(dut):
    """The PHY clock is only lined up once per frame; show how far off-frequency it may be."""
    h = await start(dut)
    await mii_setup(h, "mii_arp_dsl")
    rng, expect = random.Random(24), arp_frame()
    for ppm in (-200, 200, -1000, 1000, -3000, 3000):
        res = []
        for _ in range(max(FRAMES // 5, 2)):
            phy = await mii_send(dut, h, rng, ppm=ppm)
            bad, info = mii_check(phy, expect)
            res.append((bad, info))
        ok = sum(1 for b, _ in res if not b)
        margins = [min(i[1], i[2]) for _, i in res if i]
        dut._log.info(f"MII clock offset {ppm:+5d} ppm: {ok}/{len(res)} frames correct, "
                      f"smallest margin {min(margins) / 1000 if margins else float('nan'):.0f} ns")
        if abs(ppm) <= 1000:
            assert ok == len(res), (ppm, [b for b, _ in res if b][:1])


def mutate(prog, state, edit, rows=range(4)):
    t = list(prog["table"])
    s = prog["names"].index(state)
    for r in rows:
        t[4 * s + r] = edit(t[4 * s + r])
    return t


@cocotb.test(skip=GL)
async def test_mii_planted_bugs(dut):
    """Four ways to break the transmitter; the PHY-side checker must object to each."""
    h = await start(dut)
    arp, expect = PROGS["mii_arp_dsl"], arp_frame()
    set_wait = lambda n: (lambda w: (w & ~(0xFF << 11)) | n << 11)
    flip_out = lambda w: w ^ (1 << 7)
    no_align = mutate(arp, "W0", lambda w: arp["table"][4 * arp["names"].index("W1") + 2])   # do not wait for TX_CLK
    no_align = mutate(dict(arp, table=no_align), "W1", lambda w: arp["table"][4 * arp["names"].index("W1") + 2])
    bugs = {
        "one data nibble has a wrong bit": dict(table=mutate(arp, "Q5", flip_out, rows=(3,))),
        "TX_EN rises two cycles after the first nibble": dict(table=mutate(arp, "A", set_wait(0))),
        "the frame does not wait for TX_CLK": dict(table=no_align),
        "wrong second page byte (TX_EN never falls)": dict(second=0x40),
    }
    caught = []
    for name, kw in bugs.items():
        await mii_setup(h, "mii_arp_dsl", table=kw.get("table"))
        rng, bad = random.Random(25), []
        for _ in range(8):
            phy = await mii_send(dut, h, rng, second=kw.get("second", 0xFF))
            bad += mii_check(phy, expect)[0]
        assert bad, f"planted bug not caught: {name}"
        caught.append(f"{name}: {bad[0]}")
    for line in caught:
        dut._log.info("caught  " + line)
