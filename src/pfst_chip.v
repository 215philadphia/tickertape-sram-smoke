// TickerTape-Out chip layer (spec v0.3 section 6): host SPI port, registers, pin mux,
// comparator, two pfst_core_sram cores. Memory macros are outside (see tt_um wrapper).
//
// Host port timing mirrors the verified Python model chip.py cycle for cycle:
// 2-flop synchronizers, byte sampled at SCK rising, response driven at SCK falling.
// Documented deviations from chip.py (RTL has a single-port macro per core):
//   * table READ/WRITE only while the core is stopped (READ while running returns 0)
//   * RUN rising edge starts from the start state (no pause/resume mid-program)
`default_nettype none

module pfst_chip (
  input  wire        clk,
  input  wire        rst_n,
  input  wire [7:0]  ui_in,
  input  wire [7:0]  uio_in,
  output wire [7:0]  uo_out,
  output wire [7:0]  uio_out,
  output wire [7:0]  uio_oe,
  // macro buses, core 0 and core 1
  output wire [1:0]  m_men, m_wen, m_ren,
  output wire [15:0] m_addr,
  output wire [63:0] m_din,
  input  wire [63:0] m_dout
);
  // ------------------------------------------------------------ host pins + sync
  reg [1:0] sck_s, mosi_s, cs_s;
  reg       prev_sck;
  wire      sck2 = sck_s[1], mosi2 = mosi_s[1], cs2 = cs_s[1];
  always @(posedge clk) begin
    if (!rst_n) begin sck_s <= 2'b00; mosi_s <= 2'b00; cs_s <= 2'b11; end
    else begin
      sck_s  <= {sck_s[0],  ui_in[4]};
      mosi_s <= {mosi_s[0], ui_in[5]};
      cs_s   <= {cs_s[0],   ui_in[6]};
    end
  end

  // ------------------------------------------------------------ registers
  reg [7:0] r_p   [0:1]; reg [1:0] r_cfg [0:1]; reg [3:0] r_rsel [0:1];
  reg [7:0] r_outmap [0:1], r_pinmode [0:1], r_inmap01 [0:1], r_inmap23 [0:1];
  reg [7:0] r_done_state [0:1]; reg [3:0] r_out_init [0:1];
  reg [1:0] run_q; reg [7:0] thresh, irq_en; reg [3:0] uomap [0:5];

  // core signals
  wire [1:0] tx_full, tx_ovr, rx_valid, done, flag, rx_ovr, valid;
  wire [7:0] scr [0:1];
  wire [3:0] outv [0:1];
  wire [5:0] state_o [0:1];
  wire [3:0] tx_level_w [0:1];
  reg  [1:0] restart_p, rx_clear_p, push_p;
  reg  [7:0] push_data;
  reg  [1:0] ld_en_r, ld_ren_r;
  reg  [7:0] ld_addr_r; reg [31:0] ld_data_r;
  reg  cmp_q;

  function pick_in;                                     // IN source index -> pin value
    input [3:0] idx; input [7:0] ui; input [7:0] uio;
    begin pick_in = idx[3] ? uio[idx[2:0]] : ui[idx[2:0]]; end
  endfunction
  wire [3:0] raw0 = {pick_in(r_inmap23[0][7:4], ui_in, uio_in), pick_in(r_inmap23[0][3:0], ui_in, uio_in),
                     pick_in(r_inmap01[0][7:4], ui_in, uio_in), pick_in(r_inmap01[0][3:0], ui_in, uio_in)};
  wire [3:0] raw1 = {pick_in(r_inmap23[1][7:4], ui_in, uio_in), pick_in(r_inmap23[1][3:0], ui_in, uio_in),
                     pick_in(r_inmap01[1][7:4], ui_in, uio_in), pick_in(r_inmap01[1][3:0], ui_in, uio_in)};

  genvar g;
  generate for (g = 0; g < 2; g = g + 1) begin : core
    wire [1:0] txlvl;
    pfst_core_sram #(.S(6)) u (
      .clk(clk), .rst_n(rst_n), .restart(restart_p[g]), .run(run_q[g]),
      .p_val(r_p[g]), .msb_first(r_cfg[g][0]), .reset_sel_a(r_rsel[g][1:0]), .reset_sel_b(r_rsel[g][3:2]),
      .out_init(r_out_init[g]), .flag_mode(r_cfg[g][1]), .done_state(r_done_state[g]), .rx_clear(rx_clear_p[g]),
      .raw_in(g == 0 ? raw0 : raw1), .cmp(g == 1 ? cmp_q : 1'b0),
      .tx_push(push_p[g]), .tx_push_data(push_data),
      .tx_full_o(tx_full[g]), .tx_ovr_o(tx_ovr[g]), .rx_valid_o(rx_valid[g]), .scr_o(scr[g]),
      .out_o(outv[g]), .done_o(done[g]), .flag_o(flag[g]), .rx_ovr_o(rx_ovr[g]), .valid_o(valid[g]),
      .state_o(state_o[g]), .tx_level_o(txlvl),
      .ld_en(ld_en_r[g]), .ld_ren(ld_ren_r[g]), .ld_addr(ld_addr_r), .ld_data(ld_data_r),
      .mem_men(m_men[g]), .mem_wen(m_wen[g]), .mem_ren(m_ren[g]),
      .mem_addr(m_addr[8*g +: 8]), .mem_din(m_din[32*g +: 32]), .mem_dout(m_dout[32*g +: 32]));
    assign tx_level_w[g] = {2'b00, txlvl};
  end endgenerate

  // comparator: CMP <= VALID & (SCR < THRESH), registered every cycle (core 0 feeds core 1)
  always @(posedge clk) begin
    if (!rst_n) cmp_q <= 1'b0; else cmp_q <= valid[0] && (scr[0] < thresh);
  end

  // ------------------------------------------------------------ register read mux
  function [7:0] rreg;
    input [7:0] a;
    reg c; reg [3:0] r; reg [7:0] ix;
    begin
      c = a[4]; r = a[3:0]; rreg = 8'd0;
      if (a < 8'h20 && !a[5]) begin
        case (r)
          4'd0:  rreg = r_p[c];
          4'd1:  rreg = {6'd0, r_cfg[c][1], r_cfg[c][0]};
          4'd2:  rreg = {4'd0, r_rsel[c]};
          4'd3:  rreg = r_outmap[c];
          4'd4:  rreg = r_pinmode[c];
          4'd5:  rreg = r_inmap01[c];
          4'd6:  rreg = r_inmap23[c];
          4'd7:  rreg = r_done_state[c];
          4'd8:  rreg = {tx_level_w[c][1:0], tx_ovr[c], flag[c], rx_ovr[c], rx_valid[c], done[c], run_q[c]};
          4'd9:  rreg = {2'b00, state_o[c]};
          4'd10: rreg = {4'd0, r_out_init[c]};
          default: rreg = 8'd0;
        endcase
      end else if (a == 8'h20) rreg = thresh;
      else if (a == 8'h21) rreg = irq_en;
      else if (a >= 8'h22 && a <= 8'h27) begin ix = a - 8'h22; rreg = {4'd0, uomap[ix[2:0]]}; end
    end
  endfunction

  // ------------------------------------------------------------ SPI slave
  reg [3:0] bits;  reg [7:0] rx_sh, cmd, addr, pending, txsh, row_lo;
  reg [7:0] bidx;  reg       pending_v, miso, row_hi;     // row is 9 bits: {row_hi,row_lo}
  reg [31:0] word; reg [2:0] nw;
  reg       rd_a, rd_b, rd_c; reg [8:0] rd_row; reg [2:0] rd_nw;   // READ_TABLE staging

  wire [7:0] b8     = {rx_sh[6:0], mosi2};
  wire       rising  = sck2 && !prev_sck;
  wire       falling = !sck2 && prev_sck;
  wire       byte_done = !cs2 && rising && (bits == 4'd7);
  wire [3:0] op_hi  = cmd[7:4];
  wire       cc     = cmd[0];

  wire [7:0] uix = addr - 8'h22;
  integer i;
  always @(posedge clk) begin
    restart_p <= 2'b00; rx_clear_p <= 2'b00; push_p <= 2'b00; ld_en_r <= 2'b00; ld_ren_r <= 2'b00;
    if (!rst_n) begin
      prev_sck <= 1'b0; bits <= 0; rx_sh <= 0; bidx <= 0; pending_v <= 0; pending <= 0; txsh <= 0; miso <= 0;
      rd_a <= 0; rd_b <= 0; rd_c <= 0; nw <= 0; word <= 0; row_lo <= 0; row_hi <= 0; cmd <= 0; addr <= 0;
      run_q <= 2'b00; thresh <= 0; irq_en <= 0; push_data <= 0; ld_addr_r <= 0; ld_data_r <= 0;
      for (i = 0; i < 2; i = i + 1) begin
        r_p[i] <= 8'd1; r_cfg[i] <= 0; r_rsel[i] <= 0; r_outmap[i] <= 8'hE4; r_pinmode[i] <= 0;
        r_inmap01[i] <= 8'h10; r_inmap23[i] <= 8'h32; r_done_state[i] <= 8'hFF; r_out_init[i] <= 0;
      end
      for (i = 0; i < 6; i = i + 1) uomap[i] <= 0;
    end else begin
      prev_sck <= sck2;
      // READ_TABLE staging: cycle 0 issue (ld_ren), cycle 1 latch data
      if (rd_a) begin                                   // t+1: present the read
        ld_ren_r <= cc ? 2'b10 : 2'b01; ld_addr_r <= rd_row[7:0]; rd_a <= 0; rd_b <= 1;
      end else if (rd_b) begin                          // t+2: macro samples the address
        rd_b <= 0; rd_c <= 1;
      end else if (rd_c) begin                          // t+3: macro output register is valid
        rd_c <= 0; pending_v <= 1;
        pending <= (rd_row[8]) ? 8'd0 :
                   (rd_nw[1:0] == 2'd0) ? (cc ? m_dout[63:56] : m_dout[31:24]) :
                   (rd_nw[1:0] == 2'd1) ? (cc ? m_dout[55:48] : m_dout[23:16]) :
                   (rd_nw[1:0] == 2'd2) ? (cc ? m_dout[47:40] : m_dout[15:8])  :
                                          (cc ? m_dout[39:32] : m_dout[7:0]);
      end

      if (cs2) begin                                   // CS high: reset the frame (MISO holds)
        bits <= 0; rx_sh <= 0; bidx <= 0; txsh <= 0; pending_v <= 0; rd_a <= 0; rd_b <= 0; rd_c <= 0;
      end else begin
        if (rising) begin
          rx_sh <= b8; bits <= (bits == 4'd7) ? 4'd0 : bits + 4'd1;
        end else if (falling) begin
          if (pending_v) begin
            miso <= pending[7]; txsh <= {pending[6:0], 1'b0}; pending_v <= 0;
          end else begin
            miso <= txsh[7]; txsh <= {txsh[6:0], 1'b0};
          end
        end
        if (byte_done) begin
          bidx <= (bidx == 8'hFF) ? 8'hFF : bidx + 8'd1;
          pending <= 8'd0; pending_v <= 1;               // default response 0
          if (bidx == 8'd0) begin
            cmd <= b8; nw <= 0;
            if (b8[7:4] == 4'd5) begin
              rx_clear_p[b8[0]] <= 1'b1; pending <= scr[b8[0]];
            end
          end else if (cmd == 8'h01) begin
            if (bidx == 8'd1) addr <= b8;
            else begin
              addr <= addr + 8'd1;
              if (addr < 8'h20 && !addr[5]) begin
                case (addr[3:0])
                  4'd0:  r_p[addr[4]]          <= b8;
                  4'd1:  r_cfg[addr[4]]        <= b8[1:0];
                  4'd2:  r_rsel[addr[4]]       <= b8[3:0];
                  4'd3:  r_outmap[addr[4]]     <= b8;
                  4'd4:  r_pinmode[addr[4]]    <= b8;
                  4'd5:  r_inmap01[addr[4]]    <= b8;
                  4'd6:  r_inmap23[addr[4]]    <= b8;
                  4'd7:  r_done_state[addr[4]] <= b8;
                  4'd10: r_out_init[addr[4]]   <= b8[3:0];
                  default: ;
                endcase
              end else if (addr == 8'h20) thresh <= b8;
              else if (addr == 8'h21) irq_en <= b8;
              else if (addr >= 8'h22 && addr <= 8'h27) uomap[uix[2:0]] <= b8[3:0];
            end
          end else if (cmd == 8'h02) begin
            if (bidx == 8'd1) begin addr <= b8 + 8'd1; pending <= rreg(b8); end
            else begin addr <= addr + 8'd1; pending <= rreg(addr); end
          end else if (op_hi == 4'd1) begin                // WRITE_TABLE
            if (bidx == 8'd1) begin row_lo <= b8; row_hi <= 1'b0; word <= 0; nw <= 0; end
            else begin
              word <= {word[23:0], b8};
              if (nw == 3'd3) begin
                nw <= 0; word <= 0;
                if (!row_hi && !run_q[cc]) begin
                  ld_en_r <= cc ? 2'b10 : 2'b01; ld_addr_r <= row_lo; ld_data_r <= {word[23:0], b8};
                end
                if (row_lo == 8'hFF) row_hi <= 1'b1;
                row_lo <= row_lo + 8'd1;
              end else nw <= nw + 3'd1;
            end
          end else if (op_hi == 4'd2) begin                // READ_TABLE
            pending_v <= 1'b0;
            if (bidx == 8'd1) begin row_lo <= b8; row_hi <= 1'b0; nw <= 3'd1; rd_nw <= 3'd0; rd_row <= {1'b0, b8}; end
            else begin rd_nw <= nw; rd_row <= {row_hi, row_lo};
                       if (nw == 3'd3) begin nw <= 0; row_lo <= row_lo + 8'd1; if (row_lo == 8'hFF) row_hi <= 1'b1; end
                       else nw <= nw + 3'd1; end
            if (run_q[cc]) begin pending <= 8'd0; pending_v <= 1'b1; end   // single-port macro: not readable while running
            else rd_a <= 1'b1;
          end else if (op_hi == 4'd3) begin                // TX_PUSH
            push_p[cc] <= 1'b1; push_data <= b8;
          end else if (op_hi == 4'd4) begin                // CTRL
            if (b8[1]) restart_p[cc] <= 1'b1;
            run_q[cc] <= b8[0];
          end
        end
      end
    end
  end

  // ------------------------------------------------------------ pin muxes + IRQ
  reg [7:0] uo, uio_o, uio_e;
  reg       irq;
  integer c, p, j;
  reg       v;
  always @* begin
    uio_o = 8'd0; uio_e = 8'd0;
    for (c = 0; c < 2; c = c + 1)
      for (p = 0; p < 4; p = p + 1) begin
        v = outv[c][r_outmap[c][2*p +: 2]];
        case (r_pinmode[c][2*p +: 2])
          2'd1: begin uio_e[4*c+p] = 1'b1; uio_o[4*c+p] = v; end
          2'd2: begin uio_e[4*c+p] = !v;   uio_o[4*c+p] = 1'b0; end   // open drain: 1 = release
          default: ;
        endcase
      end
    uo = 8'd0;
    for (j = 0; j < 6; j = j + 1)
      if (uomap[j][3]) uo[j] = outv[uomap[j][2]][uomap[j][1:0]];
    irq = 1'b0;
    for (c = 0; c < 2; c = c + 1)
      irq = irq | (irq_en[4*c] & done[c]) | (irq_en[4*c+1] & rx_valid[c]) | (irq_en[4*c+2] & flag[c]);
    uo[6] = irq; uo[7] = miso;
  end
  assign uo_out = uo; assign uio_out = uio_o; assign uio_oe = uio_e;
endmodule
`default_nettype wire
