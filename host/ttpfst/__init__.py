"""Host-side software for the TickerTape-Out PFST chip.

Layers (each only imports the ones above it in this list):
  spi.py      SPI mode 0 master as a generator of pin "effects"; the only place that knows bit timing
  driver.py   the chip's host commands (registers, tables, TX FIFO, CTRL, SCR) as generators
  loader.py   load a compiled program plus its configuration onto a core, verified by read-back
  programs.py default configurations of the programs in compiled_tables.json
  runner.py   runs a generator against an "io" object (board or simulation)
  board.py    the Tiny Tapeout demo board (MicroPython SDK) io object; only imports ttboard when used

Everything is plain Python that MicroPython also runs: generators, no typing, no dataclasses.
"""
__version__ = "0.1.0"
