"""A pure-Python model of the chip's HOST SPI PORT ONLY (docs/architecture.md "Host interface"), for fast tests that
need no simulator. It encodes our reading of the protocol; it is NOT evidence about the RTL (test_host_sim.py,
which runs the real RTL, is the authority). Used to test the effect layer, the board adapter and the loader's error
paths quickly, and to run without Icarus.

Implements WRITE_REG/READ_REG (regs 0..0x27), WRITE_TABLE/READ_TABLE, TX_PUSH, CTRL, READ_SCR; STATUS = RUN|DONE bits
and FIFO level from pushes. `corrupt_table_row` makes one table word read back wrong (a stuck SRAM bit).
"""


class FakeChip:
    def __init__(self, corrupt_table_row=None):
        self.tables = [[0] * 256, [0] * 256]
        self.regs = [0] * 0x28
        self.fifo = [[], []]
        self.run = [0, 0]
        self.corrupt = corrupt_table_row
        self.cs = 1
        self.sck = 0
        self.mosi = 0
        self.miso = 0
        self.frames = []

    # ---- pin level ----
    def pins(self, sck, mosi, cs_n):
        if self.cs == 1 and cs_n == 0:
            self.byte = 0
            self.nbits = 0
            self.rxb = []
            self.out = 0
            self.nextout = 0
        if cs_n == 1 and self.cs == 0:
            self.frames.append(list(self.rxb))
        if cs_n == 0 and sck == 1 and self.sck == 0:                  # rising edge: sample MOSI
            self.byte = (self.byte << 1 | mosi) & 0xFF
            self.nbits += 1
            if self.nbits == 8:
                self.rxb.append(self.byte)
                self.on_byte(len(self.rxb) - 1)
                self.nbits = 0
                self.out = self.nextout
                self.nextout = 0
        if cs_n == 0 and sck == 0 and self.sck == 1:                  # falling edge: drive MISO
            self.miso = (self.out >> (7 - self.nbits)) & 1
        self.cs, self.sck, self.mosi = cs_n, sck, mosi

    def on_byte(self, j):
        cmd = self.rxb[0]
        hi, c = cmd & 0xF0, cmd & 1
        if j == 0:
            return
        if hi == 0x00 and cmd == 0x01 and j >= 2:
            self.regs[self.rxb[1] + j - 2] = self.rxb[j]
        elif hi == 0x00 and cmd == 0x02:
            self.nextout = self.regs_read(self.rxb[1] + j - 1)       # byte j+1 carries the response
        elif hi == 0x10 and j >= 2:
            n = j - 2
            row = self.rxb[1] + n // 4
            w = self.tables[c][row]
            w = (w & ~(0xFF << (8 * (3 - n % 4)))) | self.rxb[j] << (8 * (3 - n % 4))
            self.tables[c][row] = w
        elif hi == 0x20:
            n = j - 1
            row = self.rxb[1] + n // 4
            w = self.tables[c][row]
            if self.corrupt == row:
                w ^= 1
            self.nextout = (w >> (8 * (3 - n % 4))) & 0xFF
        elif hi == 0x30 and j >= 1:
            self.fifo[c].append(self.rxb[j])
        elif hi == 0x40 and j == 1:
            if self.rxb[1] & 2:
                self.fifo[c] = []
            self.run[c] = self.rxb[1] & 1

    def regs_read(self, a):
        if a in (8, 0x18):
            c = (a >> 4) & 1
            return min(len(self.fifo[c]), 3) << 6 | self.run[c]
        return self.regs[a]
