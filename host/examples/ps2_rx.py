"""PS/2 receive: a protocol the chip was not designed for. The RP plays a keyboard (CLK uio[1], DATA uio[0]); core 0
(ps2_rx_dsl) checks odd parity in its state number and saves good bytes; a parity or stop-bit error saves nothing
and raises FLAG (CFG bit 1, flag mode).

Board: the RP bit-bangs the keyboard, so the chip runs at 100 kHz and the PS/2 clock comes out near 1.7 kHz (a real
keyboard is 10 to 16.7 kHz: use a 1 MHz chip clock for one; it needs the PS/2 5 V to 3.3 V level shifting and the
pull-ups a PS/2 port normally provides, none of which is tested here).
"""
from ttpfst import driver, loader, programs, spi

PROGRAM = "ps2_rx_dsl"
HALF_P = 30                  # cycles per half CLK period at P = 1 (as test/test_programs.py)


def frame(b, bad_parity=False, bad_stop=False, half_p=HALF_P):
    """One device-to-host frame as a list of (data, clk) per cycle: DATA changes mid-way through CLK high."""
    data = [(b >> k) & 1 for k in range(8)]
    par = (1 - sum(data) % 2) ^ int(bad_parity)         # odd parity
    seq, prev = [], 1
    for d in [0] + data + [par, 0 if bad_stop else 1]:
        seq += [(prev, 1)] * (half_p // 2) + [(d, 1)] * (half_p - half_p // 2) + [(d, 0)] * half_p
        prev = d
    return seq + [(1, 1)] * 200


def play(frame_cycles):
    """Drive the (data, clk) sequence on uio[0], uio[1], one entry per chip cycle (absolute timing)."""
    yield (spi.MARK,)
    last = None
    for t in range(len(frame_cycles)):
        d, c = frame_cycles[t]
        if (d, c) != last:                               # only touch the pins when a level changes
            yield (spi.UNTIL, t)
            yield (spi.UIO_IN, d | c << 1, 0x03)
            last = (d, c)
    yield (spi.UNTIL, len(frame_cycles))


def poll_byte(core, max_polls=100):
    """Wait for RX_VALID and read the byte; None if none arrives."""
    for _ in range(max_polls):
        st = yield from driver.status(core)
        if st & driver.STATUS_RX_VALID:
            v = yield from driver.read_scr(core)
            return v
    return None


def start_keyboard(tables, conf):
    yield (spi.UIO_IN, 0b11, 0x03)                       # both lines released (pulled up)
    yield from loader.load(0, tables[PROGRAM], conf, PROGRAM)
    yield from driver.start(0)


def main(data=b"\x1c\xf0\x1c", tables_path="compiled_tables.json"):
    from ttpfst import board, runner
    io = board.open_board(100000)
    tables = programs.read_tables(tables_path)

    def go():
        yield from start_keyboard(tables, programs.PS2_BOARD)
        got = []
        for b in data:
            yield from play(frame(b))
            got.append((yield from poll_byte(0)))
        return got
    got = runner.run(go(), io)
    print("received", got)
    return got
