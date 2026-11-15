"""UART RX: the RP plays a UART source on a uio pin; core c (uart_rx_dsl) receives bytes, the host reads each with
READ_SCR. This is the only example that exercises READ_SCR and the RX_VALID / RX_OVR status bits.

Board: needs no wiring (the RP drives the line itself). Chip clock 1 MHz, P = 1 gives 40 cycles per bit = 25 kbaud,
slow enough for MicroPython to drive the line; the program tolerates +-1% baud error in simulation.
"""
import math

from ttpfst import driver, loader, programs, spi

PROGRAM = "uart_rx_dsl"


def frame_edges(byte, bit_cycles, err=0.0):
    """(cycle, level) edges of one 8N1 frame, LSB first, bit period bit_cycles * (1 + err) cycles."""
    period = bit_cycles * (1.0 + err)
    levels = [0] + [(byte >> i) & 1 for i in range(8)] + [1]
    return [(int(math.ceil(k * period)), lvl) for k, lvl in enumerate(levels)], int(math.ceil(11 * period))


def receive(tables, data, conf, core, pin, bit_cycles, err=0.0, max_polls=200):
    """Load `core`, start it, send each byte of `data` on uio[pin], read each back. Returns (bytes, STATUS).
    A byte that never raises RX_VALID is returned as None."""
    mask = 1 << pin
    yield (spi.UIO_IN, mask, mask)                       # idle-high line before the receiver starts
    yield from loader.load(core, tables[PROGRAM], conf, PROGRAM)
    yield from driver.start(core)
    got = []
    for b in data:
        edges, end = frame_edges(b, bit_cycles, err)
        yield (spi.MARK,)
        for t, lvl in edges:
            yield (spi.UNTIL, t)
            yield (spi.UIO_IN, lvl << pin, mask)
        yield (spi.UNTIL, end)                           # stop bit plus one bit of idle
        v = None
        for _ in range(max_polls):
            st = yield from driver.status(core)
            if st & driver.STATUS_RX_VALID:
                v = yield from driver.read_scr(core)     # clears RX_VALID
                break
        got.append(v)
    st = yield from driver.status(core)
    return got, st


def main(data=b"TickerTape", tables_path="compiled_tables.json"):
    from ttpfst import board, runner
    io = board.open_board(1000000)
    tables = programs.read_tables(tables_path)
    got, st = runner.run(receive(tables, list(data), programs.UART_RX_BOARD, 0, 0, 40), io)
    print("received", bytes(x for x in got if x is not None), "STATUS", hex(st))
    return got
