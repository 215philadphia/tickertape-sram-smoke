"""Load a compiled program and its configuration onto one core, verified by read-back.

`prog` is one entry of compiled_tables.json (keys: table, names, reset_sel, msb_first, ...).
`conf` is a dict of the per-program configuration; every key is optional except p, out_init and pinmode:

  p           clock divider: a row lasts p * (1 + wait) chip cycles
  cfg         extra CFG bits (bit 0 is MSB-first and comes from the program; bit 1 flag mode)
  out_init    pin levels while stopped and after RESTART (set before anything drives a pin)
  pinmode     2 bits per pin (docs/architecture.md)
  outmap      default 0xE4 (identity)
  inmap01     default 0x10     inmap23 default 0x32 (UIO = 8 | n takes input n from uio_in instead of ui_in)
  done_state  state number, or a state NAME from the program, or None (0xFF, no DONE)
  thresh      comparator threshold (shared register 0x20)
  uomap       list of up to 6 values for 0x22..0x27 (shared registers)

The registers THRESH/UOMAP are shared by both cores. Order follows test_programs.load(): table first (the core
must be stopped), then OUT_INIT, then the block P..DONE_STATE in one auto-incrementing write.
"""
from . import driver

UIO = 0x8
REG_P, REG_CFG, REG_RSEL, REG_OUTMAP, REG_PINMODE, REG_INMAP01, REG_INMAP23, REG_DONE, REG_STATUS, REG_STATE, REG_OUT_INIT = range(11)
REG_THRESH = 0x20
REG_IRQ_EN = 0x21
REG_UOMAP = 0x22


class LoadError(Exception):
    pass


def resolve_done(prog, done):
    if done is None:
        return 0xFF
    if isinstance(done, str):
        names = prog["names"]
        if done not in names:
            raise LoadError("no state named %s in %s" % (done, names))
        return names.index(done)
    return done


def register_values(prog, conf):
    """The 8 bytes written to P..DONE_STATE for this program (pure; unit-tested)."""
    ra, rb = prog["reset_sel"]
    cfg = int(prog["msb_first"]) | conf.get("cfg", 0)
    return [conf["p"], cfg, ra | rb << 2, conf.get("outmap", 0xE4), conf["pinmode"],
            conf.get("inmap01", 0x10), conf.get("inmap23", 0x32), resolve_done(prog, conf.get("done_state"))]


def load(core, prog, conf, name="program"):
    """Stop the core, write the table, verify it, write the registers, verify them. Does not start the core."""
    table = prog["table"]
    base = 0x10 * core
    yield from driver.stop(core)                                # tables load only while the core is stopped
    yield from driver.write_table(core, 0, table)
    got = yield from driver.read_table(core, 0, len(table))
    if got != table:
        bad = [i for i in range(len(table)) if got[i] != table[i]]
        raise LoadError("%s: table read-back differs in %d of %d rows, first row %d (wrote %#x, read %#x)"
                        % (name, len(bad), len(table), bad[0], table[bad[0]], got[bad[0]]))
    yield from driver.wreg(base + REG_OUT_INIT, [conf["out_init"]])   # before any pin is driven
    regs = register_values(prog, conf)
    yield from driver.wreg(base + REG_P, regs)
    got = yield from driver.rreg(base + REG_P, len(regs))
    if got != regs:
        raise LoadError("%s: register read-back %s, wrote %s" % (name, got, regs))
    got = yield from driver.rreg(base + REG_OUT_INIT, 1)
    if got[0] != conf["out_init"]:
        raise LoadError("%s: OUT_INIT read-back %#x, wrote %#x" % (name, got[0], conf["out_init"]))
    if conf.get("thresh") is not None:
        yield from driver.wreg(REG_THRESH, [conf["thresh"]])
        got = yield from driver.rreg(REG_THRESH, 1)
        if got[0] != conf["thresh"]:
            raise LoadError("%s: THRESH read-back %#x" % (name, got[0]))
    uomap = conf.get("uomap")
    if uomap:
        yield from driver.wreg(REG_UOMAP, uomap)
        got = yield from driver.rreg(REG_UOMAP, len(uomap))
        if got != list(uomap):
            raise LoadError("%s: UOMAP read-back %s, wrote %s" % (name, got, uomap))
    return len(table)
