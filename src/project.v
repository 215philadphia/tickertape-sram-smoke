/*
 * TickerTape-Out Gate 0 smoke test: one IHP RM_IHPSG13_1P_256x32_c2_bm_bist
 * macro through the Tiny Tapeout CMOS5L flow.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Modes (uio_in[1:0], synchronized):
 *   00 IDLE   uo_out = 0
 *   01 TEST   two-pass write/read self-test of all 256 words
 *             uo_out = {done, pass, err_count[5:0]}
 *   10 CHASE  A_ADDR <= A_DOUT[7:0] every cycle (the PFST next-state loop:
 *             SRAM output register used as the state register)
 *             uo_out = A_DOUT[7:0]; after TEST, memory holds next = addr+1,
 *             so uo_out counts 0..255 at the clock rate
 *   11 READ   A_ADDR = ui_in, uo_out = byte uio_in[3:2] of A_DOUT
 */
`default_nettype none

module tt_um_tickertape_sram_smoke (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  localparam M_IDLE = 2'd0, M_TEST = 2'd1, M_CHASE = 2'd2, M_READ = 2'd3;

  // ---- input synchronizers ----------------------------------------------
  reg [3:0] ctl_s1, ctl_s2;
  always @(posedge clk) begin
    ctl_s1 <= uio_in[3:0];
    ctl_s2 <= ctl_s1;
  end
  wire [1:0] mode = ctl_s2[1:0];
  wire [1:0] bsel = ctl_s2[3:2];

  // ---- test pattern -----------------------------------------------------
  // Low byte is a next-pointer (a+1) so CHASE walks every address.
  function [31:0] pattern(input [7:0] a, input inv);
    pattern = {a ^ 8'hFF, a ^ 8'h5A, a, a + 8'd1} ^ {32{inv}};
  endfunction

  // ---- self-test FSM ----------------------------------------------------
  localparam S_IDLE = 3'd0, S_WRITE = 3'd1, S_READ = 3'd2, S_DRAIN = 3'd3,
             S_DONE = 3'd4;

  reg  [2:0]  state;
  reg  [7:0]  addr;
  reg         pass_inv;     // pass 0: inverted pattern, pass 1: true pattern
  reg         rd_valid;
  reg  [7:0]  rd_addr;
  reg  [5:0]  err_count;
  reg         done;

  wire [31:0] dout;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      addr      <= 8'd0;
      pass_inv  <= 1'b1;
      rd_valid  <= 1'b0;
      rd_addr   <= 8'd0;
      err_count <= 6'd0;
      done      <= 1'b0;
    end else if (mode != M_TEST) begin
      state    <= S_IDLE;
      rd_valid <= 1'b0;
    end else begin
      // Compare the word read on the previous cycle.
      if (rd_valid && dout != pattern(rd_addr, pass_inv) && err_count != 6'h3F)
        err_count <= err_count + 6'd1;
      rd_valid <= 1'b0;

      case (state)
        S_IDLE: begin
          addr      <= 8'd0;
          pass_inv  <= 1'b1;
          err_count <= 6'd0;
          done      <= 1'b0;
          state     <= S_WRITE;
        end
        S_WRITE: begin
          addr <= addr + 8'd1;
          if (addr == 8'hFF) state <= S_READ;
        end
        S_READ: begin
          rd_valid <= 1'b1;
          rd_addr  <= addr;
          addr     <= addr + 8'd1;
          if (addr == 8'hFF) state <= S_DRAIN;
        end
        S_DRAIN: begin  // let the last compare happen before switching pass
          if (pass_inv) begin
            pass_inv <= 1'b0;
            state    <= S_WRITE;
          end else begin
            done  <= 1'b1;
            state <= S_DONE;
          end
        end
        default: ;  // S_DONE: hold
      endcase
    end
  end

  // ---- SRAM port muxing -------------------------------------------------
  wire test_wr = (mode == M_TEST) && (state == S_WRITE);
  wire test_rd = (mode == M_TEST) && (state == S_READ);

  reg  [7:0] sram_addr;
  always @* begin
    case (mode)
      M_CHASE: sram_addr = dout[7:0];
      M_READ:  sram_addr = ui_in;
      default: sram_addr = addr;
    endcase
  end

  wire sram_wen = test_wr;
  wire sram_ren = test_rd || (mode == M_CHASE) || (mode == M_READ);
  wire sram_men = sram_wen || sram_ren;

  (* keep *)
  RM_IHPSG13_1P_256x32_c2_bm_bist sram0 (
      .A_CLK      (clk),
      .A_MEN      (sram_men),
      .A_WEN      (sram_wen),
      .A_REN      (sram_ren),
      .A_ADDR     (sram_addr),
      .A_DIN      (pattern(addr, pass_inv)),
      .A_DLY      (1'b1),              // must be tied high (IHP model check)
      .A_DOUT     (dout),
      .A_BM       (32'hFFFF_FFFF),
      .A_BIST_CLK (1'b0),
      .A_BIST_EN  (1'b0),
      .A_BIST_MEN (1'b0),
      .A_BIST_WEN (1'b0),
      .A_BIST_REN (1'b0),
      .A_BIST_ADDR(8'd0),
      .A_BIST_DIN (32'd0),
      .A_BIST_BM  (32'd0)
  );

  // ---- outputs ----------------------------------------------------------
  reg [7:0] out_r;
  always @* begin
    case (mode)
      M_TEST:  out_r = {done, done && (err_count == 6'd0), err_count};
      M_CHASE: out_r = dout[7:0];
      M_READ:  out_r = dout[8*bsel +: 8];
      default: out_r = 8'd0;
    endcase
  end

  assign uo_out  = out_r;
  assign uio_out = 8'd0;
  assign uio_oe  = 8'd0;

  wire _unused = &{ena, uio_in[7:4], 1'b0};

endmodule
