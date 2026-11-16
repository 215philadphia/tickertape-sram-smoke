# 10BASE-T Ethernet: what the chip can do, and what it cannot

10 Mbit Ethernet is one of the competition's stretch protocols. This page reports how far the fabricated
design reaches into it **without any change to the chip**, measures where it stops, and sketches what a
second version would need. The demonstrations are new programs for the existing compiler; `src/`,
`src/config.json` and `info.yaml` are untouched, so the signed-off layout is the same.

**The short version.** The chip cannot send or receive a real Ethernet frame. It can do three real pieces of
10BASE-T, at the true line rate:

| Demonstration | Programs (states) | Result on the chip RTL |
|---|---|---|
| Link test pulses | `nlp_timer_dsl` (4) on core 0 + `nlp_pulse_dsl` (2) on core 1 | 100 ns pulses exactly 16.000 ms apart, from the tables alone |
| Manchester transmit at 10 Mb/s | `eth_gate_dsl` (4) on core 0 + `eth_tx_dsl` (24) on core 1 | Preamble, SFD, 1 to 3 host-pushed bytes, start of idle; every edge on the 50 ns grid |
| Frame-start detector | `eth_sfd_dsl` (27) on one core | Pulse 150 to 175 ns after the SFD's last edge; correct for all frames up to ±12.5 ns of edge jitter |

Everything in the "Measured" sections below was run. Everything in "Judgment" and "Untested" was not, and
says so.

## The clock: 40 MHz, not 50

A 10BASE-T bit lasts 100 ns and Manchester code puts an edge in the middle of every bit, so a transmitter
needs 50 ns steps. A row of the PFST lasts a whole number of clock cycles (exactly P x (1 + wait), proved as
T1 in [formal/README.md](../formal/README.md); the shortest row is one cycle). At the 50 MHz signoff clock
50 ns is 2.5 cycles, which no row can make. At **40 MHz** it is exactly 2 cycles and a bit is 4.

- All tests on this page run with a 25 ns clock. `info.yaml` still says 50 MHz, the signoff clock.
- Running slower than the signoff clock is safe for setup timing. Hold timing does not depend on the clock
  period.
