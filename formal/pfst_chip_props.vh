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

  // cover: pins really can be driven in each mode, so P1-P4 are not vacuous
  always @(posedge clk) if (f_past_valid) begin
    cover(uio_oe[0] && r_pinmode[0][1:0] == 2'd1);
    cover(uio_oe[0] && r_pinmode[0][1:0] == 2'd2);
    cover(uio_oe[0] && r_pinmode[0][1:0] == 2'd3 && run_q[0]);
    cover(uio_oe[4] && r_pinmode[1][1:0] == 2'd3 && run_q[1]);
  end
