// Formal properties for pfst_chip (host port, registers, pin mux, two cores). Pasted into a copy of
// src/pfst_chip.v by formal/run.sh; src/ is never modified. The SRAM outputs (m_dout) and every input pin
// are free, so these hold whatever the programs, the host and the outside world do.
// Assumption: the proof starts from reset.

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;
  initial assume(!rst_n);

  genvar fc, fp;
  generate for (fc = 0; fc < 2; fc = fc + 1) begin : fprop_core
    for (fp = 0; fp < 4; fp = fp + 1) begin : fprop_pin
      wire [1:0] pm = r_pinmode[fc][2*fp +: 2];
      wire       oe = uio_oe[4*fc + fp];
      always @(posedge clk) if (f_past_valid) begin
        // P1: a pin in PINMODE 0 (input) is never driven
        if (pm == 2'd0) assert(!oe);
        // P2: an open-drain pin (PINMODE 2) only ever drives low, never high
        if (pm == 2'd2 && oe) assert(!uio_out[4*fc + fp]);
        // P3: a row-controlled pin (PINMODE 3) is not driven once its core has been stopped
        if (pm == 2'd3 && !$past(run_q[fc])) assert(!oe);
        // P4: out of reset, no bidirectional pin is driven
        if ($past(!rst_n)) assert(!oe);
      end
    end
  end endgenerate

  // P5: a stopped core has released all its row-controlled drive enables
  always @(posedge clk) if (f_past_valid) begin
    if (!$past(run_q[0])) assert(dirv[0] == 4'd0);
    if (!$past(run_q[1])) assert(dirv[1] == 4'd0);
    // P6: the SRAM write strobe of a core is never high while that core runs
    if (run_q[0]) assert(!m_wen[0]);
    if (run_q[1]) assert(!m_wen[1]);
  end

  // No cover points at this level: reaching a driven pin needs about 100 cycles of SPI configuration, which is
  // beyond what the solver does in reasonable time. That the pins are driven in all three modes is shown by the
  // cocotb tests (test/test_programs.py: push-pull, open drain, and row-controlled pins).

  // ------------------------------------------------------------------ comparator and UOMAP pass-through
  // Expected values are computed independently of the RTL: the comparison by a 9-bit subtraction's borrow,
  // and pin selection by indexing the 16 input pins directly (0-7 ui_in, 8-15 uio_in).
  reg f_past2 = 1'b0;
  always @(posedge clk) if (f_past_valid) f_past2 <= 1'b1;
  wire [15:0] f_pins = {uio_in, ui_in};
  wire [8:0]  f_diff = {1'b0, scr[0]} - {1'b0, thresh};       // borrow (bit 8) set exactly when SCR < THRESH

  always @(posedge clk) if (f_past_valid) begin
    // C1: CMP is registered: it equals VALID[0] AND (SCR[0] < THRESH) as of the previous cycle; 0 out of reset
    if ($past(!rst_n)) assert(!cmp_q);
    else assert(cmp_q == ($past(valid[0]) && $past(f_diff[8])));
  end

  genvar fj;
  generate for (fj = 0; fj < 6; fj = fj + 1) begin : fprop_uo
    wire [7:0] m = uomap[fj];
    always @(posedge clk) if (f_past_valid) begin
      // C2: direct pass-through (UOMAP b7=1, b6=1) is combinational: uo_out follows the selected pin in the same cycle
      if (m[7] && m[6]) assert(uo_out[fj] == f_pins[m[3:0]]);
      // C4: an unmapped output (b7=0, b3=0) is held low
      if (!m[7] && !m[3]) assert(!uo_out[fj]);
    end
    always @(posedge clk) if (f_past2) begin
      // C3: synchronized pass-through (b7=1, b6=0) shows the selected pin exactly two clock edges later,
      //     provided the mapping was not changed in between
      if (m[7] && !m[6] && $past(m) == m && $past(m, 2) == m && $past(rst_n) && $past(rst_n, 2))
        assert(uo_out[fj] == $past(f_pins[m[3:0]], 2));
    end
  end endgenerate
