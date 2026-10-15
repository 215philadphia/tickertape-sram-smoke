# SPDX-License-Identifier: Apache-2.0
# Gate 0 smoke test: IHP 256x32 SRAM macro behind a tiny self-test FSM.

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

GL = os.environ.get("GATES") == "yes"

IDLE, TEST, CHASE, READ = 0, 1, 2, 3
SYNC = 3          # 2-flop synchronizer + 1 cycle margin
TEST_CYCLES = 2 * (1 + 256 + 256 + 1) + 10


def pattern(a, inv=False):
    w = ((a ^ 0xFF) << 24) | ((a ^ 0x5A) << 16) | (a << 8) | ((a + 1) & 0xFF)
    return w ^ 0xFFFFFFFF if inv else w


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())   # 50 MHz
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = IDLE
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def set_mode(dut, mode, bsel=0):
    dut.uio_in.value = (bsel << 2) | mode
    await ClockCycles(dut.clk, SYNC)


async def run_self_test(dut):
    await set_mode(dut, TEST)
    await ClockCycles(dut.clk, TEST_CYCLES)
    await FallingEdge(dut.clk)
    v = int(dut.uo_out.value)
    return v >> 7, (v >> 6) & 1, v & 0x3F


@cocotb.test()
async def self_test_passes(dut):
    await setup(dut)
    done, ok, errs = await run_self_test(dut)
    dut._log.info(f"done={done} pass={ok} errors={errs}")
    assert (done, ok, errs) == (1, 1, 0)


def _dout_signal(dut):
    """Return the SRAM read-data signal, preferring the RTL net name."""
    for name in ("dout", "sram0.A_DOUT"):
        sig = dut
        try:
            for part in name.split("."):
                sig = getattr(sig, part)
            return sig
        except AttributeError:
            continue
    raise AttributeError("Could not find SRAM read-data signal (dout or sram0.A_DOUT)")


def _readback_address(project):
    """Resolve the pending compare address in RTL or the bit-blasted GL netlist.

    Synthesis recodes state and removes pass_inv, so neither is a portable
    simulation handle. rd_valid and rd_addr identify the read being compared.
    """
    if not int(project.rd_valid.value):
        return None
    try:
        return int(project.rd_addr.value)
    except AttributeError:
        return sum(
            int(getattr(project, f"rd_addr[{bit}]").value) << bit
            for bit in range(8)
        )


async def corrupt_reads(dut, targets):
    """Simulation-only fault injection: corrupt readback of selected addresses.

    This forces the SRAM read-data path in the simulator only; it does not
    modify the RTL, SRAM macro, or manufactured design.
    """
    project = dut.user_project
    dout = _dout_signal(project)
    remaining = set(targets)

    while remaining:
        await FallingEdge(dut.clk)

        mode = int(dut.uio_in.value) & 0b11
        if mode != TEST:
            continue

        addr = _readback_address(project)
        if addr not in remaining:
            continue

        original = int(dout.value)
        corrupted = original ^ 0x00010000

        # This read is compared at the next rising edge.
        # The SRAM updates its output at that edge. Do not restore the old
        # word afterward: that would overwrite the following read's data.
        dout.value = corrupted
        await RisingEdge(dut.clk)
        remaining.remove(addr)


@cocotb.test()
async def self_test_detects_corruption(dut):
    """Corrupt three readbacks; the checker must count them."""
    await setup(dut)
    corrupt_task = cocotb.start_soon(corrupt_reads(dut, (7, 100, 255)))
    done, ok, errs = await run_self_test(dut)
    corrupt_task.cancel()
    dut._log.info(f"done={done} pass={ok} errors={errs}")
    assert (done, ok, errs) == (1, 0, 3)


@cocotb.test()
async def chase_walks_all_addresses(dut):
    """A_DOUT[7:0] -> A_ADDR each cycle: the PFST next-state loop."""
    await setup(dut)
    done, ok, _ = await run_self_test(dut)
    assert done and ok
    await set_mode(dut, CHASE)
    seen = []
    for _ in range(600):
        await FallingEdge(dut.clk)
        seen.append(int(dut.uo_out.value))
    # Once in the loop, each cycle's output must be previous + 1 (mod 256).
    steps = [(b - a) & 0xFF for a, b in zip(seen[4:], seen[5:])]
    assert all(s == 1 for s in steps), steps[:20]
    assert set(seen[4:]) == set(range(256))


@cocotb.test()
async def manual_read_all_bytes(dut):
    await setup(dut)
    done, ok, _ = await run_self_test(dut)
    assert done and ok
    for a in (0, 1, 0x5A, 0xA5, 0xFF):
        for b in range(4):
            dut.ui_in.value = a
            await set_mode(dut, READ, b)
            await ClockCycles(dut.clk, 2)
            await FallingEdge(dut.clk)
            got = int(dut.uo_out.value)
            exp = (pattern(a) >> (8 * b)) & 0xFF
            assert got == exp, f"addr {a:#x} byte {b}: got {got:#x} exp {exp:#x}"
