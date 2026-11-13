"""Export tables + ground-truth traces for the OCaml golden model to cross-check
against. Reuses encode.py's EncodedCore, which is already validated in lock-step
against pfst.Core (latch_check.py, ~33M cycles)."""
import random
from encode import encode, EncodedCore
from programs import uart_tx, uart_rx, spi_tx
from i2c import i2c_master
import nanotick as N

random.seed(2)
BYTES = [0x00, 0xFF, 0x55, 0xAA, 0x01, 0x80, 0x42, 0x13, 0x37, 0x96] + \
        [random.randrange(256) for _ in range(10)]


def write_blocks(f, **blocks):
    for k, v in blocks.items():
        if isinstance(v, (list, tuple)):
            f.write(f"{k}_N={len(v)}\n")
            for x in v:
                f.write(f"{x}\n")
        else:
            f.write(f"{k}={v}\n")


def export_tx(path, prog, rows, P):
    e = encode(prog, rows)
    c = EncodedCore(prog, P, rows)
    q, wave = list(BYTES), []
    for _ in range(len(BYTES) * 11 * 434 + 200):   # ~11 bit-periods/byte headroom, real cycles (P already inside wait counts)
        if q and not c.tx_full:
            c.tx_reg, c.tx_full = q.pop(0), 1
        wave.append(c.step({'rx': 0}) & 1)
    with open(path, "w") as f:
        write_blocks(f, S=e["S"], P=P, MSB=int(prog.msb_first),
                     RSEL=e["reset_sel"][0] | e["reset_sel"][1] << 2,
                     TABLE=e["table"], INTS=BYTES, GROUND=wave)


def export_spi(path, prog, rows, P):
    e = encode(prog, rows)
    c = EncodedCore(prog, P, rows)
    q, mosi, sck, cs = list(BYTES), [], [], []
    for _ in range(len(BYTES) * 60 * P + 100):
        if q and not c.tx_full:
            c.tx_reg, c.tx_full = q.pop(0), 1
        pins = c.step({'rx': 0})
        mosi.append(pins & 1); sck.append(pins >> 1 & 1); cs.append(pins >> 2 & 1)
    with open(path, "w") as f:
        write_blocks(f, S=e["S"], P=P, MSB=int(prog.msb_first),
                     RSEL=e["reset_sel"][0] | e["reset_sel"][1] << 2,
                     TABLE=e["table"], INTS=BYTES, GROUND=mosi + [10**6] + sck + [10**6] + cs)


def export_rx(path, prog, rows, P, B, err=0.0, seed=3):
    rnd = random.Random(seed)
    e = encode(prog, rows)
    c = EncodedCore(prog, P, rows)
    Bt = B * (1 + err)
    t, edges = rnd.uniform(5, 50), []
    for b in BYTES:
        bits = [0] + [(b >> k) & 1 for k in range(8)] + [1]
        for k, v in enumerate(bits):
            edges.append((t + k * Bt, v))
        t += 10 * Bt + rnd.uniform(0, 3) * Bt
    total = int(t + 3 * Bt)
    wave, j, lvl = [], 0, 1
    for n in range(total):
        while j < len(edges) and edges[j][0] <= n:
            lvl = edges[j][1]; j += 1
        wave.append(lvl)
    ground_saves = []
    for cyc, v in enumerate(wave):
        before = len(c.rx_bytes)
        c.step({"rx": v})
        if len(c.rx_bytes) != before:
            ground_saves.append(cyc)
    assert c.rx_bytes == BYTES, ("export_rx reference itself wrong", c.rx_bytes)
    with open(path, "w") as f:
        write_blocks(f, S=e["S"], P=P, MSB=int(prog.msb_first),
                     RSEL=e["reset_sel"][0] | e["reset_sel"][1] << 2,
                     TABLE=e["table"], INTS=wave, GROUND=BYTES + [-1] + ground_saves)


def export_table_only(path, prog, rows, P=1):
    """For I2C / Nano-Tick: OCaml drives its own environment, only the table is needed."""
    e = encode(prog, rows)
    with open(path, "w") as f:
        write_blocks(f, S=e["S"], P=P, MSB=int(prog.msb_first),
                     RSEL=e["reset_sel"][0] | e["reset_sel"][1] << 2,
                     TABLE=e["table"], INTS=[], GROUND=[], DONE=(
                         e["names"].index("DONE") if "DONE" in e["names"] else 255))


if __name__ == "__main__":
    B = 50e6 / 115200
    export_tx("uart_tx.vec", uart_tx(B, 2, True), 64, 2)
    export_rx("uart_rx.vec", uart_rx(B, 2, True), 64, 2, B)
    export_rx("uart_rx_early.vec", N.rx_early_save(B, 2), 64, 2, B)
    export_spi("spi_tx.vec", spi_tx(0, True), 64, 2)
    export_table_only("i2c_wr.vec", i2c_master(False, flag=True), 64)
    export_table_only("i2c_full.vec", i2c_master(True, flag=True), 256)
    export_table_only("nt_trader.vec", N.trader("fixed3"), 64, P=2)
    export_table_only("nt_rx.vec", uart_rx(B, 2, True), 64, P=2)
    print("exported: uart_tx.vec uart_rx.vec uart_rx_early.vec spi_tx.vec "
          "i2c_wr.vec i2c_full.vec nt_trader.vec nt_rx.vec")
