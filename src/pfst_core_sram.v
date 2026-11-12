// PFST core, table stored in the IHP 256x32 SRAM macro (spec v0.3 + v1 timing).
//
// The macro's output register (A_DOUT) holds the row in effect and doubles as
// the state register: next-state and next-select come straight from it.
//
// Fetch pipeline ("v1 timing", an amendment to spec section 2):
//   * A read is ISSUED in the LAST cycle of the current row. The macro returns
//     the next row one cycle later, so row k+1 takes effect in the cycle right
//     after row k's last cycle and every row lasts exactly P*(1+wait) cycles.
//   * Inputs and internal sources that form the address are therefore sampled
//     in the last cycle of the previous row (one cycle earlier than the golden
//     model's fetch cycle). Internal sources use POST-operation values, so a
//     row of length 1 (wait=0, P=1) still sees the effect of its own op.
//   * Outputs are registered: a row's pins appear one cycle after it takes
//     effect.
//
// Word layout (low to high), WORD = S+23 = 29 bits in a 32-bit macro word:
//   selB[1:0] selA[3:2] op[5:4] osel[6] out[10:7] wait[18:11] next[24:19] dir[28:25]
// dir (v1.1): per-row drive enable, used only by pins in PINMODE 3; 0 in every older table.
// Slot sources: A: 0=IN0 1=IN1 2=TX_FULL 3=IN2 ; B: 0=CNT_ZERO 1=OBIT 2=CMP 3=IN3
`default_nettype none

module pfst_core_sram #(
  parameter S = 6                       // state bits; table = 4*2**S = 256 rows
) (
  input  wire              clk,
  input  wire              rst_n,
  input  wire              restart,     // host RESTART (also clears the TX FIFO)
  input  wire              run,         // low = halted; rising edge starts from the start state

  input  wire [7:0]        p_val,       // prescaler P, 0 means 256
  input  wire              msb_first,
  input  wire [1:0]        reset_sel_a,
  input  wire [1:0]        reset_sel_b,
  input  wire [3:0]        out_init,    // pin values while stopped and after RESTART
  input  wire              flag_mode,   // out[3] of a fetched row sets sticky FLAG
  input  wire [7:0]        done_state,  // fetching a row of this state sets sticky DONE (0xFF = none)
  input  wire              rx_clear,    // host READ_SCR: clear RX_VALID

  input  wire [3:0]        raw_in,      // IN0..IN3, unsynchronized
  input  wire              cmp,         // on-chip comparator bit, already registered

  input  wire              tx_push,
  input  wire [7:0]        tx_push_data,
  output wire              tx_full_o,
  output wire              tx_ovr_o,
  output reg               rx_valid_o,
  output reg  [7:0]        scr_o,
  output wire [3:0]        out_o,
  output reg  [3:0]        dir_o,       // per-row drive enable of out[3:0] (PINMODE 3 pins)
  output reg               done_o,
  output reg               flag_o,
  output reg               rx_ovr_o,
  output reg               valid_o,     // SAVE seen since reset (feeds the comparator)
  output wire [S-1:0]      state_o,
  output wire [1:0]        tx_level_o,

  // table load, only while halted (macro is single-port)
  input  wire              ld_en,
  input  wire              ld_ren,      // host table read (core halted)
  input  wire [S+1:0]      ld_addr,
  input  wire [31:0]       ld_data,

  // SRAM macro interface (connect to RM_IHPSG13_1P_256x32_c2_bm_bist)
  output wire              mem_men,
  output wire              mem_wen,
  output wire              mem_ren,
  output wire [S+1:0]      mem_addr,
  output wire [31:0]       mem_din,
  input  wire [31:0]       mem_dout
);

  localparam HOLD = 2'd0, SHIFT = 2'd1, LOAD = 2'd2, SAVE = 2'd3;

  // ------------------------------------------------------------ row fields
  wire [31:0]  R       = mem_dout;
  wire [1:0]   r_selb  = R[1:0];
  wire [1:0]   r_sela  = R[3:2];
  wire [1:0]   r_op    = R[5:4];
  wire         r_osel  = R[6];
  wire [3:0]   r_out   = R[10:7];
  wire [7:0]   r_wait  = R[18:11];
  wire [S-1:0] r_next  = R[S+18:19];
  wire [3:0]   r_dir   = R[S+22:S+19];

  // ------------------------------------------------------------ state
  wire halt = !rst_n || restart || !run;      // run low acts like restart for control
  reg  first;                                 // mem_dout holds a newly read row
  reg  rowv;                                  // a row is in effect
  reg  boot;                                  // first read of a run still to issue
  reg  [7:0] wcnt_q;
  reg  [8:0] sub_q;

  reg  [7:0] sr;
  reg        obit;
  reg  [3:0] cnt;
  reg  [3:0] out_reg;
  reg  [3:0] in_sync, in_sync2;

  reg  [7:0] tx_reg, tx_q0, tx_q1;
  reg        tx_full;
  reg  [1:0] tx_qlevel;
  reg        tx_ovr;

  assign out_o      = out_reg;
  assign state_o    = (first || rowv) ? r_next : {S{1'b0}};
  assign tx_level_o = tx_full ? (tx_qlevel + 2'd1) : 2'd0;
  assign tx_full_o = tx_full;
  assign tx_ovr_o  = tx_ovr;

  // ------------------------------------------------------------ op effects
  wire do_op    = first && !halt;          // a row's op never takes effect in a halting cycle
  wire do_shift = do_op && (r_op == SHIFT);
  wire do_load  = do_op && (r_op == LOAD);
  wire do_save  = do_op && (r_op == SAVE);

  wire        shin      = in_sync2[0];
  wire        sh_obit   = msb_first ? sr[7] : sr[0];
  wire [7:0]  sh_sr     = msb_first ? {sr[6:0], shin} : {shin, sr[7:1]};
  wire        n_obit    = do_shift ? sh_obit : obit;
  wire [7:0]  n_sr      = do_shift ? sh_sr : (do_load ? tx_reg : sr);
  wire [3:0]  n_cnt     = do_load ? 4'd8 :
                          (do_shift ? ((cnt == 4'd0) ? 4'd0 : cnt - 4'd1) : cnt);

  // TX FIFO: pop (LOAD) first, then push, as in the golden model's ordering.
  wire pop = do_load;
  wire [7:0] reg_after_pop   = pop ? ((tx_qlevel != 2'd0) ? tx_q0 : tx_reg) : tx_reg;
  wire [7:0] q0_after_pop    = pop ? tx_q1 : tx_q0;
  wire       full_after_pop  = pop ? (tx_qlevel != 2'd0) : tx_full;
  wire [1:0] level_after_pop = pop ? (tx_qlevel - (tx_qlevel != 2'd0)) : tx_qlevel;
  wire push_fits_reg  = tx_push && !full_after_pop;
  wire push_fits_q0   = tx_push && full_after_pop && (level_after_pop == 2'd0);
  wire push_fits_q1   = tx_push && full_after_pop && (level_after_pop == 2'd1);
  wire push_overflow  = tx_push && full_after_pop && (level_after_pop == 2'd2);
  wire [7:0] tx_reg_n   = push_fits_reg ? tx_push_data : reg_after_pop;
  wire [7:0] tx_q0_n    = push_fits_q0  ? tx_push_data : q0_after_pop;
  wire [7:0] tx_q1_n    = push_fits_q1  ? tx_push_data : tx_q1;
  wire       tx_full_n  = full_after_pop || tx_push;
  wire [1:0] tx_qlevel_n = (push_fits_q0 || push_fits_q1) ? level_after_pop + 2'd1
                                                          : level_after_pop;

  // ------------------------------------------------------------ row timer
  // remaining cycles after the current one = rem_w*P + rem_s (no multiplier)
  wire [8:0] p_eff = (p_val == 8'd0) ? 9'd256 : {1'b0, p_val};
  wire [8:0] p_m1  = p_eff - 9'd1;
  wire [7:0] rem_w = first ? r_wait : wcnt_q;
  wire [8:0] rem_s = first ? p_m1   : sub_q;
  wire       last  = (rem_w == 8'd0) && (rem_s == 9'd0);
  wire [8:0] dec_s = (rem_s != 9'd0) ? rem_s - 9'd1 : p_m1;
  wire [7:0] dec_w = (rem_s != 9'd0) ? rem_w : rem_w - 8'd1;

  // ------------------------------------------------------------ next address
  wire [S-1:0] cur_st  = boot ? {S{1'b0}} : r_next;
  wire [1:0]   cur_sa  = boot ? reset_sel_a : r_sela;
  wire [1:0]   cur_sb  = boot ? reset_sel_b : r_selb;
  wire a_val = (cur_sa == 2'd0) ? in_sync2[0] :
               (cur_sa == 2'd1) ? in_sync2[1] :
               (cur_sa == 2'd2) ? full_after_pop : in_sync2[2];
  wire b_val = (cur_sb == 2'd0) ? (n_cnt == 4'd0) :
               (cur_sb == 2'd1) ? n_obit :
               (cur_sb == 2'd2) ? cmp : in_sync2[3];

  wire cur_is_done = ({{(8-S){1'b0}}, cur_st} == done_state);
  reg  row_done_q;
  wire issue = run && (boot ? !(first || rowv)       // boot read: nothing in flight
                            : ((first || rowv) && last));

  assign mem_men  = run ? issue : (ld_en || ld_ren);
  assign mem_ren  = run ? issue : ld_ren;
  assign mem_wen  = !run && ld_en;
  assign mem_addr = run ? {cur_st, a_val, b_val} : ld_addr;
  assign mem_din  = ld_data;

  // ------------------------------------------------------------ outputs
  wire [3:0] out_field = {r_out[3:1], r_osel ? n_obit : r_out[0]};

  // ------------------------------------------------------------ sequential
  always @(posedge clk) begin
    // synchronizers run always
    in_sync2 <= in_sync;
    in_sync  <= raw_in;

    // RESTART (spec section 6): flush FIFO, clear DONE/FLAG/TX_OVR. It does NOT touch
    // SCR / RX_VALID / RX_OVR / VALID: those are host-managed (READ_SCR) or cleared by reset.
    if (!rst_n || restart) begin
      tx_full <= 1'b0; tx_qlevel <= 2'd0; tx_ovr <= 1'b0;
      tx_reg <= 8'd0; tx_q0 <= 8'd0; tx_q1 <= 8'd0;   // defined LOAD from an empty FIFO
      done_o <= 1'b0; flag_o <= 1'b0;
    end else begin
      tx_reg <= tx_reg_n; tx_q0 <= tx_q0_n; tx_q1 <= tx_q1_n;
      tx_full <= tx_full_n; tx_qlevel <= tx_qlevel_n;
      if (push_overflow) tx_ovr <= 1'b1;
      if (do_op && row_done_q) done_o <= 1'b1;
      if (do_op && flag_mode && r_out[3]) flag_o <= 1'b1;
    end
    if (!rst_n) begin
      rx_valid_o <= 1'b0; scr_o <= 8'd0; rx_ovr_o <= 1'b0; valid_o <= 1'b0;
    end else begin
      if (rx_clear) rx_valid_o <= 1'b0;
      if (do_save) begin
        scr_o <= sr; rx_valid_o <= 1'b1; valid_o <= 1'b1;
        if (rx_valid_o) rx_ovr_o <= 1'b1;
      end
    end
    if (!halt) row_done_q <= issue ? cur_is_done : row_done_q;
    else row_done_q <= 1'b0;

    if (halt) begin
      first <= 1'b0; rowv <= 1'b0; boot <= 1'b1;
      wcnt_q <= 8'd0; sub_q <= 9'd0;
      sr <= 8'd0; obit <= 1'b0; cnt <= 4'd0; out_reg <= out_init; dir_o <= 4'd0;   // stopped: row-controlled pins released
    end else begin
      first <= issue;
      if (boot && issue) boot <= 1'b0;
      if (first) rowv <= 1'b1;
      wcnt_q <= dec_w;
      sub_q  <= dec_s;
      if (first) begin
        sr <= n_sr; obit <= n_obit; cnt <= n_cnt;
        out_reg <= out_field;
        dir_o   <= r_dir;
      end
    end
  end

endmodule
`default_nettype wire
