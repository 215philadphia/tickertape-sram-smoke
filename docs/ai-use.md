# Use of AI tools

The competition allows AI tools and asks entrants to describe how they used them. This page records that
use.

## Recorded in this repository

Commits made with Claude Code (Anthropic) carry a `Co-Authored-By: Claude` trailer and a link to the
session. To list them:

```bash
git log --grep="Co-Authored-By: Claude" --format="%h %ad %s" --date=short
```

Work done this way (each change goes to the author for review before it is merged):

| Date | Work | How the result was checked |
|---|---|---|
| 2026-11-13 | README rewrite for the PFST design; `.gitignore` for model build output | RTL tests (5/5) and model tests (0 failures) run before writing; README facts checked against the source |
| 2026-11-13 | Signoff results in the README, read from the CI results branch of gds run 28 | Numbers copied from the published timing, precheck and LVS reports |
| 2026-11-13 | Comparison of the cap/slew/fanout experiment branches, and a post-global-routing design-repair experiment (`RUN_POST_GRT_DESIGN_REPAIR`) | LibreLane variable names and step order checked against LibreLane's source; result judged by the GDS run |
| 2026-11-13 | `CLAUDE.md` (competition rules applied to this repo) and the documentation in `docs/` (`architecture.md`, `toolchain.md`, `verification.md`, this page) | Every statement checked against the RTL, the compiler, the tests and the competition page |
| 2026-11-13 | `test/test_programs.py`: every compiled program run on the chip RTL, with test-side decoders and an I2C target | Run on Icarus Verilog; each test also checked to fail on a deliberately broken table |
| 2026-11-13 | `ps2_rx_dsl`, a PS/2 receiver in the DSL (parity carried in the state number), with model and RTL tests | Passes on the golden model and the RTL; a table that skips the parity check fails the test |
| 2026-11-13 | "At a glance" overview in the README | Each claim linked to the test or document that supports it |
| 2026-11-13 | `docs/design-evolution.md`, comparing the author's original pitch with the built design | Each difference checked against the RTL, compiler and tests; reasons not stated in the source are marked as our reading |
| 2026-11-13 | `docs/applications.md`: realistic uses of the chip and where its ideas apply in trading hardware | Claims about the chip linked to the tests and documents behind them; limits stated explicitly |

## Earlier work

Work before 13 November 2026 (the specification, the RTL, the Python reference model, the OCaml golden
model and compiler, the tests and the flow configuration) was developed with a mixture of AI tools:
**Claude (Anthropic)** running in a GitHub Codespace connected to this repository, together with
**ChatGPT (OpenAI)**, **Gemini (Google)** and **Grok (xAI)**. Files were pushed to and pulled from
GitHub through the Codespace. Those commits carry no `Co-Authored-By` trailer, so the history does not mark
them individually as AI-assisted; this section is the record instead. The concept itself originated with
David Cox.

The same rule applied as in the later work: a result was accepted only when independent checks agreed.
The OCaml golden model is checked bit-exact against the Python model, the protocol references were
written from the protocol specifications rather than from either model, the compiler's static checks
are tested with programs that must be rejected, and the RTL is tested through its pins and at gate
level on the Tiny Tapeout flow ([verification.md](verification.md)).

## Principles followed

- The author decides what is merged; AI-made changes go through pull requests.
- AI-written claims about the design are checked against the source, tests or reports before they are
  committed.
- Verification evidence comes from tools (simulators, the OCaml checks, the Tiny Tapeout flow), not from
  an AI's description of the design.
