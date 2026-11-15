"""Run a generator (see spi.py for the effect protocol) against an io object.

io.do(effect) executes one effect and returns its result. The board's io is board.BoardIO; the simulation's is in
host/tests/cocotb_io.py (which has its own async copy of this loop, since cocotb waits on simulator events).
"""


def run(gen, io):
    """Drive gen to completion, return its return value."""
    try:
        eff = next(gen)
        while True:
            eff = gen.send(io.do(eff))
    except StopIteration as e:
        return e.value
