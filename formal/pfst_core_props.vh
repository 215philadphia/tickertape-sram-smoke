// Formal properties for pfst_core_sram.
//
// formal/run.sh pastes this file into a COPY of src/pfst_core_sram.v, just before its `endmodule`, so the
// properties can see the core's internal registers. src/ is never modified and none of this is synthesized.
//
// The SRAM macro sits outside the core, and mem_dout is a free input here: every property below holds for
// EVERY possible table contents, i.e. for every program, not just the ones we have written.
//
// Assumptions (the only ones; each is also stated in formal/README.md):
//   A1. The proof starts from reset (rst_n low in the first cycle).
//   A2. P (p_val) is not changed while the core is running. The host sets P while the core is stopped; the
//       RTL does not enforce this. P is otherwise arbitrary: f_p below is any constant.

  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  initial assume(!rst_n);                                    // A1

  (* anyconst *) reg [7:0] f_p;                              // A2: an arbitrary, fixed prescaler value
  always @* if (run) assume(p_val == f_p);

  wire [17:0] f_pe = (f_p == 8'd0) ? 18'd256 : {10'd0, f_p};   // effective P: 0 means 256

  // ------------------------------------------------------------------ row timer: exact length
  // Independent count of how long the current row has been in effect, and of the wait field it began with.
  reg  [17:0] f_age_q;
  reg  [7:0]  f_w_q;
  wire [17:0] f_age   = first ? 18'd1 : f_age_q + 18'd1;       // this cycle is the f_age-th cycle of the row
  wire [7:0]  f_w     = first ? r_wait : f_w_q;
  wire [17:0] f_total = f_pe * ({10'd0, f_w} + 18'd1);         // P x (1 + wait)
  always @(posedge clk) begin f_age_q <= f_age; f_w_q <= f_w; end

  wire f_inrow = !halt && (first || rowv);                     // a row is in effect and the core is not halting

  always @(posedge clk) if (f_past_valid) begin
    // ---- control-state invariants (needed to make the timer proof inductive)
    assert(boot || first || rowv);
    assert(!(boot && first));
    assert(!(boot && rowv));
    if (!first && rowv) begin
      assert({9'd0, sub_q} < f_pe);                                                // sub-counter within one prescaler period
      assert(f_age_q + 18'd1 + {10'd0, wcnt_q} * f_pe + {9'd0, sub_q} == f_total);   // elapsed + remaining == length
    end

    // ---- T1: every row lasts exactly P x (1 + wait) cycles
    if (f_inrow &&  last) assert(f_age == f_total);              // ends on exactly the right cycle ...
    if (f_inrow && !last) assert(f_age <  f_total);              // ... and never runs past it (timer never underflows)

    // ---- T2: the next row is read in the last cycle and takes effect in the very next one (no gap)
    if (f_inrow &&  last) assert(mem_men && mem_ren);
    if (f_inrow && !last) assert(!(mem_men && mem_ren));         // no read while a row is still in progress
    if ($past(f_inrow && last)) assert(first);

    // ---- T3: the table cannot be written while the core runs
    assert(!(run && mem_wen));

    // ---- T4: any halt (reset, RESTART or run low) puts the core in its start state with pins at OUT_INIT
    if ($past(halt)) begin
      assert(!first && !rowv && boot);
      assert(wcnt_q == 8'd0 && sub_q == 9'd0 && sr == 8'd0 && cnt == 4'd0 && !obit);
      assert(out_o == $past(out_init));
      assert(dir_o == 4'd0);                                     // row-controlled pins released
      assert(state_o == {S{1'b0}});
    end
  end

  // ------------------------------------------------------------------ TX FIFO: a 3-byte queue scoreboard
  // A simple queue model driven by the same inputs. pop (LOAD) happens before push, as in the RTL.
  reg [7:0] fq0, fq1, fq2, fstale;
  reg [1:0] fcnt;
  reg       fovr;
  reg [1:0] c_n;
  reg [7:0] a0_n, a1_n, a2_n, st_n;
  reg       ov_n;
  always @(posedge clk) begin
    c_n = fcnt; a0_n = fq0; a1_n = fq1; a2_n = fq2; st_n = fstale; ov_n = fovr;
    if (!rst_n || restart) begin
      c_n = 2'd0; ov_n = 1'b0; st_n = 8'd0;
    end else begin
      if (do_load && c_n != 2'd0) begin st_n = a0_n; a0_n = a1_n; a1_n = a2_n; c_n = c_n - 2'd1; end
      if (tx_push) begin
        if (c_n < 2'd3) begin
          if (c_n == 2'd0) a0_n = tx_push_data;
          if (c_n == 2'd1) a1_n = tx_push_data;
          if (c_n == 2'd2) a2_n = tx_push_data;
          c_n = c_n + 2'd1;
        end else ov_n = 1'b1;
      end
    end
    fcnt <= c_n; fq0 <= a0_n; fq1 <= a1_n; fq2 <= a2_n; fstale <= st_n; fovr <= ov_n;
  end

  always @(posedge clk) if (f_past_valid) begin
    assert(tx_qlevel <= 2'd2);
    if (!tx_full) assert(tx_qlevel == 2'd0);
    // T5: the RTL FIFO matches the model for every possible push/pop sequence
    assert(tx_level_o == fcnt);                                  // level 0..3
    assert(tx_ovr_o == fovr);                                    // overflow flag: a push into a full FIFO, nothing else
    if (fcnt > 2'd0) assert(tx_reg == fq0);                      // oldest byte first
    if (fcnt > 2'd1) assert(tx_q0  == fq1);
    if (fcnt > 2'd2) assert(tx_q1  == fq2);
    if (fcnt == 2'd0) assert(tx_reg == fstale);                  // LOAD from an empty FIFO returns the last byte loaded (0 after reset/RESTART)
  end

  // ------------------------------------------------------------------ SCR / RX flags / sticky flags
  always @(posedge clk) if (f_past_valid) begin
    // T6: SAVE copies SR to SCR and sets RX_VALID and VALID
    if ($past(do_save && rst_n)) assert(scr_o == $past(sr) && rx_valid_o && valid_o);
    // T7: a SAVE while RX_VALID is still set raises RX_OVR; RX_OVR is raised by nothing else
    if ($past(do_save && rst_n && rx_valid_o)) assert(rx_ovr_o);
    if ($past(rst_n) && rx_ovr_o && !$past(rx_ovr_o)) assert($past(do_save && rx_valid_o));
    // T8: RESTART keeps SCR (spec v1.1 section 5); only reset clears it. RX_VALID changes only by READ_SCR.
    if ($past(rst_n && restart)) begin
      assert(scr_o == $past(scr_o));
      assert(rx_valid_o == ($past(rx_valid_o) && !$past(rx_clear)));
      assert(rx_ovr_o == $past(rx_ovr_o) && valid_o == $past(valid_o));
    end
    // T9: DONE and FLAG are sticky until RESTART or reset
    if ($past(rst_n && !restart && done_o)) assert(done_o);
    if ($past(rst_n && !restart && flag_o)) assert(flag_o);
    if ($past(!rst_n || restart)) assert(!done_o && !flag_o);
  end

  // ------------------------------------------------------------------ cover: the properties above are not vacuous
  always @(posedge clk) if (f_past_valid) begin
    cover(f_inrow && first && last && f_total == 18'd1);                 // a one-cycle row
    cover(f_inrow && !first && last && f_total == 18'd12);               // a 12-cycle row, ending mid-way
    cover(f_inrow && last && f_total > 18'd12 && f_total <= 18'd40);
    cover(do_load && fcnt == 2'd3);                                      // LOAD from a full FIFO
    cover(do_load && fcnt == 2'd0);                                      // LOAD from an empty FIFO
    cover(fovr);                                                         // FIFO overflow
    cover(do_save && rx_valid_o);                                        // SAVE overrun
    cover(done_o && !restart);
    cover(rst_n && restart && $past(rowv));                              // RESTART in the middle of a program
  end
