"""Nano-Tick, both cores, no host in the loop once started.

Core 0 (uart_rx_dsl) receives one-byte prices on uio[0]; the comparator flags price < THRESH; core 1
(nt_trader_dsl) answers each downward crossing with a 3-byte SPI order on uio[7:4] (SPI CS uio[6], SCK uio[5],
MOSI uio[4]). The host only (a) re-arms core 1's TX FIFO with the order text after each order and (b) here also
plays the exchange: the RP drives the price line on uio[0] itself (no wiring needed) and polls uio[6:4] to
decode the orders.

Board: 10 MHz chip clock, RX P = 26 (9615 baud), trader P = 256 so MicroPython polling keeps up. UNVERIFIED on
hardware: whether polling is fast enough at this P is a measurement still to be made.
"""
from ttpfst import driver, loader, programs, spi

ORDER = [0x42, 0x55, 0x59]          # "BUY"
CS, SCK, MOSI = 6, 5, 4             # uio_out bits of core 1's SPI
RX_PROGRAM, TRADER_PROGRAM = "uart_rx_dsl", "nt_trader_dsl"


class SpiDecoder:
    """Mode 0 SPI decoder for core 1's pins, fed one uio_out sample at a time."""

    def __init__(self):
        self.cs_p, self.sck_p, self.bits, self.frame = 1, 0, [], None

    def feed(self, v):
        """Returns a completed frame (list of bytes) when CS rises, else None."""
        cs, sck, mosi = (v >> CS) & 1, (v >> SCK) & 1, (v >> MOSI) & 1
        done = None
        if self.cs_p == 1 and cs == 0:
            self.frame, self.bits = [], []
        if cs == 0 and sck == 1 and self.sck_p == 0:
            self.bits.append(mosi)
            if len(self.bits) == 8:
                self.frame.append(int("".join(str(b) for b in self.bits), 2))
                self.bits = []
        if cs == 1 and self.cs_p == 0 and self.frame is not None:
            done, self.frame = self.frame, None
        self.cs_p, self.sck_p = cs, sck
        return done


def price_edges(price, bit_cycles):
    """UART frame for one price byte as (cycle, level) edges: start bit, 8 data bits LSB first, stop bit."""
    return [(k * bit_cycles, lvl) for k, lvl in enumerate([0] + [(price >> i) & 1 for i in range(8)] + [1])]


def play(price, bit_cycles, window_cycles, dec, poll_cycles=1):
    """Drive one price on uio[0] (the RP is the UART source) for `window_cycles`, polling core 1's SPI pins the
    whole time, because an order starts within a few bit times of the stop bit. Returns completed order frames.
    One loop, one time base: the line edges and the polling cannot drift apart."""
    edges = price_edges(price, bit_cycles)
    yield (spi.MARK,)
    frames, i = [], 0
    while True:
        el = yield (spi.ELAPSED,)
        if el >= window_cycles:
            return frames
        while i < len(edges) and edges[i][0] <= el:
            yield (spi.UIO_IN, edges[i][1], 0x01)
            i += 1
        v = yield (spi.UIO_OUT,)
        f = dec.feed(v)
        if f is not None:
            frames.append(f)
        yield (spi.WAIT, poll_cycles)


def trade(tables, prices, thresh, rx_conf, trader_conf, bit_cycles, window_cycles, poll_cycles=1):
    """Load both cores, play `prices`, return the list of order frames seen. Re-arms the order after each."""
    rx = dict(rx_conf)
    yield (spi.UIO_IN, 1, 0x01)                         # idle-high price line before core 0 starts
    yield from loader.load(0, tables[RX_PROGRAM], rx, RX_PROGRAM)
    yield from loader.load(1, tables[TRADER_PROGRAM], trader_conf, TRADER_PROGRAM)
    yield from driver.wreg(loader.REG_THRESH, [thresh])
    yield from driver.start(0)
    yield from driver.start(1)                          # RESTART flushes the FIFO: push after it
    yield from driver.tx_push(1, ORDER)
    orders = []
    dec = SpiDecoder()
    for price in prices:
        got = yield from play(price, bit_cycles, window_cycles, dec, poll_cycles)
        for f in got:
            orders.append(f)
            yield from driver.tx_push(1, ORDER)         # re-arm for the next crossing
    return orders


def main(prices=(120, 90, 80, 130, 99, 150, 100, 60, 101), thresh=100, tables_path="compiled_tables.json"):
    from ttpfst import board, runner
    io = board.open_board(10000000)
    tables = programs.read_tables(tables_path)
    orders = runner.run(trade(tables, list(prices), thresh, programs.NANO_RX_BOARD, programs.NANO_TRADER_BOARD,
                              40 * 26, window_cycles=40 * 26 * 14 + 200000), io)
    print("orders:", orders)
    return orders
