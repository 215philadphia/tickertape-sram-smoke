# Project guidance: TickerTape-Out (Jane Street protocol emulator ASIC competition)

This repo is an entry in Jane Street's protocol emulator ASIC competition. Every change must keep
the entry within the competition rules below. Source:
<https://blog.janestreet.com/protocol-emulator-asic-competition/> (read 2026-11-13; includes the
November 9 update). If the page changes, the page wins: re-read it and update this file.

## Rules: check every change against these

| Rule | What it means here |
|---|---|
| Process: IHP 130 nm CMOS5L via Tiny Tapeout, starting from the Tiny Tapeout IHP Verilog template | Do not replace the flow. GDS must come from the Tiny Tapeout GitHub Action (`.github/workflows/gds.yaml`). A locally run flow is only allowed via Tiny Tapeout's custom GDS action, and only if the 6-hour GitHub Actions limit is hit. |
| Area: at most **8x4 tiles** (final for the March 2027 shuttle) | `info.yaml` must keep `tiles: "8x4"`. Never grow the die or macro placement beyond the 8x4 template. |
| Open source | License stays Apache-2.0 (`LICENSE`). Only add third-party code under a compatible open license, with provenance in `README.md`. The repo must be **public at submission** (it may be private before then). |
| Deadline: **18 January 2027** | Freeze RTL well before: each GDS + precheck + gl_test cycle takes about 1.5 h. |
| Pins: 24 digital (8 in, 8 out, 8 bidirectional) plus `clk` and `rst_n`; no analog pads | Do not change the top-level port list of `tt_um_tickertape_pfst`. Keep the `info.yaml` pinout accurate. |
| Reset | Flops do not power up at 0: everything that matters must be reset by `rst_n`. The design loses state when deselected, so the host must be able to reload programs. |
| Reprogrammable after fabrication | The core value of the entry. Never trade programmability for a fixed-function protocol block. |
| Sign-off: a clean Tiny Tapeout flow run and precheck | `gds` and `precheck` must pass on `main`. Gate-level simulation (`gl_test`) is strongly recommended: keep it passing. Extra sign-off (e.g. clearing max-cap/slew/fanout) is good practice, not required. |
| Clock | No required frequency; Tiny Tapeout confirmed 60 MHz is OK. The design runs at 50 MHz (`CLOCK_PERIOD` 20). |
| External parts | Allowed (on a Pmod, 3.3 V I/O). Anything the design needs must be documented in `docs/info.md`. |
| AI tools | Allowed, but **their use must be described in the write-up**. Changes made by Claude should be recorded so the write-up can describe them (commit trailers already identify them). |

## What the submission must contain

A link to the public repository with:

1. RTL (`src/`)
2. Tests (`test/`; open-source tools like cocotb help the judges run them)
3. A passing GDS and precheck from the Tiny Tapeout flow
4. Documentation of the architecture and instruction set (table word format)
5. The assembler/toolchain with example programs (`model/compiler.ml`, `model/dsl_programs.ml`)
6. A write-up of the verification approach
7. A description of how AI tools were used

A video or demo is optional. The final submission form will be added to the competition page near the deadline.

## How entries are judged

No fixed weighting. In order of emphasis on the page:

- **Flexibility:** can the chip be reprogrammed for protocols it was not designed for?
- Which protocols are demonstrated (UART, SPI, I2C first; stretch: low-speed USB, 10 Mbit Ethernet; also JTAG, SWD, PS/2, CAN)
- Anything unique the architecture makes possible
- How it was designed and verified
- The write-up, **weighed heavily**: readability and how clearly new techniques are explained

## Working rules for changes

- Before changing `src/`, `info.yaml`, `src/config.json` or the workflows, check the change against the rules table.
- After any RTL change, run `cd test && make -B` (cocotb) and `cd model && ./run_tests.sh` (OCaml model and compiler), and keep both green.
- Never merge a change that breaks `gds`, `precheck` or `gl_test` on `main`.
- One flow experiment per GDS run, so its effect can be attributed. Record results in the commit or README.
- Keep `README.md`, `docs/info.md` and `info.yaml` consistent with the design: they are part of what is judged.
