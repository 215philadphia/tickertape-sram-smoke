"""SPI target (slave), the other side of spi_tx: core 0 (spi_tgt_dsl) answers an SPI master, mode 0, MSB first.
Pins: ui_in[0] MOSI, ui_in[1] SCK, ui_in[2] CS_n (active low) in; MISO = uio[0] out, released when CS_n is high.

Board: here the RP plays the master itself, driving ui_in[2:0] (no wiring), at a 1 MHz chip clock with a half
period of 100 chip cycles = 5 kHz SCK, slow enough for MicroPython. To use a real master instead (a microcontroller
or a logic-analyzer pattern generator at 3.3 V), wire its MOSI, SCK, CS_n to ui_in[0], ui_in[1], ui_in[2] and MISO
to uio[0], and call `setup` then read `driver.read_scr(0)` after each frame. The chip is tested in simulation down to
a 12-cycle SCK period (4.2 MHz at 50 MHz); the board examples do not get near that.

Protocol on the host side: push the reply bytes BEFORE CS_n falls (an empty FIFO repeats the last byte), read each
received byte with READ_SCR (only the last byte of a multi-byte frame is still in SCR when the frame ends).
"""
from ttpfst import driver, loader, programs, spi

PROGRAM = "spi_tgt_dsl"
MOSI, SCK, CSN = 0x01, 0x02, 0x04          # ui_in[2:0]


def setup(tables, conf):
    """Load core 0, start it, park the master pins idle (CS_n high)."""
    yield (spi.UI_LOW, CSN)
    yield from loader.load(0, tables[PROGRAM], conf, PROGRAM)
    yield from driver.start(0)


def master_frame(data, half):
    """The RP as a mode 0 master: CS_n low, 8 bits per byte MSB first, MISO sampled just before each rising SCK
    edge (as a real master does), CS_n high. Returns the bytes read from MISO."""
    yield (spi.UI_LOW, 0)                                # CS_n low
    yield (spi.WAIT, 30)
    got = []
    for b in data:
        v = 0
        for i in range(7, -1, -1):
            m = MOSI if (b >> i) & 1 else 0
            yield (spi.UI_LOW, m)                        # MOSI changes while SCK is low
            yield (spi.WAIT, half)
            miso = (yield (spi.UIO_OUT,)) & 1            # sample before the rising edge
            v = v << 1 | miso
            yield (spi.UI_LOW, m | SCK)
            yield (spi.WAIT, half)
            yield (spi.UI_LOW, m)
        got.append(v)
    yield (spi.WAIT, half)
    yield (spi.UI_LOW, CSN)
    yield (spi.WAIT, 40)
    return got


def exchange(tx, mosi_bytes, half):
    """One frame: queue `tx` as the reply, play `mosi_bytes` as the master. Returns (MISO bytes, last byte saved)."""
    if tx:
        yield from driver.tx_push(0, tx)
    got = yield from master_frame(mosi_bytes, half)
    saved = yield from driver.read_scr(0)
    return got, saved


def main(tables_path="compiled_tables.json"):
    from ttpfst import board, runner
    io = board.open_board(1000000)
    tables = programs.read_tables(tables_path)

    def go():
        yield from setup(tables, programs.SPI_TGT_BOARD)
        out = []
        for tx, rx in ((0xA5, 0x00), (0x3C, 0xFF), (0x81, 0x55)):
            out.append((yield from exchange([tx], [rx], 100)))
        return out
    res = runner.run(go(), io)
    for (miso, saved), want in zip(res, (0xA5, 0x3C, 0x81)):
        print("MISO", [hex(x) for x in miso], "expected", hex(want), "saved", hex(saved))
    return res
