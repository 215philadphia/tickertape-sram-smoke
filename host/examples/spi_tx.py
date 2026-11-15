"""SPI TX: core 0 (spi_tx_dsl) shifts each pushed byte out, mode 0, MSB first.
CS_n uio[2], SCK uio[1], MOSI uio[0].

Board: chip clock 1 MHz, P = 4, slow on purpose. The SCK rate is not measured here: derive it from the program's
row waits (model/dsl_programs.ml) or measure it with a logic analyzer on uio[2:0] (UNVERIFIED).
"""
from ttpfst import driver, loader, programs, spi

PROGRAM = "spi_tx_dsl"


def send(tables, data, conf, settle_cycles=200):
    """Load core 0, start it, push the bytes one per frame. The core drives one frame per pushed byte."""
    yield from loader.load(0, tables[PROGRAM], conf, PROGRAM)
    yield from driver.start(0)                           # RESTART flushes the FIFO: push after it
    for b in data:
        yield from driver.tx_push(0, [b])
    yield (spi.WAIT, settle_cycles)


def main(data=b"\x00\xff\x55\xaa", tables_path="compiled_tables.json"):
    from ttpfst import board, runner
    io = board.open_board(1000000)
    tables = programs.read_tables(tables_path)
    runner.run(send(tables, list(data), programs.SPI_TX_BOARD, settle_cycles=20000), io)
