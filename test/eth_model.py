# SPDX-License-Identifier: Apache-2.0
"""10BASE-T helpers for test_ethernet.py and the offline jitter sweep (docs/ethernet.md).

Three independent pieces, none of them derived from the DSL programs:

* manchester_frame(): a 10BASE-T frame as a list of (time_ps, level) edges, written from IEEE 802.3
  (preamble and SFD 3.2.1/3.2.2, LSB first 3.3, Manchester code 7.3.1.1), with clock offset, per-edge
  jitter and duty-cycle distortion.
* manchester_decode(): decodes recorded TD+/TD- edges back to bits, from the same clauses.
* Core: a cycle-accurate Python model of one PFST core (transcribed from src/pfst_core_sram.v) that runs
  a compiled table. test_ethernet.py checks it against the RTL on every frame it simulates; the sweep
  then uses it to run far more frames than RTL simulation allows.

Run this file to produce the sweep table:  python3 eth_model.py [frames_per_point]
"""
import json
import os
import random
import sys

CLK_PS = 25_000                         # 40 MHz
BT_PS = 100_000                         # one bit time at 10 Mb/s
PREAMBLE = [1, 0] * 28                  # 7 octets 10101010, in transmission order
SFD = [1, 0, 1, 0, 1, 0, 1, 1]


def frame_bits(data):
    return PREAMBLE + SFD + [(b >> i) & 1 for b in data for i in range(8)]


def manchester_frame(data, t0=0, ppm=0.0, jitter_ps=0, dcd_ps=0, etd_ps=300_000, rng=None, shape="uniform"):
    """Edges [(t_ps, level)] of one frame on an idle-low line, and the time of the SFD's last edge.

    A 1 is low then high, a 0 is high then low. Every edge is moved by a random jitter in
    [-jitter_ps, +jitter_ps] (uniform, or Gaussian with sigma = jitter_ps / 3 clipped at jitter_ps), and
    rising edges are delayed and falling edges advanced by dcd_ps (duty-cycle distortion: highs get shorter
    for dcd_ps > 0). The frame ends with the start of idle: high for etd_ps, then low.
    """
    rng = rng or random.Random(0)
    half = BT_PS / 2 * (1 + ppm * 1e-6)
    levels = []
    for b in frame_bits(data):
        levels += [0, 1] if b else [1, 0]
    n_half = len(levels)
    nominal, lvl = [], 0                # (time, new level, half index)
    for k, v in enumerate(levels):
        if v != lvl:
            nominal.append((t0 + k * half, v, k))
            lvl = v
    t_end = t0 + n_half * half
    if lvl == 0:
        nominal.append((t_end, 1, n_half))
    nominal.append((t_end + etd_ps, 0, None))
    edges, sfd_edge = [], None
    for t, v, k in nominal:
        if jitter_ps:
            if shape == "gauss":
                j = max(-jitter_ps, min(jitter_ps, rng.gauss(0, jitter_ps / 3)))
            else:
                j = rng.uniform(-jitter_ps, jitter_ps)
        else:
            j = 0
        t = t + j + (dcd_ps if v else -dcd_ps)
        edges.append((int(round(t)), v))
        if k == 2 * 64 - 1:             # rising edge in the middle of the SFD's last bit
            sfd_edge = edges[-1][0]
    assert all(a[0] < b[0] for a, b in zip(edges, edges[1:])), "jitter reordered two edges"
    return edges, sfd_edge


def sample(edges, t0_ps, n, clk_ps=CLK_PS, idle=0):
    """The line level seen by n successive clock edges starting at t0_ps (value just before each edge)."""
    out, j, lvl = [], 0, idle
    for k in range(n):
        t = t0_ps + k * clk_ps
        while j < len(edges) and edges[j][0] < t:
            lvl = edges[j][1]
            j += 1
        out.append(lvl)
    return out


