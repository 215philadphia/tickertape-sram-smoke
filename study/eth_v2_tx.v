// SPDX-License-Identifier: Apache-2.0
// STUDY ONLY: not part of the TickerTape-Out chip and not in src/ or the Tiny Tapeout flow.
// A sketch of what a second version would add to send real 10BASE-T frames (docs/ethernet.md):
//   * a frame buffer in an SRAM macro that the host fills slowly and the chip reads at line rate,
//   * a Manchester serializer (40 MHz clock: 4 cycles per bit, 2 per half bit),
//   * a CRC-32 unit that appends the frame check sequence,
//   * the preamble, SFD and start-of-idle, and a 16 ms link test pulse timer.
// It exists to be synthesized for an area estimate (study/area.sh) and is simulated once (study/run.sh).
`default_nettype none
module eth_v2_tx #(parameter AW = 11) (
  input  wire          clk,        // 40 MHz
  input  wire          rst_n,
  // host side (slow): write one byte of the frame, set the length, start
  input  wire          wr_en,
  input  wire [AW-1:0] wr_addr,
  input  wire [7:0]    wr_data,
  input  wire [AW-1:0] len,        // bytes in the buffer: destination address .. end of payload (no FCS)
  input  wire          go,
  output wire          busy,
  // frame buffer: a single-port SRAM macro with a registered read (data one cycle after the address)
  output wire          mem_en,
  output wire          mem_we,
  output wire [AW-1:0] mem_addr,
  output wire [7:0]    mem_din,
  input  wire [7:0]    mem_dout,
  // line: TD+ and TD-; both low = no differential voltage
  output reg           td_p,
  output reg           td_n
);
  localparam IDLE = 3'd0, PRE = 3'd1, DATA = 3'd2, FCS = 3'd3, ETD = 3'd4;
  reg [2:0]    st;
  reg [1:0]    ph;                 // cycle within the bit; ph[1] = second half
  reg [5:0]    k;                  // bit index within preamble+SFD (0..63) or FCS (0..31)
  reg [2:0]    bi;                 // bit index within a data byte
  reg [AW-1:0] rd;                 // next byte to read
  reg [7:0]    sr;
  reg [31:0]   crc;
  reg [19:0]   nlp;                // link test pulse timer: 640 000 cycles = 16 ms

  wire last_cycle = (ph == 2'd3);
  wire pre_bit    = (k == 6'd63) | ~k[0];           // 1010...10 then 11
  wire fcs_bit    = ~crc[0];
  wire cur_bit    = (st == PRE) ? pre_bit : (st == DATA) ? sr[0] : fcs_bit;
  wire sending    = (st == PRE) || (st == DATA) || (st == FCS);
  wire last_byte  = (rd == len);

  assign busy     = (st != IDLE);
  assign mem_en   = wr_en | sending;
  assign mem_we   = wr_en & ~busy;
  assign mem_addr = busy ? rd : wr_addr;
  assign mem_din  = wr_data;

  wire nlp_fire = (nlp == 20'd639999);
  always @(posedge clk) begin
    if (!rst_n) begin
      st <= IDLE; ph <= 0; k <= 0; bi <= 0; rd <= 0; sr <= 0; crc <= 32'hFFFFFFFF; td_p <= 0; td_n <= 0; nlp <= 0;
    end else begin
      nlp <= (busy || nlp_fire) ? 20'd0 : nlp + 20'd1;       // a frame also proves the link is alive
      ph  <= busy ? ph + 2'd1 : 2'd0;
      // line: a 1 is LO then HI, a 0 is HI then LO; idle is undriven except for the link test pulse
      if (sending)        begin td_p <= cur_bit ~^ ph[1]; td_n <= cur_bit ^ ph[1]; end
      else if (st == ETD) begin td_p <= 1'b1; td_n <= 1'b0; end
      else                begin td_p <= (nlp < 20'd4); td_n <= 1'b0; end
      case (st)
        IDLE: if (go && len != 0) begin st <= PRE; k <= 0; rd <= 0; crc <= 32'hFFFFFFFF; ph <= 0; end
        PRE:  if (last_cycle) begin
                k <= k + 6'd1;
                if (k == 6'd63) begin st <= DATA; sr <= mem_dout; rd <= rd + 1'b1; bi <= 0; end
              end
        DATA: if (last_cycle) begin
                crc <= {1'b0, crc[31:1]} ^ ((crc[0] ^ sr[0]) ? 32'hEDB88320 : 32'd0);
                bi  <= bi + 3'd1;
                if (bi == 3'd7) begin
                  if (last_byte) begin st <= FCS; k <= 0; end
                  else begin sr <= mem_dout; rd <= rd + 1'b1; end
                end else sr <= {1'b0, sr[7:1]};
              end
        FCS:  if (last_cycle) begin
                crc <= {1'b1, crc[31:1]};
                k   <= k + 6'd1;
                if (k == 6'd31) begin st <= ETD; k <= 0; end
              end
        ETD:  if (last_cycle) begin k <= k + 6'd1; if (k == 6'd2) st <= IDLE; end   // 3 bit times HI
        default: st <= IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
