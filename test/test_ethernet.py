# SPDX-License-Identifier: Apache-2.0
"""10BASE-T programs on the chip, at a 40 MHz clock (docs/ethernet.md).

Three demonstrations, each loaded through the host SPI port and checked on the pins by a checker written from
IEEE 802.3, not from the programs:
  * link test pulses (nlp_timer_dsl + nlp_pulse_dsl),
  * a Manchester frame at 10 Mb/s (eth_gate_dsl + eth_tx_dsl),
  * a frame-start detector with the receive line passed through (eth_sfd_dsl).
test_eth_planted_bugs then breaks each program in at least two ways and requires the same checkers to object.

The clock is 40 MHz (25 ns) so that one Manchester half bit is exactly 2 cycles. Every test also checks that no
output pin is ever X or Z once the cores run.

Environment: ETH_SFD_FRAMES (frames per jitter point, default 40), ETH_NLP_PULSES (default 3).
At gate level (make GATES=yes) the defaults are 10 frames and 2 pulses, and the planted-bug test is skipped: it
tests the checkers, not the netlist.
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ValueChange
from cocotb.utils import get_sim_time

import eth_model as em
from test_pfst import Host
from test_programs import PROGS

CLK_PS = em.CLK_PS
BT_PS = em.BT_PS
MS = 1_000_000_000                      # ps

# ---- numbers from IEEE 802.3 (see docs/ethernet.md for the sources and which were re-read) ----
NLP_PERIOD_PS = (8 * MS, 24 * MS)       # 14.2.1.1: link test pulses 16 ms +- 8 ms apart
NLP_WIDTH_PS = (50_000, 200_000)        # Figure 14-12 template: nominally 100 ns, not wider than 200 ns
TP_IDL_PS = (250_000, 450_000)          # 14.3.1.2.1: start of idle is HI for 2.5 to 4.5 bit times

P, CFG, RSEL, OUTMAP, PINMODE, INMAP01, INMAP23, DONE_STATE, STATUS, STATE, OUT_INIT = range(11)
THRESH = 0x20
GL = os.environ.get("GATES") == "yes"
SFD_FRAMES = int(os.environ.get("ETH_SFD_FRAMES", "10" if GL else "40"))
NLP_PULSES = int(os.environ.get("ETH_NLP_PULSES", "2" if GL else "3"))
GATE_BYTE = 0x40                        # any value in 0x40..0x7F with THRESH = 0x80


def now():
    return int(get_sim_time(unit="ps"))


async def start40(dut):
    cocotb.start_soon(Clock(dut.clk, 25, unit="ns").start())    # 40 MHz
    dut.ena.value = 1
    dut.ui_in.value = 0x48
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    h = Host(dut)
    await h.cycles(10)
    dut.rst_n.value = 1
    await h.cycles(5)
    return h


async def load(h, core, prog, *, p=1, pinmode=0, inmap01=0x10, table=None, msb=None):
    """Stop the core, write the table (read back), then its registers. Does not start it."""
    await h.xfer([0x40 | core, 0x00])
    table = table if table is not None else prog["table"]
    await h.write_table(core, 0, table)
    assert await h.read_table(core, 0, len(table)) == table, "table readback"
    ra, rb = prog["reset_sel"]
    msb = prog["msb_first"] if msb is None else msb
    await h.wreg(0x10 * core + OUT_INIT, 0)
    await h.wreg(0x10 * core + P, p & 0xFF, int(msb), ra | rb << 2, 0xE4, pinmode, inmap01, 0x32, 0xFF)


async def run(h, core):
    await h.xfer([0x40 | core, 0x03])


def mutate(prog, state, edit, rows=range(4)):
    """A copy of a compiled table with edit(word) applied to the given rows (0..3) of one state."""
    t = list(prog["table"])
    s = prog["names"].index(state)
    for r in rows:
        t[4 * s + r] = edit(t[4 * s + r])
    return t


def set_wait(n):
    return lambda w: (w & ~(0xFF << 11)) | n << 11


def set_out(n):
    return lambda w: (w & ~(0xF << 7)) | n << 7


def set_op(n):
    return lambda w: (w & ~(3 << 4)) | n << 4


def set_next(prog, state):
    return lambda w: (w & ~(0x3F << 19)) | prog["names"].index(state) << 19


class Pins:
    """Watches every output pin: fails on X/Z, and records the changes of chosen uio_out bits with their times."""
    def __init__(self, dut, bits=()):
        self.dut, self.bits, self.edges, self.on = dut, bits, [], True
        self.last = None
        for s in (dut.uo_out, dut.uio_oe):
            cocotb.start_soon(self._xz(s))
        cocotb.start_soon(self._rec())

    def _read(self):
        v = self.dut.uio_out.value
        assert v.is_resolvable, f"X/Z on uio_out: {v}"
        return tuple(int(v) >> b & 1 for b in self.bits)

    async def _xz(self, s):
        """An X or Z can only appear through a value change, so every change is checked (uio_out in _rec)."""
        assert s.value.is_resolvable, f"X/Z on {s._name}: {s.value} at {now()} ps"
        while self.on:
            await ValueChange(s)
            assert s.value.is_resolvable, f"X/Z on {s._name}: {s.value} at {now()} ps"

    async def _rec(self):
        self.last = self._read()
        self.edges.append((now(), self.last))
        while self.on:
            await ValueChange(self.dut.uio_out)
            v = self._read()
            if v != self.last:
                self.last = v
                self.edges.append((now(), v))

    def stop(self):
        self.on = False


def settled(edges):
    """Keep the last value recorded at each time, then drop entries that change nothing.

    uio_out is assigned in a combinational block that first clears it, so the simulator reports zero-width
    intermediate values within one time step (also when only ui_in changed). They are not pin activity."""
    out = []
    for t, v in edges:
        if out and out[-1][0] == t:
            out.pop()
        if not out or out[-1][1] != v:
            out.append((int(t), v))
    return out


def differential(edges):
    """(TD+, TD-) samples -> +1 (HI), -1 (LO) or 0 (no differential voltage: the pair is idle)."""
    return [(t, a - b) for t, (a, b) in settled(edges)]


# ------------------------------------------------------------------ link test pulses
def nlp_check(edges, t_end):
    """Violations of the link test pulse rules in a recording of (TD+, TD-); also returns the pulses found."""
    bad, pulses, t_hi = [], [], None
    for t, d in differential(edges):
        if d == -1:
            bad.append(f"negative differential at {t} ps: link test pulses are positive only")
        if d == 1 and t_hi is None:
            t_hi = t
        elif d != 1 and t_hi is not None:
            pulses.append((t_hi, t - t_hi))
            t_hi = None
    if t_hi is not None:
        bad.append("line still HI at the end of the recording")
    for t, w in pulses:
        if not NLP_WIDTH_PS[0] <= w <= NLP_WIDTH_PS[1]:
            bad.append(f"pulse at {t} ps is {w / 1000:.0f} ns wide")
    for (t0, _), (t1, _) in zip(pulses, pulses[1:]):
        if not NLP_PERIOD_PS[0] <= t1 - t0 <= NLP_PERIOD_PS[1]:
            bad.append(f"pulses {(t1 - t0) / MS:.3f} ms apart")
    if len(pulses) < 2:
        bad.append(f"only {len(pulses)} pulse(s) in {t_end / MS:.1f} ms")
    return bad, pulses


async def nlp_setup(h, timer_table=None, pulse_table=None):
    await h.wreg(THRESH, 0)                                                  # CMP low while setting up
    await load(h, 0, PROGS["nlp_timer_dsl"], p=0, table=timer_table)          # P = 0 means 256
    await load(h, 1, PROGS["nlp_pulse_dsl"], p=1, pinmode=0b0101, table=pulse_table)   # TD+ uio[4], TD- uio[5]
    await h.xfer([0x40, 0x02])                                               # core 0: RESTART while stopped (empties the FIFO)
    await h.xfer([0x30, GATE_BYTE])                                          # the one setup byte, pushed before RUN
    await run(h, 1)
    await h.wreg(THRESH, 0x80)
    await h.xfer([0x40, 0x01])                                               # core 0: RUN (without RESTART, which would flush the byte)


async def nlp_record(dut, h, n_pulses, limit_ms):
    pins = Pins(dut, bits=(4, 5))
    t0, seen = now(), 0
    while seen < n_pulses and now() - t0 < limit_ms * MS:
        await Timer(200, unit="us")                                          # the host stays idle: CS_n high
        rec = settled(pins.edges)
        seen = sum(1 for (_, a), (_, b) in zip(rec, rec[1:]) if b[0] and not a[0])
    await Timer(1, unit="us")
    pins.stop()
    return pins.edges, now()


@cocotb.test()
async def test_eth_nlp(dut):
    """Link test pulses from the tables alone: 100 ns wide, 16.000 ms apart, positive only, host idle."""
    h = await start40(dut)
    await nlp_setup(h)
    n = NLP_PULSES
    edges, t_end = await nlp_record(dut, h, n, 20 * n)
    bad, pulses = nlp_check(edges, t_end)
    assert not bad, bad
    widths = {w for _, w in pulses}
    gaps = [b[0] - a[0] for a, b in zip(pulses, pulses[1:])]
    dut._log.info(f"NLP: {len(pulses)} pulses, widths {sorted(widths)} ps, gaps {gaps} ps")
    assert widths == {100_000}, f"pulse widths {widths}"
    assert all(g == 16 * MS for g in gaps), f"the period must be exactly 16 ms: {gaps}"


# ------------------------------------------------------------------ Manchester transmit
def tx_check(edges, t_end, data, lsb_first=True):
    """Violations found in one recorded frame, against what IEEE 802.3 says the frame must be."""
    bad = []
    try:
        bits, t_start, etd, worst = em.manchester_decode(differential(edges), t_end)
    except (AssertionError, StopIteration) as e:
        return [f"not a decodable frame: {e!r}"], None
    if bits[:56] != em.PREAMBLE:
        bad.append(f"preamble is not 56 bits of 1010...: {len(bits)} bits decoded, first {bits[:16]}")
    if bits[56:64] != em.SFD:
        bad.append(f"SFD is {bits[56:64]}")
    body = bits[64:]
    if len(body) != 8 * len(data):
        bad.append(f"{len(body)} data bits for {len(data)} bytes")
    else:
        got = [sum(body[8 * k + i] << i for i in range(8)) for k in range(len(data))]
        if got != data:
            bad.append(f"data {[hex(x) for x in got]}, expected {[hex(x) for x in data]}")
    hi = etd + (BT_PS // 2 if bits and bits[-1] else 0)                       # HI time includes a final 1's second half
    if not TP_IDL_PS[0] <= hi <= TP_IDL_PS[1]:
        bad.append(f"start of idle is HI for {hi / 1000:.0f} ns")
    if worst:
        bad.append(f"an edge is {worst} ps off the 50 ns grid")
    return bad, (t_start, etd, worst, len(bits))


async def tx_setup(h, gate_table=None, tx_table=None, tx_msb=None):
    await load(h, 0, PROGS["eth_gate_dsl"], p=1, table=gate_table)
    await load(h, 1, PROGS["eth_tx_dsl"], p=1, pinmode=0b0101, table=tx_table, msb=tx_msb)   # TD+ uio[4], TD- uio[5]
    await h.wreg(THRESH, 0x80)
    await run(h, 0)
    await run(h, 1)


async def tx_frame(dut, h, data):
    """Push the data to core 1, then one byte to core 0 to send the frame; returns the recording."""
    pins = Pins(dut, bits=(4, 5))
    await h.xfer([0x31] + data)
    await h.xfer([0x30, GATE_BYTE])
    await h.cycles((64 + 8 * len(data)) * 4 + 80)
    pins.stop()
    await h.cycles(2)
    return pins.edges, now()


TX_FRAMES = [[0x00, 0xFF, 0xA5], [0x12, 0x34, 0x56], [0x81], [0xFE, 0x01], [0x55, 0xAA, 0x0F]]


@cocotb.test()
async def test_eth_tx(dut):
    """Preamble, SFD and 1 to 3 host-pushed bytes as Manchester code at 10 Mb/s, then the start of idle."""
    h = await start40(dut)
    await tx_setup(h)
    for data in TX_FRAMES:
        edges, t_end = await tx_frame(dut, h, data)
        bad, info = tx_check(edges, t_end, data)
        assert not bad, (data, bad)
        t_start, etd, worst, nbits = info
        last = max(t for t, _ in settled(edges))
        dut._log.info(f"TX {[hex(x) for x in data]}: {nbits} bits, {(last - t_start) / 1000:.0f} ns on the wire, "
                      f"worst edge error {worst} ps, start of idle {etd / 1000:.0f} ns after the last bit")
        assert (await h.rreg(0x10 + STATUS))[0] & 0x20 == 0, "TX FIFO overflow"


# ------------------------------------------------------------------ frame-start detector
async def sfd_setup(h, table=None):
    prog = PROGS["eth_sfd_dsl"]
    await load(h, 0, prog, p=1, pinmode=0b01, inmap01=0x17, table=table)      # IN0 <- ui_in[7]; pulse on uio[0]
    await h.wreg(0x22, 0xC7, 0x87)                                            # uo_out[0] <- ui_in[7] direct, uo_out[1] synchronized
    await run(h, 0)
    await h.cycles(8)


async def drive_line(h, edges):
    for t, v in edges:
        dt = t - now()
        if dt > 0:
            await Timer(dt, unit="ps")
        h.ui7 = v
        h._write()


async def sfd_frame(dut, h, rng, table, jitter_ps=0, dcd_ps=0, shape="uniform", edges=None, direct=None):
    """One waveform on ui_in[7]. Returns (rise times of the pulse on uio[0], the true last SFD edge, the model's
    prediction of the rise times). The Python model (eth_model.Core) is run on the same waveform."""
    await RisingEdge(dut.clk)
    t_clk = now()
    sfd_edge = None
    if edges is None:
        data = [rng.randrange(256) for _ in range(rng.randint(1, 3))]
        t0 = t_clk + 40 * CLK_PS + rng.randrange(CLK_PS)
        edges, sfd_edge = em.manchester_frame(data, t0=t0, ppm=rng.uniform(-200, 200), jitter_ps=jitter_ps,
                                              dcd_ps=dcd_ps, rng=rng, shape=shape)
    else:
        edges = [(t_clk + t, v) for t, v in edges]
    edges = [(t + 1 if (t - t_clk) % CLK_PS == 0 else t, v) for t, v in edges]   # never exactly on a clock edge
    pins = Pins(dut, bits=(0,))
    if direct is not None:
        cocotb.start_soon(direct(edges))
    await drive_line(h, edges)
    await Timer(24 * CLK_PS, unit="ps")
    pins.stop()
    rec = settled(pins.edges)
    rises = [t for (_, a), (t, b) in zip(rec, rec[1:]) if b[0] and not a[0]]
    core = em.Core(table, tuple(PROGS["eth_sfd_dsl"]["reset_sel"]))
    model, prev = [], 0
    n = (now() - t_clk) // CLK_PS
    for k, lvl in enumerate(em.sample(edges, t_clk + CLK_PS, n)):
        o = core.step(lvl) & 1
        if o and not prev:
            model.append(t_clk + (k + 1) * CLK_PS)
        prev = o
    await Timer(1, unit="ps")
    return rises, sfd_edge, model


def sfd_verdict(rises, sfd_edge):
    if len(rises) != 1:
        return "miss" if not rises else "multiple"
    d = rises[0] - sfd_edge
    return "ok" if em.SFD_DELAY_PS[0] < d <= em.SFD_DELAY_PS[1] else f"wrong time ({d} ps)"


def runt_line():
    """Not a frame: two 50 ns pulses 50 ns apart on an idle line, then a 100 ns link test pulse."""
    return [(1_000_000, 1), (1_050_000, 0), (1_100_000, 1), (1_150_000, 0), (2_000_000, 1), (2_100_000, 0), (2_600_000, 0)]


def preamble_only():
    """A preamble that stops (carrier lost) without an SFD."""
    e, t, v = [], 1_000_000, 1
    for _ in range(40):
        e.append((t, v))
        t, v = t + 100_000, 1 - v
    return e + [(t + 100_000, 0), (t + 600_000, 0)]


async def sfd_run(dut, h, table, frames, points):
    """Run frames at each (jitter, dcd, shape) point. Returns {point: [verdicts]} and the RTL-vs-model mismatches."""
    rng = random.Random(2027)
    out, mism = {}, []
    for jit, dcd, shape in points:
        res = []
        for _ in range(frames):
            rises, sfd_edge, model = await sfd_frame(dut, h, rng, table, jit, dcd, shape)
            if [abs(a - b) < CLK_PS // 2 for a, b in zip(rises, model)] != [True] * len(model) or len(rises) != len(model):
                mism.append((jit, dcd, rises, model))
            res.append(sfd_verdict(rises, sfd_edge))
        out[(jit, dcd, shape)] = res
    return out, mism


SFD_CLEAN = [(0, 0, "uniform"), (4000, 0, "uniform"), (8000, 0, "uniform"), (11000, 0, "uniform"),
             (0, 8000, "uniform"), (0, -8000, "uniform"), (6000, 4000, "gauss"), (6000, -4000, "gauss")]
SFD_STRESS = [(16000, 0, "uniform"), (20000, 0, "uniform")]


@cocotb.test()
async def test_eth_sfd(dut):
    """Frame-start pulse 150..175 ns after the SFD's last edge, with up to +-11 ns of jitter; line passed through."""
    h = await start40(dut)
    table = PROGS["eth_sfd_dsl"]["table"]
    await sfd_setup(h)
    frames = SFD_FRAMES

    # pass-through while the core parses: uo_out[0] follows the line in the same cycle, uo_out[1] two edges later
    lag = []

    async def watch(edges):
        for t, v in edges[:20]:
            await Timer(max(t - now(), 0) + 2000, unit="ps")                  # 2 ns after the line edge
            d = int(dut.uo_out.value) & 1
            for k in range(4):
                if (int(dut.uo_out.value) >> 1 & 1) == v:
                    break
                await RisingEdge(dut.clk)
                await Timer(1000, unit="ps")
            lag.append((d == v, k))
    rises, sfd_edge, model = await sfd_frame(dut, h, random.Random(1), table, direct=watch)
    assert sfd_verdict(rises, sfd_edge) == "ok", (rises, sfd_edge)
    assert lag and all(d for d, _ in lag), "direct pass-through must follow the line within the cycle"
    assert all(k == 2 for _, k in lag), f"synchronized pass-through must lag exactly 2 clock edges: {lag}"

    res, mism = await sfd_run(dut, h, table, frames, SFD_CLEAN)
    assert not mism, f"RTL and Python model disagree: {mism[:3]}"
    for point, v in res.items():
        dut._log.info(f"SFD jitter +-{point[0] / 1000:.0f} ns ({point[2]}), dcd {point[1] / 1000:+.0f} ns: "
                      f"{v.count('ok')}/{len(v)} ok")
        assert v.count("ok") == len(v), (point, [x for x in v if x != "ok"])

    # beyond the limit: the result is recorded, not required; the RTL must still match the model frame for frame
    res, mism = await sfd_run(dut, h, table, frames, SFD_STRESS)
    assert not mism, f"RTL and Python model disagree: {mism[:3]}"
    for point, v in res.items():
        dut._log.info(f"SFD beyond the limit, jitter +-{point[0] / 1000:.0f} ns: {v.count('ok')}/{len(v)} ok "
                      f"({sorted(set(x.split(' ')[0] for x in v if x != 'ok'))})")

    # things that are not a frame start must not fire
    for name, wave in (("runt pulses and a link pulse", runt_line()), ("preamble without SFD", preamble_only())):
        rises, _, model = await sfd_frame(dut, h, None, table, edges=wave)
        assert rises == [] and model == [], f"{name}: pulse at {rises}"
    # and the detector still works afterwards
    rises, sfd_edge, _ = await sfd_frame(dut, h, random.Random(3), table)
    assert sfd_verdict(rises, sfd_edge) == "ok"


