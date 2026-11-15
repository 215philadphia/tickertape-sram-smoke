"""Host software (host/ttpfst, host/examples) run against the chip RTL, with the same checks as test/test_programs.py.

Every byte the host library sends goes through the SAME effect generators that run on the demo board; only the
executor differs (cocotb_io.CocoIO). Where a check would be blind to a symmetric bug (write and read back with the
same wrong byte order passes), it reads through the independent reference Host from test/test_pfst.py.
"""
import os
import sys

import cocotb
from cocotb.triggers import FallingEdge

HOST_DIR = os.environ.get("HOST_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(HOST_DIR, "examples"))   # same tree as ttpfst, so mutate.sh can mutate examples

from cocotb_io import CocoIO                                             # noqa: E402
from test_pfst import Host, bit, start                                   # noqa: E402
from test_programs import (BP, PROGS, I2cTarget, SpiMonitor, uart_decode, uart_frames, ps2_frame,   # noqa: E402
                           load as ref_load)
from ttpfst import driver, loader, programs                              # noqa: E402
import i2c_write as ex_i2c                                               # noqa: E402
import nano_tick as ex_nano                                              # noqa: E402
import uart_tx as ex_uart                                                # noqa: E402
import uart_rx as ex_urx                                                 # noqa: E402
import spi_tx as ex_spi                                                  # noqa: E402
import ps2_rx as ex_ps2                                                  # noqa: E402
import spi_target as ex_tgt                                              # noqa: E402

LAB = [0x00000000, 0x1FFFFFFF, 0x12345678, 0x0A5A5A5A, 0x15555555, 0x0AAAAAAA, 0x00000001, 0x10000000]


async def setup(dut):
    ref = await start(dut)
    return ref, CocoIO(dut, ref)


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_table_bytes_match_reference(dut):
    """Tables written by the host library read back identically through the reference Host, and the reverse.
    (Same-code write + read-back would pass with a wrong byte order; the reference read does not.)"""
    ref, io = await setup(dut)
    for core in (0, 1):
        await io.run(driver.write_table(core, 3, LAB))
        assert await ref.read_table(core, 3, len(LAB)) == LAB, f"core {core}: reference read-back differs"
        other = [w ^ 0x0F0F0F0F for w in LAB]
        await ref.write_table(core, 40, other)
        assert await io.run(driver.read_table(core, 40, len(other))) == other, f"core {core}: library read differs"


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_registers_match_reference(dut):
    """Library register writes read back through the reference Host; reset values as in test_registers."""
    ref, io = await setup(dut)
    assert await io.run(driver.rreg(0x00, 11)) == [1, 0, 0, 0xE4, 0, 0x10, 0x32, 0xFF, 0, 0, 0]
    await io.run(driver.wreg(0x10, [7, 3, 0x0B, 0x1B, 0x66, 0xA5, 0x5A, 12]))
    assert await ref.rreg(0x10, 8) == [7, 3, 0x0B, 0x1B, 0x66, 0xA5, 0x5A, 12]
    await ref.wreg(0x20, 0x80, 0x77)
    assert await io.run(driver.rreg(0x20, 2)) == [0x80, 0x77]


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_loader_equals_reference_load(dut):
    """loader.load leaves the chip in exactly the state test_programs.load does: table and registers, read via the
    reference Host, for every program with its simulation config."""
    ref, io = await setup(dut)
    cases = [(0, "uart_tx_dsl", "uart_tx_dsl"), (1, "uart_rx_dsl", "uart_rx_dsl"), (0, "i2c_wr_dsl", "i2c_wr_dsl"),
             (1, "nt_trader_dsl", "nt_trader_dsl")]
    for core, name, conf in cases:
        await io.run(loader.load(core, PROGS[name], programs.SIM[conf], name))
        table = PROGS[name]["table"]
        assert await ref.read_table(core, 0, len(table)) == table, f"{name}: table"
        regs = await ref.rreg(0x10 * core, 8)
        assert regs == loader.register_values(PROGS[name], programs.SIM[conf]), f"{name}: registers {regs}"
        assert (await ref.rreg(0x10 * core + 10))[0] == programs.SIM[conf]["out_init"], f"{name}: OUT_INIT"
    # and the exact registers the reference load() writes, for the I2C program (names -> done state)
    done = PROGS["i2c_wr_dsl"]["names"].index("DONE")
    await ref_load(ref, 0, "i2c_wr_dsl", p=1, out_init=0b11, pinmode=0b1010, inmap01=(8 | 1) << 4 | (8 | 0),
                   done_state=done)
    ref_regs = await ref.rreg(0, 8)
    await io.run(loader.load(0, PROGS["i2c_wr_dsl"], programs.SIM["i2c_wr_dsl"], "i2c_wr_dsl"))
    assert await ref.rreg(0, 8) == ref_regs, "library registers differ from reference load()"


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_uart_tx(dut):
    """examples/uart_tx on core 0: same expectation as test_compiled_uart_tx (decoded 8N1 frames on uio[0])."""
    ref, io = await setup(dut)
    line = []

    async def rec():
        while True:
            await FallingEdge(dut.clk)
            line.append(bit(dut.uio_out, 0))
    cocotb.start_soon(rec())
    data = [0x00, 0xFF, 0x55]
    await io.run(ex_uart.send(PROGS, data, programs.SIM["uart_tx_dsl"], settle_bits=4))
    await io.cycles(4 * BP)
    assert uart_decode(line, BP) == data


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_i2c_write(dut):
    """examples/i2c_write against the reactive I2cTarget: a 6-byte write to 0x50, then a NACKed address."""
    ref, io = await setup(dut)
    tgt = I2cTarget(dut, 0x50)
    for addr, payload, expect in ((0x50, [0x00, 0xFF, 0x55, 0xAA, 0x81, 0x42], True), (0x51, [0x12], False)):
        before = list(tgt.written)
        done, st = await io.run(ex_i2c.write(PROGS, addr, payload, programs.SIM["i2c_wr_dsl"]))
        assert done, f"addr {addr:#x}: never reached DONE (STATUS {st:#x})"
        new = tgt.written[len(before):]
        assert new == (payload if expect else []), f"addr {addr:#x}: target got {[hex(x) for x in new]}"
    assert (tgt.starts, tgt.stops, tgt.nacked) == (2, 2, 1), (tgt.starts, tgt.stops, tgt.nacked)


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_nano_tick(dut):
    """examples/nano_tick, both cores: same prices and expectation as test_compiled_nanotick (3 orders)."""
    ref, io = await setup(dut)
    prices = [120, 90, 80, 130, 99, 150, 100, 60, 101]
    mon = SpiMonitor(dut, cs=6, sck=5, mosi=4)                   # independent monitor next to the example's own
    orders = await io.run(ex_nano.trade(PROGS, prices, 100, programs.SIM["nt_rx"], programs.SIM["nt_trader_dsl"],
                                        bit_cycles=BP, window_cycles=2500))
    # SpiMonitor was started before the load, and uio_out reads 0 (CS "low") until PINMODE is written: one empty
    # frame is that load-time artefact, not an order. test_programs starts its monitor after the load.
    dut._log.info(f"example orders {orders} wire {mon.frames}")
    frames = [f for f in mon.frames if f]
    assert len(mon.frames) - len(frames) <= 1, mon.frames
    assert len(frames) == 3, f"{len(frames)} orders on the wire, expected 3: {mon.frames}"
    assert all(f == ex_nano.ORDER for f in frames), frames
    assert orders == frames, f"example saw {orders}, independent monitor {frames}"


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_restart_semantics(dut):
    """driver.start is RESTART + RUN: it clears DONE and flushes the TX FIFO of a core that already ran.
    (Without RESTART the second run would start with DONE set and stale bytes queued.)"""
    ref, io = await setup(dut)
    tgt = I2cTarget(dut, 0x50)
    done, st = await io.run(ex_i2c.write(PROGS, 0x50, [0x12], programs.SIM["i2c_wr_dsl"]))
    assert done and st & driver.STATUS_DONE
    await io.run(driver.tx_push(0, [1, 2]))
    assert await io.run(driver.status(0)) >> 6 == 2, "pushed bytes not queued"
    await io.run(driver.start(0))
    st = await io.run(driver.status(0))
    assert not st & driver.STATUS_DONE, f"DONE survived start(): STATUS {st:#x}"
    assert st >> 6 == 0, f"TX FIFO not flushed by start(): STATUS {st:#x}"
    await io.run(driver.stop(0))
    assert not await io.run(driver.status(0)) & driver.STATUS_RUN, "stop() left the core running"


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_uart_rx(dut):
    """examples/uart_rx on core 1 (line uio[4]) at -1%, 0 and +1% baud error: every byte read with READ_SCR,
    no overrun. Same data and expectation as test_compiled_uart_rx."""
    ref, io = await setup(dut)
    data = [0x00, 0xFF, 0x55, 0xAA, 0x81, 0x42]
    for err in (-0.01, 0.0, 0.01):
        got, st = await io.run(ex_urx.receive(PROGS, data, programs.SIM["uart_rx_core1"], 1, 4, BP, err))
        assert got == data, f"err={err}: received {[None if x is None else hex(x) for x in got]}"
        assert not st & driver.STATUS_RX_OVR, f"RX overrun, STATUS {st:#x}"


@cocotb.test()
async def test_uart_rx_frames_match_reference(dut):
    """The example's UART waveform equals the reference generator's, edge for edge (it is the test's stimulus)."""
    for err in (-0.01, 0.0, 0.01):
        for b in (0x00, 0xFF, 0x55, 0xA5):
            edges, end = ex_urx.frame_edges(b, BP, err)
            wave = uart_frames([b], BP, gap_bits=1, err=err)[10:]     # reference starts its start bit at cycle 10
            lvl, j = 1, 0
            for n in range(end):
                while j < len(edges) and edges[j][0] <= n:
                    lvl, j = edges[j][1], j + 1
                assert lvl == wave[n], f"b={b:#x} err={err}: cycle {n}"


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_spi_tx(dut):
    """examples/spi_tx on core 0, P=4: the bytes pushed come out as mode 0 frames on uio[2:0]."""
    ref, io = await setup(dut)
    mon = SpiMonitor(dut, cs=2, sck=1, mosi=0)
    data = [0x00, 0xFF, 0x55, 0xAA, 0x81, 0x42]
    await io.run(ex_spi.send(PROGS, data, programs.SIM["spi_tx_dsl"]))
    assert [b for f in mon.frames if f for b in f] == data, f"frames {mon.frames}"


@cocotb.test()
async def test_ps2_frames_match_reference(dut):
    """The example's PS/2 frame generator equals test_programs.ps2_frame for good and bad frames."""
    for b in (0x00, 0xFF, 0x1C, 0xF0, 0x5A, 0x81):
        assert ex_ps2.frame(b) == ps2_frame(b), hex(b)
        assert ex_ps2.frame(b, bad_parity=True) == ps2_frame(b, bad_parity=True)
        assert ex_ps2.frame(b, bad_stop=True) == ps2_frame(b, bad_stop=True)


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_ps2_rx(dut):
    """examples/ps2_rx, a protocol the chip was not designed for: good frames received; bad parity and a bad stop bit
    save nothing and raise FLAG; start() clears FLAG; still in sync afterwards (as test_compiled_ps2_rx)."""
    ref, io = await setup(dut)
    await io.run(ex_ps2.start_keyboard(PROGS, programs.SIM["ps2_rx_dsl"]))
    good = [0x00, 0xFF, 0x1C, 0xF0, 0x5A, 0x81]
    got = []
    for b in good:
        await io.run(ex_ps2.play(ex_ps2.frame(b)))
        got.append(await io.run(ex_ps2.poll_byte(0)))
    assert got == good, f"received {got}"
    assert not await io.run(driver.status(0)) & driver.STATUS_FLAG, "FLAG set by a good frame"
    for kind in ({"bad_parity": True}, {"bad_stop": True}):
        await io.run(ex_ps2.play(ex_ps2.frame(0x33, **kind)))
        assert await io.run(ex_ps2.poll_byte(0, max_polls=10)) is None, f"{kind}: a bad frame was saved"
        assert await io.run(driver.status(0)) & driver.STATUS_FLAG, f"{kind}: FLAG not raised"
        await io.run(driver.start(0))
        assert not await io.run(driver.status(0)) & driver.STATUS_FLAG
    await io.run(ex_ps2.play(ex_ps2.frame(0x29)))
    assert await io.run(ex_ps2.poll_byte(0)) == 0x29


@cocotb.test(timeout_time=30, timeout_unit="ms")   # sim time: a hung host loop fails instead of stalling
async def test_spi_target(dut):
    """examples/spi_target on core 0: the host plays the master through ui_in[2:0] while its own SPI port keeps
    working. Each MISO byte is the pushed reply and each MOSI byte is read back with READ_SCR, at several SCK rates
    (as test_compiled_spi_target)."""
    ref, io = await setup(dut)
    await io.run(ex_tgt.setup(PROGS, programs.SIM["spi_tgt_dsl"]))
    for half in (40, 12, 8, 6):
        for tx, rx in ((0xA5, 0x00), (0x3C, 0xFF), (0x81, 0x55), (0x7E, 0xC3)):
            got, saved = await io.run(ex_tgt.exchange([tx], [rx], half))
            assert got == [tx], f"half={half}: MISO {got[0]:#x}, expected {tx:#x}"
            assert saved == rx, f"half={half}: saved {saved:#x}, expected {rx:#x}"