def manchester_decode(edges, t_end):
    """Decode recorded differential levels to bits.

    edges: [(t_ps, d)] with d = +1 (TD+ above TD-), -1 (below) or 0 (no differential voltage), starting idle.
    Returns (bits, t_start, etd_ps, worst_edge_error_ps). The frame starts at the first departure from idle; a
    bit cell is BT_PS long; a cell whose halves are not opposite ends the frame (the start-of-idle violation).
    """
    def level(t):
        d = 0
        for te, de in edges:
            if te > t:
                break
            d = de
        return d
    start = next(t for t, d in edges if d != 0)
    bits, k = [], 0
    while True:
        a, b = level(start + k * BT_PS + BT_PS // 4), level(start + k * BT_PS + 3 * BT_PS // 4)
        if a == -1 and b == 1:
            bits.append(1)
        elif a == 1 and b == -1:
            bits.append(0)
        else:
            break
        k += 1
        assert start + k * BT_PS < t_end, "frame never ends"
    t_data_end = start + k * BT_PS
    assert level(t_data_end + 1) == 1, "start of idle must be HI"
    t_idle = next(t for t, d in edges if t > t_data_end and d != 1)
    assert level(t_idle) == 0, "after the start-of-idle pulse the pair must be undriven (no differential)"
    worst = max(abs((t - start) % (BT_PS // 2)) for t, d in edges if start <= t <= t_idle)
    worst = min(worst, BT_PS // 2 - worst) if worst > BT_PS // 4 else worst
    return bits, start, t_idle - t_data_end, worst


class Core:
    """One PFST core at P = 1 with an empty TX FIFO, cycle for cycle as in src/pfst_core_sram.v.

    step(raw_in0) is one rising clock edge; self.out is out_reg after that edge.
    """
    def __init__(self, table, reset_sel=(0, 0), msb_first=False):
        self.t, self.rsel, self.msb = list(table) + [0] * (256 - len(table)), reset_sel, msb_first
        self.first = self.rowv = 0
        self.boot = 1
        self.wcnt = self.sr = self.obit = self.cnt = self.out = 0
        self.r = 0
        self.s1 = self.s2 = 0

    def step(self, raw):
        r = self.r
        selb, sela, op, osel = r & 3, r >> 2 & 3, r >> 4 & 3, r >> 6 & 1
        rout, rwait, rnext = r >> 7 & 15, r >> 11 & 255, r >> 19 & 63
        do_op = self.first
        n_obit, n_sr, n_cnt = self.obit, self.sr, self.cnt
        if do_op and op == 1:
            n_obit = (self.sr >> 7 if self.msb else self.sr) & 1
            n_sr = ((self.sr << 1 | self.s2) & 255) if self.msb else (self.s2 << 7 | self.sr >> 1)
            n_cnt = max(self.cnt - 1, 0)
        elif do_op and op == 2:
            n_sr, n_cnt = 0, 8                                   # LOAD from an empty FIFO after RESTART
        rem_w = rwait if self.first else self.wcnt
        last = rem_w == 0                                        # P = 1: rem_s is always 0
        st, sa, sb = (0, *self.rsel) if self.boot else (rnext, sela, selb)
        a = (self.s2, 0, 0, 0)[sa]                               # IN1, TX_FULL, IN2 read 0 here
        b = (int(n_cnt == 0), n_obit, 0, 0)[sb]
        issue = (not (self.first or self.rowv)) if self.boot else ((self.first or self.rowv) and last)
        nr = self.t[st << 2 | a << 1 | b] if issue else self.r
        if self.first:
            self.sr, self.obit, self.cnt = n_sr, n_obit, n_cnt
            self.out = (rout & 14) | (n_obit if osel else rout & 1)
            self.rowv = 1
        self.wcnt = (rem_w - 1) & 255
        if self.boot and issue:
            self.boot = 0
        self.first = int(bool(issue))
        self.r = nr
        self.s2, self.s1 = self.s1, raw
        return self.out


def sfd_trial(table, reset_sel, rng, jitter_ps=0, dcd_ps=0, ppm=None, shape="uniform", data=None):
    """One frame through the model. Returns (verdict, delay_ps): verdict is 'ok', 'miss', 'early', 'late' or
    'multiple'; delay_ps is the pulse's rising clock edge minus the true (jittered) last SFD edge."""
    data = data if data is not None else [rng.randrange(256) for _ in range(rng.randint(1, 4))]
    ppm = rng.uniform(-200, 200) if ppm is None else ppm        # transmitter and chip clocks, +-100 ppm each
    t0 = 400_000 + rng.randrange(CLK_PS)
    edges, sfd_edge = manchester_frame(data, t0=t0, ppm=ppm, jitter_ps=jitter_ps, dcd_ps=dcd_ps, rng=rng, shape=shape)
    n = (edges[-1][0] + 600_000) // CLK_PS
    core = Core(table, reset_sel)
    rises, prev = [], 0
    for k, lvl in enumerate(sample(edges, 0, n)):
        o = core.step(lvl) & 1
        if o and not prev:
            rises.append(k * CLK_PS)
        prev = o
    if not rises:
        return "miss", None
    if len(rises) > 1:
        return "multiple", None
    d = rises[0] - sfd_edge
    return ("ok" if SFD_DELAY_PS[0] < d <= SFD_DELAY_PS[1] else "early" if d <= SFD_DELAY_PS[0] else "late"), d


# pulse edge minus last SFD edge: the pulse appears 6 clock edges after the edge that first samples the new
# level, and that first edge is 0..25 ns after the line edge (measured, then fixed here)
SFD_DELAY_PS = (6 * CLK_PS, 7 * CLK_PS)


def sweep(frames):
    here = os.path.dirname(os.path.abspath(__file__))
    prog = json.load(open(os.path.join(here, "compiled_tables.json")))["eth_sfd_dsl"]
    tab, rs = prog["table"], tuple(prog["reset_sel"])
    rows = []
    for name, points in (("jitter_ns", [(j, 0) for j in (0, 2, 4, 6, 8, 10, 11, 12, 12.5, 13, 13.5, 14, 16, 18, 20)]),
                         ("dcd_ns", [(0, d) for d in (-12, -10, -8, -6, -4, -2, 2, 4, 6, 8, 10, 12)]),
                         ("jitter+dcd", [(j, d) for j in (4, 8) for d in (-6, -3, 3, 6)])):
        for j, d in points:
            for shape in (("uniform", "gauss") if j else ("uniform",)):
                rng = random.Random(int(1000 * j) + d + 7)
                res = {}
                for _ in range(frames):
                    v, _d = sfd_trial(tab, rs, rng, jitter_ps=int(j * 1000), dcd_ps=d * 1000, shape=shape)
                    res[v] = res.get(v, 0) + 1
                rows.append((name, j, d, shape, frames, res))
                print(f"{name:11s} jitter +-{j:4.1f} ns ({shape:7s}) dcd {d:+3d} ns: "
                      f"ok {res.get('ok', 0)}/{frames}  " + " ".join(f"{k}={v}" for k, v in sorted(res.items()) if k != "ok"),
                      flush=True)
    return rows


if __name__ == "__main__":
    sweep(int(sys.argv[1]) if len(sys.argv) > 1 else 2000)