# ------------------------------------------------------------------ planted bugs
@cocotb.test(skip=GL)
async def test_eth_planted_bugs(dut):
    """Each program broken in at least two ways; every break must be reported by the checker of its test."""
    h = await start40(dut)
    caught = []

    # --- link test pulses ---
    pulse, timer = PROGS["nlp_pulse_dsl"], PROGS["nlp_timer_dsl"]
    nlp_bugs = {
        "pulse 250 ns wide": dict(pulse_table=mutate(pulse, "IDLE", set_wait(9))),
        "no wait for CMP to fall (a burst of pulses)": dict(pulse_table=mutate(pulse, "REL", set_next(pulse, "IDLE"))),
        "period 4.6 ms (the long rows shortened)": dict(timer_table=mutate(timer, "W", set_wait(0), rows=(0, 2))),
    }
    for name, kw in nlp_bugs.items():
        await nlp_setup(h, **kw)
        edges, t_end = await nlp_record(dut, h, 3, 12)
        bad, _ = nlp_check(edges, t_end)
        assert bad, f"planted bug not caught: NLP, {name}"
        caught.append(f"NLP, {name}: {bad[0]}")

    # --- Manchester transmit ---
    tx, gate = PROGS["eth_tx_dsl"], PROGS["eth_gate_dsl"]
    swap = lambda w: (w & ~(0xF << 7)) | ({1: 2, 2: 1}.get(w >> 7 & 15, w >> 7 & 15)) << 7
    polarity = list(tx["table"])
    for s in [f"{k}{i}" for k in "FS" for i in range(8)] + ["S7E"]:
        polarity = mutate(dict(tx, table=polarity), s, swap)
    tx_bugs = {
        "gate 8 cycles short (one preamble bit pair missing)": dict(gate_table=mutate(gate, "ARM", set_wait(232))),
        "data bits inverted": dict(tx_table=polarity),
        "bytes sent MSB first": dict(tx_msb=True),
        "first data bit not shifted out (T3 holds)": dict(tx_table=mutate(tx, "T3", set_op(0))),
        "no start-of-idle pulse": dict(tx_table=mutate(tx, "ETD", set_out(0))),
    }
    data = [0x12, 0x34, 0x56]
    for name, kw in tx_bugs.items():
        await tx_setup(h, **kw)
        edges, t_end = await tx_frame(dut, h, data)
        bad, _ = tx_check(edges, t_end, data)
        assert bad, f"planted bug not caught: TX, {name}"
        caught.append(f"TX, {name}: {bad[0]}")

    # --- frame-start detector ---
    sfd = PROGS["eth_sfd_dsl"]
    no_la = mutate(sfd, "H3", set_next(sfd, "L1"), rows=(1,))                 # a 3-sample high is always "long"
    no_lock = list(sfd["table"])
    for s in ("H1", "H2"):                                                    # a short high counts without lock
        no_lock = mutate(dict(sfd, table=no_lock), s, lambda w: sfd["table"][4 * sfd["names"].index(s) + 1], rows=(0,))
    late = mutate(sfd, "DET", set_wait(2))
    frames = max(SFD_FRAMES, 40)
    for name, table, how in (("3-sample high never treated as a short", no_la, "jitter"),
                             ("no preamble lock required", no_lock, "runt"),
                             ("pulse one cycle late", late, "clean")):
        await sfd_setup(h, table=table)
        if how == "runt":
            rises, _, _ = await sfd_frame(dut, h, None, table, edges=runt_line())
            bad = [f"pulse at {rises} on a line that carries no frame"] if rises else []
        else:
            point = (11000, 0, "uniform") if how == "jitter" else (0, 0, "uniform")
            res, mism = await sfd_run(dut, h, table, frames, [point])
            assert not mism, f"RTL and Python model disagree on a mutant: {mism[:2]}"
            bad = [x for x in res[point] if x != "ok"]
            bad = [f"{len(bad)}/{frames} frames wrong, e.g. {bad[0]}"] if bad else []
        assert bad, f"planted bug not caught: SFD, {name}"
        caught.append(f"SFD, {name}: {bad[0]}")

    for line in caught:
        dut._log.info("caught  " + line)
    assert len(caught) == len(nlp_bugs) + len(tx_bugs) + 3
