"""UART TX: the chip sends bytes as 8N1 frames on uio[0] (core 0, uart_tx_dsl).

Board: 50 MHz chip clock, P = 11 -> 440 cycles per bit = 113.6 kbaud (nominal 115200, -1.4%).
Wire a USB-UART adapter (3.3 V) RX to uio[0] and GND. Run from the board's MicroPython REPL:
    import examples.uart_tx as e; e.main(b"Hello from the PFST\\n")
(MicroPython cannot sample the line at 114 kbaud, so the board example does not decode it; the simulation test
does, against an independent decoder.)
"""
from ttpfst import driver, loader, programs, spi

PROGRAM = "uart_tx_dsl"
BIT_CYCLES = 40          # cycles per bit at P = 1 (model/dsl_programs.ml)


def send(tables, data, conf, settle_bits=12):
    """Load core 0, start it, stream `data` through the 3-byte TX FIFO, wait for the last frame to leave."""
    yield from loader.load(0, tables[PROGRAM], conf, PROGRAM)
    yield from driver.start(0)                  # RESTART flushes the FIFO: push after it
    queue = list(data)
    while queue:
        room = yield from driver.tx_room(0)
        if room:
            yield from driver.tx_push(0, queue[:room])
            queue = queue[room:]
    # FIFO empty means the last byte was popped, not finished: wait out its frame
    while True:
        st = yield from driver.status(0)
        if (st >> 6) == 0:
            break
    yield (spi.WAIT, settle_bits * BIT_CYCLES * conf["p"])


def main(data=b"Hello from the PFST\n", tables_path="compiled_tables.json"):
    from ttpfst import board, runner
    io = board.open_board(50000000)
    tables = programs.read_tables(tables_path)
    runner.run(send(tables, list(data), programs.UART_TX_BOARD), io)