- The demo board sets the project clock. Tiny Tapeout's clock specification gives the range as 1 Hz to
  66.5 MHz, made by the board's RP2 microcontroller dividing its system clock
  ([tinytapeout.com/specs/clock](https://www.tinytapeout.com/specs/clock/); read as a search-result excerpt,
  the page itself was not reachable from the session that wrote this).
- Whether 40 MHz is exact: in the board firmware, `clock_project_PWM` calls `_get_best_rp2040_freq`, which
  scans RP2 system clocks from 133 MHz downward in 1 MHz steps for one that an even divider turns into the
  requested frequency. For 40 MHz the first match is 80 MHz divided by 2
  ([tt-micropython-firmware](https://github.com/TinyTapeout/tt-micropython-firmware), `src/ttboard/demoboard.py`,
  commit `15ba5ce`). This was worked out by reading the code, not by running it on a board. **Untested on
  hardware.**
- 10BASE-T requires the bit rate within ±0.01%. That depends on the board's crystal, which has not been
  measured.

## Protocol facts used, and their sources

The text of IEEE 802.3 could not be opened from the session that did this work (the network policy blocked
it). The clause numbers below are where these rules are in the standard to the best of our knowledge; the
values were checked against the secondary sources listed, found by web search. A reader with the standard
should check them, and the tests take these numbers from one place (`test/test_ethernet.py`, top of file).

| Fact | Value used | IEEE 802.3 clause | Checked against |
|---|---|---|---|
| Preamble and start frame delimiter | 7 octets `10101010`, then `10101011`, in transmission order | 3.2.1, 3.2.2 | Patents quoting the standard: "The preamble is at least seven bytes of 10101010. The sfd byte is the pattern 10101011" |
| Bit order | Least significant bit of each octet first | 3.3 | Not found in a source we could read; from memory of the standard |
| Manchester code | A 1 is low then high (rising edge mid-bit); a 0 is high then low | 7.3.1.1 | [Microchip, "IEEE 802.3 Convention"](https://onlinedocs.microchip.com/oxy/GUID-3A005322-7241-4A38-9889-70DEE3EF1259-en-US-3/GUID-717B7771-EAB8-42FF-B9B3-9F88A9897C7C.html): a 1 is a transition from 0 to 1 |
| Link test pulse | Positive only, nominally 100 ns, at most 200 ns; 16 ms ± 8 ms apart | 14.2.1.1, Figure 14-12 | [Wikipedia, Autonegotiation](https://en.wikipedia.org/wiki/Autonegotiation) |
| Start of idle | The line stays high for 2.5 to 4.5 bit times (at least 250 ns) after the last bit | 14.3.1.2.1 | US patent 6,141,352 (2.5 to 4.5 bit times); [TestEquity Ethernet debugging guide](https://assets.testequity.com/te1/Documents/pdf/ethernet-debugging.pdf) (at least 250 ns) |
| Transmit jitter | ±11 ns after the twisted-pair model, ±20 ns without it | 14.3.1.2.3 | [UNH-IOL 10BASE-T overview](https://www.iol.unh.edu/sites/default/files/knowledgebase/ethernet/10basetmau.pdf), [Microchip AN2686](https://ww1.microchip.com/downloads/en/AppNotes/AN2686-Ethernet-Compliance-Test-10BASET-100BASETX-1000BASET.pdf) |
| Receive jitter a station must accept | 13.5 ns | 14.3.1.3.1 | [UNH-IOL MAU test suite v4.1](https://www.iol.unh.edu/sites/default/files/testsuites/ethernet/CL14_MAU/MAU_Test_Suite_v4.1.pdf) |

These sources were read as search-result excerpts, not as full documents.

## Measured: link test pulses

A 10BASE-T port that is not sending frames sends a short positive pulse every 16 ms so the other end knows
the link is up.

**Why it takes both cores.** The pulse must be about 100 ns, so the core that makes it needs P x (1 + wait)
= 4 cycles for that row, which forces P to 4 or less. With P = 4 the longest row is 1024 cycles (25.6 us) and
16 ms is 625 of them. One core has 64 states, and its only counter counts to 8. By our calculation the longest
period a single core can reach this way is about 7 ms, under the 8 ms minimum (calculated, not run).

So the work is split, using the comparator that links the cores:

- **Core 0 is the timer** (`nlp_timer_dsl`, 4 states, P = 256). It raises `CMP` by saving a byte below
  `THRESH` and lowers it by shifting that byte left once and saving again. One state loops seven long rows on
  the bit counter. The row lengths add up to 2500 units of 256 cycles: 640 000 cycles, 16.000 ms at 40 MHz.
- **Core 1 makes the pulse** (`nlp_pulse_dsl`, 2 states, P = 1): one 4-cycle high row per rising edge of
  `CMP`, then it waits for `CMP` to fall.

The host loads the tables, pushes one byte into core 0 and starts the cores. After that it does nothing:
when the FIFO is empty, `LOAD` reloads the same byte for ever.

**Result** (`test_eth_nlp`): pulse width 100.000 ns, pulses 16.000000 ms apart, no negative excursion, and the
pair undriven between pulses. The checker measures widths and intervals from the recorded pin edges and
compares them with the limits in the table above. The period is exact because row lengths are exact; the
test asserts 16 ms to the picosecond.

At the 50 MHz signoff clock the same tables would give 80 ns pulses 12.8 ms apart (calculated, not run).

## Measured: Manchester transmit at 10 Mb/s

`test_eth_tx` sends five frames and decodes each one from the recorded edges of TD+ and TD-.

| Check | Result |
|---|---|
| Preamble | 56 bits `1010...` |
| SFD | `10101011` |
| Data | 1, 2 and 3 host-pushed bytes, least significant bit first, all correct |
| Start of idle | High for 300 ns after the last bit (350 ns counting a final 1's own high half) |
| Edge timing | Every edge exactly on the 50 ns grid: 0 ps error in simulation |
| Length on the wire | 9.1 us for 3 bytes (88 bits plus the start of idle) |

The edge-timing figure is for an ideal simulated clock. On silicon the edges will carry the clock's jitter and
the output pads' rise and fall times, neither of which has been measured.

Two problems had to be worked around.

**1. `OBIT` and `CNT_ZERO` share slot B.** A Manchester bit needs two rows (one per half), and the level of
each depends on the data bit, so each row must branch on `OBIT`. The natural loop also asks "was that the
last bit of the byte?", which is `CNT_ZERO`, and one row cannot branch on both.

- **What fit: unrolling.** The eight bit positions are separate states (`F0`/`S0` to `F7`/`S7`, 16 of the 24
  states), so no counter is needed. The last one reads `OBIT` together with `TX_FULL`, which is in slot A, to
  decide between loading the next byte and ending the frame.
- **What was not needed:** looping the data bit out through a spare pin and reading it back on slot A. It
  would have cost a pin and three cycles of delay, and the unrolled version already fits.

**2. Nothing can count 62 preamble bits.** The preamble is a square wave, two rows repeated 31 times, but the
only counter counts to 8 and reloading it pops the FIFO that holds the data. So core 0 is used as a timer
again (`eth_gate_dsl`, 4 states): one byte pushed into core 0 raises `CMP` for 242 cycles, and the transmitter
on core 1 repeats its square wave while `CMP` is high. It samples `CMP` every 8 cycles, so the gate has
±4 cycles of margin. The two cores talk only through the on-chip comparator, with no pin between them.

**Sending a frame:** push up to 3 bytes into core 1, then one byte into core 0.

## Measured: frame-start detector

`eth_sfd_dsl` watches a receive line, finds the end of the preamble, and pulses an output. Meanwhile UOMAP
forwards the same line to two output pins, so the chip sits in the wire and marks where each frame's data
begins.

**The difficulty.** At 40 MHz the core takes 4 samples per bit. The preamble is a square wave whose runs
last 100 ns; the SFD ends with three 50 ns runs (high, low, high). With edges anywhere against the sample
clock, a 100 ns run reads as 3, 4 or 5 samples and a 50 ns run as 1, 2 or 3. **A run of 3 is ambiguous.**

**The rule.** Pairs of runs are not ambiguous: two short runs span 100 ns (3 to 5 samples together), two
long ones 200 ns (7 to 9). When a low run ends, the frame starts if

> the low run was 1 or 2 samples, or it was 3 and the high run before it was 1 or 2.

This holds as long as no edge is displaced by more than a quarter of a sample period each way, ±12.5 ns.
The rule only applies after 8 valid long runs in a row ("locked"), counted with the bit counter, so a noise
pulse or a link test pulse cannot trigger it. Every row is one cycle; the run length is kept in the state
number.

**How it was tested.** The test builds each waveform from the standard: a frame with a random phase against
the chip clock, a clock offset of up to ±200 ppm (±100 ppm at each end), random data, and two impairments:

- **jitter**: every edge moved independently by up to ±J (uniform, or Gaussian with sigma J/3 clipped at J);
- **duty-cycle distortion**: every rising edge late and every falling edge early by D (highs shortened), or
  the reverse for negative D.

A frame passes if there is exactly one pulse and it rises 150 to 175 ns after the true, displaced last edge
of the SFD. The 25 ns window is the sampling uncertainty of one clock period, so the pulse is **a fixed 6
clock edges after the edge that first samples the new level**.

**On the chip RTL** (`test_eth_sfd`, 40 frames per point):

| Condition | Frames correct |
|---|---|
| No impairment | 40 / 40 |
| Jitter ±4, ±8, ±11 ns (uniform) | 40 / 40 each |
| Duty-cycle distortion +8 ns, -8 ns | 40 / 40 each |
| Jitter ±6 ns (Gaussian) with distortion +4 ns, -4 ns | 40 / 40 each |
| Jitter ±16 ns (beyond the limit; recorded, not required) | 40 / 40 |
| Jitter ±20 ns (beyond the limit; recorded, not required) | 30 / 40, the rest missed |
| Two 50 ns runt pulses and a link test pulse on an idle line | No pulse |
| A preamble that stops without an SFD | No pulse |
| Pass-through, direct | Follows the line within the same cycle |
| Pass-through, synchronized | Follows exactly 2 clock edges later |

**On a Python model, 20 000 frames per point.** RTL simulation is too slow for small failure rates, so
`test/eth_model.py` holds a cycle-accurate model of one core that runs the same compiled table. The RTL test
compares the model with the RTL on every frame it simulates (pulse time, frame by frame, including the
failing ones): they agreed on all of them. The sweep (`python3 test/eth_model.py 20000`):

| Jitter (uniform) | Wrong frames in 20 000 | | Jitter (Gaussian, sigma J/3) | Wrong frames in 20 000 |
|---|---|---|---|---|
| ±0 to ±12.5 ns | 0 | | ±0 to ±13.5 ns | 0 |
| ±13.0 ns | 5 | | ±14 ns | 1 |
| ±13.5 ns | 23 | | ±16 ns | 12 |
| ±14 ns | 96 | | ±18 ns | 61 |
| ±16 ns | 774 | | ±20 ns | 154 |
| ±18 ns | 2148 | | | |
| ±20 ns | 4095 | | | |

| Other conditions | Wrong frames in 20 000 |
|---|---|
| Duty-cycle distortion alone, -12 to +12 ns | 0 at every point |
| Jitter ±4 ns with distortion ±3 or ±6 ns | 0 |
| Jitter ±8 ns with distortion ±3 ns | 0 |
| Jitter ±8 ns (uniform) with distortion -6 ns, +6 ns | 125, 136 |
| Jitter ±8 ns (Gaussian) with distortion -6 ns, +6 ns | 0, 1 |

Nearly all failures are misses: the detector loses lock in the preamble and stays silent. A few fire one run
late. There were 7 double pulses in the whole sweep.

**What this says, plainly.**

- The detector works with no errors up to ±12.5 ns of edge displacement, which is where the arithmetic says
  it must stop. Jitter and distortion add: ±8 ns with 6 ns of distortion is already past the limit.
- A transmitter at the standard's ±11 ns limit is inside that range. The **13.5 ns a receiver must accept is
  just outside it**: 23 wrong frames in 20 000 with uniform jitter. So this is not a compliant 10BASE-T
  receiver front end, and with 4 samples per bit it cannot be made one.
- It detects the frame start only. It does not decode data. Decoding needs the same long-or-short decision on
  every bit, with data-dependent runs and no room left in the table.
- If it starts listening in the middle of a frame, data that happens to look like a preamble followed by two
  short runs will trigger it. A real receiver has the same exposure and relies on carrier sense.

Not modelled: metastability in the 2-flop synchronizer, amplitude noise, and the analog line receiver in
front of the pin (see external hardware).

## Measured: the tests can fail

`test_eth_planted_bugs` breaks each program and requires the same checkers to object. All eleven are caught:

| Program | Planted bug | What the checker reports |
|---|---|---|
| Link pulses | Pulse row 10 cycles long | Pulse 250 ns wide |
| Link pulses | Generator does not wait for `CMP` to fall | A burst of pulses |
| Link pulses | Long timer rows shortened | Pulses 4.576 ms apart |
| Transmit | Gate 8 cycles short | SFD is `10101010`: one preamble bit pair missing |
| Transmit | Data levels swapped | Data inverted |
| Transmit | Core configured MSB first | Bytes bit-reversed |
| Transmit | Row `T3` does not shift | First data bit wrong |
| Transmit | No start-of-idle row | Line not high after the last bit |
| Detector | A 3-sample high run always treated as long | 3 of 40 frames missed at ±11 ns jitter |
| Detector | Lock not required | Fires on runt pulses with no frame |
| Detector | Pulse one cycle late | 40 of 40 pulses outside the window |

Every Ethernet test also fails if any output pin (`uo_out`, `uio_out`, `uio_oe`) shows X or Z once the cores
run.

Gate level: the four tests are in the default test list, so the Tiny Tapeout `gl_test` job runs them on the
placed-and-routed netlist. There the detector uses 10 frames per point, the link test uses 2 pulses, and the
planted-bug test is skipped because it tests the checkers, not the netlist.

## The limits, quantified

| Limit | Number | Consequence |
|---|---|---|
| Host bandwidth | Host SPI is at most 4 MHz at a 50 MHz clock (12.5 clock cycles per SCK), so 3.2 MHz at 40 MHz: 3.2 Mb/s into the FIFO at best. The line takes 10 Mb/s. | The host is at least 3.1 times too slow to feed a frame as it is sent. In the tests one pushed byte takes 2.8 us; one byte on the line takes 0.8 us. |
| TX FIFO | 3 bytes | A frame can carry 3 bytes. The minimum Ethernet frame is 64 bytes from destination address to FCS, 72 with preamble and SFD. |
| Table size | 64 states x 4 rows | A frame stored in the table instead of the FIFO needs one row per run of equal level. 72 bytes are 576 bits: between 576 and 1152 runs, 9 to 18 times the 64 states. |
| CRC-32 | None on the chip | The core has no XOR or feedback path. The host could compute the FCS but cannot deliver it in time. |
| Counting | One counter per core, to 8 | The 62-bit preamble needs the second core as a timer, so a transmitter uses both cores. |
| Receive sampling | 4 samples per bit at 40 MHz; the two run lengths differ by 2 samples | Tolerates ±12.5 ns of edge displacement; the standard's receiver requirement is 13.5 ns. |
| Clock | 40 MHz only | At the 50 MHz signoff clock a half bit is 2.5 cycles. |

## Judgment: what a version 2 would need

**This section is a study. Nothing in it is part of the chip, of `src/`, or of the Tiny Tapeout flow.**

To send real frames a second version needs three blocks the present one lacks:

1. **A frame buffer.** The host writes the frame into an SRAM at its own speed; the chip then reads it at line
   rate. This removes the host-bandwidth and FIFO limits together.
2. **A Manchester serializer** with a real bit and byte counter.
3. **A CRC-32 unit**, so the frame check sequence is computed as the frame is sent.

`study/eth_v2_tx.v` is a sketch of those three plus the preamble, SFD, start of idle and a link-pulse timer
(about 100 lines). `study/run.sh` simulates it once: a 60-byte frame is decoded from its line output and its
FCS matches `zlib.crc32`. It has no receive path.

**Area** (`study/area.sh`: Yosys 0.33, mapped to the IHP SG13G2 standard cells, typical corner; synthesis only):

| Block | Cells | Flip-flops | Cell area |
|---|---|---|---|
| Version-2 transmit sketch | 501 | 87 | 8 312 um² |
| Existing chip logic, same method | 3 319 | 559 | 56 184 um² |

The flow's placed standard-cell area for the existing chip is 7.3% of the 1.208 mm² core, about 88 600 um²:
1.58 times what this synthesis gives, the difference being clock tree, hold and repair buffers. Scaling the
sketch by the same factor gives **about 13 000 um² placed** (an estimate, not a layout).

The frame buffer dominates. Sizes are from the macro abstracts in IHP-Open-PDK (`sg13g2_sram/lef`):

| Buffer | Holds | Macro | Area |
|---|---|---|---|
| Minimum frames only | 256 bytes | `RM_IHPSG13_1P_256x8_c3_bm_bist` | 17 547 um² |
| Any frame up to 1518 bytes | 2048 bytes | `RM_IHPSG13_1P_1024x16_c2_bm_bist` | 79 674 um² |
| Any frame, 8-bit port | 4096 bytes | `RM_IHPSG13_1P_4096x8_c3_bm_bist` | 146 413 um² |

**Fit in 8x4.** The present design uses 14.9% of the core (two 49 488 um² macros and the logic). Adding the
2048-byte buffer and the transmit logic is about 93 000 um², which would bring utilization to about 23%. The
8x4 allocation has room; area is not what stops Ethernet. What it would cost is a third macro to place and
hook up to power, a new signoff, and pins: the sketch uses the same two line pins as the demonstration.

**Not covered by the sketch:** a receiver. A compliant one needs clock recovery with more than 4 samples per
bit (a faster clock, or both clock edges), an address filter and CRC check, and collision detection for half
duplex. We have no estimate for it.

## Untested: external hardware for a board test

**Nothing in this section has been built or measured.** The chip's pins are 3.3 V digital; 10BASE-T is a
transformer-coupled differential line, so a board test needs parts on a Pmod.

| Part | Purpose | Notes |
|---|---|---|
| 10BASE-T transformer (1:1) or an RJ45 jack with integrated magnetics | Isolation and the differential line | Required by the standard |
| Two series resistors, about 50 ohm each, from TD+ (`uio[4]`) and TD- (`uio[5]`) to the transformer | Source termination for the 100 ohm line | Two 3.3 V pins through 100 ohm into a 100 ohm line give about ±1.65 V. From memory the standard asks for 2.2 to 2.8 V peak (14.3.1.2.1), so this is below it; hobby designs that drive a line this way report that many link partners accept it |
| Transmit filter | Removes harmonics of the square edges | Without it the waveform will not meet the transmit template |
| Line receiver: a differential comparator with a squelch threshold, 100 ohm termination | Turns the receive pair into the logic level the detector reads on `ui_in[7]` | The chip has no analog input |
| 40 MHz project clock | Set by the demo board | See "The clock" above |

Even with all of this, a link partner would see link pulses and 3-byte frames it must discard as runts. A
realistic board test is to watch the pulses and a transmitted frame on an oscilloscope or a 10BASE-T analyzer,
and to feed the detector from a real port's transmit pair.

## Reproducing

```bash
cd model && ./run_tests.sh
```

```bash
cd test && make -B COCOTB_TEST_MODULES=test_ethernet
```

```bash
python3 test/eth_model.py 20000
```

```bash
study/run.sh
```

```bash
study/area.sh /path/to/sg13g2_stdcell_typ_1p20V_25C.lib
```

The RTL tests take about 5 minutes; the link-pulse test alone simulates 34 ms.
