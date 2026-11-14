"""The chip's host commands (docs/architecture.md, "Host interface") as generators.

Every function here is a generator: run it with runner.run(gen, io) or compose it with `yield from`.
c is the core number, 0 or 1.

  0x01 WRITE_REG   addr, data...         write registers, address auto-increments
  0x02 READ_REG    addr, dummy...        data comes back from the 3rd byte on
  0x10+c WRITE_TABLE row, 4 bytes/word   MSB first; ignored while the core runs
  0x20+c READ_TABLE  row, dummy...       reads 0 while the core runs
  0x30+c TX_PUSH   byte...               push into the core's 3-byte TX FIFO
  0x40+c CTRL      value                 bit 0 RUN, bit 1 RESTART
  0x50+c READ_SCR  dummy                 returns SCR and clears RX_VALID

The chip loses its tables and registers whenever it is reset or deselected: load again every time.
"""
from . import spi

WORD_BYTEORDER = "big"          # table words go MSB first; tests plant a wrong order here as a bug

CMD_WRITE_REG = 0x01
CMD_READ_REG = 0x02
CMD_WRITE_TABLE = 0x10
CMD_READ_TABLE = 0x20
CMD_TX_PUSH = 0x30
CMD_CTRL = 0x40
CMD_READ_SCR = 0x50

CTRL_RUN = 0x01
CTRL_RESTART = 0x02

REG_STATUS = 8                  # per-core register offset (core 1 adds 0x10)
STATUS_RUN = 0x01
STATUS_DONE = 0x02
STATUS_RX_VALID = 0x04
STATUS_RX_OVR = 0x08
STATUS_FLAG = 0x10
STATUS_TX_OVR = 0x20            # bits 7:6 hold the TX FIFO level (0 to 3)
FIFO_DEPTH = 3
TABLE_ROWS = 256


def word_bytes(word):
    """One 32-bit table word as 4 bytes in transfer order."""
    return list(int(word).to_bytes(4, WORD_BYTEORDER))


def bytes_word(bs):
    return int.from_bytes(bytes(bs), WORD_BYTEORDER)


def _check_core(core):
    if core not in (0, 1):
        raise ValueError("core must be 0 or 1")


def wreg(addr, values):
    """Write registers starting at addr (they auto-increment)."""
    yield from spi.xfer([CMD_WRITE_REG, addr] + list(values))


def rreg(addr, n=1):
    """Read n registers starting at addr."""
    rx = yield from spi.xfer([CMD_READ_REG, addr] + [0] * n)
    return rx[2:]


def write_table(core, row, words):
    """Write table words starting at row. The core must be stopped."""
    _check_core(core)
    if row < 0 or row + len(words) > TABLE_ROWS:
        raise ValueError("table rows out of range 0..255")
    data = [CMD_WRITE_TABLE | core, row]
    for w in words:
        data += word_bytes(w)
    yield from spi.xfer(data)


def read_table(core, row, n):
    """Read n table words starting at row (returns 0s while the core runs)."""
    _check_core(core)
    rx = yield from spi.xfer([CMD_READ_TABLE | core, row] + [0] * (4 * n))
    rx = rx[2:]
    return [bytes_word(rx[4 * j:4 * j + 4]) for j in range(n)]


def tx_push(core, data):
    """Push bytes into the TX FIFO (depth 3: a 4th byte before one is popped sets TX_OVR and is dropped)."""
    _check_core(core)
    yield from spi.xfer([CMD_TX_PUSH | core] + list(data))


def ctrl(core, value):
    _check_core(core)
    yield from spi.xfer([CMD_CTRL | core, value])


def start(core):
    """RESTART and RUN: the core starts from state 0. RESTART also flushes the TX FIFO and clears DONE/FLAG."""
    yield from ctrl(core, CTRL_RUN | CTRL_RESTART)


def stop(core):
    """RESTART with RUN low: the core stops and returns to its start state."""
    yield from ctrl(core, CTRL_RESTART)


def read_scr(core):
    """Read the core's scratch register and clear RX_VALID."""
    _check_core(core)
    rx = yield from spi.xfer([CMD_READ_SCR | core, 0])
    return rx[1]


def status(core):
    """STATUS register: bit 0 RUN, 1 DONE, 2 RX_VALID, 3 RX_OVR, 4 FLAG, 5 TX_OVR, 7:6 TX FIFO level."""
    _check_core(core)
    r = yield from rreg(0x10 * core + REG_STATUS, 1)
    return r[0]


def tx_room(core):
    """How many more bytes fit in the TX FIFO right now."""
    st = yield from status(core)
    return FIFO_DEPTH - (st >> 6)
