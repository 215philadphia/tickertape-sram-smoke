"""I2C write: core 0 (i2c_wr_dsl) writes bytes to a 7-bit target address, open drain, ends in a DONE state.

Board: 50 MHz, P = 1 (400 kHz per docs/toolchain.md; not measured). uio[0] = SDA, uio[1] = SCL, both open drain
(the chip only pulls low): they NEED EXTERNAL PULL-UPS to 3.3 V, 2.2 kOhm to 4.7 kOhm, for example on a Pmod
with the pull-ups fitted or two resistors on the uio header. The target (a 24C-type EEPROM, a sensor) must be
3.3 V. Run:  import examples.i2c_write as e; e.main(0x50, [0x00, 0xFF, 0x55])
"""
from ttpfst import driver, loader, programs

PROGRAM = "i2c_wr_dsl"


def write(tables, addr, payload, conf, max_polls=400):
    """Write `payload` to target `addr`. Returns (done, status): done False means DONE never came up."""
    yield from loader.load(0, tables[PROGRAM], conf, PROGRAM)
    queue = [addr << 1] + list(payload)
    yield from driver.start(0)                  # RESTART clears DONE and flushes the FIFO
    yield from driver.tx_push(0, queue[:3])
    queue = queue[3:]
    st = 0
    for _ in range(max_polls):
        st = yield from driver.status(0)
        if st & driver.STATUS_DONE:
            return True, st
        if queue and (st >> 6) < driver.FIFO_DEPTH:
            yield from driver.tx_push(0, [queue.pop(0)])
    return False, st


def main(addr=0x50, payload=(0x00, 0xFF, 0x55), tables_path="compiled_tables.json"):
    from ttpfst import board, runner
    io = board.open_board(50000000)
    tables = programs.read_tables(tables_path)
    done, st = runner.run(write(tables, addr, list(payload), programs.I2C_BOARD), io)
    print("DONE" if done else "TIMEOUT", "STATUS", hex(st))
    return done
