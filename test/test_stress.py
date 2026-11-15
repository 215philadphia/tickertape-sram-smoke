# SPDX-License-Identifier: Apache-2.0
"""Seeded random stress tests on the chip RTL. Not part of the default run (they take minutes):

    cd test && make -B COCOTB_TEST_MODULES=test_stress               # seed 1
    cd test && SEED=7 STRESS_FRAMES=150 make -B COCOTB_TEST_MODULES=test_stress

Every failure message carries the seed and the iteration, so a failure can be replayed.

* SPI target: random frame lengths, SCK rates down to the measured limit, random data, frames aborted by CS_n in
  mid-byte (the target must resynchronise with no RESTART), all while the host port reads registers in the background.
* Tables: random full 256-word tables written and read back on both cores, interleaved.
* Running core: writes to a table while its core runs must not change it.
"""
import os
import random

import cocotb

from test_pfst import Host, bit, start
from test_programs import PROGS, load, run

SEED = int(os.environ.get("SEED", "1"))
FRAMES = int(os.environ.get("STRESS_FRAMES", "60"))
ROUNDS = int(os.environ.get("STRESS_ROUNDS", "3"))
HALVES = (6, 7, 8, 10, 12, 20, 40)          # SCK half periods in chip cycles; 6 is the tested limit (12-cycle period)


async def master(h, dut, half, data, abort_bits=None):
    """Mode 0 master on ui_in[0] MOSI, ui_in[1] SCK, ui_in[2] CS_n. `data` are the bytes to send; with abort_bits the
    LAST byte is cut after that many bits and CS_n is released. Returns the MISO bits sampled just before each rising
    edge, as a flat list."""
    def low(mosi, sck, cs):
        h.set_low(mosi | sck << 1 | cs << 2)
    miso = []
    low(0, 0, 0)
    await h.cycles(30)
    for j, b in enumerate(data):
        nbits = abort_bits if (abort_bits is not None and j == len(data) - 1) else 8
        for i in range(7, 7 - nbits, -1):
            m = (b >> i) & 1
            low(m, 0, 0)
            await h.cycles(half)
            assert bit(dut.uio_oe, 0), "MISO not driven during the frame"
            miso.append(bit(dut.uio_out, 0))
            low(m, 1, 0)
            await h.cycles(half)
            low(m, 0, 0)
    await h.cycles(half)
    low(0, 0, 1)
    await h.cycles(40)
    assert not bit(dut.uio_oe, 0), "MISO still driven after CS_n rose"
    return miso


def bits_of(byte_list):
    return [(b >> i) & 1 for b in byte_list for i in range(7, -1, -1)]


@cocotb.test()
async def test_stress_spi_target(dut):
    rng = random.Random(SEED)
    dut._log.info(f"stress seed {SEED}, {FRAMES} frames")
    h = await start(dut)
    h.set_low(0b100)
    await load(h, 0, "spi_tgt_dsl", p=1, out_init=0, pinmode=0b11, inmap01=0x10, inmap23=0x22)
    await run(h, 0)
    # known values in the unused core 1 block, read back in the background during every frame
    core1 = [5, 0, 0, 0xE4, 0, 0x10, 0x32, 0xFF]
    await h.wreg(0x10, *core1)
    stats = {"frames": 0, "aborted": 0, "bytes": 0, "noise_reads": 0}

    async def noise(stop):
        while not stop[0]:
            got = await h.rreg(0x10, 8)
            assert got == core1, f"seed {SEED}: host-port read during a frame returned {got}"
            stats["noise_reads"] += 1

    for it in range(FRAMES):
        half = rng.choice(HALVES)
        abort = rng.random() < 0.3
        n = rng.randint(1, 3)
        tx = [rng.randrange(256) for _ in range(n)]
        rx = [rng.randrange(256) for _ in range(n)]
        where = f"seed {SEED} iter {it} half {half} tx {tx} rx {rx} abort {abort}"
        if abort:
            # j complete bytes, then a partial one: the target loads one TX byte per CS fall and one more after
            # each complete byte, so push exactly j + 1 and the FIFO is empty again afterwards
            j = rng.randint(0, n - 1)
            abort_bits = rng.randint(1, 7)
            sent = rx[:j + 1]
            tx = tx[:j + 1]
            await h.xfer([0x30] + tx)
            stop = [False]
            nz = cocotb.start_soon(noise(stop))
            miso = await master(h, dut, half, sent, abort_bits=abort_bits)
            stop[0] = True
            await nz
            want = bits_of(tx[:j]) + bits_of([tx[j]])[:abort_bits]
            assert miso == want, f"{where}: MISO bits {miso} != {want}"
            stats["aborted"] += 1
        else:
            await h.xfer([0x30] + tx)
            stop = [False]
            nz = cocotb.start_soon(noise(stop))
            miso = await master(h, dut, half, rx)
            stop[0] = True
            await nz
            assert miso == bits_of(tx), f"{where}: MISO bits differ"
            saved = (await h.xfer([0x50, 0]))[1]
            assert saved == rx[-1], f"{where}: SCR {saved:#x}, expected {rx[-1]:#x}"
            stats["bytes"] += n
        stats["frames"] += 1
    dut._log.info(f"stress done: {stats}")
    assert stats["noise_reads"] > 0, "background host-port reads never ran"


@cocotb.test()
async def test_stress_tables(dut):
    """Random full tables on both cores, interleaved, each read back whole through the host port."""
    rng = random.Random(SEED)
    h = await start(dut)
    for rnd in range(ROUNDS):
        t = [[rng.randrange(1 << 29) for _ in range(256)] for _ in range(2)]
        for c in (0, 1):
            await h.write_table(c, 0, t[c])
        for c in (1, 0):
            got = await h.read_table(c, 0, 256)
            bad = [i for i in range(256) if got[i] != t[c][i]]
            assert not bad, f"seed {SEED} round {rnd} core {c}: {len(bad)} rows differ, first row {bad[0]}"
    dut._log.info(f"{ROUNDS} rounds x 2 cores x 256 random words verified")


@cocotb.test()
async def test_stress_write_while_running(dut):
    """A table written while the core runs is ignored: a running UART transmitter's table is unchanged after random
    write attempts, and the transmitter still works afterwards."""
    rng = random.Random(SEED)
    h = await start(dut)
    await load(h, 0, "uart_tx_dsl", p=1, out_init=1, pinmode=0b01)
    table = PROGS["uart_tx_dsl"]["table"]
    await run(h, 0)
    for _ in range(ROUNDS * 3):
        row = rng.randrange(0, 200)
        await h.write_table(0, row, [rng.randrange(1 << 29) for _ in range(rng.randint(1, 8))])
    await h.xfer([0x40, 0x00])                                  # stop
    got = await h.read_table(0, 0, len(table))
    assert got == table, f"seed {SEED}: table changed by writes while running"
