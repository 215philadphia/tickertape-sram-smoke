"""SPI mode 0 master (CPOL 0, CPHA 0, MSB first) as a generator of pin "effects".

Nothing here touches a pin. A generator yields an effect tuple and is sent the result, so the SAME code runs on
the demo board (board.BoardIO executes the effects through the Tiny Tapeout SDK) and in simulation (the cocotb
harness in host/tests executes them against the chip RTL).

Effects (first element is the kind):
  (SPI, sck, mosi, cs_n, n, strict)  drive the three host pins, hold them for n SPI half periods, then return the
                                     level on MISO (uo_out[7]). strict=False: an unresolvable level may read as 0.
  (WAIT, cycles)                     let the chip run for this many of ITS clock cycles
  (UIO_OUT,)                         return uio_out (what the chip drives on its bidirectional pins)
  (UIO_IN, value, oe_mask)           drive uio_in with value on the pins whose oe_mask bit is 1 (the rest stay inputs)
  (UO_OUT,)                          return uo_out
  (MARK,)                            remember "now" as a time origin
  (UNTIL, cycles)                    wait until this many chip cycles after the last MARK (absolute, no drift)
  (ELAPSED,)                         return the chip cycles since the last MARK (for polling with a timeout)

The chip's host port (spec section 6): mode 0, MSB first, ui_in[4] SCK, ui_in[5] MOSI, ui_in[6] CS_n, MISO on
uo_out[7]. It samples MOSI at SCK rising edges and drives MISO at SCK falling edges, so MISO is read just before
the next rising edge. A response byte arrives during the byte AFTER the one that asked for it, so the first two
bytes of a frame (command, address) carry no response.
"""

SPI = 0
WAIT = 1
UIO_OUT = 2
UIO_IN = 3
UO_OUT = 4
MARK = 5
UNTIL = 6
ELAPSED = 7

CPOL = 0   # idle level of SCK. The chip is SPI mode 0; changing this breaks every transfer (tests plant it as a bug).
CS_IDLE_HALVES = 2   # CS_n high for at least this many half periods between frames (chip needs >= 8 chip cycles)


def xfer(data):
    """Send `data` (a list of byte values) in one CS_n-framed transfer.

    Returns the list of bytes clocked back on MISO, one per byte sent (see the module note about which carry data).
    """
    yield (SPI, CPOL, 0, 0, 1, False)                 # CS_n low, SCK idle, one half period of setup
    rx = []
    for j in range(len(data)):
        byte = data[j]
        v = 0
        strict = j >= 2                               # bytes 0 and 1 never carry a response
        for i in range(8):
            b = (byte >> (7 - i)) & 1
            m = yield (SPI, CPOL, b, 0, 1, strict)    # data stable while SCK idles; MISO sampled before the rising edge
            v = (v << 1) | m
            yield (SPI, 1 - CPOL, b, 0, 1, False)     # SCK active: the chip samples MOSI here
        rx.append(v)
    yield (SPI, CPOL, 0, 0, 1, False)
    yield (SPI, CPOL, 0, 1, CS_IDLE_HALVES, False)    # CS_n high ends the frame
    return rx
