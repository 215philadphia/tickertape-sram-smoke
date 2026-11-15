"""Host software (host/ttpfst, host/examples) run against the chip RTL, with the same checks as test/test_programs.py.

Every byte the host library sends goes through the SAME effect generators that run on the demo board; only the
executor differs (cocotb_io.CocoIO). Where a check would be blind to a symmetric bug (write and read back with the
same wrong byte order passes), it reads through the independent reference Host from test/test_pfst.py.
"""
import os
import sys

import cocotb
from cocotb.triggers import FallingEdge

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "examples"))

from cocotb_io import CocoIO                                             # noqa: E402
from test_pfst import Host, bit, start                                   # noqa: E402
from test_programs import (BP, PROGS, I2cTarget, SpiMonitor, uart_decode,   # noqa: E402
                           load as ref_load)
from ttpfst import driver, loader, programs                              # noqa: E402
import i2c_write as ex_i2c                                               # noqa: E402
import nano_tick as ex_nano                                              # noqa: E402
import uart_tx as ex_uart                                                # noqa: E402

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
